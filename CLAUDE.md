@AGENTS.md

## Claude-specific notes

- All non-trivial work runs through the interactive flow (`/isession` → `/iharden` →
  `/iship`; `/reap` recycles merged sessions) — specified in `AGENTS.md` above; the
  command wrappers live in `.claude/commands/`.
- Keep shared repo rules in `AGENTS.md`, not here, so Codex sees them too.
