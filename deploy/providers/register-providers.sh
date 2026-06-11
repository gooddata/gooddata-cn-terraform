#!/usr/bin/env bash
set -euo pipefail

###
# Register LLM providers (type LOCAL — any OpenAI-compatible Chat Completions
# server) with the deployed GoodData CN organization. Requires a gen-ai image
# built from a gdc-nas branch with the LOCAL provider type
# (jan/local-inference).
#
# Reads config from providers.env next to this script (gitignored — copy
# providers.env.example and fill in secrets).
#
# Registers side by side (distinct PROVIDER_IDs) for A/B testing:
#   - vllm-qwen : in-cluster vLLM            (REGISTER_VLLM=true)
#   - sie-llm   : Superlinked managed cluster (REGISTER_SIE=true)
#
# Re-running is idempotent (delete + create).
###

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/providers.env"

if [[ ! -f "$ENV_FILE" ]]; then
    echo "ERROR: $ENV_FILE not found."
    echo "       cp $SCRIPT_DIR/providers.env.example $ENV_FILE  # then fill in secrets"
    exit 1
fi
# shellcheck source=/dev/null
source "$ENV_FILE"

: "${TIGER_ENDPOINT:?Set TIGER_ENDPOINT in providers.env (e.g. https://gooddata.jan-inference.dev11.devgdc.com)}"
: "${TIGER_API_TOKEN:?Set TIGER_API_TOKEN in providers.env (org API token)}"

register() {
    local id="$1" name="$2" base_url="$3" api_key="$4" model="$5"

    echo ">> Registering provider '$id' (model: $model)"
    curl -sf -o /dev/null -w "   DELETE old: %{http_code}\n" \
        -H "Authorization: Bearer $TIGER_API_TOKEN" \
        -H "Content-Type: application/vnd.gooddata.api+json" \
        -X DELETE \
        "$TIGER_ENDPOINT/api/v1/entities/llmProviders/$id" || true

    curl -sf \
        -H "Authorization: Bearer $TIGER_API_TOKEN" \
        -H "Content-Type: application/vnd.gooddata.api+json" \
        -X POST \
        -d "{
          \"data\": {
            \"id\": \"$id\",
            \"type\": \"llmProvider\",
            \"attributes\": {
              \"name\": \"$name\",
              \"description\": \"OpenAI-compatible Chat Completions endpoint\",
              \"defaultModelId\": \"$model\",
              \"providerConfig\": {
                \"type\": \"LOCAL\",
                \"baseUrl\": \"$base_url\",
                \"apiKey\": \"$api_key\"
              },
              \"models\": [{
                \"family\": \"UNKNOWN\",
                \"id\": \"$model\"
              }]
            }
          }
        }" \
        "$TIGER_ENDPOINT/api/v1/entities/llmProviders" > /dev/null
    echo "   OK"
}

if [[ "${REGISTER_VLLM:-true}" == "true" ]]; then
    register "vllm-qwen" "vLLM (in-cluster)" \
        "${VLLM_BASE_URL:-http://vllm.inference.svc.cluster.local:8000/v1}" \
        "${VLLM_API_KEY:-local}" \
        "${VLLM_MODEL:-Qwen/Qwen3-4B}"
fi

if [[ "${REGISTER_SIE:-false}" == "true" ]]; then
    : "${SIE_BASE_URL:?Set SIE_BASE_URL in providers.env}"
    : "${SIE_API_KEY:?Set SIE_API_KEY in providers.env (SL-... token)}"
    register "sie-llm" "Superlinked SIE (managed)" \
        "$SIE_BASE_URL" \
        "$SIE_API_KEY" \
        "${SIE_MODEL:-Qwen/Qwen3.6-27B}"
fi

echo ""
echo "Done. Registered providers:"
curl -s -H "Authorization: Bearer $TIGER_API_TOKEN" \
    "$TIGER_ENDPOINT/api/v1/entities/llmProviders" \
    | python3 -c "import json,sys; [print('  -', p['id']) for p in json.load(sys.stdin)['data']]" 2>/dev/null \
    || echo "  (listing failed — check manually)"
