# AGENTS.md — session-harness

Conventions for AI coding agents working in this repo. This repo is set up for
**both Claude Code and OpenAI Codex** — we use them together (the session
implements, Codex does adversarial review). Codex reads this file automatically;
Claude reads it via `CLAUDE.md` (`@AGENTS.md`).

This is the single shared source of repo rules. A one-page summary of the whole machine
lives in `harness.md`.

## What this repo is

Two things:

1. **The `session-harness` plugin** (`session-harness/`) — an installable Claude Code plugin
   for the `/isession` → `/iharden` → `/iship` flow: attended AI coding sessions in isolated
   clones, with plans and code hardened adversarially by the complementary tool. The repo root
   is a plugin **marketplace** (`.claude-plugin/marketplace.json`) listing it.
2. **A hello-world Next.js app** (`src/`) — deliberately minimal. It is the substrate the
   harness operates on, and it is what makes the green-light real.

**The bundle is the canonical source; the repo root's own harness is a synced copy.** `scripts/`,
`.claude/commands/` and `.claude/skills/` are written by `session-harness/build.sh` from the
bundle. Never hand-edit them — edit `session-harness/` and rebuild, or the next build silently
reverts your change. The sync direction is deliberate: this repo dogfoods the plugin it ships, so
the vendored layout is exercised on every build instead of drifting until someone tries it.

Using this repo as a **base for a product**: keep the harness, replace the hello-world app with
your product, rewrite this section and §The stack, and name your product/architecture doc here
once you have one so the plan critic knows to consult it. Revisit the pre-production stance when
you ship. To adopt the harness in a repo you already have, install the plugin and run its
`harness-setup` skill instead of copying anything by hand.

<!-- BEGIN:nextjs-agent-rules -->
# This is NOT the Next.js you know

This version has breaking changes — APIs, conventions, and file structure may all differ from your training data. Read the relevant guide in `node_modules/next/dist/docs/` before writing any code. Heed deprecation notices.
<!-- END:nextjs-agent-rules -->

## The stack

- **Next.js 16** (App Router), **TypeScript**, **Tailwind CSS v4**, **ESLint**.
- Source lives under `src/` with the `@/*` import alias → `src/*`. Routes in
  `src/app/**`; add shared UI under `src/components/**` and helpers under
  `src/lib/**`.
- npm is the package manager. The lockfile **is** committed; `node_modules/` is not.

**Pre-production — clean breaks over back-compat.** Nothing ships to users yet, so a breaking
change is fine when it buys a cleaner design: prefer the clean shape over a compatibility shim
or migration. Existing persisted data may stop working as a result, and that's acceptable;
don't add migrations, version negotiation, or defensive fallbacks for old formats unless a task
explicitly asks for it. This scopes the gates: the plan critic shouldn't flag a missing
migration/back-compat path, and *regression* / *broken contract* in review mean breaking a
**currently-supported** behavior, not dropping support for deprecated data. (Revisit this
stance — and this section — once your product actually ships to users.)

## Code comments

A comment explains the code **as it stands** — the invariant, constraint, or non-obvious
why a reader needs at that line, written as if the code had always been this way. It must
make sense to a reader holding only the current version: never cite issue or PR numbers,
review rounds, or the edit that introduced the line ("added for #56", "was X before",
"now uses Y instead"). Git and the PR trail already ledger provenance and rationale-for-change;
a comment that narrates history or justifies an edit is stale the moment it merges. If a
comment only works as a pointer to a ticket or a previous version, rewrite it to justify
the code on its own terms — or delete it.

## The interactive flow (how non-trivial work gets done) — `/isession` → `/iharden` → `/iship`

Each task runs in its **own isolated clone**, driven by **one continuous attended
Claude session rooted in that clone**, so discuss → harden → implement share full
context. Only the adversarial reviews run in a separate Codex shell, brought back.
The human is present throughout — which is what lets the plan author pause to ask
clarifying questions — and the human merges the PR at the end.

- **`/isession <one-liner>`** — **bootstrap + open.** `scripts/session.sh new --slug <s>
  --launch --message <one-liner>` provisions an isolated, **independent clone** in a
  reused, **numbered** slot pool at `~/work/<repo>-session-NN` on branch
  `session/<slug>`, state in `.session.json` at the clone root, **and opens a cmux
  workspace with `claude` rooted in it, seeded with a kickoff prompt that frames the
  one-liner in the interactive flow** (discuss → `/iharden` → `/iship` — **plan first,
  not codegen**; recorded in `.session.json` so reap/release close it; soft-skips if
  cmux is absent). The slot NUMBER is the stable dir; the slug lives in
  `.session.json`, so a reused slot is never renamed. `new` is idempotent: reopen this
  slug → reclaim a warm idle slot → else fresh clone (reopen does not open a second
  window). Everything happens in the clone-rooted session — discuss, `/iharden`,
  `/iship` — which is what makes their cwd-resolution correct and keeps parallel
  sessions fully isolated.
- **`/iharden`** — Phase 2 (Harden → issue). Files the plan as an issue labeled
  `interactive:draft`, runs `session.sh adopt-issue` (renames the branch to
  `task/<N>-<slug>`), then loops: **you author** revisions to the issue body (growing a
  `## Plan decisions & rejected alternatives` section) while
  **`scripts/plan-critique.sh`** runs Codex as an independent critic in a separate
  shell; pause to ask the human on real forks. Ends on `VERDICT: APPROVED` or human
  approval, which removes the draft label **and spits out the `/goal` line the human pastes to
  start implementation** (arming the built-in loop that drives Phase 3). The label is an
  **enforced gate**: `/iship` refuses to implement a draft-labeled issue.
- **`/iship`** — Phase 3 (Implement, same session). Drives the task branch to an explicit
  completion bar — reached by pasting the `/goal` line `/iharden` emits (or run `/iship` by hand
  to resume), which arms Claude Code's **built-in `/goal`** loop (a transcript-only evaluator keeps
  the session working until the bar — a **READY** non-draft PR or an **ESCALATED** stop, both
  surfaced as one token by `scripts/session.sh status` — or the turn cap; the bar governs even
  unarmed) — runs a **`/simplify` pass over the just-written diff before review** (a code-level
  clarity edit, dispositioned toward SIMPLE — kept only where it preserves behavior), opens a
  **draft** PR after the first green-light, runs the diff-adversarial code review
  (`run-review.sh`, separate Codex shell) brought back and objectively applied
  (severity rule), writes an **AC checklist** into the PR, then flips it to non-draft
  for the human to merge — or escalates (draft PR + `interactive:escalated`) on
  failure.

State is a per-clone **`.session.json`** (gitignored); `/iharden`/`/iship` resolve the
session from the current directory — which is why they run in the clone-rooted Claude.
There's no central registry; **`scripts/session.sh list`** discovers sessions by
scanning the `<repo>-session-*` namespace. Parallel sessions = N independent
clones/branches/Claude sessions, capped at `SESSION_MAX` (default 6) total slots.
**`scripts/session.sh reap`** (also `/reap`) resets slots whose **PR has merged** to
**warm idle clones** in place — reset to `main`, but `node_modules`/`.next` kept —
that the next `session.sh new` reclaims before cloning cold, then fast-forwards the
local `main` checkout to merged work when that's unambiguously safe. Reap is
fail-closed: it only recycles on a confirmed merge with a clean tree, leaving
open/unadopted/dirty sessions alone. `scripts/session.sh release <slug|path|branch>`
does the same on demand (refuses to touch unpushed commits unless `--force`); add
`--purge` to remove the slot and reclaim disk.

## Green-light (the merge gate)

Every change must pass the green-light before review + merge:

    npm install && npm run build

`npm run build` is `next build`, which type-checks, so a green run is the bar. Do
not weaken types, delete tests, or stub things to force it green.

**A change to the plugin bundle also has to build the bundle** — `session-harness/build.sh`,
which validates the manifests, runs both offline test suites, and re-syncs the repo's own
harness from the bundle. A bundle change that skips it leaves this repo running a harness that
no longer matches what it ships.

Every provisioned session clone is seeded with the source repo's local `.env`
(`scripts/lib.sh` `seed_env`) when one exists, since a build/runtime may need it and
`.env` is gitignored (never cloned via git). It stays gitignored in the clone, so
it's never committed or pushed.

## Plan hardening (adversarial, in `/iharden`)

Before implementation, the issue **spec** is hardened adversarially: the session
authors the plan, **Codex critiques it** (`scripts/plan-critique.sh`, one round per
call — a concept ledger of the plan's proposed vocabulary, tagged
`[BLOCKER]`/`[SHOULD]`/`[NIT]` findings + a `VERDICT:` line, prompt in
`scripts/plan-reviewer.md`), the session revises the issue body, repeat to
convergence (`VERDICT: APPROVED`) or the round cap (quick=2 / normal=3 / deep=6;
default deep). Each round's critique — concept ledger, findings, and verdict — is posted
as a comment on the issue, so the adversarial trail lives on the issue, not just the session
scratch dir. A hardened spec is cheap at plan time and prevents implementation rework. The
critic script fails closed: a nonzero exit is a reviewer failure to
surface, never an implicit verdict.

**A plan is high-level design, not an implementation spec.** It pins down the *approach* —
the concept model and the key modules/interfaces the change turns on (the major pieces and
the contracts between them) — plus *testable acceptance criteria*, and stops there. Deep
implementation details — which edge cases to branch on, exact file-by-file mechanics,
error-message wording, the line-level HOW — are for `/iship` to work out against the real
code, not for the plan to pre-specify. Blending them in buries the design under detail that
rots on contact with the code — so nail the approach and the shape, and leave the rest to
implementation.

**Author disposition — converge toward SIMPLE, not toward "everything the critic
said."** The critic is adversarial and biases toward "add more," so the author must
judge each finding on its merits and think for itself, not reflexively satisfy it by
adding a field, abstraction, or subsystem. Prefer the simplest resolution that makes
it correct — often the right move is to **simplify, narrow scope, or push back with a
one-line rationale** (recorded in `## Plan decisions & rejected alternatives`), not to
grow the design. Resolve genuine `[BLOCKER]`s; decline a `[SHOULD]` whose added
complexity outweighs its benefit. A converged plan is the fewest moving parts that
meet the acceptance criteria — not one that absorbed every suggestion. Keep the
concept space clean and minimal, and the plan at design altitude — a finding whose only fix
is spelling out implementation detail is declined as *deferred to implementation*, not a
reason to grow the plan.

## Adversarial code review (looped to convergence, by the *complementary* tool)

Every branch is reviewed by the tool that didn't author it — the session (Claude)
implements → **Codex reviews** — and the review **loops**. Convergence is by
**severity, not zero-findings** (else an adversarial reviewer's nits would never let a
clean round happen): each round ends in a structured
`VERDICT: APPROVED | CHANGES_REQUESTED`, and the author fixes only **blocking**
findings — correctness, security, data-loss, broken contract/API, regression, or an
unmet acceptance criterion — while **nits** (style, naming, subjective, optional
refactors) are recorded, not gated. Loop: review → fix blocking → re-run the
green-light → re-review, until `VERDICT: APPROVED` (converged → finalize the PR for a
human to merge) or the round cap `REVIEW_MAX_ROUNDS` (default 3) is hit still
`CHANGES_REQUESTED` (→ **escalate**, don't merge). The same author disposition
applies: fix each blocking finding with the simplest change that resolves it.

The review harness is the **`adversarial-review`** skill
(`.claude/skills/adversarial-review/` + `run-review.sh`): one review round over the
current branch diff, looped by the caller. `codex exec review --base` can't take a
custom prompt, so a round is two Codex calls — the review, then a classifier that
turns its prose into the structured verdict (keeping the severity call on the
reviewer's side). When a round needs to ask the reviewer one *specific* question instead of
sweeping, `run-review.sh --ask` is the **directed probe**: advisory like the DeepSeek pass
below — it gates nothing and takes no round — and its question is written to disk before the
call, so a probe that fails is recorded on the PR as **unanswered** rather than vanishing.

**Give every round its own `--out`.** Between a round finishing and its comment going up, those
two files are the round's only copy — the comment can't be posted sooner, because it says what
the author fixed. So `run-review.sh` refuses an `--out` that already holds a round rather than
overwriting it. Answer a refusal with a fresh path, never by deleting the file in the way.

**An optional DeepSeek third opinion** (`run-review.sh --reviewer deepseek`, through `opencode`)
gives a fresh model over the same diff, for where the gating reviewer and the author share a blind
spot. It is **advisory, never a gate**: on request only, no round, no merge gate. Disposition its
findings like the concept pass's and record them on the PR. A branch over `DEEPSEEK_MAX_DIFF` is
**refused rather than truncated** — a clipped diff reads as a complete review over code the model
never saw.

**Every unattended model call is supervised** — `scripts/model-call.sh`, sourced by
`plan-critique.sh`, `concept-check.sh` and `run-review.sh`. Unsupervised, a call that hangs or dies
mid-stream both end as a round that silently did not happen. `model_call` bounds every call
(`MODEL_CALL_TIMEOUT_S`, default 1800 s), publishes only a successful attempt's output, and retries
only behind a **mechanical read-only sandbox flag** — a review-shaped prompt is not a write
boundary. `session-harness/tests/` proves this against stand-in CLIs on every build.

## Concept-minimalism pass (in `/iship`, once)

This is the **second of the flow's two concept reviews**: the first is the
plan-vocabulary concept ledger in `/iharden` (design altitude — on the proposed
spec, before any code); this one audits the realized **code** diff (implementation
altitude). They're complementary — a clean plan can still grow incidental code
concepts, and this pass catches those.

**After the FIRST adversarial review round** (so the checker sees the round-1 fixes,
which are often new code) **and before the remaining rounds**, `/iship` runs ONE
fresh-context concept audit of the branch diff (`scripts/concept-check.sh`, prompt in
`scripts/concept-reviewer.md`; checker Claude by default — parsimony, not the
correctness review): a ledger of concepts ADDED / EXTENDED / REMOVED by layer, a
KEEP / MERGE / DERIVE / DELETE verdict per addition, ending
`VERDICT: MINIMAL | SIMPLIFY`. It audits concepts — architecture vocabulary and key
code-level over-complication (an addition that's unneeded, derivable from an
existing concept, or lets two concepts collapse into one) — not correctness; it
never loops and is not a merge gate. Sitting after round 1 (not before the loop)
means the concept checker audits *reviewed* code, and the remaining review rounds
then re-review whatever the concept pass simplified — closing both gaps. The author
dispositions every finding under the
same converge-toward-SIMPLE rule — applied, or declined with a one-line rationale —
and records the ledger + dispositions in the PR's **Concepts** section — **and
posts the ledger as its own PR comment** (a durable paper trail, like the review
rounds) — for the human merger. The script fails closed as a tool (nonzero exit = checker
failure, surfaced in the PR), but the step is advisory: correctness gates stay with the
review loop.

Distinct from the **`/simplify` pass** (in `/iship`, step 1, *before* the first review): that is a
**code-level** clarity *edit* the author runs over the just-written diff and dispositions toward
SIMPLE; this concept pass is a **concept-level** *audit* that only flags, on the *reviewed* code.
Simplify shrinks the diff you'll review; the concept pass checks the architecture didn't accrete
needless concepts. Complementary — different altitude (code vs. concept), different moment (before
review vs. after round 1), different teeth (edits vs. advisory).

## Session hard rules

- One issue → one branch (`task/<issue#>-<slug>`) → one PR → the human merges.
- Stay in your clone; never `git push --force` (only `--force-with-lease`).
- Don't hand-edit `package-lock.json` — regenerate via `npm install`.
- Don't hand-edit `scripts/`, `.claude/commands/` or `.claude/skills/` — they are synced from
  `session-harness/` by its `build.sh`, which overwrites them.
- Escalate (don't merge) on: an un-greenable build, an unresolvable real finding,
  an unclean merge, or genuine ambiguity. Leave the issue OPEN when escalating.
