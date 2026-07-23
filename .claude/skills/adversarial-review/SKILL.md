---
name: adversarial-review
description: >-
  Reproduce the adversarial code-review TURN HARNESS used by this repo's
  interactive flow (/iship): review the current branch diff with the
  COMPLEMENTARY tool (Claude implements → Codex reviews, or Codex implements →
  Claude reviews), each round ending in a structured `VERDICT:` line, looped to
  convergence by SEVERITY (only BLOCKING findings gate; NITs are recorded, not
  looped), bounded by REVIEW_MAX_ROUNDS → converge=finalize the PR / cap=escalate.
  Use when you have a green branch and need the pre-merge adversarial review, or
  when you want to stand the same harness up in another repo.
allowed-tools: Bash, Read, Grep, Glob
---

# Adversarial code-review turn harness

This is the **implementation-review** mirror of `scripts/plan-critique.sh` (which
hardens the *spec* in `/iharden`). It runs as a **turn loop**: review → fix
blocking → re-run the green-light → re-review, until `VERDICT: APPROVED`
(converged → finalize the PR for the human to merge) or the round cap is hit
still `CHANGES_REQUESTED` (→ escalate). See `AGENTS.md` §"Adversarial code review" and
`.claude/commands/iship.md` step 3 for the canonical text.

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
| `CHECK_CMD` | `npm install && npm run build` | caller convention — the green-light, re-run every round after a fix |
| `REVIEW_MAX_ROUNDS` | `3` | caller convention — bounds the loop; cap-hit-still-CHANGES_REQUESTED = escalate |

The pairing is fixed: **whoever authored does not review.** Claude implements →
Codex reviews; Codex implements → Claude reviews.

**Effort by round (Codex).** Pass `run-review.sh --round <N>` (the round you're already
counting for `REVIEW_MAX_ROUNDS`). Round 1 reviews at `ultra` — max reasoning + automatic
task delegation, the deep first sweep; rounds 2+ at `xhigh`, re-reviewing a narrower fix-up.
The classifier call stays at the inherited default. `CODEX_EFFORT` overrides with a single
fixed tier. (`scripts/plan-critique.sh` scales the same way, keyed off an empty `--thread`.)

## The loop (drive this yourself, one round per turn)

0. **Commit first** so the review sees the full branch diff:
   `git add -A && git commit -m "<conventional subject>"`.
1. **Review one round:** `bash .claude/skills/adversarial-review/run-review.sh --round <N>`
   (`<N>` = this round's number — the counter you bound with `REVIEW_MAX_ROUNDS`; round 1
   reviews at `ultra`, later rounds at `xhigh`. Honours `REVIEWER`/`BASE`/`CODEX_MODEL`/
   `CODEX_EFFORT`). It writes a COMPACT review (blocking findings +
   `VERDICT:`) to `--out`, the final review message to the sibling `<out>.full.md`,
   and prints exactly one `VERDICT:` line. Read `--out` to fix; `cat` the
   `.full.md` into a PR `<details>` for provenance — don't read it into context.
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

## Why two code paths inside the helper

- **`claude -p`** emits the `VERDICT:` line natively from the adversarial prompt —
  one call per round.
- **`codex exec review --base`** is mutually exclusive with a custom `[PROMPT]`
  (clap rejects the combination), so a round is **two** Codex calls:
  (1) `codex exec review --base "$BASE" -o <prose>` captures the final review
  message; (2) a `codex exec` classifier turns that message into the structured
  `VERDICT:` line — keeping the severity call on the reviewer's findings, not on
  the author.

## Reproducing the harness in another repo

Copy this folder, then provide a `BASE` ref and a `CHECK_CMD`. The only repo
coupling is the green-light command and the BLOCKING definition (which keys off
"unmet acceptance criterion from the issue"); everything else is generic. Set
`REVIEWER` to whoever did **not** author (the default is `codex`, matching a
Claude-authored branch).
