#!/usr/bin/env bash
set -euo pipefail

# Registers the Terraform-provisioned Amazon Bedrock IAM credentials as the
# GoodData.CN LLM provider and activates it for an organization.
#
# Prerequisites:
#   - enable_ai_features = true and enable_bedrock_llm = true, applied
#   - bedrock_llm_model_id set to a Bedrock inference profile ID
#   - run from the aws/ directory (reads terraform outputs)
#
# Anthropic Claude models additionally require the one-time "use case details"
# form in the AWS Bedrock console (Model access) before they can be invoked.

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/lib/common.sh"

require_command jq "jq CLI not found; install it to run this script."
require_command curl "curl CLI not found; install it to run this script."

load_tf_outputs
require_tf_context "$(basename "$0")"

MODEL_ID=$(trim "$(tf_output_value "bedrock_llm_model_id" "")")
ACCESS_KEY_ID=$(trim "$(tf_output_value "bedrock_llm_access_key_id" "")")
SECRET_ACCESS_KEY=$(trim "$(tf_output_value "bedrock_llm_secret_access_key" "")")
BEDROCK_REGION=$(trim "$(tf_output_value "aws_region" "")")

if [[ -z "${MODEL_ID}" || -z "${ACCESS_KEY_ID}" || -z "${SECRET_ACCESS_KEY}" ]]; then
  die "Bedrock outputs are empty. Set enable_bedrock_llm = true and bedrock_llm_model_id in settings.tfvars, run terraform apply, then re-run this script."
fi

# Derive the GoodData model family from the inference profile ID.
model_family() {
  local id_lower
  id_lower=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
  case "${id_lower}" in
    *anthropic*|*claude*) printf 'ANTHROPIC' ;;
    *amazon*|*nova*|*titan*) printf 'AMAZON' ;;
    *mistral*|*pixtral*) printf 'MISTRAL' ;;
    *meta*|*llama*) printf 'META' ;;
    *cohere*) printf 'COHERE' ;;
    *openai*|*gpt*) printf 'OPENAI' ;;
    *google*|*gemini*) printf 'GOOGLE' ;;
    *) printf 'UNKNOWN' ;;
  esac
}
MODEL_FAMILY=$(model_family "${MODEL_ID}")

# Resolve organization (same convention as create-user.sh).
SUPPORTED_ORG_IDS=()
SUPPORTED_ORG_HOSTS=()
declare -A ORG_ID_TO_HOST=()
org_ids_raw=$(tf_output_value "org_ids" "")
org_domains_raw=$(tf_output_value "org_domains" "")
if [[ -n "${org_ids_raw}" ]]; then
  while IFS= read -r org_id; do
    [[ -n "${org_id}" ]] && SUPPORTED_ORG_IDS+=("${org_id}")
  done < <(jq -r '.[]' <<<"${org_ids_raw}" 2>/dev/null || true)
fi
if [[ -n "${org_domains_raw}" ]]; then
  while IFS= read -r org_domain; do
    [[ -n "${org_domain}" ]] && SUPPORTED_ORG_HOSTS+=("${org_domain}")
  done < <(jq -r '.[]' <<<"${org_domains_raw}" 2>/dev/null || true)
fi
if [[ ${#SUPPORTED_ORG_HOSTS[@]} -eq ${#SUPPORTED_ORG_IDS[@]} ]]; then
  for idx in "${!SUPPORTED_ORG_IDS[@]}"; do
    ORG_ID_TO_HOST["${SUPPORTED_ORG_IDS[$idx]}"]="${SUPPORTED_ORG_HOSTS[$idx]}"
  done
fi

if [[ ${#SUPPORTED_ORG_IDS[@]} -eq 1 ]]; then
  GDCN_ORG_ID="${SUPPORTED_ORG_IDS[0]}"
  echo "Using organization: ${GDCN_ORG_ID}"
else
  GDCN_ORG_ID=$(prompt_required ">> Organization ID [one of: $(join_by ", " "${SUPPORTED_ORG_IDS[@]}")]: " "Organization ID is required")
  GDCN_ORG_ID=$(trim "${GDCN_ORG_ID}")
fi

GDCN_ORG_HOSTNAME="${ORG_ID_TO_HOST[${GDCN_ORG_ID}]:-}"
if [[ -z "${GDCN_ORG_HOSTNAME}" ]]; then
  GDCN_ORG_HOSTNAME=$(prompt_required ">> Organization domain (e.g. example.com): " "Organization domain is required")
fi

# Admin credentials: environment override, then the Terraform-managed Secret.
GDCN_NAMESPACE="${GDCN_NAMESPACE:-$(tf_output_value "gdcn_namespace" "gooddata-cn")}"
if [[ -z "${GDCN_ADMIN_USER:-}" || -z "${GDCN_ADMIN_PASSWORD:-}" ]]; then
  secret_name="gdcn-org-admin-${GDCN_ORG_ID}"
  if command_exists kubectl && kubectl get secret -n "${GDCN_NAMESPACE}" "${secret_name}" >/dev/null 2>&1; then
    GDCN_ADMIN_USER=$(kubectl get secret -n "${GDCN_NAMESPACE}" "${secret_name}" -o jsonpath='{.data.adminUser}' | base64 -d)
    GDCN_ADMIN_PASSWORD=$(kubectl get secret -n "${GDCN_NAMESPACE}" "${secret_name}" -o jsonpath='{.data.adminPassword}' | base64 -d)
    echo "Using admin credentials from Kubernetes Secret ${GDCN_NAMESPACE}/${secret_name}"
  else
    GDCN_ADMIN_USER=$(prompt_required ">> Admin username [default: admin]: " "Admin username is required" "admin")
    GDCN_ADMIN_PASSWORD=$(prompt_password ">> Admin password: " "Admin password is required")
  fi
fi
GDCN_BOOT_TOKEN=$(printf '%s' "${GDCN_ADMIN_USER}:bootstrap:${GDCN_ADMIN_PASSWORD}" | base64 | tr -d '\n')

BASE_URL="https://${GDCN_ORG_HOSTNAME}"
PROVIDER_ID="${GDCN_LLM_PROVIDER_ID:-bedrock}"

provider_payload=$(jq -n \
  --arg id "${PROVIDER_ID}" \
  --arg model "${MODEL_ID}" \
  --arg family "${MODEL_FAMILY}" \
  --arg region "${BEDROCK_REGION}" \
  --arg ak "${ACCESS_KEY_ID}" \
  --arg sk "${SECRET_ACCESS_KEY}" \
  '{
    data: {
      id: $id,
      type: "llmProvider",
      attributes: {
        defaultModelId: $model,
        models: [{family: $family, id: $model}],
        providerConfig: {
          type: "AWS_BEDROCK",
          region: $region,
          auth: {type: "ACCESS_KEY", accessKeyId: $ak, secretAccessKey: $sk}
        }
      }
    }
  }')

setting_payload=$(jq -n \
  --arg pid "${PROVIDER_ID}" \
  '{
    data: {
      id: "active_llm_provider",
      type: "organizationSetting",
      attributes: {
        type: "ACTIVE_LLM_PROVIDER",
        content: {id: $pid, type: "llmProvider"}
      }
    }
  }')

post_or_put() {
  local url_collection="$1" url_entity="$2" payload="$3" label="$4"
  local status
  status=$(curl --silent --output /dev/null --write-out "%{http_code}" \
    -X POST "${url_collection}" \
    -H "Authorization: Bearer ${GDCN_BOOT_TOKEN}" \
    -H "Content-Type: application/vnd.gooddata.api+json" \
    -d "${payload}")
  if [[ "${status}" == "409" ]]; then
    echo "${label} already exists; updating..."
    status=$(curl --silent --output /dev/null --write-out "%{http_code}" \
      -X PUT "${url_entity}" \
      -H "Authorization: Bearer ${GDCN_BOOT_TOKEN}" \
      -H "Content-Type: application/vnd.gooddata.api+json" \
      -d "${payload}")
  fi
  if [[ ! "${status}" =~ ^2 ]]; then
    die "Failed to configure ${label} (HTTP ${status})."
  fi
  echo "${label}: OK (HTTP ${status})"
}

echo
echo "Registering Bedrock LLM provider '${PROVIDER_ID}' (${MODEL_FAMILY} / ${MODEL_ID}, region ${BEDROCK_REGION})..."
post_or_put \
  "${BASE_URL}/api/v1/entities/llmProviders" \
  "${BASE_URL}/api/v1/entities/llmProviders/${PROVIDER_ID}" \
  "${provider_payload}" \
  "LLM provider"

post_or_put \
  "${BASE_URL}/api/v1/entities/organizationSettings" \
  "${BASE_URL}/api/v1/entities/organizationSettings/active_llm_provider" \
  "${setting_payload}" \
  "Active LLM provider setting"

echo
echo "Done. AI chat in organization '${GDCN_ORG_ID}' now uses Bedrock model ${MODEL_ID}."
if [[ "${MODEL_FAMILY}" == "ANTHROPIC" ]]; then
  echo "Note: Anthropic models require the one-time use case form in the AWS Bedrock console (Model access) before invocation succeeds."
fi
