# Changelog

All notable changes to the `session-harness` plugin. Format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions are semantic.

The `version` in `.claude-plugin/plugin.json` is the single source of version truth — an entry
here without a version bump ships nothing to anyone who already installed the plugin.

## [0.1.0] — first packaged release

The interactive session harness, previously files you copied between repos, is now an
installable plugin with a marketplace entry.

### Added

- **Four commands**: `/isession`, `/iharden`, `/iship`, `/reap`. They resolve the harness root
  from `${CLAUDE_PLUGIN_ROOT}` with a fallback to the enclosing repo, so one text works whether
  the harness is installed as a plugin or vendored under `scripts/` + `.claude/`.
- **`adversarial-review` skill** — the review turn harness: one round over the branch diff,
  looped by the caller, converging by severity rather than zero findings.
- **`harness-setup` skill** — wires the four repo-level things a plugin can't ship: `.gitignore`
  entries for per-session state, the permission allow-list, the `AGENTS.md` conventions both
  adversaries read, and the green-light. Layers onto what a repo already has.
- **DeepSeek third opinion** — `run-review.sh --reviewer deepseek`, through `opencode`. Advisory,
  never a gate: no round, no merge block, and failures say *record it and carry on*. A diff over
  `DEEPSEEK_MAX_DIFF` (200 000 B) is refused rather than truncated.
- **Directed probe** — `run-review.sh --ask "<question>"`. One aimed question instead of a sweep,
  on whichever reviewer is selected. The question is written to `<out>.question.md` before the
  call, so a probe that dies can be recorded on the PR as UNANSWERED.
- **`scripts/model-call.sh`** — supervises every unattended model call (`run-review.sh`,
  `plan-critique.sh`, `concept-check.sh`). Bounds each call (`MODEL_CALL_TIMEOUT_S`, default
  1800 s), publishes only a successful attempt's output, and retries only behind a mechanical
  read-only sandbox flag.
- **An occupied `--out` is refused, not overwritten** — until its comment is posted, a round's
  two files are its only copy. An empty file is a dead run's leftover and does not lock the path.
- **Two offline test suites** run by `build.sh`: `tests/model-call.test.sh` and
  `tests/run-review.test.sh`, both against stand-in CLIs. Each reports its own assertion count.

### Fixed

- `run-review.sh` exited 128 with nothing on stderr in a repo without `origin/HEAD` — a clone
  taken while the remote was empty never gets one. Under `set -euo pipefail` the failing
  `git symbolic-ref` substitution ended the script before its `else origin/main` fallback,
  making that fallback unreachable. `lib.sh` `default_branch` had the same shape.
- `lib.sh` derived `REPO_DIR` from the scripts' own location, correct only when vendored at
  `<repo>/scripts/`. As a plugin it resolved to the plugin's parent, so a session would have
  cloned the plugin instead of the work.
- `plan-critique.sh` looked for its critic prompt under `$REPO_DIR`, requiring every repo under
  review to carry a copy. It now loads the one shipped beside it.
- `/iship` hardcoded `npm install && npm run build` as the green-light, so the commands ignored
  the green-light `harness-setup` detects and writes into `AGENTS.md`. They now read it from
  `AGENTS.md` §Green-light.
- `--help` printed the shebang and every inline comment in the file. It now prints the header
  block only.
