---
name: harness-setup
description: >-
  Wire the interactive session harness (/isession → /iharden → /iship, /reap)
  into the repository in front of you. Installing the plugin already gives you the
  commands and the adversarial-review skill; this skill adds the four repo-level
  things the flow needs and cannot ship with — the .gitignore entries for per-session
  state, the permission allow-list that stops every harness call prompting, the
  AGENTS.md conventions the plan critic and code reviewer both read, and the
  green-light command every review round re-runs. Detects what the repo already has
  and layers on top instead of overwriting. Optionally vendors the harness into the
  repo (scripts/ + .claude/) for a team that wants it committed rather than installed.
  Use when someone says "set up the session harness", "harness this repo", "wire up
  /isession", or asks why /iharden can't find a session.
allowed-tools: Bash, Read, Grep, Glob, Write, Edit
---

# Setting the session harness up in a repo

Installing the plugin gives every repo the four commands and the `adversarial-review`
skill. It cannot give a repo the four things that are **properties of that repo** —
what to ignore, what to allow, what the conventions are, and what "green" means. This
skill adds exactly those, and nothing else.

Run it once per repo. It is safe on a repo you don't own: every step **layers onto**
what's there and asks before replacing anything.

## Preconditions — check these first, report before changing anything

```bash
git rev-parse --show-toplevel                 # must be a git repo
git remote get-url origin                     # must exist — the flow files issues and opens PRs
gh auth status                                # gh must be authenticated against that remote
for t in git gh jq claude codex; do command -v "$t" >/dev/null || echo "MISSING: $t"; done
command -v cmux >/dev/null || echo "note: cmux absent — /isession degrades to printing a cd command"
command -v opencode >/dev/null || echo "note: opencode absent — the advisory DeepSeek pass is unavailable"
```

A missing **origin remote** is the one hard stop: the harness files issues and opens PRs,
so a repo with no GitHub remote can't run the flow. Say so and stop. `cmux` and `opencode`
are optional and degrade cleanly — report them, don't block. A missing `codex` means the
gating reviewer can't run; say so, and offer `REVIEWER=claude` / `CRITIC=claude` only if
the human confirms **Claude is not also the author** (whoever authored must not review).

## 1 · `.gitignore` — per-session state must never be committed

`.session.json` is written at each session clone's root and is that clone's private state.
Append only what's missing:

```
# interactive session state (lives at each session clone root)
.session.json

# local-only Claude settings/hooks (must NOT reach session clones)
.claude/settings.local.json
.claude/hooks/
```

## 2 · `.claude/settings.json` — the permission allow-list

Without it every harness call prompts, which defeats an attended-but-flowing session.
Merge `assets/settings.permissions.json` into the repo's existing `.claude/settings.json`
— **union the `permissions.allow` array**, don't replace the file. If the repo has no
`.claude/settings.json`, write the asset as-is.

Two entry shapes matter and both must be present for each script: the plugin invokes the
harness through `${CLAUDE_PLUGIN_ROOT}` (an absolute path), and a vendored copy invokes it
as `scripts/…`. The asset carries both.

## 3 · `AGENTS.md` — the conventions both adversaries read

The plan critic and the code reviewer are each told **"Read AGENTS.md first."** A repo with
no AGENTS.md gets reviewed against nothing, and the review's blocking bar ("unmet acceptance
criterion") has no conventions to anchor to.

Append `assets/AGENTS-harness-section.md` to the repo's `AGENTS.md` (create it if absent),
then fill its three placeholders from what you detected:

| Placeholder | Fill with |
|---|---|
| `<GREEN_LIGHT>` | the repo's real build/test command (step 4) |
| `<STACK>` | one paragraph: language, framework, package manager, where source lives |
| `<PRODUCT_DOC>` | the repo's architecture/product doc, so the plan critic consults it — or delete the sentence |

If the repo already has an `AGENTS.md`, **append the harness sections and leave everything
else alone**. If it has a `CLAUDE.md` but no `AGENTS.md`, still create `AGENTS.md` (Codex
reads only that one) and add `@AGENTS.md` to the top of `CLAUDE.md` so Claude picks it up too.

**Ask the human about the pre-production stance.** The template ships the clean-breaks-over-
back-compat paragraph, which scopes what the critic may flag and what "regression" means in
review. It is wrong for a repo already shipping to users — ask, and delete it if so.

## 4 · The green-light — what every review round re-runs

Detect it; don't guess. In order of preference: a `green`/`check`/`verify` script in
`package.json`, `Makefile`, or `justfile`; else the type-checking build (`npm run build`,
`cargo build`, `go build ./...`, `mvn -q verify`); else the test command.

```bash
jq -r '.scripts // {} | keys[]' package.json 2>/dev/null
```

Confirm the command you picked with the human, **run it once**, and only then write it into
`AGENTS.md`'s `<GREEN_LIGHT>`. A green-light that was never run is a bar nobody has proven
can be met. If it doesn't pass on a clean checkout, say so — that's the repo's problem to fix
before the harness can gate on it, not something to weaken.

## 5 · Verify, then hand over

```bash
"${CLAUDE_PLUGIN_ROOT:-.}/scripts/session.sh" list     # exits clean, reports no sessions yet
```

Then tell the human the one thing they do next — `/isession <one-liner>` — and that the flow
from there is `discuss → /iharden → /iship`, with them merging the PR at the end.

## Optional · vendoring instead of installing

A team that wants the harness committed to the repo (reviewable, pinned, no per-machine
install) can copy it in instead. Both layouts are supported by the same files:

```bash
P="${CLAUDE_PLUGIN_ROOT}"                       # the installed plugin root
mkdir -p scripts .claude/commands .claude/skills
cp "$P"/scripts/*.sh "$P"/scripts/*.md scripts/
cp "$P"/commands/*.md .claude/commands/
cp -R "$P"/skills/adversarial-review .claude/skills/
```

`run-review.sh` finds `model-call.sh` in the `scripts/` dir beside its install root, and the
commands resolve the harness root from `${CLAUDE_PLUGIN_ROOT}` with a fallback to the repo —
so the same text is correct vendored or installed. Commit the result; the flow's session
clones then carry the harness with them.

Vendoring **shadows the plugin's bare command names** (`/isession` resolves to the repo copy,
the plugin's stays reachable as `/session-harness:isession`). Pick one and say which, so a
later update to the plugin isn't silently ignored.
