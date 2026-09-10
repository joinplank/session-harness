---
name: adversarial-review
description: >-
  Reproduce the adversarial code-review TURN HARNESS used by the interactive flow
  (/iship): review the current branch diff with the COMPLEMENTARY tool (Claude
  implements → Codex reviews, or Codex implements → Claude reviews), each round
  ending in a structured `VERDICT:` line, looped to convergence by SEVERITY (only
  BLOCKING findings gate; NITs are recorded, not looped), bounded by
  REVIEW_MAX_ROUNDS → converge=finalize the PR / cap=escalate. Ships two advisory
  extras that gate nothing: an optional DeepSeek third opinion and a directed
  --ask probe. Use when you have a green branch and need the pre-merge adversarial
  review, or when you want to stand the same harness up in another repo.
allowed-tools: Bash, Read, Grep, Glob
---

# Adversarial code-review turn harness

This is the **implementation-review** mirror of `plan-critique.sh` (which
hardens the *spec* in `/iharden`). It runs as a **turn loop**: review → fix
blocking → re-run the green-light → re-review, until `VERDICT: APPROVED`
(converged → finalize the PR for the human to merge) or the round cap is hit
still `CHANGES_REQUESTED` (→ escalate). See `AGENTS.md` §"Adversarial code review" and
`/iship` step 3 for the canonical text.

## The one rule that makes it terminate

Convergence is by **severity, not zero-findings** — otherwise an adversarial
reviewer's endless nits would never let a clean round happen.

- **BLOCKING** (must be fixed to converge): a correctness bug, a security or
  data-loss risk, a broken public contract/API, a regression, or an **unmet
  acceptance criterion from the issue**.
- **NIT** (never blocks): style, naming, formatting, subjective preference,
  optional refactors, doc wording, speculative "could also." **Record** these in
  the PR/issue comment; do **not** loop on them.

## Knobs (repo defaults)

| Var | Default | Meaning |
| --- | --- | --- |
| `REVIEWER` | `codex` | env for `run-review.sh` — whoever did **not** author reviews |
| `BASE` | `origin/<default-branch>` | env for `run-review.sh` — what the branch diff is taken against |
| `CODEX_MODEL` | `gpt-5.6-sol` | env for `run-review.sh` — the Codex model the review + classifier run on |
| `CODEX_EFFORT` | *(unset)* | env for `run-review.sh` — force one reasoning tier for all rounds; unset = round policy (below) |
| `DEEPSEEK_MODEL` | `deepseek/deepseek-v4-pro` | env for `run-review.sh` — the model the optional DeepSeek pass runs on |
| `DEEPSEEK_MAX_DIFF` | `200000` | env for `run-review.sh` — bytes of diff the DeepSeek pass will accept before refusing |
| `OPENCODE_BIN` | *(resolved)* | env for `run-review.sh` — the opencode binary; falls back to `~/.opencode/bin/opencode` |
| `MODEL_CALL_TIMEOUT_S` | `1800` | env for `model-call.sh` — the per-call bound; 30 min is an order of magnitude above the longest real call, so only a stopped one reaches it |
| `CHECK_CMD` | `npm install && npm run build` | caller convention — the green-light, re-run every round after a fix |
| `REVIEW_MAX_ROUNDS` | `3` | caller convention — bounds the loop; cap-hit-still-CHANGES_REQUESTED = escalate |

The pairing is fixed: **whoever authored does not review.** Claude implements →
Codex reviews; Codex implements → Claude reviews.

**Effort by round (Codex).** Pass `run-review.sh --round <N>` (the round you're already
counting for `REVIEW_MAX_ROUNDS`). Round 1 reviews at `ultra` — max reasoning + automatic
task delegation, the deep first sweep; rounds 2+ at `xhigh`, re-reviewing a narrower fix-up.
The classifier call stays at the inherited default. `CODEX_EFFORT` overrides with a single
fixed tier. (`plan-critique.sh` scales the same way, keyed off an empty `--thread`.)

## The loop (drive this yourself, one round per turn)

0. **Commit first** so the review sees the full branch diff:
   `git add -A && git commit -m "<conventional subject>"`. Mint this run's scratch dir once —
   `W="$(mktemp -d)"` — and keep every round's output under it (a caller that already has one,
   like `/iship`, reuses that).
1. **Review one round:** `bash run-review.sh --round <N> --out "$W/review-r<N>.md"`
   (`<N>` = this round's number — the counter you bound with `REVIEW_MAX_ROUNDS`; round 1
   reviews at `ultra`, later rounds at `xhigh`. Honours
   `REVIEWER`/`BASE`/`CODEX_MODEL`/`CODEX_EFFORT`). It writes a COMPACT review (blocking findings +
   `VERDICT:`) to `--out`, the final review message to the sibling `<out>.full.md`,
   and prints exactly one `VERDICT:` line. Read `--out` to fix; `cat` the
   `.full.md` into a PR `<details>` for provenance — don't read it into context.

   **Name `--out` for the round.** Between a round finishing and the caller posting it, those two
   files are the round's only copy — the comment can't go up sooner, because it says what the
   author fixed. Reusing one path across rounds destroys the earlier round with no warning, so an
   `--out` (or `<out>.full.md`) that already holds a round is **refused before the reviewer runs**,
   naming the occupied path. Answer a refusal with a fresh path, not by deleting the file. (A
   reviewer that died leaves an empty file, which is not a round and does not block re-running it.)
2. `VERDICT: APPROVED` → **converged.** Stop looping; finalize (ready the PR for
   the human to merge). Log the dismissed NITs in the PR comment.
3. `VERDICT: CHANGES_REQUESTED` → fix **only the BLOCKING** items, commit, re-run
   the green-light (`CHECK_CMD`), then go back to step 1.
4. Repeat until `APPROVED` **or** you have run `REVIEW_MAX_ROUNDS` rounds.

**Outcome:**
- `APPROVED` within the cap → finalize; record dismissed nits.
- Cap hit still `CHANGES_REQUESTED` (a blocking finding you can't resolve in
  scope) → **escalate**, do not merge. The cap bounds the loop — no review thrash.
- If the reviewer tool can't be run at all → do **not** merge; escalate and say
  exactly which reviewer command failed. Never substitute manual self-review.

## The optional DeepSeek pass (`--reviewer deepseek`)

A third opinion an engineer asks for when they want one — a fresh model over the same diff,
useful where the gating reviewer and the author share a blind spot. **It is never a gate**, and
that follows from it being optional: a reviewer that is sometimes skipped is one nothing that
merges can depend on. So it does not enter the loop, does not count a round, and its
`CHANGES_REQUESTED` does not block a merge.

Read it the way the concept pass is read: **disposition every finding** — apply it, or decline it
with a one-line rationale — and record the pass on the PR. Convergence still turns on the gating
reviewer alone. Its failures say *record it and carry on* rather than *escalate*, for the same
reason.

    bash run-review.sh --reviewer deepseek --out "$W/deepseek-1.md"

`$W` is this run's scratch dir (step 0 of the loop above mints it); a second third opinion in the
same run gets `deepseek-2.md`, under the same one-path-per-pass rule the loop explains.

DeepSeek runs through `opencode` (which holds the credential) on the same single-call contract as
the `claude` reviewer: one call, the diff inlined, the model closing with its own `VERDICT:` line.
Because the diff is inlined into a window much shorter than the gating reviewers', a branch over
`DEEPSEEK_MAX_DIFF` is **refused rather than truncated** — a silently clipped diff would read as a
complete review over code the model never saw, and no one re-checks an advisory verdict.

## The directed probe (`--ask`)

One aimed question about the same diff, for when a round needs to ask the
reviewer something specific instead of sweeping. It follows the selected
reviewer and refuses none of them — a question needs a custom prompt, so every
backend is a single call.

```bash
run-review.sh --reviewer codex --ask "Does X hold for every caller of Y?" --out "$W/probe-1.md"
```

The answer lands at `--out`; **the question is written to `<out>.question.md`
before the call is made**, so a probe that dies leaves it recoverable. Like the
DeepSeek pass it is **advisory**: it gates nothing, consumes no review round, and
a failure is not an escalation. A probe whose attempts are exhausted is recorded
on the PR as **UNANSWERED**, with its question — the call was made, so "unasked"
would misreport it.

## Why two code paths inside the helper

- **`claude -p`** (and the DeepSeek pass) emits the `VERDICT:` line natively from
  the adversarial prompt — one call per round.
- **`codex exec review --base`** is mutually exclusive with a custom `[PROMPT]`
  (clap rejects the combination), so a round is **two** Codex calls:
  (1) `codex exec review --base "$BASE" -o <prose>` captures the final review
  message; (2) a `codex exec` classifier turns that message into the structured
  `VERDICT:` line — keeping the severity call on the reviewer's findings, not on
  the author.

## Every model call is supervised (`model-call.sh`)

`run-review.sh` invokes no model CLI directly. Each review, classifier and probe
call goes through `model_call`, which **bounds** it (`MODEL_CALL_TIMEOUT_S`),
**isolates** each attempt's output so only a successful attempt is published, and
**retries** exactly the calls that have a mechanical write boundary. An
unsupervised call has two failure modes that both end as a round which silently
did not happen: it hangs forever, or it dies mid-stream having produced nothing.

Retry is opt-in, and the rule is the sandbox flag, not the shape of the prompt:
`codex exec … -s read-only` earns a retry (the classifier, and the Codex probe),
while `codex exec review --base` (no sandbox flag),
`claude -p --dangerously-skip-permissions` and `opencode run --pure` (plugins,
not writes) are bounded and run once.

## Reproducing the harness in another repo

Copy this folder **and `model-call.sh`**. `run-review.sh` finds that helper in the
`scripts/` directory beside the skill's install root, which is where it sits in both
supported layouts — `<plugin-root>/scripts/` when the harness is installed as a plugin,
`<repo>/scripts/` when a repo vendored it under `.claude/skills/`. Then provide a `BASE`
ref and a `CHECK_CMD`. Beyond that helper the only repo coupling is the green-light
command and the BLOCKING definition (which keys off "unmet acceptance criterion from the
issue"); everything else is generic. Set `REVIEWER` to whoever did **not** author (the
default is `codex`, matching a Claude-authored branch).
