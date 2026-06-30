#!/usr/bin/env bash
set -euo pipefail

###
# Swap the active in-cluster inference server.
#
# All inference servers share the single GPU node (1× L40S), so only ONE can
# run at a time. This script scales the chosen server up, scales every other
# server to zero (freeing the GPU), then registers it as the org's LOCAL LLM
# provider and activates it on a workspace.
#
# Usage:
#   ./use-server.sh <server> [workspace]
#     <server>    key from the SERVERS table below (e.g. vllm, sie)
#     [workspace] workspace id to activate the provider on (default: ecommerce-parent)
#
# Adding a new server (TGI, SGLang, TensorRT-LLM, ...) = one row in SERVERS
# plus its k8s manifest. Everything else (provider registration, swap,
# activation) is generic.
#
# Requires: kubectl context on the cluster, and deploy/providers/providers.env
# with TIGER_ENDPOINT + TIGER_API_TOKEN.
###

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/../providers/providers.env"

# --- Server registry: key | k8s workload | namespace | OpenAI baseUrl | model | providerId ---
# workload is "<kind>/<name>" so the swap can scale it 0/1 generically.
declare -A WORKLOAD NS BASEURL MODEL PROVIDER DISABLE_THINKING MAX_ITER
#                workload                               namespace   baseUrl                                              model                          providerId      disable_thinking  max_iter
register_server() { WORKLOAD[$1]=$2; NS[$1]=$3; BASEURL[$1]=$4; MODEL[$1]=$5; PROVIDER[$1]=$6; DISABLE_THINKING[$1]=${7:-false}; MAX_ITER[$1]=${8:-40}; }
register_server vllm "deployment/vllm"                 inference  "http://vllm.inference.svc.cluster.local:8000/v1"     "Qwen/Qwen3.6-27B"             "vllm-qwen"  false  40
register_server sie  "statefulset/sie-worker-l4-sglang" sie       "http://sie-gateway.sie.svc.cluster.local:8080/v1"   "Qwen/Qwen3.6-27B:no-spec"  "sie-llm"    true   40

SERVER="${1:-}"
WORKSPACE="${2:-ecommerce-parent}"

if [[ -z "$SERVER" || -z "${WORKLOAD[$SERVER]:-}" ]]; then
    echo "Usage: ./use-server.sh <server> [workspace]"
    echo "Servers: ${!WORKLOAD[*]}"
    exit 1
fi

[[ -f "$ENV_FILE" ]] || { echo "ERROR: $ENV_FILE not found (need TIGER_ENDPOINT + TIGER_API_TOKEN)"; exit 1; }
# shellcheck source=/dev/null
source "$ENV_FILE"
: "${TIGER_ENDPOINT:?set TIGER_ENDPOINT in providers.env}"
: "${TIGER_API_TOKEN:?set TIGER_API_TOKEN in providers.env}"

echo ">> Switching inference to '$SERVER' (workspace: $WORKSPACE)"

# 1. Scale every OTHER server to 0 (free the shared GPU), chosen server to 1.
for s in "${!WORKLOAD[@]}"; do
    kind="${WORKLOAD[$s]%%/*}"; name="${WORKLOAD[$s]##*/}"
    if [[ "$s" == "$SERVER" ]]; then
        echo "   scaling up   ${WORKLOAD[$s]} (ns ${NS[$s]})"
        kubectl -n "${NS[$s]}" scale "$kind" "$name" --replicas=1 >/dev/null 2>&1 || true
    else
        echo "   scaling down ${WORKLOAD[$s]} (ns ${NS[$s]})"
        kubectl -n "${NS[$s]}" scale "$kind" "$name" --replicas=0 >/dev/null 2>&1 || true
    fi
done

# 2. Register the chosen server as a LOCAL LLM provider (OPENAI type + custom
#    baseUrl; auth needs the API_KEY discriminator even for unauthenticated servers).
pid="${PROVIDER[$SERVER]}"; url="${BASEURL[$SERVER]}"; model="${MODEL[$SERVER]}"
echo ">> Registering provider '$pid' → $url ($model)"
AUTH=(-H "Authorization: Bearer $TIGER_API_TOKEN")
JSON=(-H "Content-Type: application/vnd.gooddata.api+json")
curl -sf -o /dev/null "${AUTH[@]}" "${JSON[@]}" -X DELETE "$TIGER_ENDPOINT/api/v1/entities/llmProviders/$pid" 2>/dev/null || true
curl -sf -o /dev/null -w "   provider: %{http_code}\n" "${AUTH[@]}" "${JSON[@]}" -X POST \
    -d "{\"data\":{\"id\":\"$pid\",\"type\":\"llmProvider\",\"attributes\":{\"name\":\"$pid\",\"defaultModelId\":\"$model\",\"providerConfig\":{\"type\":\"OPENAI\",\"baseUrl\":\"$url\",\"auth\":{\"type\":\"API_KEY\",\"apiKey\":\"local\"}},\"models\":[{\"family\":\"UNKNOWN\",\"id\":\"$model\"}]}}}" \
    "$TIGER_ENDPOINT/api/v1/entities/llmProviders"

# 3. Set model-tuning flags on gen-ai.
#    - DISABLE_THINKING: small models (SIE 4B) must suppress <think> blocks
#    - MAX_ITER: 4B models need more correction attempts (schema retries, search
#      retries) to complete multi-step visualization workflows; raise the ceiling
#      for SIE and restore default for larger models.
echo ">> Setting LOCAL_LLM_DISABLE_THINKING=${DISABLE_THINKING[$SERVER]} AGENTIC_MAX_ITERATIONS=${MAX_ITER[$SERVER]} on gen-ai"
kubectl -n gooddata-cn set env deploy/gooddata-cn-gen-ai \
    "LOCAL_LLM_DISABLE_THINKING=${DISABLE_THINKING[$SERVER]}" \
    "AGENTIC_MAX_ITERATIONS=${MAX_ITER[$SERVER]}" >/dev/null

# 4. Activate it on the workspace (replace any existing setting).
echo ">> Activating on workspace '$WORKSPACE'"
curl -sf -o /dev/null "${AUTH[@]}" "${JSON[@]}" -X DELETE \
    "$TIGER_ENDPOINT/api/v1/entities/workspaces/$WORKSPACE/workspaceSettings/activeLlmProvider" 2>/dev/null || true
curl -sf -o /dev/null -w "   activeLlmProvider: %{http_code}\n" "${AUTH[@]}" "${JSON[@]}" -X POST \
    -d "{\"data\":{\"id\":\"activeLlmProvider\",\"type\":\"workspaceSetting\",\"attributes\":{\"type\":\"ACTIVE_LLM_PROVIDER\",\"content\":{\"id\":\"$pid\",\"type\":\"llmProvider\",\"defaultModelId\":\"$model\"}}}}" \
    "$TIGER_ENDPOINT/api/v1/entities/workspaces/$WORKSPACE/workspaceSettings"

cat <<EOF

Done. '$SERVER' is the active inference server for workspace '$WORKSPACE'.
The GPU node loads the model on first request (cold start: vLLM ~15-20 min for
27B incl. download; SIE small models ~5 min). Watch:
  kubectl -n ${NS[$SERVER]} get pods -w
EOF
