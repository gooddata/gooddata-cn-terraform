#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/lib/common.sh"

require_command jq "jq CLI not found; install it to run this script."

curl_json() {
  local response status body
  response=$(curl --silent --show-error --write-out "\n%{http_code}" "$@")
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

trim() {
  local value="${1:-}"
  value=${value#"${value%%[![:space:]]*}"}
  value=${value%"${value##*[![:space:]]}"}
  printf '%s' "${value}"
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
    echo -e "\n\n>> ERROR: ${error}" >&2
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
    echo -e "\n\n>> ERROR: ${error}" >&2
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
        echo -e "\n\n>> ERROR: Please answer yes or no." >&2
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
        echo -e "\n\n>> Auth endpoint not ready (HTTP ${http_status}). Retrying in 5s..."
        sleep 5
        ;;
      429|5*|000)
        echo -e "\n\n>> Auth endpoint not ready (HTTP ${http_status}). Retrying in 5s..."
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
DEFAULT_ORG_HOSTNAME=$(tf_output_value "org_domain")
if [[ -n "${DEFAULT_ORG_HOSTNAME}" ]]; then
  GDCN_ORG_HOSTNAME=$(prompt_required ">> GoodData.CN organization hostname [default: ${DEFAULT_ORG_HOSTNAME}]: " "GoodData.CN organization hostname is required" "${DEFAULT_ORG_HOSTNAME}")
else
  GDCN_ORG_HOSTNAME=$(prompt_required ">> GoodData.CN organization hostname (e.g. org.example.com): " "GoodData.CN organization hostname is required")
fi
GDCN_ADMIN_USER=$(prompt_required ">> GoodData.CN existing ADMIN username: " "GoodData.CN admin username is required")
GDCN_ADMIN_PASSWORD=$(prompt_password ">> GoodData.CN existing ADMIN password: " "GoodData.CN admin password is required")
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

echo -e "\n>> User ${GDCN_USER_EMAIL} is ready. Log in at https://${GDCN_ORG_HOSTNAME} with ${GDCN_USER_EMAIL}."
