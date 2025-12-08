#!/usr/bin/env bash
set -euo pipefail

yaml_escape() {
  local value=${1-}
  value=${value//$'\r'/}
  value=${value//\\/\\\\}
  value=${value//\"/\\\"}
  value=${value//$'\n'/\\n}
  printf '"%s"' "${value}"
}

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/lib/common.sh"

require_command kubectl "kubectl CLI not found; it is required to apply the Organization CR."

load_tf_outputs
require_tf_context "$(basename "$0")"

BASE_DOMAIN=$(tf_output_value "base_domain")
DETECTED_INGRESS_CLASS=$(tf_output_value "ingress_class_name" "nginx")
SUPPORTED_ORG_IDS=("org")
DEFAULT_ORG_HOSTNAME=""
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
    DEFAULT_ORG_HOSTNAME=$(jq -r '.[0] // empty' <<<"${org_domains_raw}" 2>/dev/null || true)
  fi
fi
ORG_ID_PROMPT_CHOICES=$(join_by ", " "${SUPPORTED_ORG_IDS[@]}")
if [[ -z "${DETECTED_INGRESS_CLASS}" ]]; then
  DETECTED_INGRESS_CLASS="nginx"
fi

USE_CERT_MANAGER_TLS="true"
if [[ "${DETECTED_INGRESS_CLASS,,}" == "alb" ]]; then
  USE_CERT_MANAGER_TLS="false"
elif [[ "${TF_OUTPUTS_LOADED}" -eq 0 ]]; then
  echo ">> Terraform outputs unavailable; assuming ingress class 'nginx' for TLS settings."
fi

use_alb_dns="false"
if [[ "${DETECTED_INGRESS_CLASS,,}" == "alb" ]]; then
  use_alb_dns="true"
fi

echo
while true; do
  read -ep ">> GoodData.CN organization ID [one of: ${ORG_ID_PROMPT_CHOICES}]: " GDCN_ORG_ID
  GDCN_ORG_ID=$(trim "${GDCN_ORG_ID}")
  if [[ -z "${GDCN_ORG_ID}" ]]; then
    echo -e "\n\n>> ERROR: Organization ID is required\n\n" >&2
    continue
  fi
  if [[ ! "${GDCN_ORG_ID}" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]]; then
    echo -e "\n\n>> ERROR: Organization ID '${GDCN_ORG_ID}' must be lowercase alphanumeric (hyphens allowed inside).\n\n" >&2
    continue
  fi
  is_valid_org_id="false"
  for candidate in "${SUPPORTED_ORG_IDS[@]}"; do
    if [[ "${GDCN_ORG_ID}" == "${candidate}" ]]; then
      is_valid_org_id="true"
      break
    fi
  done
  if [[ "${is_valid_org_id}" != "true" ]]; then
    echo -e "\n\n>> ERROR: '${GDCN_ORG_ID}' is not in the allowed list: ${ORG_ID_PROMPT_CHOICES}\n\n" >&2
    continue
  fi
  break
done

read -ep ">> GoodData.CN organization display name [default: Test, Inc.]: " GDCN_ORG_NAME
GDCN_ORG_NAME=${GDCN_ORG_NAME:-Test, Inc.}

if [[ "${use_alb_dns}" == "true" ]]; then
  if [[ -z "${BASE_DOMAIN}" ]]; then
    echo -e "\n\n>> ERROR: ingress class 'alb' detected, but base_domain was not provided in Terraform outputs." >&2
    echo ">> Ensure Terraform outputs include 'base_domain' (rerun 'terraform output' in the provider directory) before using this script." >&2
    exit 1
  fi
  GDCN_ORG_HOSTNAME="${GDCN_ORG_ID}.${BASE_DOMAIN}"
  echo -e "\n>> Organization hostname set to ${GDCN_ORG_HOSTNAME}"
  echo -e ">> ExternalDNS will create or update the DNS record automatically.\n"
else
  if [[ -n "${DEFAULT_ORG_HOSTNAME}" ]]; then
    read -ep ">> GoodData.CN organization domain [default: ${DEFAULT_ORG_HOSTNAME}]: " GDCN_ORG_HOSTNAME
    GDCN_ORG_HOSTNAME=${GDCN_ORG_HOSTNAME:-${DEFAULT_ORG_HOSTNAME}}
  else
    read -ep ">> GoodData.CN organization domain (e.g. example.com): " GDCN_ORG_HOSTNAME
  fi
  if [[ -z "${GDCN_ORG_HOSTNAME}" ]]; then
    echo -e "\n\n>> ERROR: GoodData.CN organization domain is required" >&2
    exit 1
  fi
fi

read -ep ">> Kubernetes namespace that GoodData.CN is deployed to [default: gooddata-cn]: " GDCN_NAMESPACE
GDCN_NAMESPACE=${GDCN_NAMESPACE:-gooddata-cn}
if [[ -z "${GDCN_NAMESPACE}" ]]; then
  echo -e "\n\n>> ERROR: Kubernetes namespace is required" >&2
  exit 1
fi

read -ep ">> GoodData.CN admin username [default: admin]: " GDCN_ADMIN_USER
GDCN_ADMIN_USER=${GDCN_ADMIN_USER:-admin}

read -resp ">> GoodData.CN admin password: " GDCN_ADMIN_PASSWORD
echo
if [[ -z "${GDCN_ADMIN_PASSWORD}" ]]; then
  echo -e "\n\n>> ERROR: GoodData.CN admin password is required" >&2
  exit 1
fi

read -ep ">> GoodData.CN admin group [default: adminGroup]: " GDCN_ADMIN_GROUP
GDCN_ADMIN_GROUP=${GDCN_ADMIN_GROUP:-adminGroup}

GDCN_ADMIN_HASH=$(openssl passwd -6 "${GDCN_ADMIN_PASSWORD}")

TLS_BLOCK=""
if [[ "${USE_CERT_MANAGER_TLS}" == "true" ]]; then
  TLS_BLOCK=$(cat <<YAML
  tls:
    secretName: $(yaml_escape "${GDCN_ORG_ID}-tls")
    issuerName: letsencrypt
    issuerType: ClusterIssuer
YAML
)
fi

echo ">> Applying Organization custom resource to namespace ${GDCN_NAMESPACE}..."
kubectl apply -f - <<YAML
apiVersion: controllers.gooddata.com/v1
kind: Organization
metadata:
  name: $(yaml_escape "${GDCN_ORG_ID}-org")
  namespace: $(yaml_escape "${GDCN_NAMESPACE}")
spec:
  id: $(yaml_escape "${GDCN_ORG_ID}")
  name: $(yaml_escape "${GDCN_ORG_NAME}")
  hostname: $(yaml_escape "${GDCN_ORG_HOSTNAME}")
  adminGroup: $(yaml_escape "${GDCN_ADMIN_GROUP}")
  adminUser: $(yaml_escape "${GDCN_ADMIN_USER}")
  adminUserToken: $(yaml_escape "${GDCN_ADMIN_HASH}")
${TLS_BLOCK}
YAML

cat <<EOF2

>> GoodData.CN organization created.
>> Next, configure your OIDC provider OR run scripts/create-user.sh
>>   if you are using the local Dex auth service for testing.
EOF2
