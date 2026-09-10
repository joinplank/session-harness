---
description: Phase 2 of INTERACTIVE mode. File the converged plan as a draft issue and harden it adversarially — Codex critiques in a separate shell, THIS session revises with full context and pauses to ask you on real forks. Ends on convergence or your approval.
allowed-tools: Read, Grep, Glob, Bash, Write, Edit, Agent
---

Harden the plan (Phase 2). Run this in the **clone-rooted Claude session** you opened after
`/isession` (the Claude whose working directory IS the clone) — it resolves the session from
`.session.json` in the current directory. If you're not in one, the `session.sh` calls below
will tell you to run `/isession` first (then open a Claude in the clone it prints).

## 0. Resolve session state (fresh vs resume vs done)

From the session clone root, decide which path you're on (this prevents orphaning a
second issue, and lets you **resume** a hardening that was interrupted after the issue was
filed):

```bash
# Where the harness lives. Installed as a plugin, the loader substitutes the token below with the
# plugin root; in a repo that vendored the harness the token is left alone, expands to empty, and
# the fallback names the repo itself — so one line is correct in both layouts.
H="${CLAUDE_PLUGIN_ROOT}"; [ -n "$H" ] || H="$(git rev-parse --show-toplevel)"

[ -f .session.json ] || { echo "not in a session clone — run /isession first"; exit 1; }
W="$(mktemp -d)"   # scratch for the body + critique thread; used by BOTH the fresh and resume paths
ISSUE="$(jq -r '.issue' .session.json)"
if [ "$ISSUE" = "null" ]; then
  echo "FRESH: no issue yet — file it in step 1."
else
  # Fail CLOSED: capture the label lookup's output AND status separately, so a transient
  # gh/network failure is NOT mistaken for "not draft" (which would skip hardening and send
  # a still-draft issue to /iship). An empty label set (issue has no labels) exits 0 → DONE.
  if ! LABELS="$(gh issue view "$ISSUE" --json labels -q '.labels[].name' 2>/dev/null)"; then
    echo "could not fetch labels for issue #$ISSUE — retry; do NOT assume it is hardened"; exit 1
  fi
  if printf '%s\n' "$LABELS" | grep -qx interactive:draft; then
    echo "RESUME: issue #$ISSUE exists and is still interactive:draft — SKIP step 1, continue the loop in step 2 with ISSUE=$ISSUE."
  else
    echo "DONE: issue #$ISSUE is already hardened (not draft) — use /iship"; exit 1
  fi
fi
```

(`$H` is the harness root — set once here and reused by every block below that shells out
to the harness. If a later block finds it empty, re-run that one line; it is the whole
portability contract between the plugin and vendored layouts.)

- **FRESH** → do step 1 (file the issue), then step 2.
- **RESUME** → **skip step 1**; continue hardening in step 2 with the existing `ISSUE`.
- **DONE** → stop; the plan is hardened — use `/iship`.

## 1. Draft + file the issue (FRESH only)

From the converged discussion, write the issue body — Context, Design (the concept model
and the contracts between the major pieces, organized by decision — not a layer-by-layer
walk-through, which invites mechanics creep), Acceptance criteria (including the
green-light AC), Out of scope, Notes, and a `## Plan decisions & rejected
alternatives` section you'll grow during hardening. Keep it at **design altitude** — the
approach: the concept model and the key modules/interfaces the change turns on, plus
testable acceptance criteria. Leave deep implementation details (which edge cases to branch
on, exact file-by-file mechanics, error wording, the line-level how) to `/iship`, or the
plan buries its own design under execution detail.
Write it to `$W/body.md` (the `W`
scratch dir was created in step 0), then file it labeled `interactive:draft` and record it
on the session:

```bash
gh label create interactive:draft -c FBCA04 \
  -d "Interactive plan still hardening; not ready to adopt" 2>/dev/null || true
URL="$(gh issue create -t "<title>" -F "$W/body.md" --label interactive:draft)" \
  || { echo "gh issue create failed — fix and retry; nothing was filed, session unchanged"; exit 1; }
[ -n "$URL" ] || { echo "issue create returned no URL — aborting before adopt"; exit 1; }
ISSUE="$(basename "$URL")"
"$H/scripts/session.sh" adopt-issue --issue "$ISSUE"   # renames branch session/<slug> -> task/<N>-<slug>, records issue in .session.json
```

**Create and adopt are two steps.** Only `adopt-issue` records the issue into
`.session.json`, so if you're interrupted *after* `gh issue create` but *before*
`adopt-issue`, the issue (#`$ISSUE`) is already filed but the session doesn't know it — a
re-run of `/iharden` would see `issue=null` and file a **duplicate** draft. If that happens,
do **not** re-run `/iharden`; finish the recording manually with the issue number printed
above:

```bash
"$H/scripts/session.sh" adopt-issue --issue "$ISSUE"   # records the already-filed issue; renames session/<slug> -> task/<N>-<slug>
```

The `interactive:draft` label is an **enforced gate**: `/iship` refuses to implement a
draft-labeled issue, so implementation can't start while the plan is still hardening.

## 2. Adversarial harden loop (you author; Codex critiques)

Loop, bounded by the level cap (quick=2 / normal=3 / deep=6; default
deep):

```bash
"$H/scripts/plan-critique.sh" --issue "$ISSUE" --thread "$W/thread.md" --out "$W/round.md" --comment
```

The Codex critic scales reasoning by round automatically via `--thread`: the first critique
(empty thread) runs at `ultra` for the deep initial read, later rounds at `xhigh`; `CODEX_EFFORT`
forces a single tier.

`plan-critique.sh` splits its output the way the code review does: **`$W/round.md` is COMPACT** —
the tagged findings + the `VERDICT:` line, which is what you read — while the **full critique
(concept ledger + findings)** goes to `$W/round.full.md` and, via `--comment`, to a comment on the
issue. So the durable adversarial trail lives on the issue (the `$W` scratch vanishes with the
session) and your context stays clean across rounds; your revisions to the body are the other half
of that trail.

- Read `$W/round.md` (compact — the tagged findings + the final `VERDICT:` line); **do not Read
  `round.full.md`** (its concept ledger is verbose and re-emitted every round — its actionable
  items are already in the findings, and the full critique is on the issue for the trail).
  **Nonzero exit = critic failure** → stop and tell the human; do **not** guess a verdict.
- `VERDICT: CHANGES_REQUESTED` → address every `[BLOCKER]` and reasonable `[SHOULD]` by
  **editing the issue body** (`gh issue edit "$ISSUE" --body-file <new>`),
  growing the `## Plan decisions & rejected alternatives` section. **If a finding raises a
  genuine fork only the human can decide, PAUSE and ask them** — you can, because you're the
  author and they're present — then continue. Re-run the critique.
  - **Keep the design MINIMAL — think for yourself, don't let the adversarial critic ratchet up
    complexity.** Codex biases toward "add more"; do **not** reflexively satisfy a finding by
    adding a field, abstraction, or subsystem. Prefer the simplest resolution that makes the plan
    correct — often the right move is to **simplify, narrow scope, or decline with a one-line
    rationale** (recorded in `## Plan decisions & rejected alternatives`), not to grow the design.
    Resolve genuine `[BLOCKER]`s; push back on a `[SHOULD]` whose added complexity outweighs its
    benefit. A converged plan is the fewest moving parts that meet the acceptance criteria — not
    one that absorbed every suggestion. When a finding pushes real complexity, that's often a
    **fork to raise with the human** rather than silently accept. And a finding whose only fix
    is pre-specifying implementation — an edge-case branch, a file path, a mechanical choice —
    is normally **declined as deferred to implementation** (noted once in `## Plan decisions &
    rejected alternatives`); the plan stays at design altitude.
- `VERDICT: APPROVED` → converged.
- Cap hit without convergence → surface the open findings to the human; the issue stays
  `interactive:draft`. Do **not** proceed to implementation.

## 3. Gate → arm implementation

On `VERDICT: APPROVED` **or** explicit human approval, remove the draft label:

```bash
gh issue edit "$ISSUE" --remove-label interactive:draft
```

Hardening is done — **spit out the next step.** Print exactly this `/goal` line with `#N` filled in
and ask the human to paste it to start implementation (in *this* session, so the plan and its
reasoning carry into implementation with full context):

```
/goal Ship issue #N via /iship. Done when the harness's `session.sh status` reports READY (a non-draft PR closes #N) or ESCALATED (interactive:escalated). Run it to prove which. Or stop after 20 turns.
```

Pasting it arms Claude Code's **built-in `/goal`** loop (user-invocable only — the Skill tool can't
trigger it), which drives this same clone-rooted session through the implementation method in
`/iship` (steps 1–4) and stops at the completion bar — READY (a non-draft PR
open for merge) or ESCALATED (stopped for a human), both defined there. Running `/iship` by hand
later (to resume) re-emits this same line from its step 0.
