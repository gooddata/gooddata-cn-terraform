# Evaluation (gd-eval)

Quantified evaluation of the AI assistant on the `ecommerce-parent` workspace
using GoodData's [`gooddata-eval`](https://github.com/gooddata/gooddata-python-sdk/tree/master/packages/gooddata-eval)
CLI — pass-rate per model and side-by-side model comparison.

## Install

```bash
uv tool install gooddata-eval        # provides `gd-eval`
export PATH="$HOME/.local/bin:$PATH"
```

## Run

```bash
source ../providers/providers.env    # TIGER_ENDPOINT + TIGER_API_TOKEN
HOST=$TIGER_ENDPOINT; TOK=$TIGER_API_TOKEN

# sanity: list providers/models the workspace can use
gd-eval models --host "$HOST" --token "$TOK" --workspace ecommerce-parent

# compare the in-cluster models on this dataset (provider/model, exact ids)
gd-eval run \
  --host "$HOST" --token "$TOK" \
  --workspace ecommerce-parent \
  --dataset ./dataset \
  --model "vllm-qwen/Qwen/Qwen3.6-27B" \
  --model "sie-llm/Qwen/Qwen3-4B-Instruct-2507" \
  --runs 1 --json results.json
```

Note: provider-qualified model ids (`<providerId>/<modelId>`) avoid the
first-`/`-split gotcha with HF model names.

## Dataset (`./dataset`, one JSON per question)

| kind | needs OpenAI key | what it checks |
|---|---|---|
| `search_tool` | no (deterministic) | agent emits a valid `search_objects` tool call — the path that broke on 4B / thinking-mode |
| `general_question` | **yes** (`OPENAI_API_KEY`, LLM-judge) | answer contains the must-have facts (known-correct values from our data) |

Starter items cover revenue/orders/customer search + two known-answer
questions (active customers = 1205, ARPU ≈ 210,880). Extend by dropping more
`*.json` files in `dataset/`. The QA team's synthetic dataset plugs in the
same way (or via `--langfuse-dataset`).

**Sovereignty note:** `general_question` sends Q+A to OpenAI for judging. For a
fully-local eval, use only `search_tool` items, or point `OPENAI_BASE_URL` at
an in-cluster model.
