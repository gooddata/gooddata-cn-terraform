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

read -ep ">> GoodData.CN organization ID [default: test]: " GDCN_ORG_ID
GDCN_ORG_ID=${GDCN_ORG_ID:-test}

read -ep ">> GoodData.CN organization display name [default: Test, Inc.]: " GDCN_ORG_NAME
GDCN_ORG_NAME=${GDCN_ORG_NAME:-Test, Inc.}

read -ep ">> GoodData.CN organization hostname (from Terraform output: gdcn_org_hostname): " GDCN_ORG_HOSTNAME
if [[ -z "${GDCN_ORG_HOSTNAME}" ]]; then
  echo -e "\n\n>> ERROR: GoodData.CN organization hostname is required" >&2
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
  tls:
    secretName: $(yaml_escape "${GDCN_ORG_ID}-tls")
    issuerName: letsencrypt
    issuerType: ClusterIssuer
YAML

cat <<EOF2

>> GoodData.CN organization created.
>> Next, configure your OIDC provider or run scripts/create-user.sh
>>   if you are using the local Dex auth service for testing.
EOF2
