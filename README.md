# session-harness

The **interactive coding harness**, packaged as a Claude Code plugin: one task = one isolated
clone + one attended Claude session, plans hardened and code reviewed **adversarially by the
complementary tool** (Claude authors → Codex critiques), and a **human merging every PR**.

This repo is two things. [`session-harness/`](session-harness/) is the **plugin** — that's what
you install. The hello-world Next.js app at `src/` is the **substrate** the repo runs the harness
on, so the plugin is dogfooded rather than only described.

Conventions for agents live in [`AGENTS.md`](AGENTS.md); a one-page summary of the whole machine
is [`harness.md`](harness.md); the release lifecycle is [`MARKETPLACE.md`](MARKETPLACE.md).

## Install it in your repo

```
/plugin marketplace add joinplank/session-harness
/plugin install session-harness@session-harness
```

Then, in the repo you want to work in, ask Claude to **"set up the session harness"** (or run
`/session-harness:harness-setup`). That step wires the four things a plugin can't ship because
they're properties of *your* repo: the `.gitignore` entries for per-session state, the permission
allow-list, the `AGENTS.md` conventions both adversaries are told to read, and the green-light
command every review round re-runs.

Full install options — one-file bundle, skills-only, or vendored into a repo — are in
[`session-harness/README.md`](session-harness/README.md).

## The flow — `/isession` → `/iharden` → `/iship`

| Phase | Command | What happens |
|---|---|---|
| 1 · bootstrap | `/isession <one-liner>` | provisions an isolated clone at `~/work/<repo>-session-NN` (branch `session/<slug>`) and opens a cmux workspace with Claude rooted in it — discuss the task, converge on a plan |
| 2 · harden | `/iharden` | files the plan as a draft GitHub issue, then loops: the session revises ⇄ Codex critiques (`plan-critique.sh`) — until `VERDICT: APPROVED` or your ok; emits the `/goal` line that arms implementation |
| 3 · ship | `/iship` | implements under the goal bar: simplify pass → green-light → draft PR → adversarial review loop (`run-review.sh`, plus one concept-minimalism pass) → AC checklist → flips the PR ready for a **human to merge** — or escalates |

`/reap` recycles merged sessions into warm idle clones (`node_modules` kept), so the next session
skips the cold `npm install`. Reviews converge by **severity, not zero-findings**: only blocking
findings (correctness, security, data-loss, broken contract, regression, unmet acceptance
criterion) gate; nits are recorded, never looped. Every critique and review round is posted to the
issue or PR, so the adversarial trail is durable.

Two advisory passes gate nothing and take no round: an optional **DeepSeek third opinion**
(`--reviewer deepseek`, through `opencode`) for where the gating reviewer and the author share a
blind spot, and a **directed probe** (`--ask "<question>"`) for when a round needs one specific
answer rather than a sweep.

### Requirements

- A **GitHub remote** — the harness files issues and opens PRs (`gh` authenticated).
- CLIs on `PATH`: `git`, `gh`, `jq`, plus the worker tools `claude` and `codex`.
- Optional: `cmux` (opens each session in its own workspace; the harness degrades gracefully
  without it) and `opencode` (the advisory DeepSeek pass).
- Node ≥ 20 and npm, for the app in this repo.

## The app in this repo

```bash
npm install
npm run dev        # http://localhost:3000  (the "Hello, world" page)
npm run build      # compiles + type-checks — the harness green-light
```

Next.js 16 (App Router) · TypeScript · Tailwind CSS v4 · ESLint. Source is under `src/` with the
`@/*` import alias.

## Working on the plugin

```bash
cd session-harness && ./build.sh
```

The bundle is the **canonical source**. `build.sh` validates the skills, commands and both
manifests, runs `claude plugin validate` and two offline test suites, then **syncs the bundle into
this repo's own `scripts/` + `.claude/`** and proves the vendored copy still resolves its helper —
so the layout a vendoring team gets is exercised on every build. Never hand-edit the synced copies;
edit `session-harness/` and rebuild.

Using this repo as a base for a product: keep the harness, replace the hello-world app with your
product, rewrite `AGENTS.md` §"What this repo is" and §"The stack", and keep the green-light
`npm install && npm run build` or change it everywhere it's named.

## License

[MIT](LICENSE).
