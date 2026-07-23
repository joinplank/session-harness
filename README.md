# plank-harness

A hello-world **Next.js** app wired up with the Plank **interactive coding
harness**: one task = one isolated clone + one attended Claude session, plans
hardened and code reviewed **adversarially by the complementary tool** (Claude
authors → Codex critiques), and a **human merging every PR**. The app is what
the harness operates on; the harness is the point.

Use this repo as the base for a new project, or copy the harness into an
existing one. Conventions for agents live in [`AGENTS.md`](./AGENTS.md); a
one-page summary of the whole machine lives in [`harness.md`](./harness.md).

## The app

```bash
npm install
npm run dev        # http://localhost:3000  (the "Hello, world" page)
npm run build      # compiles + type-checks — the harness green-light
```

Next.js 16 (App Router) · TypeScript · Tailwind CSS v4 · ESLint. Source is under
`src/` with the `@/*` import alias.

## The harness — `/isession` → `/iharden` → `/iship`

| Phase | Command | What happens |
|---|---|---|
| 1 · bootstrap | `/isession <one-liner>` | provisions an isolated clone at `~/work/<repo>-session-NN` (branch `session/<slug>`) and opens a cmux workspace with Claude rooted in it — discuss the task, converge on a plan |
| 2 · harden | `/iharden` | files the plan as a draft GitHub issue, then loops: the session revises ⇄ Codex critiques (`scripts/plan-critique.sh`) — until `VERDICT: APPROVED` or your ok; emits the `/goal` line that arms implementation |
| 3 · ship | `/iship` | implements under the goal bar: simplify pass → green-light → draft PR → adversarial review loop (`run-review.sh`, plus one concept-minimalism pass) → AC checklist → flips the PR ready for a **human to merge** — or escalates |

`/reap` recycles merged sessions into warm idle clones (`node_modules` kept), so
the next session skips the cold `npm install`. Reviews converge by **severity,
not zero-findings**: only blocking findings (correctness, security, data-loss,
broken contract, regression, unmet acceptance criterion) gate; nits are
recorded, never looped. Every critique and review round is posted to the issue
or PR, so the adversarial trail is durable.

Under the hood (the slash commands are thin wrappers):

```bash
scripts/session.sh new --slug <s> --launch --message "<task>"   # what /isession runs
scripts/session.sh list | status | release <slug> | reap
scripts/plan-critique.sh --issue <N> --comment                  # one plan-critique round (Codex)
scripts/concept-check.sh                                        # one concept-minimalism audit
.claude/skills/adversarial-review/run-review.sh --round <N>     # one code-review round
```

### Requirements

- A **GitHub remote** — the harness files issues and opens PRs (`gh` authenticated).
- CLIs on `PATH`: `git`, `gh`, `jq`, `cmux` (opens each session in its own
  workspace; the harness degrades gracefully without it), plus the worker tools
  `claude` and `codex`.
- Node ≥ 20, npm.

## Using this as a base

1. Create a new repo from this one and push it to GitHub (the harness needs the
   remote for issues and PRs).
2. Replace the hello-world app with your product.
3. Rewrite `AGENTS.md` §"What this repo is" and §"The stack"; name your
   product/architecture doc there once you have one, so the plan critic knows to
   consult it. Revisit the pre-production stance when you ship.
4. Keep the green-light `npm install && npm run build`, or change it everywhere
   it's named (`AGENTS.md`, `harness.md`, the adversarial-review `SKILL.md`).

To adopt just the harness in an existing repo, copy `scripts/` (`lib.sh`,
`session.sh`, `plan-critique.sh`, `plan-reviewer.md`, `concept-check.sh`,
`concept-reviewer.md`), `.claude/`, `harness.md`, the harness sections of
`AGENTS.md` + `CLAUDE.md`, and the `.gitignore` entries for `.session.json`,
`.claude/settings.local.json`, and `.claude/hooks/`.
