# Infra / serving-layer benchmark — metric definitions

Separate track from `deploy/eval/` (which measures **model quality** via
`gooddata-eval`). This track measures the **serving layer / provider** —
SIE (SGLang) vs vLLM vs others — on the **same GPU, same model, same prompts**,
so any difference is attributable to the serving stack, not the model.

Why this exists: the things that bite us are serving-layer, not quality —
SIE's ~42 s readiness timeout, the ~57 s per-conversation SGLang relaunch,
cold-start cost on an L40S, throughput under the agentic loop's many sequential
calls. `gooddata-eval` does not measure any of these.

## Isolation rules (apples-to-apples)
- **Same hardware:** 1× L40S (g6e.xlarge). Single GPU → one server at a time.
- **Same model** across servers being compared (pick one both can serve), or
  state explicitly when comparing a server's *own* best model.
- **Same prompt set + same decode params** (`max_tokens`, `temperature=0`).
- Servers swap via `deploy/inference/use-server.sh` (scales others to 0).

## Metrics — precise definitions (when the clock starts/stops)

### Cold start (the headline)
| metric | clock start | clock stop |
|---|---|---|
| **cold_full** | `kubectl scale 0→1` issued | first successful `/v1/chat/completions` response |
| `provision_ready` | scale 0→1 issued | pod `Ready` (node provision + container + model load to healthy) |
| `first_request_warmup` | pod `Ready` | first response done (catches SGLang/vLLM first-request compile) |
| **new_conversation_cold** ⭐ | model **resident**, new conversation started | first token | catches SIE's per-conversation `launch_server` (~57 s) — run via the gen-ai chat API, not the raw `/v1` endpoint |

Decompose so we can tell *where* the time goes (node provision vs model load
vs first-request compile). `provision_ready` needs the GPU node to spin up; to
isolate model-load only, pre-warm the node (a placeholder pod) and re-measure.

### Warm performance (model resident)
| metric | definition |
|---|---|
| **TTFT** | time from request sent → first streamed token |
| **TPOT** | mean time per output token after the first (decode speed) |
| **throughput_tok_s** | total output tokens / wall-clock, at a given concurrency |
| **e2e p50/p95/p99** | end-to-end request latency percentiles |
| **saturation_concurrency** | concurrency at which p95 e2e exceeds a chosen SLA (e.g. 2× the c=1 latency) |

### Scaling & stability
| metric | definition |
|---|---|
| `scale_up_time` | scale 0→1 → pod Ready (== `provision_ready`) |
| `scale_to_zero_time` | scale 1→0 → pod gone (and GPU node removed by autoscaler, ~10 min) |
| `error_rate` | failed/timed-out requests ÷ total, under load |
| `recovery_time` | pod kill → next successful response |
| `gpu_util` / `vram_used` | at idle vs at target concurrency (`nvidia-smi` in-pod) |

## Comparison matrix
`{vllm, sie}` × `{cold_full, provision_ready, new_conversation_cold, warm}` ×
`concurrency {1, 4, 8}` — one fixed model + one L40S.
Add columns later: Bedrock (managed), Rackspace bare-metal.

## Scoreboard (what we report)
Per server: cold_full (+ decomposition), TTFT/TPOT warm, throughput & e2e
percentiles per concurrency, saturation point, error rate, scale timings.
Headline question: **does SIE's serving stack cost us cold-start / per-conversation
latency that vLLM doesn't — and at what throughput does each saturate one L40S?**

## How to run
- `coldstart.sh <vllm|sie>` — cold-start phases (kubectl-orchestrated).
- `loadtest.py --base-url … --model … --concurrency N` — warm sweep (stdlib only).
- `run-matrix.sh` — full matrix over both servers → scoreboard JSON + table.
Endpoints are in-cluster; the scripts use `kubectl port-forward` to reach them.
