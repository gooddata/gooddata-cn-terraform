# Hardening the agentic harness for local models

Design note for the GoodData gen-ai agentic loop when driven by a **mid-size
open-weights model** (Qwen3.6-27B and below) instead of a frontier model.

## Root cause

The current loop *describes* the protocol and trusts the model to follow it:
"here are tools, call `set_skills` to unlock a skill, then call its tool, and
if you get an error, fix it." Frontier models follow this; local models do not.
Observed with Qwen3.6-27B:

1. hallucinates a plausible tool name (`create_visualization`) that isn't
   registered;
2. calls a skill's tool **without** first activating the skill;
3. does **not** recover from `Tool 'X' not found. Available: [...]` — it repeats
   the same invalid call.

On local hardware each model turn is **~50–80 s** (27B FP8, L40S). So
unreliability is *also* a latency problem: a visualization that should take 2
turns burns 40 useless turns. **Correctness and speed are the same lever:
fewer, valid round-trips.**

## Principles

1. **Constrain, don't instruct.** Make the valid action space a hard property
   of decoding, not a request in the prompt.
2. **One model turn per decision.** Every avoidable round-trip is ~1 minute.
3. **Fail closed, then repair.** Never echo "not found" and re-ask freely.
4. **Smallest tool surface per turn.** Fewer targets to hallucinate, shorter
   prefill.

## Changes, ranked by leverage / cost

### S1 — Constrained tool selection (guided decoding) — *highest leverage, config-level*
When a tool action is expected, constrain decoding to the **current** valid
tool set so the decoder can only emit a registered name. Hallucinated names
(`create_visualization`) become physically impossible.

- **⚠️ Use `guided_choice` on the tool name, NOT `tool_choice="required"`.**
  Research caveat (vLLM issue tracker): `required` mode forces a JSON grammar
  that *conflicts with* `qwen3_coder`'s native XML tool format and degrades this
  parser (and has edge-case 400s with Qwen3 + reasoning). For this model prefer
  `extra_body={"guided_choice": [<valid tool names>]}` or **named-function**
  `tool_choice` (one specific function) — both whitelist the action without
  fighting the XML parser.
- **Where:** `chat_completions_llm.py` (the LOCAL/Chat-Completions adapter).
  Today it sends `tool_choice="auto"`. On a decision turn, attach
  `guided_choice` of the currently-valid tool names via `extra_body`.
- **Cost:** adapter-only. No model change.
- **Evidence:** vLLM `guided_choice` "output will be exactly one of the
  choices"; Qwen's own docs: protocol adherence "not guaranteed … even with
  proper prompting" → must be enforced in the harness, not the prompt.

### S2 — Collapse `set_skills → tool` into one step — *removes a round-trip*
The two-step "activate, then call" is a frontier affordance. For local models,
**auto-activate**: when the model calls a tool that belongs to an inactive
skill, the dispatcher activates the skill and runs the tool in the *same* turn,
instead of returning "not found". Removes one ~50–80 s turn per skill use and
eliminates failure #2.

- **Where:** tool dispatcher / `skill_registry_factory.py`. Resolve
  `tool → owning_skill`; if inactive, activate then execute. Single code path.
- **Cost:** small, localized.

### S3 — Tool-name repair + structured error feedback — *kills the loop*
On an unknown name, fuzzy-match (edit distance + a small alias table) to the
nearest registered tool; if within threshold, execute it. Only if no match,
return a **structured** error — the authoritative available-tools list (and the
intended tool's doc) — and make the next turn constrained (S1). An alias map
handles known synonyms (`create_visualization → create_adhoc_visualization`).

- **Why structured, not "just re-ask":** for non-frontier models, naive
  append-the-error-and-reflect usually does NOT recover — they repeat the same
  call (exactly our failure #3; arXiv 2510.17874, 2509.18847). External
  structured feedback works: RAG-Repair (injecting the right tool docs after an
  error) improved task success ~36% on average. Reflexion (arXiv 2303.11366)
  adds episodic memory of past errors so the model stops repeating them.
- **Where:** dispatcher catch path (`base_tool.py` execute boundary).
- **Cost:** ~30 lines + alias table.

### S4 — Minimal, turn-scoped tool surface — *fewer hallucinations, faster prefill (research-elevated to a top quick win)*
Expose only the tools relevant to the current step, not every skill. Smaller
surface = fewer hallucination targets and shorter prompts (cheaper prefill on a
slow GPU).

- **Evidence is strong:** small models degrade when shown the full tool library
  *even when it fits in context*. Llama3.1-8B failed to select the right tool
  among 46 but succeeded among 19 ("Less is More", arXiv 2411.15399); RAG-MCP
  (arXiv 2505.03275) showed all-tools = 13.6% selection accuracy and that
  just-in-time / retrieved tool exposure more than triples it. This is also the
  direct argument for S2 (flatten the skill protocol) — fewer, just-in-time
  tools beat a big static menu.
- **Where:** tool-list assembly before each model call.

### S5 — Bounded, productive recovery — *fail fast, not 40×*
Detect "same tool + same args + same error" and break after N=2 instead of
looping to the 40-iteration cap. On repeat, either force a different
`tool_choice` or return a graceful text answer.

- **Where:** `conversation_service` loop guard.

## Net effect

| | before | after |
|---|---|---|
| hallucinated tool name | possible | impossible (S1) |
| skill activation | model must remember | automatic (S2) |
| typo / synonym | hard error → loop | repaired (S3) |
| runaway | up to 40 turns | ≤ 2–3 turns (S5) |
| visualization request | never completes | ~2–3 turns |

S1 alone (adapter config) is the quick win and likely fixes the visualization
path on its own. S2+S3 make it robust; S4+S5 make it fast and bounded. None
require a different model — they make the *current* local model behave.

## Prompt layer (supporting, not load-bearing)

With S1–S5 the prompt stops being the safety mechanism, but still help local
models:
- one concrete **few-shot** example of a correct `set_skills(['visualization'])
  → <real tool>` sequence (show, don't describe);
- an explicit line: "Only call a tool present in the current tool list."

Keep prompts short — long prompts slow prefill on the GPU and don't fix
protocol adherence that S1–S5 already enforce.

## Scope

Applies to the `LOCAL`/OpenAI-compatible provider path (vLLM, SIE, TGI). Has no
effect on frontier providers, which already follow the protocol — so these can
be gated to local providers and shipped without risk to the OpenAI path.

## Research backing (deep-research, adversarially verified)

The central thesis — *prompting can't fix this, the harness must* — is
confirmed at high confidence: Qwen's own docs state protocol adherence is "not
guaranteed … even with proper prompting or templates" and advise production
"countermeasures." So S1–S5 (harness) are load-bearing; the prompt layer is a
cheap complement (a few-shot example using deliberately *fake* tool names
reliably teaches the call format to 7–9B models — LangChain).

Key sources:
- Qwen function-calling docs (protocol not guaranteed): https://qwen.readthedocs.io/en/latest/framework/function_call.html
- vLLM structured outputs / `guided_choice`: https://docs.vllm.ai/en/v0.9.2/features/structured_outputs.html
- vLLM tool calling (required/named-function, qwen3_coder caveat): https://docs.vllm.ai/en/latest/features/tool_calling/
- Tool surface bloat — "Less is More" (46→19 tools): https://arxiv.org/pdf/2411.15399
- RAG-MCP (just-in-time tool exposure ~3× accuracy): https://arxiv.org/abs/2505.03275
- Tool-error recovery failures in non-frontier agents: https://arxiv.org/pdf/2510.17874 · https://arxiv.org/abs/2509.18847
- Reflexion (episodic memory of errors): https://arxiv.org/abs/2303.11366
- Few-shot tool-calling (fake-tool examples): https://blog.langchain.com/few-shot-prompting-to-improve-tool-calling-performance/
