---
description: Phase 3 of INTERACTIVE mode. Implement the hardened issue in THIS session (keeping full plan context), get adversarial code review in a separate Codex shell, objectively apply it, and open a PR for the human to merge.
allowed-tools: Read, Grep, Glob, Bash, Write, Edit, Agent
---

Implement (Phase 3). Run in the **clone-rooted Claude session** (the same one you discussed
and `/iharden`-ed in); it resolves issue `#N` from `.session.json` in the current directory
(it errors if you haven't `/iharden`-ed yet — `issue` is null — or if the issue is still
being hardened — labeled `interactive:draft`; see step 0).

Drive to the completion bar below. The bar is the **objective**; the numbered steps are the
**method**. Normally you're **already running under the `/goal` loop** that `/iharden` armed (you
pasted the line it emitted) — so proceed through the steps. You retain the full discuss + plan
context from this session — use it; don't re-derive decisions from the issue body alone.

These rules govern the whole run: verify each criterion by running its real check
(the green-light, the Codex `VERDICT:` line, `gh pr view`), and **never weaken a check to force
it green**. Escalation is the **iship way** — if a criterion can't pass (the build won't
green, the review cap is hit still `CHANGES_REQUESTED`, or a blocking finding is unresolvable),
do step 3's escalation (draft PR + `interactive:escalated` + comment) instead of declaring
success. The bar's escalation disjunct makes a correctly-escalated run **terminal** to the
evaluator — escalation satisfies the bar by stopping honestly, never by looping harder.

Mint a scratch dir for the review artifacts used below: `W="$(mktemp -d)"`.

## 0. Pre-flight, then arm the `/goal` loop (normal path: `/iharden` already armed it)

**How you got here.** In the normal flow `/iharden` emits the `/goal` line on approval and you
pasted it, so the loop is **already armed** — do the pre-flight below, then go straight to step 1.
Only if you ran `/iship` **by hand** (to resume, or you skipped the emitted line) is no goal armed
yet; then also do the **Arm** step at the end of this section.

**Pre-flight (always).** The harden gate is only real if it's enforced here: refuse to implement an
issue that is still `interactive:draft` (hardening not finished — `/iharden` removes that label on
convergence). From the session clone root:

```bash
# Where the harness lives. Installed as a plugin, the loader substitutes the token below with the
# plugin root; in a repo that vendored the harness the token is left alone, expands to empty, and
# the fallback names the repo itself — so one line is correct in both layouts.
H="${CLAUDE_PLUGIN_ROOT}"; [ -n "$H" ] || H="$(git rev-parse --show-toplevel)"
# The review skill sits at a different depth in the two layouts, so name it once here.
R="$H/skills/adversarial-review/run-review.sh"; [ -f "$R" ] || R="$H/.claude/skills/adversarial-review/run-review.sh"

[ -f .session.json ] || { echo "not in a session clone — run /isession first"; exit 1; }
ISSUE="$(jq -r '.issue' .session.json)"
[ "$ISSUE" != "null" ] || { echo "no issue adopted yet — run /iharden first"; exit 1; }
# Fail CLOSED: a transient lookup failure must NOT be read as "hardened" (don't implement
# against an unverified plan). Capture output + status separately.
if ! LABELS="$(gh issue view "$ISSUE" --json labels -q '.labels[].name' 2>/dev/null)"; then
  echo "could not fetch labels for issue #$ISSUE — retry; do NOT implement against an unverified plan"; exit 1
fi
if printf '%s\n' "$LABELS" | grep -qx interactive:draft; then
  echo "issue #$ISSUE is still interactive:draft — finish /iharden (it removes the label) before /iship"; exit 1
fi
```

(`$H` is the harness root and `$R` the review script — set once here and reused by every block below that shells out
to the harness. If a later block finds it empty, re-run those two lines; it is the whole
portability contract between the plugin and vendored layouts.)

**Arm (manual entry only).** If you got here by running `/iship` by hand and **no `/goal` is armed
yet**, arm it now. Claude Code's **built-in `/goal`** keeps the session working — after every turn a
fast evaluator re-checks the condition *from the conversation transcript alone* (it runs no tools of
its own) and re-prompts until it holds. It is **user-invocable only** (the Skill tool cannot trigger
it), so the human must paste it. Print exactly this line with `#N` filled in, ask the human to paste
it, and **end your turn** — step 1 begins on their next message (or, if they decline or say
"continue," proceed unarmed; the bar governs either way). If the loop is **already armed** (the
normal path), skip this and go straight to step 1:

```
/goal Ship issue #N via /iship. Done when the harness's `session.sh status` reports READY (a non-draft PR closes #N) or ESCALATED (interactive:escalated). Run it to prove which. Or stop after 20 turns.
```

**The completion bar, stated once (this is what the terse goal keys on):** the run is done at one
of two terminal states, each surfaced by `"$H/scripts/session.sh" status` as a single transcript token
the evaluator can read —
- **READY** — step 4 flipped a non-draft PR (that closes #N) to ready-for-merge. It does that
  *only* after the green-light passed and the review loop converged on `VERDICT: APPROVED` — with
  the one-time concept-minimalism pass folded in **after the first review round** (step 3), so
  reaching READY already implies the whole bar.
- **ESCALATED** — step 3 stopped for a human (PR kept draft + `interactive:escalated` label).

The condition keys on those two tokens instead of re-listing the sub-criteria, because reaching
READY *requires* them (steps 2–4) — so `status` runs no build; it just reads PR/label state and is
fail-safe (any lookup error reports `IN-PROGRESS`, never a false terminal). The evaluator only sees
what the transcript shows, so steps 3 and 4 **run `"$H/scripts/session.sh" status`** at their terminal
state to surface the token.

## 1. Implement

(Normal path: you're already under the `/goal` loop `/iharden` armed — start here. If instead you
armed manually in step 0, step 1 begins on the human's next message, never in step 0's turn.)

Make the changes on this clone's task branch (`task/<N>-<slug>`), guided by the issue's acceptance
criteria **and** the decisions/rationale you hold in context. Commit as you go.

**Code comments obey AGENTS.md §Code comments for the whole run** — a comment explains the code
as it stands, never citing issue/PR numbers or review rounds and never narrating the edit that
introduced it. This governs review-round fixes too: a fix's comment justifies the resulting code
on its own terms, not the finding that prompted it (the PR thread is where findings live).

**Scope-drift tripwire.** If the diff starts growing concepts the issue never named — a new table,
endpoint, config knob, or piece of vocabulary — stop and check with the human before continuing:
that is a plan change, not implementation detail. (The concept pass in 3b audits after the fact;
this catches runaway while you author.)

**Then run the `/simplify` skill — before you green-light.** Once the implementation is functionally
complete and building, invoke the **`/simplify`** skill over this branch's diff (`git diff
main...HEAD`), told to **preserve behavior and public contracts** and to **rewrite or drop any
comment that violates AGENTS.md §Code comments** (issue/PR references, edit narration) — a
code-level clarity pass on the code you just wrote. Run it *now*, before the Step-2 green-light, so the green-light, the reviewer,
and the concept pass (3b) all see the simplified result rather than your first draft. (If `/simplify`
isn't available in this session, fall back to the `code-simplifier` agent, or do the equivalent pass
by hand.)

**Disposition its edits — converge toward SIMPLE, not toward "accept every rewrite":** keep the
behavior-preserving clarity wins; **revert** anything that changes behavior, over-abstracts, or is
churn for its own sake. Commit what you keep; the Step-2 green-light then verifies it builds. Note
in the PR's **Summary** that a simplify pass ran.

This placement is deliberate: it's a **code-level** edit that runs BEFORE review, so the adversarial
rounds and the concept pass audit already-simplified code — less churn, and findings land on the
shape you'll ship. It does **not** replace step 3b's **concept-level** parsimony audit (that runs
later, on the reviewed code, and only flags — it doesn't edit).

## 2. Green-light, then open a DRAFT PR

The green-light belongs to the repo, not to this harness: **`AGENTS.md` §Green-light** names it.
Read it there and run it — never assume a stack. If AGENTS.md names none, stop and ask; a build
command you guessed proves nothing when it passes.

**Capture it to a log** — build output is hundreds of lines and you re-run this every review
round; your context should absorb one word on success and the error tail on failure:

```bash
(<the green-light from AGENTS.md>) > "$W/green.log" 2>&1 && echo GREEN || tail -60 "$W/green.log"
```

A fresh clone pays a cold dependency install on the first run. Then push and open a **draft** PR
immediately, so escalation always has a PR to mark:

```bash
git push -u origin HEAD
gh pr create --draft --base main \
  --title "<subject>" --body "$(printf 'Implements #%s\n\nCloses #%s\n' '<N>' '<N>')"
```

**Seed the evolving PR description now** — start `$W/pr-body.md`, the one description that step 3
refreshes each review round (its concept pass fills the Concepts section) and step 4 finalizes.
Lay down the section skeleton step 4 defines — **Summary**, **How tested**, **Review**,
**Concepts**, **Acceptance-criteria checklist** — plus the `Closes #N` keyword. Leave Review
"pending (loop next)", **Concepts** "pending — the concept pass runs after review round 1 (step
3b)", and the ACs unchecked for now; step 3 fills them in. Then set it:

```bash
gh pr edit --body-file "$W/pr-body.md"
```

## 3. Adversarial code review + concept pass — interleaved, in a separate Codex shell

The review runs in **rounds** (each a separate Codex shell, brought back here), bounded by
`REVIEW_MAX_ROUNDS` (default 3). The **one-time concept-minimalism pass runs *between* the first
round and the rest**, so: **round 1 → concept pass (once, 3b) → remaining rounds → converge**.
That ordering is deliberate — the concept checker then audits *reviewed* code (a review round's
blocking fix is often new code — a helper, a branch — that deserves the concept lens too), and the
remaining review rounds re-review whatever the concept pass simplified. It closes both gaps a
run-it-once-before-review order leaves open.

**A review round** is:

```bash
ROUND=<n>   # this round's number (1, 2, 3…); round 1 runs Codex at ultra, later rounds at xhigh
"$R" --reviewer codex --round "$ROUND" --out "$W/review-r$ROUND.md"
```

This writes **two** files: `$W/review-r$ROUND.md` — COMPACT (the classifier's blocking findings +
the `VERDICT:` line) — and `$W/review-r$ROUND.full.md` — the reviewer's final review message (the
raw session transcript is never published). **Read only the compact file** to assess and fix; it's
all you need under the severity rule. **Never `Read` the `.full.md` into your context** — it exists
solely to `cat` into the PR `<details>` below for provenance. That split is what keeps this
session's context clean across review rounds.

**Name `--out` for the round.** Between a round finishing and the comment below going up, those two
files are the round's only copy — the comment can't be posted sooner, because it says what you
fixed. So `run-review.sh` **refuses an `--out` that already holds a round** rather than overwriting
it. Answer a refusal with a fresh path, never by deleting the file in the way.

(Pin `--reviewer codex` explicitly: the main session is the Claude author, so the
independent reviewer must be Codex — state it rather than rely on the default.
This review is **diff-adversarial**: `codex exec review` sees the branch diff, not the issue
spec, so it does **not** check acceptance-criteria completeness. That's by design — **you +
the human are the AC authority**, enforced by the step-4 AC checklist that gates the
draft→ready flip. Don't pass `ISSUE`/`REPO_SLUG` expecting an AC check; the Codex path
ignores the spec.)

**Assessing a round.** Read `$W/review-r$ROUND.md` (compact — its `VERDICT:` line + blocking findings),
then **objectively** assess the findings under the severity rule — fix **blocking** (correctness,
security, data-loss, broken contract/API, regression, or an unmet acceptance criterion), record
nits without looping — and **guard against rationalizing your own work** (you wrote it; weigh the
critique honestly) **while equally guarding against the reviewer's additive bias**: fix each
blocking finding with the SIMPLEST change that resolves it — don't add abstractions or machinery a
simpler fix wouldn't need, and don't treat a nit as license to complicate the code. On
`CHANGES_REQUESTED`: fix blocking, re-run the green-light (same log-capture pattern as step 2).

**Record each round on the PR** (the paper trail) — right after you read the verdict and apply
fixes, post a comment: a one-line header (round #, verdict, blocking/nit counts, what you fixed)
with the **full Codex review folded in a `<details>`** so it's preserved but doesn't bury the PR,
and **refresh the PR description** (`$W/pr-body.md`, seeded in step 2) — fill in the Review section
and firm up Summary + the AC checklist as they settle:

```bash
ROUND=<n>; VERDICT="$(grep -E '^VERDICT:' "$W/review-r$ROUND.md" | tail -1)"
{
  printf '🔍 Codex review — round %s · %s\nFixed: %s\n\n' "$ROUND" "$VERDICT" '<one line: what you fixed this round, or "nothing blocking (approved)">'
  printf '<details><summary>Full Codex review (round %s)</summary>\n\n' "$ROUND"
  cat "$W/review-r$ROUND.full.md"   # final Codex review straight to the PR — bash pipe, never into your context
  printf '\n</details>\n'
} > "$W/round-comment.md"
gh pr comment --body-file "$W/round-comment.md"   # per-round paper trail
gh pr edit    --body-file "$W/pr-body.md"         # keep the description current
```

(If a round's review text contains a literal `</details>`, fence or indent it so the fold doesn't
close early — rare in a code review.)

### 3a. First review round

Run **one** review round (the block above) and apply its fixes under the severity rule. This round
runs first so the concept pass (3b) audits reviewed code, not the raw first-cut diff.

### 3b. Concept-minimalism pass — ONCE, after the first round

This is the **code-level** concept review; the **plan-level** one already ran in `/iharden` (the
plan-critique's concept ledger, on the proposed spec). Here you audit the realized diff's CONCEPT
delta with a fresh-context checker (prompt: `concept-reviewer.md`) — it judges concepts
(architecture vocabulary + whether code-level additions over-complicate: unneeded, derivable, or
collapsible), not correctness; the review rounds own correctness:

```bash
"$H/scripts/concept-check.sh" --out "$W/concepts.md"    # ends VERDICT: MINIMAL | SIMPLIFY
```

Read `$W/concepts.md` and disposition every MERGE/DERIVE/DELETE finding under the author
disposition (AGENTS.md): **apply** the ones whose simplification is safe and in scope — commit,
re-run the step-2 green-light — and **decline** the rest with a one-line rationale. Never weaken an
acceptance criterion to shrink the count. This pass runs ONCE (no loop; it is not a merge gate).
Its edits are **not** unreviewed: the remaining rounds (3c) re-review them. Record the ledger +
your dispositions in the PR's **Concepts** section (below). If the checker exits nonzero, note
"concept check failed to run" there and continue — a failure is surfaced, never silently treated
as MINIMAL.

**Record it on the PR** (same paper trail as the review rounds) — right after you disposition the
findings, post the ledger as its own PR comment: a one-line header — the `VERDICT:` line plus a
one-line disposition summary (net concept delta and what you applied/declined) — with the **full
ledger folded in a `<details>`** so it's preserved without burying the PR, and fill the PR
description's **Concepts** section:

```bash
{
  printf '🧭 Concept-minimalism pass · %s\nDispositions: %s\n\n' \
    "$(grep -E '^VERDICT:' "$W/concepts.md" | tail -1)" \
    '<net delta + what you applied / declined + why, or "net 0 — nothing to change (MINIMAL)">'
  printf '<details><summary>Full concept ledger</summary>\n\n'
  cat "$W/concepts.md"                              # bash pipe straight to the PR, never into your context
  printf '\n</details>\n'
} > "$W/concept-comment.md"
gh pr comment --body-file "$W/concept-comment.md"   # the concept pass on the PR's paper trail
gh pr edit    --body-file "$W/pr-body.md"           # Concepts section now filled
```

(If the checker exited nonzero there's no ledger to fold — post a one-liner noting the concept check
failed to run instead, so the gap is visible on the PR, not silent.)

### 3c. Remaining review rounds — to convergence

Continue the review loop (round 2, 3, … still bounded by `REVIEW_MAX_ROUNDS` — the concept pass is
not a round and doesn't consume the budget), re-running a round after every change. Because the
concept pass (3b) just edited the code, **at least one review round must run after it** — that round
re-reviews both the round-1 fixes and the concept-pass changes. Converge by **severity**: stop when
a round returns `VERDICT: APPROVED` over code you haven't changed since. (If round 1 was already
`APPROVED` **and** the concept pass changed nothing, you're converged — no further round needed.)
Then go to step 4.

**Escalate (do NOT merge)** if the cap is hit still `CHANGES_REQUESTED`, the reviewer can't
run, the build can't be made green, or a blocking finding can't be resolved in scope. **If no
PR exists yet** — e.g. an un-greenable build that never reached the first green-light in step 2
— push the branch and **open a draft PR first** so escalation has something to mark
(`git push -u origin HEAD` then `gh pr create --draft ...`). Then:
keep the PR a **draft**, **apply** the `interactive:escalated` label (create it if missing,
then add it — creating a label does NOT attach it), and post a **structured escalation
comment** so the human sees exactly where it stopped:

```bash
gh label create interactive:escalated -c B60205 -d "Interactive run needs a human" 2>/dev/null || true
gh issue edit <N> --add-label interactive:escalated
gh issue comment <N> --body "$(cat <<'EOF'
Escalated to human (interactive).

## What I did
<bullets: what landed, what passed>

## Blocker
<exactly what failed: build error, unresolved blocking finding, review cap hit, ambiguity>

## State
<branch pushed? draft PR url; green-light status; last Codex VERDICT + the unresolved finding>

## Next
<what a human needs to decide or unblock>
EOF
)"
```

Then surface the terminal token (the evaluator only sees the transcript) and pause for the human:

```bash
"$H/scripts/session.sh" status    # prints "ESCALATED — issue #N labeled interactive:escalated …"
```

### 3d. Advisory passes — only when asked for, never a gate

Two calls sit outside the loop. Both are **advisory** — no round, no merge block, and failing to
run one is not an escalation. Never run either unprompted.

**A DeepSeek third opinion**, for where the gating reviewer and you (the author) might share a
blind spot:

```bash
"$R" --reviewer deepseek --out "$W/deepseek-1.md"
```

It runs through `opencode` on the same single-call contract as the Claude reviewer. A branch over
`DEEPSEEK_MAX_DIFF` (200 000 B) is refused rather than truncated. Disposition its findings under
the converge-toward-SIMPLE rule and post it as its own PR comment, folded in a `<details>` like a
review round. (Same path rule: a second one gets `deepseek-2.md`.)

**A directed probe**, when a round needs one specific answer — does this invariant hold at every
call site? is a claim in the PR body true? — rather than another sweep:

```bash
"$R" --reviewer codex --ask "<the question>" --out "$W/probe-1.md"
```

The answer lands at `--out`, the question at `$W/probe-1.question.md` before the call is made. A
probe emits no `VERDICT:` line. If it returns nothing, record it on the PR as **UNANSWERED** with
its question — the call was made, so "unasked" would be false.

## 4. Finalize: PR write-up + review provenance, then flip to ready

Give the PR a complete write-up, so a human can review it without
re-deriving anything. **Push the reviewed code first** — step 3's fixes were committed locally,
so the PR HEAD is stale until you push, and the human merges whatever the PR points at:

```bash
git status --porcelain                         # MUST be empty — nothing uncommitted left behind
git push                                        # PR HEAD now == the reviewed code
```

`$W/pr-body.md` was seeded in step 2 and refreshed each round in step 3 (Concepts filled by the
concept pass in 3b) — **finalize** it now (don't rewrite from scratch). Its five sections + the
close keyword: **Summary** (what changed), **How tested** (the green-light + anything else you
ran), **Review** (the Codex `VERDICT:`, which blocking findings you fixed, and which **nits you
dismissed** + why), **Concepts** (the step-3b ledger — added/removed/net — and each finding's
disposition: applied, or declined + why; or "checker failed to run"), and the **Acceptance-criteria
checklist** (each AC, how it was verified, any human-approved exception with a one-line rationale) —
make sure every AC is now checked or has an approved exception. End with `Closes #<N>`, then set it:

```bash
gh pr edit --body-file "$W/pr-body.md"      # infers the PR from the branch
```

Then post ONE concise **"ready for human merge"** provenance comment on the PR — the Codex
verdict, a one-line summary of what changed + how tested, and any dismissed nits. **Do NOT paste
the full review again** — the per-round `<details>` folds already preserve it, and re-pasting it
just buries the PR; the review outcome already lives in the PR body's Review section:

```bash
gh pr comment --body "Ready for human merge: green build + Codex review converged (APPROVED). <one-line: what changed + how tested>. Dismissed nits: <list or 'none'>."
```

**Only when every AC is checked or has an approved exception**, flip it ready, then surface the
terminal token so the `/goal` evaluator (transcript-only) sees the bar is met:

```bash
gh pr ready                  # draft -> ready (inferred from the current branch)
"$H/scripts/session.sh" status    # prints "READY — non-draft PR #… closes #N …" into the transcript
```

Leave the PR for the **human to merge** — never merge it yourself. After they merge (closes #N),
clean up the clone with **`"$H/scripts/session.sh" reap`** (or `/reap`): it confirms the PR merged +
the tree is clean, then **recycles this clone into a warm idle clone** — reset to `main`,
`node_modules`/`.next` kept — so the next session reclaims it instead of a cold `npm install`.
To free the slot yourself without waiting for reap, `"$H/scripts/session.sh" release <slug> --force`
resets it to a warm idle slot (reclaimed by the next session; add `--purge` to remove it for
disk). After a squash merge the work is in `main` but not provable by ancestry, so `--force` is
right; for an unmerged but fully-pushed session, plain `release <slug|path|branch>` works.
