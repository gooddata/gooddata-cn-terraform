---
name: sync-settings-tfvars
description: Merge new structure from the checked-in aws/azure/local settings.tfvars.example files into the developer's gitignored settings.tfvars, adding newly introduced variables and refreshing stale boilerplate comments while never altering a value the developer already set. Use this whenever the user says their settings.tfvars is out of date or behind the example, asks to sync/update/refresh/reconcile settings.tfvars, mentions that an example file changed or gained new variables, wonders which new tfvars knobs appeared after a pull, rebase, or merge, or hits an "unsupported argument" / undefined-variable / missing-required-variable error from Terraform after pulling — even if they never use the word "sync".
---

# Sync settings.tfvars from settings.tfvars.example

`settings.tfvars.example` is checked in and evolves with the code: new variables
appear, defaults flip, comments get corrected. The developer's real
`settings.tfvars` is gitignored, so it silently falls behind — and because it's
gitignored, **there is no git history to recover it from if you damage it.** It
also holds live secrets (license key, Docker Hub PAT, subscription IDs).

That asymmetry drives every rule below: the example is the authority on
*structure*, the private file is the authority on *values*, and a mistake in the
private file is unrecoverable.

## The four pairs

| Env | Example (checked in) | Private (gitignored) |
| --- | --- | --- |
| `aws/` | `settings.tfvars.example` | `settings.tfvars` |
| `azure/` | `settings.tfvars.example` | `settings.tfvars` |
| `stackit/` | `settings.tfvars.example` | `settings.tfvars` |
| `local/` | `settings.tfvars.example` | `settings.tfvars` |

Sync all four unless the user names specific ones. A private file that doesn't
exist yet isn't a sync — say so and offer to seed it from the example instead of
inventing values.

## Procedure

### 1. Back up outside the repo

```bash
BACKUP=$(mktemp -d) || { echo "could not create backup dir — stop"; exit 1; }
for e in aws azure stackit local; do
  [ -f "$e/settings.tfvars" ] || continue
  cp "$e/settings.tfvars" "$BACKUP/$e-settings.tfvars" \
    && cmp -s "$e/settings.tfvars" "$BACKUP/$e-settings.tfvars" \
    || { echo "backup of $e/settings.tfvars failed — stop, do not merge"; exit 1; }
done
echo "backup: $BACKUP"
```

Every copy is checked, and a failure stops the run before anything is edited.
Don't collapse this into one `&&` chain per iteration: a `cp` that fails early
is otherwise masked by a later iteration succeeding, and you would merge into an
unrecoverable file believing it was backed up.

Outside the repo on purpose: `.gitignore` matches `*.tfvars`, so a
`settings.tfvars.bak` sitting in `aws/` would *not* be ignored and could be
committed with live secrets in it. Report the backup path to the user.

### 2. Survey the drift

```bash
python3 .claude/skills/sync-settings-tfvars/scripts/structure_diff.py aws azure stackit local
```

This redacts every value, so its output is safe to read and quote. Per pair it
gives a unified diff of the *structure* (comments and variable names, with
multi-line heredocs/lists collapsed) plus three lists: variables only in the
example (these are what you must add), variables only in the private file
(deliberate overrides — keep them), and everything currently set.

Then read both files in full. The script tells you where to look; it can't tell
you which comments are boilerplate versus the developer's own notes, and that
distinction is the whole job.

### 3. Merge

Work through the private file top to bottom, in place. Apply the rules in the
next section. Keep each file's existing section order — the goal is a file the
developer still recognizes, not a regenerated one.

### 4. Verify

```bash
# fmt only the files that exist — a developer using one cloud has no azure/stackit/local tfvars
# no -diff: on a misformatted file it prints the offending lines, secrets included
for e in aws azure stackit local; do
  [ -f "$e/settings.tfvars" ] && terraform fmt -check "$e/settings.tfvars"
done
python3 .claude/skills/sync-settings-tfvars/scripts/structure_diff.py aws azure stackit local

# definitive: exits non-zero if any value fails a validation block
cd <env> && terraform plan -var-file=settings.tfvars

# quick look, no init needed; console takes one expression per invocation
# read the output — it exits 0 even when a validation fails
cd <env> && for v in size_profile enable_ai_features; do
  echo "var.$v" | terraform console -var-file=settings.tfvars
done
```

- `fmt -check` must come back clean (exit 0; it prints only the paths of files
  that need reformatting). It covers `.tfvars` but **not** `.tfvars.example`.
  Never add `-diff` here — the diff body quotes the misformatted lines verbatim,
  which for these files means license keys and tokens on your terminal.
- The second `structure_diff` run must show no example-only variables left. The
  remaining diff should be only intentional: real values against commented
  placeholders, the developer's own annotations, and their extra overrides.
- `terraform console -var-file=settings.tfvars` does run every `validation`
  block — observed on Terraform 1.15.6, where even `1 + 1` reports the errors
  for *all* invalid variables — but **it is not a pass/fail gate**: it prints
  the validation error, then prints the result anyway and still **exits 0**.
  Read its output; never infer success from its exit status or from a loop that
  "ran clean". It usually needs no `init`, which is why it's the quick first
  look.
- `terraform plan -var-file=settings.tfvars` is the definitive check — it exits
  non-zero on a rejected value, including cross-variable validations like AI
  Lake requiring `starrocks_size_profile`. Input validation is evaluated before
  provider credentials are needed, so it still reports variable errors in an env
  with no cloud access; expect unrelated provider/credential errors alongside
  and ignore those. Prefer it whenever you can run it.
- If either fails with `Inconsistent dependency lock file`, don't assume it's
  unrelated. Confirm it is pre-existing — reproduce it on the unmodified files
  (e.g. `git stash` your edits, or run against a clean checkout) — and only then
  report and leave it, because `terraform init -upgrade` would rewrite a lock
  file the user didn't ask you to touch. If it appears only *after* your edit,
  it is yours to fix.
- **Re-run the whole sync mentally, or literally, once more.** A second pass must
  be a no-op. If it wouldn't be — if you'd reorder the same comment or re-add the
  same line — you applied a rule non-deterministically, and every future sync
  will churn the file. Idempotence is the cheapest signal that you followed the
  rules rather than rewrote to taste.

Never run `terraform apply`. `terraform plan` is safe and is the check that
actually gates on a bad value; run it where you can.

### 5. Report

Per environment: variables added, comment wording refreshed, values preserved,
and anything deliberately left alone. Then, separately and prominently, any
**behavior change** (see the default-flip trap) and any file you touched beyond
the private ones. Quote variable names, never secret values.

## Merge rules

**Values are sacred.** If the private file assigns something, that assignment
survives byte-for-byte — including versions that look "old" next to the example.
A pinned `helm_gdcn_version = "4.8.0"` against an example's `"4.10.0"` is a
deployment decision, not drift. Mention the difference in your report and move
on. The one thing that overrides this is a value the current schema rejects
(caught in step 4), which you raise rather than silently rewrite.

**Add what's missing, where it belongs.** A variable the example introduces gets
copied into the private file in its own section, in the example's position and
comment-state — a commented placeholder stays commented. The developer opts in
later; you're making the knob discoverable, not enabling it.

**A commented placeholder is documentation, unless the developer personalized
it.** A commented line changes nothing at apply time; its job is to show the
shape of the knob and a currently-sensible value. So placeholders track the
example, literal included — when the example flips `# enable_ai_features = true`
to `# enable_ai_features = false`, the private file's placeholder flips too.
The exception is a literal the developer clearly typed themselves: their real
hostname, their email, an actual instance class where the example has
`me@example.com` or `x.x.x.x/32`. That's a parked note for a change they intend
to make, so keep the literal and refresh only the comment above it. The test is
simple — would this exact literal appear in a fresh checkout of the example? If
yes it's boilerplate and tracks. If no, they wrote it and it stays.

**Refresh boilerplate comments, and adapt the voice.** Section headers and
explanatory comments should match the example's current wording, since that's
where corrections land. But example comments are written for an unset file
("Uncomment to enable the observability stack"), and the private file often has
the thing set. Carry the *content* and fix the voice, e.g. "GenAI services are
ON by default; uncomment to disable" becomes "…; disabled here" above an
explicit `enable_ai_features = false`. Copying the example's imperative verbatim
over a line that's already set reads as an instruction the developer failed to
follow.

Do it in place: replace boilerplate lines where they already sit and leave
everything else in its current order. Don't restructure a section to match the
example's layout — the private file's shape is the developer's, and reordering
makes the next sync churn it again.

**Keep the developer's own annotations.** A comment explaining *why they* chose
something — a load-test rationale above `rds_instance_class`, a commented-out
telemetry POC block — is content the example never had and must not be
overwritten by boilerplate. Distinguish by subject: boilerplate explains what a
variable does, an annotation explains a local decision. When a section has both,
keep the annotation where it sits and refresh only the boilerplate around it.

**Boilerplate the developer deleted stays deleted.** If the private file sets a
variable and has trimmed the explanation above it, don't reinstate that
explanation from the example. Someone who has set a value already knows what it
does, and these files get read constantly by the one person who owns them —
re-adding prose they removed makes the sync noisy and, worse, non-idempotent,
since the next run would want to add it all over again. Refresh comments that are
there; don't restore comments that aren't.

**Don't leave a placeholder for something already set.** If the private file
actually assigns a variable, drop the example's commented `# var = ...`
placeholder for it rather than carrying both. Two mentions of the same variable
a few lines apart, one commented, is the kind of thing that gets edited by
mistake later.

**Private-only variables stay.** Anything in the private file but not the
example is an intentional override. Leave it, keep its rationale comment, and
list it in the report so the user can confirm it's still wanted.

**Respect per-cloud asymmetry — check before adding.** The four environments
have genuinely different variable sets, so never copy a section across clouds by
analogy. Confirm against that environment's `variables.tf` that a variable exists
and a value is legal before introducing it. Three real examples: AI Lake
(`enable_ai_lake`, `starrocks_size_profile`) exists for AWS and has no Azure
counterpart, and `size_profile` accepts `prod-xl` on AWS while Azure's validation
block rejects it; and STACKIT declares `enable_image_cache` but validates that
it stays `false`, with no `dockerhub_*` variables at all, because STACKIT's
container registry has no Terraform resources. Comments listing valid values
are part of this — an AWS-accurate list pasted into Azure documents a value
that fails validation.

**Fix comments that are wrong, and say that you did.** Occasionally a private
file carries a comment that no longer describes the code under it — a leftover
from a block that was rewritten. Replace it with something short and accurate
rather than preserving misinformation, and call it out in the report so the
developer can confirm you read their intent correctly. Keep new comments to one
or two lines, matching the density of the surrounding file.

## Traps

**A default flip is a behavior change hiding in a comment.** When an example
comment goes from "Uncomment to enable X" to "X is ON by default; uncomment to
disable", the variable's `default` in `variables.tf` changed. Nothing in the
private file needs editing — but a variable left commented out now means the
*opposite* of what it meant before. Verify the new default against
`<env>/variables.tf`, then tell the user plainly which environments just changed
behavior. This is usually the most consequential thing in the whole sync and the
easiest to miss, because the mechanical diff is one comment line.

**Structure changes can add a required companion.** A single variable can become
a pair — `enable_ai_lake` gaining a mandatory `starrocks_size_profile`. When an
example's comment says two lines are required, carry both placeholders, or an
opt-in later will fail. Read what the comment asserts, don't just copy lines.

**When the two files assert contradictory facts, the example wins — but say so.**
You'll hit comments that can't both be true: the private file claiming retention
data sits in per-signal PVCs while the example says Loki and Tempo write to
object storage. The example ships alongside the code and gets corrected when the
code changes, so it's the authority on *how the system behaves*; the private file
never is. Propagate the example's claim. But a specific factual assertion is
worth two minutes of checking — grep the relevant module rather than trusting
either file — and if you can't confirm it, note the contradiction in your report
so the developer can settle it. Quietly overwriting one unverified claim with
another is how wrong documentation spreads.

**The example itself may be stale.** The examples are checked in, so they drift
too — a comment saying "uncomment to enable" under a variable whose default is
now `true`, or `.tfvars.example` misalignment that `terraform fmt` can't reach
(it won't align commented assignments, and most lines in these files are
commented). Fixing that is usually right since the example is the source of truth
for every future sync, but it's a tracked file outside the ask, so keep it tight:
fix only what you had to read anyway to do the sync, don't open a whole-file
style audit, and flag it separately in the report so it isn't mistaken for part
of the private-file sync.

**Secrets stay out of your output.** License keys, Docker Hub PATs, and
subscription IDs live in these files. Refer to them by variable name. Prefer
`structure_diff.py` over `diff`/`cat` when showing the user what changed, and
never paste a private file's contents into a report, commit message, or PR body.
