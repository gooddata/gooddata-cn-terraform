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
When a tool action is expected, send `tool_choice="required"` with the
**current** valid tool set, so the decoder can only emit a registered name and
a schema-valid argument object. Hallucinated names become physically
impossible and arguments always validate. Kills failure #1 and the empty/
mis-parsed tool calls outright.

- **Where:** `chat_completions_llm.py` (the LOCAL/Chat-Completions adapter).
  Today it sends `tool_choice="auto"`. For a decision turn send
  `tool_choice="required"`; optionally back it with vLLM guided decoding
  (`guided_choice` of tool names, or `xgrammar`/`outlines` via
  `extra_body.guided_*`) so even the name is grammar-constrained.
- **Cost:** adapter-only. No model change.

### S2 — Collapse `set_skills → tool` into one step — *removes a round-trip*
The two-step "activate, then call" is a frontier affordance. For local models,
**auto-activate**: when the model calls a tool that belongs to an inactive
skill, the dispatcher activates the skill and runs the tool in the *same* turn,
instead of returning "not found". Removes one ~50–80 s turn per skill use and
eliminates failure #2.

- **Where:** tool dispatcher / `skill_registry_factory.py`. Resolve
  `tool → owning_skill`; if inactive, activate then execute. Single code path.
- **Cost:** small, localized.

### S3 — Tool-name repair before reject — *kills the loop*
On an unknown name, fuzzy-match (edit distance + a small alias table) to the
nearest registered tool; if within threshold, execute it. Only if no match,
return a structured error — and make the next turn constrained (S1). An alias
map handles known synonyms (`create_visualization → create_adhoc_visualization`).

- **Where:** dispatcher catch path (`base_tool.py` execute boundary).
- **Cost:** ~30 lines + alias table.

### S4 — Minimal, turn-scoped tool surface — *fewer hallucinations, faster prefill*
Expose only the tools relevant to the current step, not every skill. After a
skill is active, surface that skill's tools. Smaller surface = fewer
hallucination targets and shorter prompts (cheaper prefill on a slow GPU).

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
