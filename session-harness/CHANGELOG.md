# Changelog

All notable changes to the `session-harness` plugin. Format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions are semantic.

The `version` field in `.claude-plugin/plugin.json` is the single source of version truth —
an entry here without a version bump ships nothing to anyone who already installed the plugin.

## [0.1.0] — first packaged release

The interactive session harness, previously a set of files you copied between repos, is now an
installable plugin with a marketplace entry.

### Added

- **Four slash commands** shipped by the plugin: `/isession`, `/iharden`, `/iship`, `/reap`.
  They resolve the harness root from `${CLAUDE_PLUGIN_ROOT}` with a fallback to the enclosing
  repo, so one command text is correct whether the harness is installed as a plugin or vendored
  into a repo under `scripts/` + `.claude/`.
- **`adversarial-review` skill** — the review turn harness: one round over the branch diff,
  looped by the caller, converging by SEVERITY rather than zero findings.
- **`harness-setup` skill** — wires the four repo-level things the flow needs and a plugin
  cannot ship: the `.gitignore` entries for per-session state, the permission allow-list, the
  `AGENTS.md` conventions both adversaries read, and the green-light command. Layers onto what a
  repo already has instead of overwriting it.
- **An advisory DeepSeek third opinion** — `run-review.sh --reviewer deepseek`, through
  `opencode`. A fresh model over the same diff, for where the gating reviewer and the author
  share a blind spot. It is **never a gate**, which follows from being optional: it takes no
  round, its `CHANGES_REQUESTED` does not block a merge, and its failures say *record it and
  carry on* rather than *escalate*. A branch over `DEEPSEEK_MAX_DIFF` (200 000 B) is **refused
  rather than truncated** — a clipped diff would read as a complete review over code the model
  never saw, and nobody re-checks an advisory verdict.
- **A directed probe** — `run-review.sh --ask "<question>"`. One aimed question about the same
  diff instead of a sweep, following whichever reviewer is selected. Advisory like the DeepSeek
  pass. The question is written to `<out>.question.md` **before** the call, so a probe that dies
  leaves it recoverable and can be recorded on the PR as UNANSWERED.
- **`scripts/model-call.sh`** — one supervisor for every unattended model call in the flow,
  sourced by `run-review.sh`, `plan-critique.sh` and `concept-check.sh`. An unsupervised call has
  two failure modes that both end as a round which silently did not happen: it hangs forever, or
  it dies mid-stream having produced nothing. `model_call` bounds every call
  (`MODEL_CALL_TIMEOUT_S`, default 1800 s), isolates each attempt's output so a dead attempt's
  bytes can never splice into a retry's, and retries **only** where a mechanical read-only
  sandbox flag makes a second run cost no more than the first.
- **An occupied `--out` is refused, not overwritten.** Between a round finishing and its comment
  going up, those two files are the round's only copy. An empty file is a dead run's leftover,
  not a round, and does not lock the path.
- **Two offline test suites**, run by `build.sh` on every build: `tests/model-call.test.sh`
  (30 assertions against stand-in CLIs — the bound fires, a timed-out call is not retried, a dead
  attempt's bytes never surface, the watchdog leaves nothing running, an interrupted supervisor
  takes its call with it) and `tests/run-review.test.sh` (the refusal surface — usage errors,
  occupied outputs, an empty diff, and that an advisory failure never says "escalate").

### Fixed

- **`run-review.sh` could die at exit 128 with nothing on stderr** in a repo without
  `origin/HEAD` — a clone taken while the remote was empty never gets one. Under
  `set -euo pipefail` the failing `git symbolic-ref` substitution ended the script before its
  documented `else origin/main` fallback could be reached, making that fallback unreachable and
  turning a routine repo state into a silent non-review. `lib.sh`'s `default_branch` had the same
  shape and the same fix.
- **`lib.sh` derived `REPO_DIR` from the scripts' own location**, which is correct only when they
  are vendored at `<repo>/scripts/`. Installed as a plugin it resolved to the plugin's parent, so
  a session would have cloned the plugin instead of the work. It now resolves from the current
  directory, which is the same answer in the vendored layout.
- **`plan-critique.sh` looked for its critic prompt at `$REPO_DIR/scripts/plan-reviewer.md`**,
  requiring every repo under review to carry a copy. It now loads the prompt shipped beside it,
  matching `concept-check.sh`.
