#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/lib/common.sh"

require_command jq "jq CLI not found; install it to run this script."
require_command curl "curl CLI not found; install it to run this script."

CURL_TLS_ARGS=()
GRAFANA_CURL_CONNECT_ARGS=()

try_load_grafana_admin_credentials_from_secret() {
  local namespace="observability"
  local secret_name="${1:-grafana}"
  local admin_user_b64 admin_password_b64 admin_user admin_password

  command_exists kubectl || return 1
  command_exists base64 || return 1

  kubectl get secret -n "${namespace}" "${secret_name}" >/dev/null 2>&1 || return 1

  admin_user_b64=$(kubectl get secret -n "${namespace}" "${secret_name}" -o jsonpath='{.data.admin-user}' 2>/dev/null || true)
  admin_password_b64=$(kubectl get secret -n "${namespace}" "${secret_name}" -o jsonpath='{.data.admin-password}' 2>/dev/null || true)

  if [[ -z "${admin_user_b64}" || -z "${admin_password_b64}" ]]; then
    return 1
  fi

  admin_user=$(printf '%s' "${admin_user_b64}" | base64 -d 2>/dev/null || true)
  admin_password=$(printf '%s' "${admin_password_b64}" | base64 -d 2>/dev/null || true)

  if [[ -z "${admin_user}" || -z "${admin_password}" ]]; then
    return 1
  fi

  GRAFANA_ADMIN_USER="${admin_user}"
  GRAFANA_ADMIN_PASSWORD="${admin_password}"
  echo "Using Grafana admin credentials from Kubernetes Secret ${namespace}/${secret_name}"
  return 0
}

configure_grafana_connect_args() {
  GRAFANA_CURL_CONNECT_ARGS=()
  if is_inside_container && [[ "${OBSERVABILITY_HOSTNAME}" == "localhost" || "${OBSERVABILITY_HOSTNAME}" == *.localhost ]]; then
    if command_exists getent && getent hosts host.docker.internal >/dev/null 2>&1; then
      echo "Container detected, routing via host.docker.internal."
      GRAFANA_CURL_CONNECT_ARGS=(--connect-to "${OBSERVABILITY_HOSTNAME}:443:host.docker.internal:443")
    fi
  fi
}

resolve_grafana_admin_credentials() {
  local discovered_secret=""
  local listed_secret=""

  if [[ -n "${GRAFANA_ADMIN_USER:-}" && -n "${GRAFANA_ADMIN_PASSWORD:-}" ]]; then
    echo "Using Grafana admin credentials from environment variables."
    return 0
  fi

  if try_load_grafana_admin_credentials_from_secret "grafana"; then
    return 0
  fi

  if command_exists kubectl; then
    listed_secret=$(kubectl get secret -n observability -l app.kubernetes.io/instance=grafana -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
    if [[ -n "${listed_secret}" ]]; then
      discovered_secret=$(trim "${listed_secret}")
      if [[ -n "${discovered_secret}" ]] && try_load_grafana_admin_credentials_from_secret "${discovered_secret}"; then
        return 0
      fi
    fi
  fi

  GRAFANA_ADMIN_USER=$(prompt_required ">> Grafana admin username [default: admin]: " "Grafana admin username is required" "admin")
  GRAFANA_ADMIN_PASSWORD=$(prompt_password ">> Grafana admin password: " "Grafana admin password is required")
}

curl_grafana_json() {
  local response status body
  response=$(curl --silent --show-error --write-out "\n%{http_code}" \
    "${CURL_TLS_ARGS[@]}" "${GRAFANA_CURL_CONNECT_ARGS[@]}" \
    -u "${GRAFANA_ADMIN_USER}:${GRAFANA_ADMIN_PASSWORD}" "$@")
  status=${response##*$'\n'}
  body=${response%$'\n'*}

  printf '%s\n%s\n' "${body}" "${status}"
  [[ "${status}" =~ ^2 ]]
}

###
# Main
###
load_tf_outputs
require_tf_context "$(basename "$0")"

TLS_MODE=$(tf_output_value "tls_mode")
if [[ "${TLS_MODE}" == "selfsigned" ]]; then
  echo "Using self-signed TLS (curl --insecure)."
  CURL_TLS_ARGS=(--insecure)
fi

OBSERVABILITY_HOSTNAME=$(trim "$(tf_output_value "observability_hostname" "")")
if [[ -z "${OBSERVABILITY_HOSTNAME}" ]]; then
  OBSERVABILITY_HOSTNAME=$(prompt_required ">> Grafana hostname (e.g. localhost): " "Grafana hostname is required")
fi
OBSERVABILITY_HOSTNAME=$(trim "${OBSERVABILITY_HOSTNAME}")

GRAFANA_ADMIN_USER="${GRAFANA_ADMIN_USER:-}"
GRAFANA_ADMIN_PASSWORD="${GRAFANA_ADMIN_PASSWORD:-}"

resolve_grafana_admin_credentials
configure_grafana_connect_args

echo
GRAFANA_USER_EMAIL=$(prompt_required ">> Email: " "Email is required")

GRAFANA_USER_PASSWORD=$(prompt_password ">> Password: " "Password is required")

PROMOTE_TO_ADMIN=$(prompt_yes_no ">> Make this user an admin? [y/N]: " "n")

# Create the user
echo -e "\nCreating Grafana user ${GRAFANA_USER_EMAIL}..."
create_payload=$(jq -n \
  --arg name "${GRAFANA_USER_EMAIL}" \
  --arg email "${GRAFANA_USER_EMAIL}" \
  --arg login "${GRAFANA_USER_EMAIL}" \
  --arg password "${GRAFANA_USER_PASSWORD}" \
  '{name: $name, email: $email, login: $login, password: $password}')

create_full=$(curl_grafana_json -X POST \
  "https://${OBSERVABILITY_HOSTNAME}/observability/api/admin/users" \
  -H "Content-Type: application/json" \
  -d "${create_payload}") || true
create_status=${create_full##*$'\n'}
create_body=$(printf '%s\n' "${create_full}" | sed '$d')

if [[ ! "${create_status}" =~ ^2 ]]; then
  if [[ "${create_status}" == "412" ]]; then
    die "User already exists with email or login ${GRAFANA_USER_EMAIL}."
  fi
  die "Failed to create Grafana user (HTTP ${create_status}). Response:\n${create_body}"
fi

grafana_user_id=$(printf '%s\n' "${create_body}" | jq -r '.id // empty' 2>/dev/null || true)
if [[ -z "${grafana_user_id}" ]]; then
  die "User created but response did not include an id."
fi

echo "Grafana user created (id=${grafana_user_id})."

# Assign admin role if requested
if [[ "${PROMOTE_TO_ADMIN}" == "yes" ]]; then
  echo "Promoting ${GRAFANA_USER_EMAIL} to Admin..."
  role_payload=$(jq -n '{role: "Admin"}')
  curl_grafana_json -X PATCH \
    "https://${OBSERVABILITY_HOSTNAME}/observability/api/org/users/${grafana_user_id}" \
    -H "Content-Type: application/json" \
    -d "${role_payload}" >/dev/null
  echo "${GRAFANA_USER_EMAIL} is now an Admin."
fi

echo -e "\nDone! User can log in at https://${OBSERVABILITY_HOSTNAME}/observability with:"
echo "  Email:    ${GRAFANA_USER_EMAIL}"
echo "  Password: ${GRAFANA_USER_PASSWORD}"
