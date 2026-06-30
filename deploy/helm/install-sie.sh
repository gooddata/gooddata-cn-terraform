#!/usr/bin/env bash
set -euo pipefail

###
# Install SIE (Superlinked Inference Engine) into OUR cluster.
#
# Prerequisites: kubectl configured (../deploy.sh <env> kubectl), helm 3.8+,
# GPU pool enabled (enable_inference_gpu_pool=true in the env tfvars).
#
# After install, the OpenAI-compatible endpoint for the LOCAL provider is:
#   http://sie-gateway.sie.svc.cluster.local:8080/v1
###

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

SIE_CHART_VERSION="${SIE_CHART_VERSION:-0.6.14}"
helm upgrade --install sie-cluster oci://ghcr.io/superlinked/charts/sie-cluster \
    --version "$SIE_CHART_VERSION" \
    --namespace sie \
    --create-namespace \
    -f "$SCRIPT_DIR/sie-values.yaml" \
    --timeout 15m

echo ""
echo ">> Waiting for the gateway..."
kubectl -n sie rollout status deploy -l app.kubernetes.io/component=gateway --timeout=300s 2>/dev/null \
    || kubectl -n sie get pods

echo ""
echo ">> Pods:"
kubectl -n sie get pods

cat <<'EOF'

Smoke test (worker needs a GPU node + model load — first request may take minutes):
  kubectl -n sie port-forward svc/sie-gateway 8080:8080 &
  curl -s http://localhost:8080/v1/models | head -c 400
  curl -s http://localhost:8080/v1/chat/completions -H "Content-Type: application/json" \
    -d '{"model":"Qwen/Qwen3-0.6B","messages":[{"role":"user","content":"Say OK"}],"max_tokens":10}'

Then register the provider (providers/providers.env already points at the in-cluster gateway):
  ../providers/register-providers.sh
EOF
