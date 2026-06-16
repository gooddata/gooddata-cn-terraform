# GlobalMart — gen-ai agent benchmark suite

Graded benchmark (simple → hard) for evaluating GoodData's gen-ai agentic
assistant when driven by a **local model** (current baseline Qwen3.6-27B FP8;
A/B candidate Qwen3-30B-A3B). The suite is the reference we proceed by: it
defines the questions, how they map to the **gd-eval CLI**, what gd-eval can
and cannot check, and the run procedure.

Target workspace: **GlobalMart** (PR #23775). Eval surface (from the LDM,
`globalmart_declarative_hierarchy.json`):

| element | count |
|---|---|
| datasets | 225 |
| attributes | 359 |
| facts | 220 |
| **metrics** | **1071** |
| analytical dashboards | 32 |
| visualization objects | 384 |

Domains: retail / e-commerce / finance / HR / supply-chain / loyalty / fraud /
facilities. This is an enterprise-grade model — far richer than ecommerce-parent
(6 datasets). **The signature hard axis here is DISAMBIGUATION, not arithmetic:**
with 1071 metrics and many near-duplicate names (`Total Net Revenue` vs
`Total Net Revenue (Net Sales Summary)` vs `Gross Revenue (Margin Bridge)` vs
`Revenue (Blended Daily Revenue)`, plus pre-sliced `— North Region` / `— Online
Channel` and `MoM:` variants), the decisive test is whether the agent finds and
selects the *right* metric/dataset.

---

## What we measure (dimensions, not just "right answer")

1. **Correctness** — right value / right tool.
2. **Retrieval & disambiguation** — picks the correct metric among similar names.
3. **Protocol adherence** — `set_skills → tool` executed correctly.
4. **Multi-step completion** — finishes a multi-turn flow through to render.
5. **Graceful failure** — missing/ambiguous → honest "not found" / asks to
   disambiguate, **never hallucinates a number**.
6. **Latency** — turns + wall-clock (gd-eval does not measure → API smoke).

---

## The graded ladder

Questions use **real GlobalMart names**. Column legend:
- **kind** → gd-eval `test_kind` (`search_tool` = deterministic, no judge;
  `general_question` = local LLM-judge) or `API smoke` (outside gd-eval).
- **data?** → ✅ runnable without row data (metadata/retrieval only) ·
  ⏳ needs GlobalMart data loaded (numeric assertion).

| # | level | question | hard axis | kind | data? | pass criterion |
|---|---|---|---|---|---|---|
| L1 | retrieval (easy) | "Find the metric for total order count." | unambiguous lookup | search_tool | ✅ | emits valid `search_objects`; top hit = `Total Order Count` |
| L1b | retrieval (disambiguation) ⭐ | "Find the net revenue metric." | pick right of many | search_tool | ✅ | `search_objects` returns the Net-Revenue family; ranks `Total Net Revenue (Net Sales Summary)` near top |
| L2 | single value | "What is total net revenue?" | — | general_question | ⏳ | answer = known total (fill from data) |
| L2b | single value | "What is the total order count?" | — | general_question | ⏳ | known total |
| L3 | breakdown + viz ⭐ | "Show net revenue by sales channel." | multi-step + right dataset/attr | general_question + API smoke | ⏳ | judge: names channels; smoke: **VisualizationPart emitted** |
| L4 | top-N / filter | "Top 5 stores by sales amount." | sort + limit | general_question | ⏳ | top-5 store names match known |
| L4b | time | "Net revenue by month for last fiscal year." | time dimension | general_question | ⏳ | monthly series, correct period |
| L5 | comparative | "Which sales channel has the highest gross margin, and how does it compare to the lowest?" | reasoning + 2 values | general_question | ⏳ | correct high/low channel + delta |
| L5b | cross-dataset | "Compare return amount to sales amount by product category." | join across datasets (Returns + Daily Store Sales) | general_question | ⏳ | both measures by category |
| L6 | graceful-fail ⭐ | "What is the average flight delay?" (foreign concept, not in model) | honesty | general_question | ✅ | says it can't find such a metric; **no fabricated number** |
| L6b | ambiguity ⭐ | "Show me revenue." (1071 metrics, dozens of revenue variants) | disambiguate WHICH | general_question | ✅ | asks to clarify OR picks a canonical revenue metric and states which |
| L6c | multi-turn | "Net revenue by region." → "Now only the top region, over time." | follow-up context | API smoke | ⏳ | second turn refines first (no restart) |

⭐ = the differentiators that separate a good local model from a weak one
(disambiguation, graceful-fail, ambiguity). These are where mid-size models
fail and where the suite earns its keep. **L1/L1b/L6/L6b are buildable AND
runnable from the LDM alone** (no row data) — start there.

> Note on "absent" for L6: GlobalMart is comprehensive — it *does* contain
> churn (Customer Churn Risk Score), forecast (Demand Forecast Accuracy), NPS,
> and purchase propensity. Pick L6 graceful-fail concepts that are genuinely
> foreign (e.g. flight delay, patient readmission) and re-confirm absence against
> the LDM before finalizing.

---

## The CLI: gd-eval (gooddata-eval)

### Install
```bash
uv tool install gooddata-eval        # provides `gd-eval`
export PATH="$HOME/.local/bin:$PATH"
```

### Dataset format
One JSON file per question under `dataset/`. Two kinds:

`search_tool` (deterministic — no judge, no key) — checks the agent emits a
valid `search_objects` call for the question:
```json
{
  "test_kind": "search_tool",
  "question": "Find the net revenue metric.",
  "expected_search_terms": ["net revenue"]
}
```

`general_question` (LLM-judge — checks the answer contains must-have facts):
```json
{
  "test_kind": "general_question",
  "question": "What is total net revenue?",
  "must_have": ["<known value — fill from data>"]
}
```

### Local judge (sovereignty — chosen)
Point the judge at our in-cluster vLLM instead of OpenAI, so no Q+A leaves the
VPC:
```bash
export OPENAI_BASE_URL="http://vllm.inference.svc.cluster.local:8000/v1"
export OPENAI_API_KEY="local"
```
Caveat: judge quality = our model (a less strict grader than GPT); for
borderline answers it is less reliable. Acceptable for an internal A/B; flag
disputed items for manual review.

### Run (the A/B: baseline vs MoE candidate)
```bash
source ../providers/providers.env          # TIGER_ENDPOINT + TIGER_API_TOKEN
gd-eval run \
  --host "$TIGER_ENDPOINT" --token "$TIGER_API_TOKEN" \
  --workspace globalmart \
  --dataset ./dataset \
  --model "vllm-qwen/Qwen/Qwen3.6-27B" \
  --model "vllm-a3b/Qwen/Qwen3-30B-A3B-Instruct-2507" \
  --runs 3 --json results.json
```
`--runs 3` to expose non-determinism (the model sometimes skips steps). Use
provider-qualified model ids (`<providerId>/<modelId>`).

### What gd-eval covers vs not
| level | gd-eval | how |
|---|---|---|
| L1, L1b | ✅ | `search_tool` (deterministic) |
| L2–L5b, L6, L6b | ✅ | `general_question` (local judge) |
| L3 render, latency, L6c multi-turn | ❌ | **API smoke** (below) |

---

## API smoke tests (what gd-eval can't do)

Drive the chat API directly (as in manual verification): create conversation →
POST `/messages` (SSE) → inspect events.

- **Viz render (L3):** confirm the final assistant item is `content.type =
  "multipart"` with a `visualization` part — proves the chart renders, not just
  that a tool was called.
- **Latency:** wall-clock per question + number of tool turns (the ~75s create
  flow = 5 sequential turns). This is the headline A/B metric for the MoE
  candidate.
- **Multi-turn (L6c):** send turn 2 in the same conversation; confirm it refines
  turn 1.

---

## Scoring

Report per model (27B vs 30B-A3B), per level:
- **pass-rate** (gd-eval, `--runs 3` → also consistency across trials)
- **latency** p50/p95 wall-clock + mean tool-turns (API smoke)
- **graceful-fail rate** (L6/L6b — did it stay honest? hallucinated number = hard fail)
- **disambiguation accuracy** (L1b/L6b — right metric among near-duplicates)

Headline comparison: does the MoE candidate hold pass-rate/disambiguation while
cutting latency? That is the decision the A/B exists to make.

---

## Run procedure (checklist)

1. **[blocked]** GlobalMart accessible — workspace deployed + data source
   connected. Data lives in perftest RDS (`bi_tests`, schema
   `globalmart_15c503cc7977cf26`), reachable only by the QA team (SG blocks us).
   → pending QA (inventory + access path).
2. Build `dataset/` — write L1/L1b/L6/L6b now (LDM-only, no data); add
   L2–L5b numeric `must_have` once data values are known.
3. Stand up the second server: deploy `Qwen3-30B-A3B-Instruct-2507` as
   `vllm-a3b` (swap via `use-server.sh`), warm up.
4. Configure local judge (`OPENAI_BASE_URL` → in-cluster vLLM).
5. `gd-eval run` with both `--model`s, `--runs 3`.
6. Run API smoke (viz render, latency, multi-turn) against both servers.
7. Compile the scoreboard; decide 27B vs A3B.

## Open dependencies
- **GlobalMart data access** (perftest RDS) — QA team (blocks L2–L5b runs + all
  numeric assertions). L1/L1b/L6/L6b can run as soon as the workspace LDM is in a
  reachable env.
- **Workspace in a reachable env** — load GlobalMart LDM into our env (as done
  for ecommerce-parent) and point a data source at the data once access is sorted.
- **gd-eval viz/latency/multi-turn** not supported → API smoke scripts (to write).
