# session-harness

An installable plugin for the **interactive coding harness**: one task = one isolated clone +
one attended Claude session, plans and code hardened adversarially by the **complementary tool**
(Claude authors → Codex critiques), and a **human merging every PR**.

Current version and what changed: [`CHANGELOG.md`](CHANGELOG.md).

---

## What you get

| | |
|---|---|
| **Commands** | `/isession` · `/iharden` · `/iship` · `/reap` |
| **Skills** | `adversarial-review` (the review turn harness) · `harness-setup` (wire it into a repo) |
| **Scripts** | `session.sh` `plan-critique.sh` `concept-check.sh` `model-call.sh` `lib.sh` + the two critic prompts |

### The flow

| Phase | Command | What happens |
|---|---|---|
| 1 · bootstrap | `/isession <one-liner>` | provisions an isolated clone at `~/work/<repo>-session-NN` (branch `session/<slug>`) and opens a cmux workspace with Claude rooted in it — discuss, converge on a plan |
| 2 · harden | `/iharden` | files the plan as a draft GitHub issue, then loops: the session revises ⇄ Codex critiques — until `VERDICT: APPROVED` or your ok; emits the `/goal` line that arms implementation |
| 3 · ship | `/iship` | implements under the goal bar: simplify pass → green-light → draft PR → adversarial review loop (plus one concept-minimalism pass) → AC checklist → flips the PR ready for a **human to merge** — or escalates |
| — | `/reap` | recycles slots whose PR has merged into warm idle clones, so the next session skips the cold install |

Reviews converge by **severity, not zero-findings**: only blocking findings (correctness,
security, data-loss, broken contract, regression, unmet acceptance criterion) gate; nits are
recorded, never looped. Every critique and review round is posted to the issue or PR, so the
adversarial trail is durable.

---

## Install

**As a plugin (recommended).** From this repo:

```
/plugin marketplace add joinplank/session-harness
/plugin install session-harness@session-harness
```

Then, in any repo you want to run the flow in, ask Claude to **"set up the session harness"** —
or invoke the setup skill directly:

```
/session-harness:harness-setup
```

That step exists because four things are properties of *your* repo and cannot ship in a plugin:
the `.gitignore` entries for per-session state, the permission allow-list, the `AGENTS.md`
conventions both adversaries are told to read, and the green-light command every review round
re-runs. The skill detects what's already there and layers on top.

**As a one-file bundle.** Build (or use the committed) `dist/session-harness.plugin` and install
it through the plugin manager.

**As skills only.** `unzip dist/adversarial-review.zip -d ~/.claude/skills/` gives you the review
turn harness without the session commands.

**Vendored into a repo.** A team that wants the harness committed rather than installed can copy
`scripts/`, `commands/` → `.claude/commands/`, and `skills/adversarial-review/` →
`.claude/skills/`. The same files work in both layouts: `run-review.sh` finds `model-call.sh` in
the `scripts/` dir beside its install root, and the commands resolve the harness root from
`${CLAUDE_PLUGIN_ROOT}` with a fallback to the repo. `harness-setup` will do this for you.

### Requirements

- A **GitHub remote** — the harness files issues and opens PRs (`gh` authenticated). This is the
  one hard requirement; the flow has nowhere to put a plan or a review without it.
- On `PATH`: `git`, `gh`, `jq`, plus the worker tools `claude` and `codex`.
- Optional: `cmux` (opens each session in its own workspace; degrades to printing a `cd`
  command), `opencode` (the advisory DeepSeek pass).

---

## The reviews

**The gating loop.** The branch is reviewed by the tool that did **not** author it, in rounds
bounded by `REVIEW_MAX_ROUNDS` (default 3). Each round ends in a structured `VERDICT:` line; the
author fixes only blocking findings, re-runs the green-light, and re-reviews. Converged →
finalize the PR. Cap hit still `CHANGES_REQUESTED` → escalate, don't merge.

**Two concept reviews, at different altitudes.** A plan-vocabulary ledger in `/iharden` (design
altitude, before any code), and a realized-code audit in `/iship` after review round 1
(implementation altitude). The second is advisory and never loops.

**Two advisory extras that gate nothing.** An optional **DeepSeek third opinion**
(`--reviewer deepseek`, through `opencode`) for where the gating reviewer and the author share a
blind spot, and a **directed probe** (`--ask "<question>"`) for when a round needs one specific
answer rather than a sweep. Both take no round and neither blocks a merge — which follows from
being optional: a pass that is sometimes skipped is one nothing that merges can depend on.

**Every model call is supervised.** `model-call.sh` bounds each call, isolates each attempt's
output so a dead attempt's bytes can never splice into a retry's, and retries only where a
mechanical read-only sandbox flag makes a second run cost no more than the first. An unsupervised
call has two failure modes that both end as a round which silently did not happen: it hangs
forever, or it dies mid-stream having produced nothing.

Full contract: [`skills/adversarial-review/SKILL.md`](skills/adversarial-review/SKILL.md).

---

## Building

```bash
cd session-harness
./build.sh
```

It validates the skills, commands and both manifests, runs `claude plugin validate`, executes
both offline test suites, **syncs the bundle into the repo's own `scripts/` + `.claude/`** (the
repo dogfoods what it ships, which is also the only exercise the vendored layout gets), proves
the vendored copy resolves its helper, and only then writes `dist/`. Any failure aborts with
`dist/` and the repo-root harness untouched.

**The bundle is the canonical source.** Never hand-edit the repo root's `scripts/`,
`.claude/commands/` or `.claude/skills/` — edit here and rebuild.

## License

[MIT](LICENSE). A copy travels inside the built `.plugin` bundle.
