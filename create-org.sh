#!/usr/bin/env bash
set -euo pipefail

# ------------------------------------------------------------
# Helper: run curl, surface HTTP status + response body.
# Returns the body on STDOUT so callers can still capture it,
# and exits non‑zero on non‑2xx to preserve existing logic.
# ------------------------------------------------------------
curl_json() {
  # Execute curl and append HTTP code on a new line
  local response status body
  response=$(curl --silent --show-error --write-out "\n%{http_code}" "$@")
  status=${response##*$'\n'}
  body=${response%$'\n'*}

  # Surface status and error body
  echo -e ">> HTTP status: ${status}" >&2
  if [[ "${status}" != "200" && "${status}" != "404" ]]; then
    echo "${body}" >&2
  fi

  # Emit body and status (body first, status last) so caller can parse
  printf '%s\n%s\n' "${body}" "${status}"

  # Non‑2xx return non‑zero so callers can still `|| true`
  [[ "${status}" =~ ^2 ]]
}

###
# Interactive prompts for organization config
###

read -ep ">> GoodData.CN organization ID [default: test]: " GDCN_ORG_ID
GDCN_ORG_ID=${GDCN_ORG_ID:-test}

read -ep ">> GoodData.CN organization display name [default: Test, Inc.]: " GDCN_ORG_NAME
GDCN_ORG_NAME=${GDCN_ORG_NAME:-Test, Inc.}

read -ep ">> GoodData.CN organization hostname (from Terraform output: gdcn_org_hostname): " GDCN_ORG_HOSTNAME
if [ -z "$GDCN_ORG_HOSTNAME" ]; then
  echo -e "\n\n>> ERROR: GoodData.CN organization hostname is required" >&2
  exit 1
fi

read -ep ">> GoodData.CN admin username [default: admin]: " GDCN_ADMIN_USER
GDCN_ADMIN_USER=${GDCN_ADMIN_USER:-admin}

read -resp ">> GoodData.CN admin password: " GDCN_ADMIN_PASSWORD
echo
if [ -z "$GDCN_ADMIN_PASSWORD" ]; then
  echo -e "\n\n>> ERROR: GoodData.CN admin password is required" >&2
  exit 1
fi
GDCN_ADMIN_HASH=$(openssl passwd -6 "$GDCN_ADMIN_PASSWORD")
GDCN_BOOT_TOKEN_RAW="${GDCN_ADMIN_USER}:bootstrap:${GDCN_ADMIN_PASSWORD}"
GDCN_BOOT_TOKEN=$(printf '%s' "$GDCN_BOOT_TOKEN_RAW" | base64)

read -ep ">> GoodData.CN admin group [default: adminGroup]: " GDCN_ADMIN_GROUP
GDCN_ADMIN_GROUP=${GDCN_ADMIN_GROUP:-adminGroup}

read -ep ">> GoodData.CN first user email [default: admin@${GDCN_ORG_HOSTNAME}]: " GDCN_DEX_USER_EMAIL
GDCN_DEX_USER_EMAIL=${GDCN_DEX_USER_EMAIL:-admin@$GDCN_ORG_HOSTNAME}

read -resp ">> GoodData.CN first user password: " GDCN_DEX_USER_PASSWORD
echo
if [ -z "$GDCN_DEX_USER_PASSWORD" ]; then
  echo -e "\n\n>> ERROR: GoodData.CN first user password is required" >&2
  exit 1
fi

###
# Create GoodData.CN Organization
###
echo -e "\n\n>> Applying Organization to Kubernetes..."
kubectl -n gooddata-cn apply -f - <<EOF
apiVersion: controllers.gooddata.com/v1
kind: Organization
metadata:
  name: ${GDCN_ORG_ID}-org
spec:
  id: ${GDCN_ORG_ID}
  name: "${GDCN_ORG_NAME}"
  hostname: ${GDCN_ORG_HOSTNAME}
  adminGroup: ${GDCN_ADMIN_GROUP}
  adminUser: ${GDCN_ADMIN_USER}
  adminUserToken: "${GDCN_ADMIN_HASH}"
  tls:
    secretName: ${GDCN_ORG_ID}-tls
    issuerName: letsencrypt
    issuerType: ClusterIssuer
EOF

###
# Create Dex user and update GoodData admin
###
echo -e "\n\n>> Creating first GoodData.CN user..."
# Doing multiple retries since it can take a moment for the Organization API to become available
for i in {1..200}; do
  # Capture full body+status from helper
  full=$(curl_json -X POST "https://${GDCN_ORG_HOSTNAME}/api/v1/auth/users" \
    -H "Authorization: Bearer ${GDCN_BOOT_TOKEN}" \
    -H "Content-type: application/json" \
    -d '{
          "email": "'"${GDCN_DEX_USER_EMAIL}"'",
          "password": "'"${GDCN_DEX_USER_PASSWORD}"'",
          "displayName": "'"${GDCN_ADMIN_USER}"'"
        }') || true
  http_status=$(printf '%s\n' "${full}" | tail -n1)
  dex_response=$(printf '%s\n' "${full}" | sed '$d')

  # Fatal on 400 without retry
  if [[ "${http_status}" == "400" ]]; then
    echo -e "\n\n>> ERROR: Received 400 error from API. Correct the problem and try again." >&2
    exit 1
  fi

  # Break on success (2xx)
  if [[ "${http_status}" =~ ^2 ]]; then
    break
  fi

  echo -e "\n\n>> GoodData.CN authentication endpoint not ready. Retrying in 5s..."
  sleep 5
done
if [ -z "${dex_response:-}" ]; then
  echo -e "\n\n>> ERROR: Failed to create first user after multiple attempts" >&2
  exit 1
fi
dex_auth_id=$(
  printf '%s\n' "$dex_response" |
  sed -n 's/.*"authenticationId"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p'
)

echo -e "\n\n>> Configuring first user in organization..."
full=$(curl_json -X PATCH "https://${GDCN_ORG_HOSTNAME}/api/v1/entities/users/${GDCN_ADMIN_USER}" \
  -H "Authorization: Bearer ${GDCN_BOOT_TOKEN}" \
  -H "Content-Type: application/vnd.gooddata.api+json" \
  -d '{
      "data": {
          "id": "'"${GDCN_ADMIN_USER}"'",
          "type": "user",
          "attributes": {
              "authenticationId": "'"${dex_auth_id}"'",
              "email": "'"${GDCN_DEX_USER_EMAIL}"'",
              "firstname": "'"$(echo "${GDCN_DEX_USER_EMAIL}" | cut -d'@' -f1)"'",
              "lastname": ""
          }
      }
  }')
http_status=${full##*$'\n'}

echo -e "\n\n\n>> Organization and admin user setup complete."
echo -e ">> Log in at https://${GDCN_ORG_HOSTNAME} with ${GDCN_DEX_USER_EMAIL} and your chosen password."
echo -e ">> If you need to make API calls, you can use this bearer token: ${GDCN_BOOT_TOKEN}"
