---
description: Bootstrap INTERACTIVE mode. Provision an isolated clone for a task AND open a cmux workspace with Claude rooted in it, seeded with your one-liner — then discuss → /iharden → /iship happen in that window.
argument-hint: <one-liner description of the task>
allowed-tools: Read, Grep, Glob, Bash
---

Bootstrap an INTERACTIVE session for: **$ARGUMENTS**

Interactive mode runs each task in its **own isolated clone**, driven by **one continuous Claude
session rooted in that clone** — so discuss → harden → implement all share full context, with only
the adversarial reviews shelling out. This command provisions the clone **and opens a cmux
workspace with `claude` rooted in it, seeded with a kickoff prompt that frames your task in the
interactive flow (plan first)** — so that session starts by discussing/planning, NOT jumping to
codegen. It does **not** discuss or write anything in THIS session.

Why a separate window: a Claude session's working directory is fixed at launch, and `/iharden` /
`/iship` resolve the session from the current directory's `.session.json` — so they must run in
the Claude **rooted in the clone** (the one this opens), not in this (repo-root) session. That's
what keeps each session isolated and lets several run in parallel.

## 1. Resolve the slug, provision, and open the session

Derive a short kebab `<slug>` from the one-liner (the human may pass `--slug`). Then hand the slug
**and** the one-liner to `session.sh new --launch` — it's idempotent (reopen an existing slug →
reclaim a warm idle slot → else fresh clone), and `--launch` opens a cmux workspace rooted in the
slot running `claude` seeded with a kickoff prompt that frames `--message` in the interactive flow
(plan first — discuss → /iharden → /iship, not codegen):

```bash
# Where the harness lives. Installed as a plugin, the loader substitutes the token below with the
# plugin root; in a repo that vendored the harness the token is left alone, expands to empty, and
# the fallback names the repo itself — so one line is correct in both layouts.
H="${CLAUDE_PLUGIN_ROOT}"; [ -n "$H" ] || H="$(git rev-parse --show-toplevel)"

SLUG="<slug>"
DIR="$("$H/scripts/session.sh" new --slug "$SLUG" --launch --message "$ARGUMENTS")"   # prints the clone path
```

(`$H` is the harness root — set once here and reused by every block below that shells out
to the harness. If a later block finds it empty, re-run that one line; it is the whole
portability contract between the plugin and vendored layouts.)

Slots are a reused, **numbered** pool — `~/work/<repo>-session-NN`. The slot NUMBER is the stable dir; the slug and the cmux
workspace name live in `.session.json`, so `reap`/`release` can close the workspace and a reused
slot is never renamed. The message is passed via a gitignored seed file, so any characters in it
survive. If cmux isn't installed, `new` skips the launch and prints a `cd … && claude` fallback.
(Re-running on an **active** slug just reopens it — it does **not** open a second window. To
discard and recreate, add `--force`.)

## 2. Report — the session window is open

`new --launch` opens the cmux workspace and prints the clone path. Tell the human, concisely, that
their interactive session is open and already discussing the task:

```
Interactive session '<slug>' is open in a new cmux workspace (claude, seeded with your task):
    <DIR>
Switch to that window — it's already on your task. Continue there: discuss → /iharden → /iship.
(If cmux wasn't available: cd <DIR> && claude)
```

**Stop here.** Do **not** discuss the task, file an issue, or write code in THIS session — all of
that happens in the cmux-rooted Claude, which has its own full context. Run `"$H/scripts/session.sh"
list` to see open sessions; `"$H/scripts/session.sh" release <slug>` resets a finished one to a warm
idle slot **and closes its cmux workspace** (`--purge` to remove it for disk; refuses to touch
unpushed work without `--force`).
