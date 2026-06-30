#!/usr/bin/env bash
set -euo pipefail
###
# Cold-start benchmark for one in-cluster inference server.
#
# Measures the cold-start phases defined in metrics.md:
#   provision_ready      scale 0->1  -> pod Ready (node provision + model load)
#   first_request_warmup pod Ready   -> first streamed response done
#   cold_full            scale 0->1  -> first streamed response done
#
# Usage: ./coldstart.sh <vllm|sie> [max_tokens]
# Requires: kubectl context on the cluster, python3, loadtest.py alongside.
###
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVER="${1:-}"; MAX_TOKENS="${2:-64}"

# key | workload | ns | service | port | model   (mirror of use-server.sh registry)
case "$SERVER" in
  vllm) WORKLOAD="deployment/vllm";                  NS="inference"; SVC="vllm";        PORT=8000; MODEL="Qwen/Qwen3.6-27B" ;;
  sie)  WORKLOAD="statefulset/sie-worker-l4-sglang"; NS="sie";       SVC="sie-gateway"; PORT=8080; MODEL="Qwen/Qwen3-4B-Instruct-2507" ;;
  *) echo "Usage: ./coldstart.sh <vllm|sie> [max_tokens]"; exit 1 ;;
esac
KIND="${WORKLOAD%%/*}"; NAME="${WORKLOAD##*/}"
READY_TIMEOUT="${READY_TIMEOUT:-1800s}"   # 27B cold load can take 15-20 min
LOCAL_PORT="${LOCAL_PORT:-18000}"

now() { python3 -c 'import time;print(f"{time.time():.3f}")'; }

echo ">> [$SERVER] ensuring clean cold start (scale to 0)"
kubectl -n "$NS" scale "$KIND" "$NAME" --replicas=0 >/dev/null 2>&1 || true
# wait until no pods for this workload
for _ in $(seq 1 60); do
  n=$(kubectl -n "$NS" get pods -l "app=$NAME" --no-headers 2>/dev/null | grep -c . || true)
  [ "${n:-0}" -eq 0 ] && break; sleep 5
done

echo ">> [$SERVER] scaling up 0->1 and timing readiness (timeout $READY_TIMEOUT)"
T0=$(now)
kubectl -n "$NS" scale "$KIND" "$NAME" --replicas=1 >/dev/null
if ! kubectl -n "$NS" rollout status "$KIND/$NAME" --timeout="$READY_TIMEOUT" >/dev/null 2>&1; then
  echo "ERROR: $WORKLOAD did not become Ready within $READY_TIMEOUT"; exit 2
fi
T_READY=$(now)

echo ">> [$SERVER] port-forwarding svc/$SVC:$PORT -> localhost:$LOCAL_PORT"
kubectl -n "$NS" port-forward "svc/$SVC" "$LOCAL_PORT:$PORT" >/dev/null 2>&1 &
PF_PID=$!
trap 'kill $PF_PID 2>/dev/null || true' EXIT
# wait for the forward to accept connections
for _ in $(seq 1 30); do
  python3 -c "import socket,sys; s=socket.socket(); s.settimeout(1); sys.exit(0 if s.connect_ex(('127.0.0.1',$LOCAL_PORT))==0 else 1)" 2>/dev/null && break
  sleep 1
done

echo ">> [$SERVER] first request (warmup / first-token compile)"
FIRST_JSON=$(python3 "$SCRIPT_DIR/loadtest.py" --base-url "http://localhost:$LOCAL_PORT/v1" \
  --model "$MODEL" --concurrency 1 --requests 1 --max-tokens "$MAX_TOKENS" --json 2>/dev/null || echo '{}')
T_FIRST=$(now)

provision_ready=$(python3 -c "print(round($T_READY-$T0,1))")
first_warmup=$(python3 -c "print(round($T_FIRST-$T_READY,1))")
cold_full=$(python3 -c "print(round($T_FIRST-$T0,1))")
first_ttft=$(python3 -c "import json;print(json.loads('''$FIRST_JSON''').get('ttft_p50_s'))" 2>/dev/null || echo null)

python3 - "$SERVER" "$MODEL" "$provision_ready" "$first_warmup" "$cold_full" "$first_ttft" <<'PY'
import json, sys
s, model, pr, fw, cf, ttft = sys.argv[1:7]
print(json.dumps({
  "server": s, "model": model,
  "provision_ready_s": float(pr),
  "first_request_warmup_s": float(fw),
  "cold_full_s": float(cf),
  "first_request_ttft_s": None if ttft in ("null","None") else float(ttft),
}, indent=2))
PY
