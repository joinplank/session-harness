@AGENTS.md

## Claude-specific notes

- All non-trivial work runs through the interactive flow (`/isession` → `/iharden` →
  `/iship`; `/reap` recycles merged sessions) — specified in `AGENTS.md` above.
- The commands and the `adversarial-review` skill are **synced copies** under `.claude/`,
  written by `session-harness/build.sh` from the plugin bundle. Edit the bundle, then rebuild;
  a change made in `.claude/` or `scripts/` is reverted by the next build.
- Keep shared repo rules in `AGENTS.md`, not here, so Codex sees them too.
