# GoodData — Local Inference for the gen-ai agent (onboarding & context)

Context for picking up the **"Taking Control of Inference"** work: running
GoodData's gen-ai agentic assistant on **self-hosted / local LLM inference**
(no data leaves the VPC) for data-sovereignty customers (**DATEV, Mark43**).
This doc is written so a fresh Claude Code session has full context immediately.

---

## TL;DR

We made GoodData's agentic assistant (skill activation → search → create
visualization → render) run **end-to-end on a local open model** (Qwen3.6-27B
FP8) served by **vLLM on a single NVIDIA L40S 48 GB**, with no dependency on a
frontier model. The work is a set of **model-agnostic harness fixes** in the
gen-ai service plus a deploy/eval scaffold. It is verified on vLLM; the same
fixes should now also work on **SIE** (Superlinked) since SIE v0.6.7 unblocked
27B FP8 on the L40S.

---

## Repos & branches

| repo | branch | what |
|---|---|---|
| `janpansky/gdc-nas` | `jan/local-inference` | gen-ai harness fixes (the core code) |
| `janpansky/gooddata-cn-terraform` | `jan/independent-deploy` | deploy wrapper, vLLM + SIE manifests, `use-server.sh`, eval suite |

Latest gen-ai commit: render fix → arg coerce → thinking-as-config (v7–v10).
Built image: `972873489489.dkr.ecr.us-east-1.amazonaws.com/local-inference/gen-ai:jan-local-inference-10`.

---

## The harness fixes — what & why

These exist because the gen-ai loop was built/validated against **frontier
models via the Responses API**; a mid-size open model on the **Chat Completions
adapter** (the path vLLM/SIE/TGI use) breaks the implicit assumptions. The
fixes are **reactive / config-driven**, so the frontier (OpenAI Responses) path
is untouched — they only activate on the local path's failure modes.

1. **Visualization render** (`conversation_service.py`) — the Chat Completions
   adapter returns the final answer as a plain `TextMessage` and (unlike the
   Responses adapter) can't emit a `VisualizationPart`, so created charts never
   rendered. Fix: collect viz refs created during the turn and fold the final
   answer into a `MultipartMessage(TextPart + VisualizationPart[])`. **This was
   the real "viz didn't show" root cause.**
2. **Stringified tool args** (`base_tool.py`) — the `qwen3_coder` parser
   serializes nested/primitive args as strings (`visualization="{...}"`,
   `compatible_with_afm="None"`) → pydantic `model_type` error. Fix: on
   validation failure, decode JSON-string objects/arrays and `"None"/"null"/
   "true"/"false"` literals, then re-validate once.
3. **Tool-name repair** (`tool_registry.py`) — mid-size models hallucinate
   tool names (`create_visualization`). Fix: alias table + fuzzy match to the
   nearest real tool before erroring.
4. **Thinking suppression as config** (`chat_completions_llm.py` + `llm_factory.py`)
   — Qwen3's `<think>` block costs ~1 min/turn and inflates context. Disabled
   via `chat_template_kwargs.enable_thinking=false`, but **gated by env
   `LOCAL_LLM_DISABLE_THINKING`** (default off = model-neutral), so it isn't
   hardcoded to Qwen. Set it per deployment.

Design principle: **don't rely on the model following the protocol — enforce it
in the harness/decoding, keep it generalized, isolate model-specific choices in
config.** (Full design note: `deploy/docs/local-model-harness.md`, S1–S5.)

---

## Current state (verified)

- vLLM `Qwen/Qwen3.6-27B` FP8 on g6e.xlarge (1× L40S 48 GB), `--tool-call-parser=qwen3_coder`,
  `--max-model-len=32768`, `--enforce-eager`, `enableServiceLinks: false`,
  Recreate strategy, HF cache on gp3 PVC.
- End-to-end agentic flow works: `set_skills → search_objects →
  create_adhoc_visualization → render`. Verified via the chat API: the final
  message is `multipart` with a `visualization` part. A create-viz flow is
  ~5 sequential turns (~35–75 s), thinking off.
- Env runs in EKS + RDS (Postgres, holds the ecommerce demo data, in-VPC).
- **GPU is scaled to zero when idle** (`kubectl -n inference scale deploy/vllm
  --replicas=0`) — bring up with `--replicas=1`, ~10–20 min warmup.

---

## How to deploy & test

```bash
# 1. SSO + bring up env (see deploy/README.md)
aws sso login --profile aws-panther-dev
./deploy/deploy.sh local-inference init && apply        # ~35 min if from scratch

# 2. pick which model server serves the workspace (single GPU = one at a time)
./deploy/inference/use-server.sh vllm ecommerce-parent  # registers provider + activates

# 3. bring GPU up + warm
kubectl -n inference scale deploy/vllm --replicas=1

# 4. set thinking-off on gen-ai (Qwen)
kubectl -n gooddata-cn set env deploy/gooddata-cn-gen-ai LOCAL_LLM_DISABLE_THINKING=true
```
Smoke-test the chat via API: create conversation → POST
`/api/v1/ai/workspaces/<ws>/chat/conversations/<id>/messages` (Accept:
text/event-stream); confirm the final assistant item is `content.type=multipart`
with a `visualization` part.

---

## Testing on SIE (Superlinked)

The harness fixes are **adapter-level and model-agnostic** — SIE is an
OpenAI-compatible Chat Completions server, same path as vLLM, so they apply
unchanged. SIE **v0.6.7** (released after our findings) unblocked 27B FP8 on the
L40S. To test:

1. Deploy SIE v0.6.7 (`deploy/helm/sie-values.yaml`, `install-sie.sh`).
2. Set **`workers.common.modelReadyTimeoutSec`** high enough for 27B FP8 load on
   L40S (the old fixed ~42 s SGLang readiness timeout was the original blocker).
3. Request the FP8 profile `Qwen/Qwen3.6-27B:rtx-pro-6000` (the `:profile`
   suffix is now preserved through the gateway; previously collapsed to BF16 → OOM).
4. Point the provider at SIE: `./deploy/inference/use-server.sh sie <workspace>`.
5. Set `LOCAL_LLM_DISABLE_THINKING=true` on gen-ai.

**Open question to watch on SIE:** each new conversation appears to trigger a
fresh SGLang `launch_server` (~57 s) even when the model is resident. For an
agentic assistant (many sequential calls) that's a latency killer — confirm
whether v0.6.7 keeps the model warm across conversations. (Config API is
append-only by design — add new profiles per experiment, don't mutate `default`.)

---

## Eval / benchmark

`deploy/eval/globalmart_benchmark.md` — graded L1→L6 suite (simple → hard) for
the agent, mapped to the **gd-eval** CLI (`search_tool` deterministic +
`general_question` with a **local** judge via `OPENAI_BASE_URL` → in-cluster
vLLM). The signature hard axis on GlobalMart (1071 metrics) is **disambiguation**
+ **graceful-fail** (no hallucinated numbers), not arithmetic. Drives the
planned A/B: Qwen3.6-27B (dense baseline) vs Qwen3-30B-A3B (MoE, faster).

---

## Open items / blockers

- **GlobalMart test data** (PR #23775) — LDM is in the PR; data lives in
  perftest RDS (`bi_tests`, schema `globalmart_15c503cc7977cf26`), reachable
  only by the QA team (SG blocks us). Numeric eval assertions are blocked on
  that access; retrieval/graceful-fail tests can run from the LDM alone.
- **SIE per-conversation cold start** (above) — decisive for SIE viability.
- **Model A/B** — Qwen3-30B-A3B (Apache-2.0 MoE, ~3 B active) is the efficiency
  candidate to cut latency without a bigger GPU.

---

## Key constraints & decisions

- **Single L40S 48 GB** is the ceiling. AWS has **no single A100/H100** — only
  8-GPU p4de/p5 at $32–98/hr. L40S (g6e.xlarge, ~$1.86/hr) is the only
  affordable single GPU ≥48 GB with FP8. Scale beyond → g6e.12xlarge (4× L40S)
  or multi-GPU H100.
- **License matters**: best-benchmarked tool-callers (xLAM-2, Hammer) are
  cc-by-nc (non-commercial) → unusable for DATEV/Mark43. Stick to permissive
  (Apache-2.0 Qwen/Granite, MIT Phi-4, Llama community, Apache gpt-oss).
- **Keep the harness generalized** — don't over-tune to one model; model-specific
  choices live in config (e.g. `LOCAL_LLM_DISABLE_THINKING`), enforcement lives
  in the harness, not the prompt.
- Don't touch Peter's env (`peter-genai`). Test data/workspaces are owned by the
  QA team — we connect, we don't author them.
