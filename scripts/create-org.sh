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

DEFAULT_ORG_DOMAIN=$(tf_output_value "org_domain")
DETECTED_INGRESS_CLASS=$(tf_output_value "ingress_class_name" "nginx")
if [[ "${TF_OUTPUTS_LOADED}" -eq 1 ]]; then
  echo ">> Detected ingress class from Terraform outputs: ${DETECTED_INGRESS_CLASS}"
elif [[ -z "${DETECTED_INGRESS_CLASS}" ]]; then
  DETECTED_INGRESS_CLASS="nginx"
fi

USE_CERT_MANAGER_TLS="true"
if [[ "${DETECTED_INGRESS_CLASS,,}" == "alb" ]]; then
  USE_CERT_MANAGER_TLS="false"
  echo ">> Ingress class 'alb' detected; skipping cert-manager TLS configuration in the Organization CR."
elif [[ "${TF_OUTPUTS_LOADED}" -eq 0 ]]; then
  echo ">> Terraform outputs unavailable; assuming ingress class 'nginx' for TLS settings."
fi

echo
read -ep ">> GoodData.CN organization ID [default: test]: " GDCN_ORG_ID
GDCN_ORG_ID=${GDCN_ORG_ID:-test}

read -ep ">> GoodData.CN organization display name [default: Test, Inc.]: " GDCN_ORG_NAME
GDCN_ORG_NAME=${GDCN_ORG_NAME:-Test, Inc.}

if [[ -n "${DEFAULT_ORG_DOMAIN}" ]]; then
  read -ep ">> GoodData.CN organization domain [default: ${DEFAULT_ORG_DOMAIN}]: " GDCN_ORG_HOSTNAME
  GDCN_ORG_HOSTNAME=${GDCN_ORG_HOSTNAME:-${DEFAULT_ORG_DOMAIN}}
else
  read -ep ">> GoodData.CN organization domain (e.g. example.com): " GDCN_ORG_HOSTNAME
fi
if [[ -z "${GDCN_ORG_HOSTNAME}" ]]; then
  echo -e "\n\n>> ERROR: GoodData.CN organization domain is required" >&2
  exit 1
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
>> Next, configure your OIDC provider or run scripts/create-user.sh
>>   if you are using the local Dex auth service for testing.
EOF2
