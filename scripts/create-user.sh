#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/lib/common.sh"

require_command jq "jq CLI not found; install it to run this script."

CURL_TLS_ARGS=()
CURL_CONNECT_ARGS=()

curl_json() {
  local response status body
  response=$(curl --silent --show-error --write-out "\n%{http_code}" "${CURL_TLS_ARGS[@]}" "${CURL_CONNECT_ARGS[@]}" "$@")
  status=${response##*$'\n'}
  body=${response%$'\n'*}

  printf '%s\n%s\n' "${body}" "${status}"

  [[ "${status}" =~ ^2 ]]
}

try_load_admin_credentials_from_secret() {
  local namespace="${1}"
  local org_id="${2}"
  local secret_name="gdcn-org-admin-${org_id}"
  local admin_user_b64 admin_password_b64 admin_user admin_password

  command_exists kubectl || return 1
  command_exists base64 || return 1

  kubectl get secret -n "${namespace}" "${secret_name}" >/dev/null 2>&1 || return 1

  admin_user_b64=$(kubectl get secret -n "${namespace}" "${secret_name}" -o jsonpath='{.data.adminUser}' 2>/dev/null || true)
  admin_password_b64=$(kubectl get secret -n "${namespace}" "${secret_name}" -o jsonpath='{.data.adminPassword}' 2>/dev/null || true)

  if [[ -z "${admin_user_b64}" || -z "${admin_password_b64}" ]]; then
    return 1
  fi

  admin_user=$(printf '%s' "${admin_user_b64}" | base64 -d 2>/dev/null || true)
  admin_password=$(printf '%s' "${admin_password_b64}" | base64 -d 2>/dev/null || true)

  if [[ -z "${admin_user}" || -z "${admin_password}" ]]; then
    return 1
  fi

  GDCN_ADMIN_USER="${admin_user}"
  GDCN_ADMIN_PASSWORD="${admin_password}"
  echo "Using admin credentials from Kubernetes Secret ${namespace}/${secret_name}"
  return 0
}

sanitize_user_id() {
  local value="${1}"
  value=${value//@/.at.}
  value=${value//[^A-Za-z0-9._-]/-}
  printf '%s' "${value}"
}

extract_auth_id() {
  jq -r '.authenticationId // .data.attributes.authenticationId // empty'
}

extract_display_name() {
  jq -r '.displayName // .data.attributes.displayName // empty'
}

is_auth_endpoint_retryable_status() {
  local status="${1:-}"
  case "${status}" in
    401|429|5*|000) return 0 ;;
    *) return 1 ;;
  esac
}

extract_idp_user_info_by_email() {
  local body="${1}"
  local email="${2}"

  printf '%s' "${body}" | jq -r --arg email "${email}" '
    def authId(o): (o.authenticationId // o.id // o.attributes?.authenticationId // o.attributes?.id // o.data?.attributes?.authenticationId // o.data?.id // empty);
    def displayName(o): (o.displayName // o.attributes?.displayName // o.data?.attributes?.displayName // empty);
    def emailValue(o): (o.email // o.attributes?.email // o.data?.attributes?.email // empty);
    def emit(o): "\((authId(o)))\t\((displayName(o)))";
    def byEmail(stream): ([stream | select((emailValue(.) | ascii_downcase) == ($email | ascii_downcase) and (authId(.) | length) > 0) | emit(.)])[0] // empty;

    if type == "object" then
      if (authId(.) | length) > 0 and ((emailValue(.) | length) == 0 or (emailValue(.) | ascii_downcase) == ($email | ascii_downcase)) then
        emit(.)
      elif (.data | type) == "array" then
        byEmail(.data[]?)
      elif (.users | type) == "array" then
        byEmail(.users[]?)
      elif (.items | type) == "array" then
        byEmail(.items[]?)
      elif (.results | type) == "array" then
        byEmail(.results[]?)
      else
        empty
      end
    elif type == "array" then
      byEmail(.[]?)
    else
      empty
    end
  ' 2>/dev/null || true
}

lookup_idp_user_by_email() {
  local encoded_email paths path full http_status response user_info parsed_auth_id parsed_display_name found_auth_without_display retry_attempt
  local max_attempts_per_path retry_sleep_seconds
  found_auth_without_display="false"
  max_attempts_per_path=24
  retry_sleep_seconds=5

  encoded_email=$(urlencode "${GDCN_USER_EMAIL}")
  paths=(
    "/api/v1/auth/users/${encoded_email}"
    "/api/v1/auth/users?email=${encoded_email}"
    "/api/v1/auth/users"
  )

  for path in "${paths[@]}"; do
    retry_attempt=1
    while true; do
      full=$(curl_json -X GET "https://${GDCN_ORG_HOSTNAME}${path}" \
        -H "Authorization: Bearer ${GDCN_BOOT_TOKEN}" \
        -H "Content-type: application/json") || true
      http_status=${full##*$'\n'}
      response=$(printf '%s\n' "${full}" | sed '$d')

      case "${http_status}" in
        2*)
          user_info=$(extract_idp_user_info_by_email "${response}" "${GDCN_USER_EMAIL}")
          if [[ -z "${user_info}" ]]; then
            break
          fi
          parsed_auth_id=${user_info%%$'\t'*}
          parsed_display_name=${user_info#*$'\t'}
          if [[ -n "${parsed_auth_id}" ]]; then
            dex_auth_id="${parsed_auth_id}"
            IDP_DISPLAY_NAME=$(trim "${parsed_display_name}")
            [[ -n "${IDP_DISPLAY_NAME}" ]] || IDP_DISPLAY_NAME=$(printf '%s\n' "${response}" | extract_display_name)
            IDP_DISPLAY_NAME=$(trim "${IDP_DISPLAY_NAME}")
            if [[ -z "${IDP_DISPLAY_NAME}" ]]; then
              found_auth_without_display="true"
              break
            fi
            return 0
          fi
          break
          ;;
        400|404)
          break
          ;;
        *)
          if is_auth_endpoint_retryable_status "${http_status}"; then
            if (( retry_attempt >= max_attempts_per_path )); then
              die "Auth endpoint remained unavailable at ${path} after ${max_attempts_per_path} attempts (last HTTP ${http_status}) while checking existing users."
            fi
            echo -e "Auth endpoint not ready (HTTP ${http_status}), retrying in ${retry_sleep_seconds}s (${retry_attempt}/${max_attempts_per_path})..."
            retry_attempt=$((retry_attempt + 1))
            sleep "${retry_sleep_seconds}"
            continue
          fi
          die "Failed to query existing Dex user (HTTP ${http_status}) on ${path}. Response:\n${response}"
          ;;
      esac
    done
  done

  if [[ "${found_auth_without_display}" == "true" ]]; then
    die "Dex user exists for ${GDCN_USER_EMAIL}, but displayName could not be retrieved from IdP."
  fi

  return 1
}

resolve_existing_dex_user() {
  local dex_response="${1}"
  reuse_existing_user_auth_id "${dex_response}"
  lookup_idp_user_by_email || die "Dex user exists but failed to retrieve displayName for ${GDCN_USER_EMAIL}. Please ensure the IdP user is queryable."
}

derive_org_names_from_display_name() {
  local normalized first_name last_name

  normalized=$(trim "${1:-}")
  if [[ -z "${normalized}" ]]; then
    normalized="${GDCN_USER_EMAIL%@*}"
  fi
  normalized=$(printf '%s' "${normalized}" | tr -s ' ')
  normalized=$(trim "${normalized}")

  first_name="${normalized%% *}"
  if [[ "${normalized}" == *" "* ]]; then
    last_name=$(trim "${normalized#* }")
  else
    last_name=""
  fi

  [[ -n "${first_name}" ]] || first_name="user"
  [[ -n "${last_name}" ]] || last_name="user"

  IDP_DISPLAY_NAME="${normalized}"
  GDCN_USER_FIRSTNAME="${first_name}"
  GDCN_USER_LASTNAME="${last_name}"
}

dex_response_indicates_existing_user() {
  local response="${1}"
  local detail

  detail=$(printf '%s' "${response}" | jq -r '[(.detail // empty), (.message // empty), (.title // empty), (.error // empty), (.error_description // empty)] | join(" ")' 2>/dev/null || true)
  if [[ -z "${detail}" ]]; then
    detail="${response}"
  fi

  detail=$(printf '%s' "${detail}" | tr '[:upper:]' '[:lower:]')
  [[ "${detail}" == *"user already exists"* ]]
}

reuse_existing_user_auth_id() {
  local dex_response="${1}"
  local existing existing_status existing_body local_auth_id

  local_auth_id=$(printf '%s\n' "${dex_response}" | extract_auth_id)
  if [[ -z "${local_auth_id}" ]]; then
    existing=$(curl_json -X GET "https://${GDCN_ORG_HOSTNAME}/api/v1/entities/users/${GDCN_USER_ID_PATH}" \
      -H "Authorization: Bearer ${GDCN_BOOT_TOKEN}" \
      -H "Content-Type: application/vnd.gooddata.api+json") || true
    existing_status=${existing##*$'\n'}
    existing_body=$(printf '%s\n' "${existing}" | sed '$d')
    if [[ "${existing_status}" =~ ^2 ]]; then
      local_auth_id=$(printf '%s\n' "${existing_body}" | extract_auth_id)
    fi
  fi

  [[ -n "${local_auth_id}" ]] || die "Dex user already exists but authenticationId is unknown. Delete the Dex user or retrieve the authenticationId manually before retrying.\nResponse:\n${dex_response}"
  echo -e "\nDex user already exists. Reusing authenticationId."
  dex_auth_id="${local_auth_id}"
}

build_api_token_id() {
  local ts random_suffix
  ts=$(date +%s)
  random_suffix=$(printf '%04d' "$((RANDOM % 10000))")
  printf 'cli-%s-%s' "${ts}" "${random_suffix}"
}

create_user() {
  local payload full http_status dex_response local_auth_id

  payload=$(jq -n \
    --arg email "${GDCN_USER_EMAIL}" \
    --arg password "${GDCN_USER_PASSWORD}" \
    --arg displayName "${DISPLAY_NAME}" \
    '{email: $email, password: $password, displayName: $displayName}')

  printf '\nCreating user...\n'
  for _ in {1..200}; do
    full=$(curl_json -X POST "https://${GDCN_ORG_HOSTNAME}/api/v1/auth/users" \
      -H "Authorization: Bearer ${GDCN_BOOT_TOKEN}" \
      -H "Content-type: application/json" \
      -d "${payload}") || true
    http_status=$(printf '%s\n' "${full}" | tail -n1)
    dex_response=$(printf '%s\n' "${full}" | sed '$d')

    if [[ "${http_status}" =~ ^2 ]]; then
      local_auth_id=$(printf '%s\n' "${dex_response}" | extract_auth_id)
      [[ -n "${local_auth_id}" ]] || die "Dex response missing authenticationId:\n${dex_response}"
      dex_auth_id="${local_auth_id}"
      IDP_DISPLAY_NAME=$(printf '%s\n' "${dex_response}" | extract_display_name)
      IDP_DISPLAY_NAME=$(trim "${IDP_DISPLAY_NAME}")
      [[ -n "${IDP_DISPLAY_NAME}" ]] || IDP_DISPLAY_NAME="${DISPLAY_NAME}"
      return 0
    fi

    case "${http_status}" in
      409)
        resolve_existing_dex_user "${dex_response}"
        return 0
        ;;
      400)
        if dex_response_indicates_existing_user "${dex_response}"; then
          resolve_existing_dex_user "${dex_response}"
          return 0
        fi
        die "Received ${http_status} error from auth endpoint. Response:\n${dex_response}"
        ;;
      401|429|5*|000)
        echo -e "Auth endpoint not ready (HTTP ${http_status}), retrying in 5s..."
        sleep 5
        ;;
      4*)
        die "Received ${http_status} error from auth endpoint. Response:\n${dex_response}"
        ;;
      *)
        die "Unexpected response (HTTP ${http_status}) from auth endpoint. Response:\n${dex_response}"
        ;;
    esac
  done

  die "Failed to create Dex user after multiple attempts"
}

prompt_new_user_profile() {
  GDCN_USER_FIRSTNAME=$(trim "$(prompt_required ">> First name: " "First name cannot be empty")")
  if [[ -z "${GDCN_USER_FIRSTNAME}" ]]; then
    die "First name cannot be empty"
  fi
  GDCN_USER_LASTNAME=$(trim "$(prompt_required ">> Last name: " "Last name cannot be empty")")
  if [[ -z "${GDCN_USER_LASTNAME}" ]]; then
    die "Last name cannot be empty"
  fi
  GDCN_USER_PASSWORD=$(prompt_password ">> Password: " "Password is required")
}

prompt_admin_assignment() {
  GDCN_PROMOTE_TO_ADMIN=$(prompt_yes_no ">> Make this user an admin? [y/N]: " "n")
  if [[ "${GDCN_PROMOTE_TO_ADMIN}" == "yes" ]]; then
    GDCN_ADMIN_GROUP_ID=$(prompt_required ">> Admin group ID [default: adminGroup]: " "Admin group ID is required" "adminGroup")
    GDCN_ADMIN_GROUP_ID=$(trim "${GDCN_ADMIN_GROUP_ID}")
    if [[ -z "${GDCN_ADMIN_GROUP_ID}" ]]; then
      die "Admin group ID cannot be empty"
    fi
  fi
}

resolve_idp_identity_for_email() {
  if lookup_idp_user_by_email; then
    echo -e "\nDex user ${GDCN_USER_EMAIL} already exists. Using IdP displayName and skipping first/last/password prompts."
    return 0
  fi

  prompt_new_user_profile
  DISPLAY_NAME="${GDCN_USER_FIRSTNAME} ${GDCN_USER_LASTNAME}"
  IDP_DISPLAY_NAME="${DISPLAY_NAME}"
  create_user
}

configure_user() {
  local payload full http_status gd_response

  payload=$(jq -n \
    --arg id "${GDCN_USER_ID}" \
    --arg email "${GDCN_USER_EMAIL}" \
    --arg firstname "${GDCN_USER_FIRSTNAME}" \
    --arg lastname "${GDCN_USER_LASTNAME}" \
    --arg authId "${dex_auth_id}" \
    '{
      data: {
        id: $id,
        type: "user",
        attributes: {
          email: $email,
          firstname: $firstname,
          lastname: $lastname,
          authenticationId: $authId
        }
      }
    }')

  printf '\nConfiguring user...\n'
  full=$(curl_json -X POST "https://${GDCN_ORG_HOSTNAME}/api/v1/entities/users" \
    -H "Authorization: Bearer ${GDCN_BOOT_TOKEN}" \
    -H "Content-Type: application/vnd.gooddata.api+json" \
    -d "${payload}") || true
  http_status=${full##*$'\n'}
  gd_response=$(printf '%s\n' "${full}" | sed '$d')

  if [[ "${http_status}" =~ ^2 ]]; then
    return 0
  fi

  if [[ "${http_status}" == "409" ]]; then
    echo -e "\nUser already exists. Updating attributes..."
    curl_json -X PATCH "https://${GDCN_ORG_HOSTNAME}/api/v1/entities/users/${GDCN_USER_ID_PATH}" \
      -H "Authorization: Bearer ${GDCN_BOOT_TOKEN}" \
      -H "Content-Type: application/vnd.gooddata.api+json" \
      -d "${payload}" >/dev/null
    return 0
  fi

  die "Failed to create GoodData.CN user (HTTP ${http_status}). Response:\n${gd_response}"
}

add_user_to_admin_group() {
  local payload

  printf '\nAdding %s to admin group %s...\n' "${GDCN_USER_ID}" "${GDCN_ADMIN_GROUP_ID}"
  payload=$(jq -n \
    --arg id "${GDCN_USER_ID}" \
    '{
      members: [
        {
          id: $id
        }
      ]
    }')

  curl_json -X POST "https://${GDCN_ORG_HOSTNAME}/api/v1/actions/userManagement/userGroups/${GDCN_ADMIN_GROUP_ID}/addMembers" \
    -H "Authorization: Bearer ${GDCN_BOOT_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "${payload}" >/dev/null
}

generate_user_bearer_token() {
  local token_id payload full http_status response bearer_token

  token_id=$(build_api_token_id)
  payload=$(jq -n \
    --arg id "${token_id}" \
    '{
      data: {
        id: $id,
        type: "apiToken"
      }
    }')

  printf '\nGenerating API bearer token...\n' >&2
  full=$(curl_json -X POST "https://${GDCN_ORG_HOSTNAME}/api/v1/entities/users/${GDCN_USER_ID_PATH}/apiTokens" \
    -H "Authorization: Bearer ${GDCN_BOOT_TOKEN}" \
    -H "Content-Type: application/vnd.gooddata.api+json" \
    -d "${payload}") || true
  http_status=${full##*$'\n'}
  response=$(printf '%s\n' "${full}" | sed '$d')

  if [[ ! "${http_status}" =~ ^2 ]]; then
    die "Failed to generate API token for ${GDCN_USER_EMAIL} (HTTP ${http_status}). Response:\n${response}"
  fi

  bearer_token=$(printf '%s\n' "${response}" | jq -r '.data.attributes.bearerToken // empty')
  [[ -n "${bearer_token}" ]] || die "API token creation succeeded, but response is missing data.attributes.bearerToken:\n${response}"

  printf '%s\n' "${bearer_token}"
}

# Ask the user for info
load_tf_outputs
require_tf_context "$(basename "$0")"

TLS_MODE=$(tf_output_value "tls_mode")
if [[ "${TLS_MODE}" == "selfsigned" ]]; then
  echo "Using self-signed TLS (curl --insecure)."
  CURL_TLS_ARGS=(--insecure)
fi

SUPPORTED_ORG_IDS=("org")
SUPPORTED_ORG_HOSTS=()
declare -A ORG_ID_TO_HOST=()
if command_exists jq && [[ "${TF_OUTPUTS_LOADED}" -eq 1 ]]; then
  org_ids_raw=$(tf_output_value "org_ids")
  if [[ -n "${org_ids_raw}" && "${org_ids_raw}" != "null" ]]; then
    parsed_ids=()
    while IFS= read -r org_id; do
      if [[ -n "${org_id}" ]]; then
        parsed_ids+=("${org_id}")
      fi
    done < <(jq -r '.[]' <<<"${org_ids_raw}" 2>/dev/null || true)
    if [[ ${#parsed_ids[@]} -gt 0 ]]; then
      SUPPORTED_ORG_IDS=("${parsed_ids[@]}")
    fi
  fi
  org_domains_raw=$(tf_output_value "org_domains")
  if [[ -n "${org_domains_raw}" && "${org_domains_raw}" != "null" ]]; then
    while IFS= read -r org_domain; do
      if [[ -n "${org_domain}" ]]; then
        SUPPORTED_ORG_HOSTS+=("${org_domain}")
      fi
    done < <(jq -r '.[]' <<<"${org_domains_raw}" 2>/dev/null || true)
  fi
fi
if [[ ${#SUPPORTED_ORG_HOSTS[@]} -eq ${#SUPPORTED_ORG_IDS[@]} ]]; then
  for idx in "${!SUPPORTED_ORG_IDS[@]}"; do
    ORG_ID_TO_HOST["${SUPPORTED_ORG_IDS[$idx]}"]="${SUPPORTED_ORG_HOSTS[$idx]}"
  done
fi
ORG_ID_PROMPT_CHOICES=$(join_by ", " "${SUPPORTED_ORG_IDS[@]}")

echo
while true; do
  read -ep ">> Organization ID [one of: ${ORG_ID_PROMPT_CHOICES}]: " GDCN_ORG_ID
  GDCN_ORG_ID=$(trim "${GDCN_ORG_ID}")
  if [[ -z "${GDCN_ORG_ID}" ]]; then
    echo -e "\nError: Organization ID is required.\n" >&2
    continue
  fi
  if [[ ! "${GDCN_ORG_ID}" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]]; then
    echo -e "\nError: Organization ID '${GDCN_ORG_ID}' must be lowercase alphanumeric (hyphens allowed inside).\n" >&2
    continue
  fi
  is_supported="false"
  for candidate in "${SUPPORTED_ORG_IDS[@]}"; do
    if [[ "${GDCN_ORG_ID}" == "${candidate}" ]]; then
      is_supported="true"
      break
    fi
  done
  if [[ "${is_supported}" != "true" ]]; then
    echo -e "\nError: '${GDCN_ORG_ID}' is not in the allowed list: ${ORG_ID_PROMPT_CHOICES}.\n" >&2
    continue
  fi
  break
done

GDCN_ORG_HOSTNAME="${ORG_ID_TO_HOST[${GDCN_ORG_ID}]:-}"
if [[ -z "${GDCN_ORG_HOSTNAME}" ]]; then
  warn "Terraform outputs missing or incomplete; unable to auto-detect hostname for '${GDCN_ORG_ID}'."
  GDCN_ORG_HOSTNAME=$(prompt_required ">> Organization domain (e.g. example.com): " "Organization domain is required")
fi

# If we're running inside a devcontainer, "localhost" refers to the container.
# For local k3d (Docker-outside-of-Docker), the ingress port is on the Docker host.
# Important: keep the URL hostname as-is so Ingress host routing works, but
# connect to host.docker.internal underneath.
if is_inside_container && [[ "${GDCN_ORG_HOSTNAME}" == "localhost" || "${GDCN_ORG_HOSTNAME}" == *.localhost ]]; then
  if command_exists getent && getent hosts host.docker.internal >/dev/null 2>&1; then
    echo "Container detected, routing via host.docker.internal."
    CURL_CONNECT_ARGS=(--connect-to "${GDCN_ORG_HOSTNAME}:443:host.docker.internal:443")
  fi
fi

# Admin credentials
# - Prefer environment overrides if set (useful for CI)
# - Otherwise, try to read from a Terraform-managed Secret
# - Finally, prompt interactively as a fallback
GDCN_NAMESPACE=${GDCN_NAMESPACE:-gooddata-cn}
if [[ -n "${GDCN_ADMIN_USER:-}" && -n "${GDCN_ADMIN_PASSWORD:-}" ]]; then
  echo "Using admin credentials from environment variables."
elif ! try_load_admin_credentials_from_secret "${GDCN_NAMESPACE}" "${GDCN_ORG_ID}"; then
  GDCN_ADMIN_USER=$(prompt_required ">> Admin username [default: admin]: " "Admin username is required" "admin")
  GDCN_ADMIN_PASSWORD=$(prompt_password ">> Admin password: " "Admin password is required")
fi

GDCN_BOOT_TOKEN_RAW="${GDCN_ADMIN_USER}:bootstrap:${GDCN_ADMIN_PASSWORD}"
GDCN_BOOT_TOKEN=$(printf '%s' "${GDCN_BOOT_TOKEN_RAW}" | base64 | tr -d '\n')

GDCN_USER_EMAIL=$(prompt_required ">> Email: " "Email is required")
GDCN_USER_ID=$(sanitize_user_id "${GDCN_USER_EMAIL}")
if [[ -z "${GDCN_USER_ID}" ]]; then
  die "Failed to derive a valid user identifier from ${GDCN_USER_EMAIL}"
fi
GDCN_USER_ID_PATH=$(urlencode "${GDCN_USER_ID}")

IDP_DISPLAY_NAME=""
dex_auth_id=""
GDCN_USER_BEARER_TOKEN=""

resolve_idp_identity_for_email

derive_org_names_from_display_name "${IDP_DISPLAY_NAME}"
prompt_admin_assignment

# Configure the user in GoodData.CN
configure_user

if [[ "${GDCN_PROMOTE_TO_ADMIN}" == "yes" ]]; then
  # Add the user to the admin group
  add_user_to_admin_group
  echo -e "\nUser ${GDCN_USER_EMAIL} is now an admin (group: ${GDCN_ADMIN_GROUP_ID})."
fi

GDCN_USER_BEARER_TOKEN=$(generate_user_bearer_token)

echo -e "\nDone! Log in at https://${GDCN_ORG_HOSTNAME} with ${GDCN_USER_EMAIL}."
echo -e "\nAPI bearer token (save it now -- this is the only time it will be shown):"
echo "${GDCN_USER_BEARER_TOKEN}"
