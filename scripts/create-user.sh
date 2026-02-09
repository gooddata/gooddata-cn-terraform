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

  echo -e ">> HTTP status: ${status}" >&2
  if [[ "${status}" != "200" && "${status}" != "201" && "${status}" != "204" ]]; then
    echo "${body}" >&2
  fi

  printf '%s\n%s\n' "${body}" "${status}"

  [[ "${status}" =~ ^2 ]]
}

die() {
  echo -e "\n\n>> ERROR: $*" >&2
  exit 1
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
  echo ">> Using admin credentials from Kubernetes Secret ${namespace}/${secret_name}"
  return 0
}

sanitize_user_id() {
  local value="${1}"
  value=${value//@/.at.}
  value=${value//[^A-Za-z0-9._-]/-}
  printf '%s' "${value}"
}

prompt_required() {
  local prompt="$1"
  local error="$2"
  local default="${3:-}"
  local value
  while true; do
    read -ep "${prompt}" value
    if [[ -z "${value}" && -n "${default}" ]]; then
      value="${default}"
    fi
    if [[ -n "${value}" ]]; then
      printf '%s\n' "${value}"
      return 0
    fi
    echo -e "\n\n>> ERROR: ${error}\n\n" >&2
  done
}

prompt_password() {
  local prompt="$1"
  local error="$2"
  local value
  while true; do
    read -resp "${prompt}" value
    echo >&2
    if [[ -n "${value}" ]]; then
      printf '%s\n' "${value}"
      return 0
    fi
    echo -e "\n\n>> ERROR: ${error}\n\n" >&2
  done
}

prompt_yes_no() {
  local prompt="$1"
  local default="${2:-n}"
  local answer normalized
  while true; do
    read -ep "${prompt}" answer
    if [[ -z "${answer}" ]]; then
      answer="${default}"
    fi
    normalized=$(printf '%s' "${answer}" | tr '[:upper:]' '[:lower:]')
    case "${normalized}" in
      y|yes)
        printf 'yes\n'
        return 0
        ;;
      n|no)
        printf 'no\n'
        return 0
        ;;
      *)
        echo -e "\n\n>> ERROR: Please answer yes or no.\n\n" >&2
        ;;
    esac
  done
}

urlencode() {
  jq -rn --arg v "${1}" '$v|@uri'
}

extract_auth_id() {
  jq -r '.authenticationId // .data.attributes.authenticationId // empty'
}

create_user() {
  local payload full http_status dex_response existing existing_status existing_body local_auth_id

  payload=$(jq -n \
    --arg email "${GDCN_USER_EMAIL}" \
    --arg password "${GDCN_USER_PASSWORD}" \
    --arg displayName "${DISPLAY_NAME}" \
    '{email: $email, password: $password, displayName: $displayName}')

  printf '\n\n>> Creating user...\n'
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
      return 0
    fi

    case "${http_status}" in
      409)
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
        echo -e "\n>> Dex user already exists. Reusing authenticationId."
        dex_auth_id="${local_auth_id}"
        return 0
        ;;
      401)
        echo -e "\n\n>> Auth endpoint not ready (HTTP ${http_status}). Retrying in 5s...\n\n"
        sleep 5
        ;;
      429|5*|000)
        echo -e "\n\n>> Auth endpoint not ready (HTTP ${http_status}). Retrying in 5s...\n\n"
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

  printf '\n>> Configuring user...\n'
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
    echo -e "\n>> User already exists. Updating attributes..."
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

  printf '\n>> Adding %s to admin group %s via user management action...\n' "${GDCN_USER_ID}" "${GDCN_ADMIN_GROUP_ID}"
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

# Ask the user for info
load_tf_outputs
require_tf_context "$(basename "$0")"

TLS_MODE=$(tf_output_value "tls_mode")
if [[ "${TLS_MODE}" == "selfsigned" ]]; then
  echo ">> Detected tls_mode=selfsigned; using curl --insecure for local dev."
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
  read -ep ">> GoodData.CN organization ID for the new user [one of: ${ORG_ID_PROMPT_CHOICES}]: " GDCN_ORG_ID
  GDCN_ORG_ID=$(trim "${GDCN_ORG_ID}")
  if [[ -z "${GDCN_ORG_ID}" ]]; then
    echo -e "\n\n>> ERROR: Organization ID is required\n\n" >&2
    continue
  fi
  if [[ ! "${GDCN_ORG_ID}" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]]; then
    echo -e "\n\n>> ERROR: Organization ID '${GDCN_ORG_ID}' must be lowercase alphanumeric (hyphens allowed inside).\n\n" >&2
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
    echo -e "\n\n>> ERROR: '${GDCN_ORG_ID}' is not in the allowed list: ${ORG_ID_PROMPT_CHOICES}\n\n" >&2
    continue
  fi
  break
done

GDCN_ORG_HOSTNAME="${ORG_ID_TO_HOST[${GDCN_ORG_ID}]:-}"
if [[ -z "${GDCN_ORG_HOSTNAME}" ]]; then
  warn "Terraform outputs missing or incomplete; unable to auto-detect hostname for '${GDCN_ORG_ID}'."
  GDCN_ORG_HOSTNAME=$(prompt_required ">> GoodData.CN organization domain (e.g. example.com): " "GoodData.CN organization domain is required")
fi

# If we're running inside a devcontainer, "localhost" refers to the container.
# For local k3d (Docker-outside-of-Docker), the ingress port is on the Docker host.
# Important: keep the URL hostname as-is so Ingress host routing works, but
# connect to host.docker.internal underneath.
if is_inside_container && [[ "${GDCN_ORG_HOSTNAME}" == "localhost" || "${GDCN_ORG_HOSTNAME}" == *.localhost ]]; then
  if command_exists getent && getent hosts host.docker.internal >/dev/null 2>&1; then
    echo ">> Detected container environment; connecting via host.docker.internal (preserving Host=${GDCN_ORG_HOSTNAME})."
    CURL_CONNECT_ARGS=(--connect-to "${GDCN_ORG_HOSTNAME}:443:host.docker.internal:443")
  fi
fi

# Admin credentials
# - Prefer environment overrides if set (useful for CI)
# - Otherwise, try to read from a Terraform-managed Secret
# - Finally, prompt interactively as a fallback
GDCN_NAMESPACE=${GDCN_NAMESPACE:-gooddata-cn}
if [[ -n "${GDCN_ADMIN_USER:-}" && -n "${GDCN_ADMIN_PASSWORD:-}" ]]; then
  echo ">> Using admin credentials from environment variables."
elif ! try_load_admin_credentials_from_secret "${GDCN_NAMESPACE}" "${GDCN_ORG_ID}"; then
  GDCN_ADMIN_USER=$(prompt_required ">> GoodData.CN EXISTING ADMIN username [default: admin]: " "GoodData.CN admin username is required" "admin")
  GDCN_ADMIN_PASSWORD=$(prompt_password ">> GoodData.CN EXISTING ADMIN password: " "GoodData.CN admin password is required")
fi

GDCN_USER_FIRSTNAME=$(trim "$(prompt_required ">> New GoodData.CN user first name: " "First name cannot be empty")")
if [[ -z "${GDCN_USER_FIRSTNAME}" ]]; then
  die "First name cannot be empty"
fi
GDCN_USER_LASTNAME=$(trim "$(prompt_required ">> New GoodData.CN user last name: " "Last name cannot be empty")")
if [[ -z "${GDCN_USER_LASTNAME}" ]]; then
  die "Last name cannot be empty"
fi
GDCN_USER_EMAIL=$(prompt_required ">> New GoodData.CN user email: " "GoodData.CN user email is required")
GDCN_USER_ID=$(sanitize_user_id "${GDCN_USER_EMAIL}")
if [[ -z "${GDCN_USER_ID}" ]]; then
  die "Failed to derive a valid user identifier from ${GDCN_USER_EMAIL}"
fi
GDCN_USER_ID_PATH=$(urlencode "${GDCN_USER_ID}")
GDCN_USER_PASSWORD=$(prompt_password ">> New GoodData.CN user password: " "New GoodData.CN user password is required")
GDCN_PROMOTE_TO_ADMIN=$(prompt_yes_no ">> Give this user admin privileges to GoodData.CN? [y/N]: " "n")
if [[ "${GDCN_PROMOTE_TO_ADMIN}" == "yes" ]]; then
  GDCN_ADMIN_GROUP_ID=$(prompt_required ">> GoodData.CN admin group ID [default: adminGroup]: " "Admin group ID is required" "adminGroup")
  GDCN_ADMIN_GROUP_ID=$(trim "${GDCN_ADMIN_GROUP_ID}")
  if [[ -z "${GDCN_ADMIN_GROUP_ID}" ]]; then
    die "Admin group ID cannot be empty"
  fi
fi

GDCN_BOOT_TOKEN_RAW="${GDCN_ADMIN_USER}:bootstrap:${GDCN_ADMIN_PASSWORD}"
GDCN_BOOT_TOKEN=$(printf '%s' "${GDCN_BOOT_TOKEN_RAW}" | base64 | tr -d '\n')
DISPLAY_NAME="${GDCN_USER_FIRSTNAME} ${GDCN_USER_LASTNAME}"

dex_auth_id=""

# Create the user in Dex
create_user

# Configure the user in GoodData.CN
configure_user

if [[ "${GDCN_PROMOTE_TO_ADMIN}" == "yes" ]]; then
  # Add the user to the admin group
  add_user_to_admin_group
  echo -e "\n>> User ${GDCN_USER_EMAIL} now has admin privileges via group ${GDCN_ADMIN_GROUP_ID}."
fi

echo -e "\n>> User is ready. Log in at https://${GDCN_ORG_HOSTNAME} with ${GDCN_USER_EMAIL}."
