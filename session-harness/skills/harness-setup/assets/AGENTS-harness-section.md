<!-- Appended by the session-harness `harness-setup` skill. Fill the three placeholders
     (<STACK>, <GREEN_LIGHT>, <PRODUCT_DOC>) and delete this comment. -->

## The stack

<STACK>

**Pre-production — clean breaks over back-compat.** Nothing ships to users yet, so a breaking
change is fine when it buys a cleaner design: prefer the clean shape over a compatibility shim
or migration. Existing persisted data may stop working as a result, and that's acceptable;
don't add migrations, version negotiation, or defensive fallbacks for old formats unless a task
explicitly asks for it. This scopes the gates: the plan critic shouldn't flag a missing
migration/back-compat path, and *regression* / *broken contract* in review mean breaking a
**currently-supported** behavior, not dropping support for deprecated data. (Revisit this
stance — and this section — once the product actually ships to users. **Delete this paragraph
if it already has.**)

## Code comments

A comment explains the code **as it stands** — the invariant, constraint, or non-obvious
why a reader needs at that line, written as if the code had always been this way. It must
make sense to a reader holding only the current version: never cite issue or PR numbers,
review rounds, or the edit that introduced the line ("added for #56", "was X before",
"now uses Y instead"). Git and the PR trail already ledger provenance and rationale-for-change;
a comment that narrates history or justifies an edit is stale the moment it merges. If a
comment only works as a pointer to a ticket or a previous version, rewrite it to justify
the code on its own terms — or delete it.

## The interactive flow — `/isession` → `/iharden` → `/iship`

Each task runs in its **own isolated clone**, driven by **one continuous attended Claude
session rooted in that clone**, so discuss → harden → implement share full context. Only the
adversarial reviews run in a separate Codex shell, brought back. The human is present
throughout — which is what lets the plan author pause to ask clarifying questions — and the
human merges the PR at the end.

- **`/isession <one-liner>`** — bootstrap. Provisions an isolated, independent clone in a
  reused, numbered slot pool at `~/work/<repo>-session-NN` on branch `session/<slug>`, state in
  `.session.json` at the clone root, and opens a cmux workspace with `claude` rooted in it,
  seeded with a kickoff prompt that frames the one-liner in the flow (**plan first, not
  codegen**). Idempotent: reopen this slug → reclaim a warm idle slot → else fresh clone.
- **`/iharden`** — files the plan as an issue labeled `interactive:draft`, renames the branch to
  `task/<N>-<slug>`, then loops: **you author** revisions to the issue body (growing a
  `## Plan decisions & rejected alternatives` section) while an independent critic runs in a
  separate shell. Ends on `VERDICT: APPROVED` or human approval, which removes the draft label
  and emits the `/goal` line that arms implementation. The label is an **enforced gate**:
  `/iship` refuses to implement a draft-labeled issue.
- **`/iship`** — implements on the task branch to an explicit completion bar: a `/simplify` pass
  over the just-written diff → green-light → draft PR → adversarial review loop (with one
  concept-minimalism pass after round 1) → AC checklist → flips the PR ready for a **human to
  merge**, or escalates.

`/reap` recycles slots whose **PR has merged** into warm idle clones — reset to the default
branch, dependencies kept — that the next session reclaims before cloning cold. It is
fail-closed: only a confirmed merge with a clean tree recycles.

## Green-light (the merge gate)

Every change must pass the green-light before review + merge:

    <GREEN_LIGHT>

Do not weaken types, delete tests, or stub things to force it green.

## Plan hardening (adversarial, in `/iharden`)

Before implementation, the issue **spec** is hardened adversarially: the session authors the
plan, the complementary tool critiques it (one round per call — a concept ledger of the plan's
proposed vocabulary, tagged `[BLOCKER]`/`[SHOULD]`/`[NIT]` findings + a `VERDICT:` line), the
session revises the issue body, repeat to convergence or the round cap. Each round's critique is
posted as a comment on the issue, so the adversarial trail lives on the issue. The critic script
fails closed: a nonzero exit is a reviewer failure to surface, never an implicit verdict.

**A plan is high-level design, not an implementation spec.** It pins down the *approach* — the
concept model and the key modules/interfaces the change turns on — plus *testable acceptance
criteria*, and stops there. Deep implementation details are for `/iship` to work out against the
real code.

**Author disposition — converge toward SIMPLE, not toward "everything the critic said."** The
critic is adversarial and biases toward "add more," so the author must judge each finding on its
merits. Prefer the simplest resolution that makes it correct — often the right move is to
**simplify, narrow scope, or push back with a one-line rationale** (recorded in `## Plan
decisions & rejected alternatives`), not to grow the design. Resolve genuine `[BLOCKER]`s;
decline a `[SHOULD]` whose added complexity outweighs its benefit.

## Adversarial code review (looped to convergence, by the *complementary* tool)

Every branch is reviewed by the tool that didn't author it, and the review **loops**.
Convergence is by **severity, not zero-findings** (else an adversarial reviewer's nits would
never let a clean round happen): each round ends in a structured
`VERDICT: APPROVED | CHANGES_REQUESTED`, and the author fixes only **blocking** findings —
correctness, security, data-loss, broken contract/API, regression, or an unmet acceptance
criterion — while **nits** are recorded, not gated. Loop: review → fix blocking → re-run the
green-light → re-review, until `VERDICT: APPROVED` or the round cap `REVIEW_MAX_ROUNDS`
(default 3) is hit still `CHANGES_REQUESTED` (→ **escalate**, don't merge).

The review harness is the **`adversarial-review`** skill: one review round over the current
branch diff, looped by the caller. When a round needs to ask the reviewer one *specific*
question instead of sweeping, `run-review.sh --ask` is the **directed probe** — advisory: it
gates nothing and takes no round, and its question is written to disk before the call, so a
probe that fails is recorded on the PR as **unanswered** rather than vanishing.

**An optional DeepSeek third opinion** (`run-review.sh --reviewer deepseek`, through `opencode`)
gives a fresh model over the same diff, for where the gating reviewer and the author share a blind
spot. It is **advisory, never a gate**: on request only, no round, no merge gate. Disposition its
findings like the concept pass's and record them on the PR.

**Every unattended model call is supervised** — `model-call.sh`, sourced by `plan-critique.sh`,
`concept-check.sh` and `run-review.sh`. Unsupervised, a call that hangs or dies mid-stream both end
as a round that silently did not happen. `model_call` bounds every call, publishes only a
successful attempt's output, and retries only behind a **mechanical read-only sandbox flag**.

## Concept-minimalism pass (in `/iship`, once)

**After the FIRST adversarial review round** and before the remaining rounds, `/iship` runs ONE
fresh-context concept audit of the branch diff: a ledger of concepts ADDED / EXTENDED / REMOVED
by layer, a KEEP / MERGE / DERIVE / DELETE verdict per addition, ending
`VERDICT: MINIMAL | SIMPLIFY`. It audits concepts — architecture vocabulary and key code-level
over-complication — not correctness; it never loops and is not a merge gate. Sitting after
round 1 means it audits *reviewed* code, and the remaining review rounds then re-review whatever
it simplified. The author dispositions every finding under the same converge-toward-SIMPLE rule
and records the ledger + dispositions in the PR. The script fails closed as a tool (nonzero exit
= checker failure, surfaced in the PR), but the step is advisory.

## Session hard rules

- One issue → one branch (`task/<issue#>-<slug>`) → one PR → the human merges.
- Stay in your clone; never `git push --force` (only `--force-with-lease`).
- Don't hand-edit the lockfile — regenerate it with the package manager.
- Escalate (don't merge) on: an un-greenable build, an unresolvable real finding, an unclean
  merge, or genuine ambiguity. Leave the issue OPEN when escalating.

<!-- The plan critic and code reviewer are each told "Read AGENTS.md first." Name this repo's
     architecture/product doc here so the critic consults it: <PRODUCT_DOC>. Delete this
     comment and the sentence if there isn't one yet. -->
