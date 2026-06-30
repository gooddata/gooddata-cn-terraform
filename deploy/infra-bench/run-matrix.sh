#!/usr/bin/env bash
set -euo pipefail
###
# Run the full serving-layer matrix over both servers and print a scoreboard.
# Single GPU -> servers are benchmarked sequentially (each cold-started, warm-
# swept, then scaled down before the next).
#
# Usage: ./run-matrix.sh [server...]      (default: vllm sie)
# Concurrency sweep + max_tokens are configurable via env.
###
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVERS=("${@:-}"); [ -z "${SERVERS[*]}" ] && SERVERS=(vllm sie)
CONCURRENCIES="${CONCURRENCIES:-1 4 8}"
MAX_TOKENS="${MAX_TOKENS:-128}"
RES="$SCRIPT_DIR/results"; mkdir -p "$RES"
LOCAL_PORT="${LOCAL_PORT:-18000}"

svc_of() { case "$1" in vllm) echo "vllm 8000 inference deployment/vllm Qwen/Qwen3.6-27B";; sie) echo "sie-gateway 8080 sie statefulset/sie-worker-l4-sglang Qwen/Qwen3-4B-Instruct-2507";; esac; }

for s in "${SERVERS[@]}"; do
  read -r SVC PORT NS WORKLOAD MODEL <<<"$(svc_of "$s")"
  [ -z "${SVC:-}" ] && { echo "skip unknown server: $s"; continue; }
  echo "============================================================"
  echo " SERVER: $s  ($MODEL)"
  echo "============================================================"

  # 1) cold start (leaves the server running)
  bash "$SCRIPT_DIR/coldstart.sh" "$s" "$MAX_TOKENS" | tee "$RES/$s-coldstart.json" || { echo "cold start failed for $s, skipping"; continue; }

  # 2) warm sweep
  kubectl -n "$NS" port-forward "svc/$SVC" "$LOCAL_PORT:$PORT" >/dev/null 2>&1 &
  PF=$!; sleep 3
  : > "$RES/$s-warm.jsonl"
  for c in $CONCURRENCIES; do
    python3 "$SCRIPT_DIR/loadtest.py" --base-url "http://localhost:$LOCAL_PORT/v1" \
      --model "$MODEL" --concurrency "$c" --requests "$((c*4))" --max-tokens "$MAX_TOKENS" --json \
      | tee -a "$RES/$s-warm.jsonl"
  done
  kill $PF 2>/dev/null || true

  # 3) scale down to free the GPU for the next server
  kubectl -n "$NS" scale "${WORKLOAD%%/*}" "${WORKLOAD##*/}" --replicas=0 >/dev/null 2>&1 || true
  echo
done

echo "============================================================"
echo " SCOREBOARD"
echo "============================================================"
python3 - "$RES" <<'PY'
import json, os, sys, glob
res = sys.argv[1]
print(f"{'server':6} {'cold_full_s':>11} {'prov_ready_s':>12} {'warmup_s':>9} | {'conc':>4} {'ttft_p50':>8} {'tpot':>7} {'e2e_p95':>8} {'tok/s':>7} {'err':>4}")
for cs in sorted(glob.glob(os.path.join(res, "*-coldstart.json"))):
    s = os.path.basename(cs).split("-")[0]
    try: cold = json.load(open(cs))
    except Exception: cold = {}
    cf, pr, wu = cold.get("cold_full_s"), cold.get("provision_ready_s"), cold.get("first_request_warmup_s")
    warm = os.path.join(res, f"{s}-warm.jsonl")
    rows = []
    if os.path.exists(warm):
        for line in open(warm):
            line = line.strip()
            if line.startswith("{"):
                try: rows.append(json.loads(line))
                except Exception: pass
    if not rows:
        print(f"{s:6} {str(cf):>11} {str(pr):>12} {str(wu):>9} | (no warm data)")
    for i, r in enumerate(rows):
        head = f"{s:6} {str(cf):>11} {str(pr):>12} {str(wu):>9}" if i == 0 else f"{'':6} {'':>11} {'':>12} {'':>9}"
        print(f"{head} | {r.get('concurrency'):>4} {str(r.get('ttft_p50_s')):>8} {str(r.get('tpot_mean_s')):>7} {str(r.get('e2e_p95_s')):>8} {str(r.get('throughput_tok_s')):>7} {str(r.get('error_rate')):>4}")
PY
