# Inference servers (swappable)

The environment is built to **test multiple inference servers** behind the same
GoodData gen-ai pipeline. The gen-ai BYOLLM adapter speaks the OpenAI Chat
Completions API, so any OpenAI-compatible server (vLLM, Superlinked SIE, TGI,
TensorRT-LLM, …) plugs in with no code or image change — only a provider
registration.

## Single GPU → one server at a time

We run one GPU node (1× L40S 48 GB). Only one inference server can hold the GPU,
so servers are **swapped**, not run concurrently:

```bash
./use-server.sh vllm     # Qwen3.6-27B FP8 via vLLM (strong model, agentic flow)
./use-server.sh sie      # Qwen3-4B-Instruct via Superlinked SIE (pipeline test)
```

`use-server.sh <server> [workspace]` does everything:
1. scales the chosen server's k8s workload to 1 and every other to 0 (frees the GPU),
2. registers it as the org's LOCAL LLM provider (OPENAI type + in-cluster baseUrl),
3. activates it on the workspace (default `ecommerce-parent`).

Requires `../providers/providers.env` (TIGER_ENDPOINT + TIGER_API_TOKEN).

## Server registry

Servers are defined in one table at the top of `use-server.sh`
(`register_server`). Adding a new one (e.g. TGI) = one row + its k8s manifest;
swap/registration/activation are generic.

| key | model | server | manifest |
|---|---|---|---|
| `vllm` | Qwen3.6-27B (FP8) | vLLM | `../k8s/vllm-qwen.yaml` |
| `sie` | Qwen3-4B-Instruct (tools, 32K) | Superlinked SIE | `../helm/install-sie.sh` + `sie-values.yaml` |

## Notes / findings

- **SIE 27B doesn't run on the 48 GB L40S today** — no FP8 profile for this tier,
  the `:profile` suffix is stripped before dispatch, and the ~42 s SGLang
  startup-health timeout isn't configurable (27B can't load in time on L40S).
  vLLM serves 27B FP8 on the same card with no such limit. Details in the
  Superlinked findings thread.
- After scale-to-zero the model re-downloads (HF cache is an emptyDir). For
  faster restarts, wire the S3 model cache (`aws/inference-cache.tf`).
