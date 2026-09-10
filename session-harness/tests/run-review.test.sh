#!/usr/bin/env bash
# Gate for skills/adversarial-review/run-review.sh, run offline. Every assertion here is about
# a REFUSAL — a call the script must not make, or must not report as a review. None of them
# reaches a model, so the suite costs nothing and is safe to run on every build.
#
# The refusals matter more than they look. A reviewer handed an empty diff approves it; an --out
# that already holds a round loses the round when it is overwritten; and an advisory pass that
# tells its operator to "escalate, do not merge" contradicts the contract that made it optional.
# Each of those failures produces something that reads exactly like a real review, which is why
# they are asserted rather than left to a reviewer to notice.
#
# Exit: 0 = every property holds · 1 = a property failed.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
RUN_REVIEW="${1:-$HERE/../skills/adversarial-review/run-review.sh}"
[ -f "$RUN_REVIEW" ] || { echo "no run-review.sh at $RUN_REVIEW" >&2; exit 1; }
RUN_REVIEW="$(cd "$(dirname "$RUN_REVIEW")" && pwd)/$(basename "$RUN_REVIEW")"

W="$(mktemp -d)"
trap 'rm -rf "$W"' EXIT HUP INT TERM
FAILED=0
PASSED=0

ok() { # ok <condition-result> <label>
  if [ "$1" = 0 ]; then PASSED=$((PASSED + 1)); echo "  ok  $2"; else echo "  FAIL  $2" >&2; FAILED=1; fi
}

# A repo with a real origin and a real branch diff. Everything below runs inside it, because
# run-review.sh reads the work tree it is called from — a suite that ran in this bundle's own
# checkout would review this bundle.
setup_repo() {
  local origin="$W/origin.git" work="$W/work"
  git init --quiet --bare -b main "$origin"
  git clone --quiet "$origin" "$work" 2>/dev/null
  git -C "$work" config user.email harness@example.invalid
  git -C "$work" config user.name  harness
  echo "base" > "$work/file.txt"
  git -C "$work" add file.txt
  git -C "$work" commit --quiet -m "base"
  git -C "$work" push --quiet -u origin main 2>/dev/null
  git -C "$work" checkout --quiet -b task/1-probe
  printf '%s\n' "$@" >> "$work/file.txt"
  git -C "$work" commit --quiet -am "change"
  printf '%s' "$work"
}
REPO="$(setup_repo change-one)"
cd "$REPO" || exit 1

# --- usage errors are usage errors (exit 2), before anything is spent ---------

echo "run-review.test: usage refusals"
bash "$RUN_REVIEW" --round 0 --out "$W/a.md" >/dev/null 2>&1
[ "$?" = 2 ]; ok $? "--round 0 is a usage error"
bash "$RUN_REVIEW" --round abc --out "$W/b.md" >/dev/null 2>&1
[ "$?" = 2 ]; ok $? "--round must be a number"
bash "$RUN_REVIEW" --nonsense >/dev/null 2>&1
[ "$?" = 2 ]; ok $? "an unknown flag is a usage error"
bash "$RUN_REVIEW" --ask "does X hold?" --round 2 --out "$W/c.md" >/dev/null 2>&1
[ "$?" = 2 ]; ok $? "--round does not apply to --ask (a probe consumes no round)"

# --- an occupied --out is refused, not overwritten ----------------------------
# The two files a round writes are its only copy until the caller posts them, so this refusal
# is what stands between a second round and the first round's text.

echo "run-review.test: an occupied output path is refused"
printf 'a previous round\n' > "$W/taken.md"
bash "$RUN_REVIEW" --out "$W/taken.md" >/dev/null 2>"$W/taken.err"
[ "$?" = 2 ]; ok $? "an --out that already holds a round is refused"
grep -q 'already holds a round' "$W/taken.err"; ok $? "the refusal names what is in the way"
grep -q 'a previous round' "$W/taken.md"; ok $? "the occupying round is left intact"

printf 'a previous full review\n' > "$W/sibling.full.md"
bash "$RUN_REVIEW" --out "$W/sibling.md" >/dev/null 2>&1
[ "$?" = 2 ]; ok $? "an occupied <out>.full.md is refused too"

# An empty file is a dead run's leftover, not a round, and must not lock the number out.
: > "$W/empty.md"
bash "$RUN_REVIEW" --out "$W/empty.md" --reviewer deepseek >/dev/null 2>"$W/empty.err"
grep -q 'already holds a round' "$W/empty.err"
[ "$?" != 0 ]; ok $? "an EMPTY --out is not treated as an occupied one"

# --- an empty diff is refused rather than approved ----------------------------
# The failure this prevents: a reviewer handed nothing finds nothing and returns APPROVED.

echo "run-review.test: an empty diff is never reviewed"
git checkout --quiet main
bash "$RUN_REVIEW" --out "$W/empty-diff.md" >/dev/null 2>"$W/empty-diff.err"
[ "$?" = 1 ]; ok $? "a branch with no changes vs base fails rather than approving"
grep -q 'nothing to review' "$W/empty-diff.err"; ok $? "it says why"
git checkout --quiet task/1-probe

bash "$RUN_REVIEW" --base refs/heads/does-not-exist --out "$W/badref.md" >/dev/null 2>"$W/badref.err"
[ "$?" = 1 ]; ok $? "an unresolvable --base fails"
grep -q 'could not diff' "$W/badref.err"; ok $? "an unresolvable --base is diagnosed as one"

# --- advisory vs gating: a failure means different things ---------------------
# A pass that is optional cannot tell its operator to stop the merge. Asserting the wording is
# asserting the contract: it is the only place the distinction is visible to a human.

echo "run-review.test: an advisory failure says carry on, a gating one says escalate"
OPENCODE_BIN="$W/no-such-opencode" bash "$RUN_REVIEW" --reviewer deepseek --out "$W/ds.md" \
  >/dev/null 2>"$W/ds.err"
[ "$?" = 1 ]; ok $? "the DeepSeek pass fails when opencode is absent"
grep -q 'advisory pass' "$W/ds.err"; ok $? "and reports it as advisory, not as an escalation"
grep -q 'escalate, do not merge' "$W/ds.err"
[ "$?" != 0 ]; ok $? "an advisory failure never says 'escalate, do not merge'"

OPENCODE_BIN="$W/no-such-opencode" bash "$RUN_REVIEW" --reviewer deepseek --ask "does X hold?" \
  --out "$W/dsprobe.md" >/dev/null 2>"$W/dsprobe.err"
[ "$?" = 1 ]; ok $? "a DeepSeek probe fails the same way"
grep -q 'advisory pass' "$W/dsprobe.err"; ok $? "a probe is advisory whichever reviewer answers it"

# The gating half, only where the restricted PATH actually hides the reviewer — otherwise the
# assertion would pass for the wrong reason.
RESTRICTED=/usr/bin:/bin:/usr/sbin:/sbin
if PATH="$RESTRICTED" command -v codex >/dev/null 2>&1; then
  echo "  skip  gating-failure wording (codex is on the restricted PATH)"
else
  PATH="$RESTRICTED" bash "$RUN_REVIEW" --reviewer codex --out "$W/gate.md" >/dev/null 2>"$W/gate.err"
  [ "$?" = 1 ]; ok $? "a gating reviewer that cannot run fails"
  grep -q 'escalate, do not merge' "$W/gate.err"; ok $? "and says escalate, do not merge"
fi

# --- an unknown reviewer is rejected -----------------------------------------

echo "run-review.test: an unknown reviewer is rejected"
bash "$RUN_REVIEW" --reviewer nope --out "$W/nope.md" >/dev/null 2>"$W/nope.err"
[ "$?" = 1 ] || [ "$?" = 2 ]; ok $? "an unknown reviewer never runs a review"
grep -qE "not found|expected claude\|codex\|deepseek" "$W/nope.err"; ok $? "it names the reviewers it accepts"

# --- a probe records its question before asking it ----------------------------
# A probe that dies is exactly when the question is needed, so it is written first. This needs a
# reviewer that EXISTS and then fails: a missing CLI is refused before any call is made, and there
# "unasked" is the truth — the preservation contract covers a call that was made and produced
# nothing. The stub is that reviewer.
#
# The stub is `opencode`, so the whole probe path runs for real: run-review.sh resolves the binary,
# builds the prompt, writes the question, and hands the call to the supervisor, which reports a
# died-before-the-bound attempt exactly as it would for the real CLI.

echo "run-review.test: a probe's question survives a failed probe"
printf '#!/bin/sh\nexit 3\n' > "$W/opencode-stub"
chmod +x "$W/opencode-stub"
MODEL_CALL_TIMEOUT_S=10 OPENCODE_BIN="$W/opencode-stub" bash "$RUN_REVIEW" --reviewer deepseek \
  --ask "does the invariant hold at every call site?" --out "$W/q.md" >/dev/null 2>"$W/q.err"
[ "$?" = 1 ]; ok $? "a probe whose reviewer produces nothing fails"
[ -s "$W/q.question.md" ]; ok $? "the question is on disk after the probe failed"
grep -q 'does the invariant hold at every call site?' "$W/q.question.md"; ok $? "and it is the question that was asked"
grep -q 'UNANSWERED' "$W/q.err"; ok $? "the failure tells the caller to record it as UNANSWERED"
[ ! -s "$W/q.md" ]; ok $? "a failed probe publishes no answer"

# A round by the same stub reviewer fails too, and never invents a verdict from an empty answer.
echo "run-review.test: a reviewer that answers nothing is not an approval"
MODEL_CALL_TIMEOUT_S=10 OPENCODE_BIN="$W/opencode-stub" bash "$RUN_REVIEW" --reviewer deepseek \
  --out "$W/silent.md" >"$W/silent.out" 2>"$W/silent.err"
[ "$?" = 1 ]; ok $? "a silent reviewer fails the round"
grep -q 'VERDICT' "$W/silent.out"
[ "$?" != 0 ]; ok $? "and prints no VERDICT line for the caller to branch on"

if [ "$FAILED" = 0 ]; then
  echo "run-review.test: OK ($PASSED assertions)"
  exit 0
fi
echo "run-review.test: FAILED" >&2
exit 1
