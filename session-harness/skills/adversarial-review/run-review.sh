#!/usr/bin/env bash
# One adversarial code-review round over the current branch diff, by the
# COMPLEMENTARY tool. Prints exactly one `VERDICT:` line on stdout and writes a
# COMPACT review (blocking findings + VERDICT) to --out, plus the reviewer's
# FINAL review message to a sibling <out>.full.md (the review itself — the raw
# session transcript stays in a scratch file and is deleted, never published).
# The caller READS --out (small — keeps its context clean) and only `cat`s the
# .full.md into a PR <details> for provenance. This is the implementation-review
# mirror of the /iharden plan critique (plan-critique.sh); the bounded
# LOOP (fix blocking -> green-light -> re-review, to convergence or
# REVIEW_MAX_ROUNDS) is driven by the caller — see SKILL.md. Severity call stays
# on the reviewer: only correctness/security/data-loss/broken-contract/
# regression/unmet-AC are BLOCKING; the rest are NITs.
#
# `deepseek` is an ADVISORY third opinion, never a gate: it runs only when an engineer asks
# for one, so nothing that merges can depend on it having run. Its verdict is read the way the
# concept pass is — findings dispositioned (applied, or declined with a one-line rationale),
# recorded on the PR — and the convergence loop still turns on the GATING reviewer alone. A
# reviewer that is sometimes skipped cannot be a gate, which is why its failures say "record it
# and carry on" where the gating reviewers say "escalate, do not merge".
#
# A DIRECTED PROBE (`--ask`) is the other thing this script does: one aimed question about the
# same diff, for when a round has to ask the reviewer something specific rather than sweep. It
# follows the SELECTED reviewer and refuses none of them — a question needs a custom prompt, so
# every backend is a single call, without the two-call `review --base` dance a Codex round needs.
# Like DeepSeek it is ADVISORY: asked on request, so it gates nothing, and it consumes no review
# round. A probe whose attempts are exhausted leaves its question on disk beside the output path,
# to be recorded on the PR as UNANSWERED — the call was made, so "unasked" would be a lie.
#
# Usage:
#   run-review.sh [--reviewer claude|codex|deepseek] [--base <ref>] [--out <file>] [--round <N>]
#   run-review.sh --ask <question> [--reviewer …] [--base <ref>] [--out <file>]
#     --round <N>  the loop round (default 1); selects the Codex effort tier (see CODEX_EFFORT).
#     --out <file> where this round lands. Give EVERY round its own path (name it for the round):
#                  an --out or <out>.full.md that already holds a round is REFUSED, not overwritten.
#     --ask <q>    ask ONE question about the diff instead of running a round. The answer lands at
#                  --out and the question at <out>.question.md, so a failure leaves it recoverable.
#
# Env (repo defaults shown):
#   REVIEWER           claude|codex|deepseek  (default: codex — the session authors, Codex reviews)
#   CODEX_MODEL        <codex model>     (default: gpt-5.6-sol — frontier tier; pins the Codex review gate)
#   CODEX_EFFORT       <effort tier>     (optional; forces ONE reasoning tier for every round. Unset =
#                                         round policy: --round 1 = ultra (deep first sweep), 2+ = xhigh)
#   DEEPSEEK_MODEL     provider/model    (default: deepseek/deepseek-v4-pro — frontier tier, pinned
#                                         like CODEX_MODEL so the pass does not drift with a default)
#   DEEPSEEK_MAX_DIFF  <bytes>           (default: 200000 — refuse rather than overflow; see the branch)
#   OPENCODE_BIN       <path>            (optional; the opencode binary DeepSeek speaks through)
#   BASE               <git ref>         (default: origin/<default-branch>, else origin/main)
#   ISSUE              <number>          (optional; lets the claude/deepseek reviewer check acceptance criteria)
#   REPO_SLUG          owner/name        (optional; used with ISSUE to fetch the spec)
#   MODEL_CALL_TIMEOUT_S <seconds>       (default: 1800 — the per-call bound every model call runs under)
#
# Exit: 0 = the call produced its artifact — a round's VERDICT line (read it to branch), or a
#           probe's answer at --out (a probe emits no verdict, by design) ·
#       1 = reviewer failed ·
#       2 = usage error, including an --out path already occupied
set -euo pipefail

REVIEWER="${REVIEWER:-}"
BASE="${BASE:-}"
OUT=""
ROUND=1
ASK=""
while [ $# -gt 0 ]; do
  case "$1" in
    --reviewer) REVIEWER="$2"; shift 2;;
    --base)     BASE="$2"; shift 2;;
    --out)      OUT="$2"; shift 2;;
    --round)    ROUND="$2"; shift 2;;
    --ask)      ASK="${2:?--ask requires a question}"; shift 2;;
    -h|--help)  grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0;;
    *) echo "unknown arg: $1" >&2; exit 2;;
  esac
done

# The supervisor every unattended model call here goes through (bound, opt-in retry, per-attempt
# output isolation). It lives with the harness's other scripts rather than in this folder, so a
# copy of the skill must bring it along — see SKILL.md's reproduction section. Two candidates
# because the skill sits at a different depth in the two supported layouts: `skills/…` under a
# plugin root, `.claude/skills/…` in a repo that vendored the harness. Both resolve to the
# sibling `scripts/` of whichever root the harness was installed at.
HERE="$(cd "$(dirname "$0")" && pwd)"
MODEL_CALL=""
for candidate in "$HERE/../../scripts/model-call.sh" "$HERE/../../../scripts/model-call.sh"; do
  [ -f "$candidate" ] || continue
  MODEL_CALL="$candidate"; break
done
[ -n "$MODEL_CALL" ] \
  || { echo "missing model-call.sh — expected it in the scripts/ dir beside this skill's install root" >&2; exit 1; }
# shellcheck source=../../scripts/model-call.sh
. "$MODEL_CALL"

case "$ROUND" in ''|*[!0-9]*) echo "--round must be a positive integer" >&2; exit 2;; esac
[ "$ROUND" -ge 1 ] || { echo "--round must be >= 1" >&2; exit 2; }
# A probe is not a round and takes no round number: --round only selects a round's effort tier, so
# accepting it here would read as an effort setting the probe does not apply.
if [ -n "$ASK" ] && [ "$ROUND" != 1 ]; then
  echo "--round does not apply to --ask (a probe consumes no review round)" >&2; exit 2
fi

# Default reviewer: Codex — the interactive session (Claude) authors, so the
# COMPLEMENTARY tool reviews. Pass --reviewer claude only when Codex authored.
REVIEWER="${REVIEWER:-codex}"

# Default BASE to origin/<default-branch>, else origin/main. `|| true`, because origin/HEAD is
# absent in more repos than it looks — a clone taken while the remote was empty never gets one —
# and under `set -euo pipefail` the failing substitution alone would end this script at exit 128
# with nothing on stderr, which is the silent non-review every other check here exists to prevent.
if [ -z "$BASE" ]; then
  DEF="$(git symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's#^origin/##' || true)"
  BASE="origin/${DEF:-main}"
fi

OUT="${OUT:-$(mktemp -t adv-review.XXXXXX).md}"
FULL="${OUT%.md}.full.md"     # sibling: the raw prose review, for PR provenance only (never Read)
QUESTION="${OUT%.md}.question.md"   # sibling: a probe's question, kept so a failed one is recoverable
DIFF_RANGE="${BASE}...HEAD"   # three-dot: branch changes since the merge-base
# Both models are pinned rather than inherited from a machine's CLI config, so a review is
# reproducible and the gate does not silently drift when a global default changes.
CODEX_MODEL="${CODEX_MODEL:-gpt-5.6-sol}"
DEEPSEEK_MODEL="${DEEPSEEK_MODEL:-deepseek/deepseek-v4-pro}"
DEEPSEEK_MAX_DIFF="${DEEPSEEK_MAX_DIFF:-200000}"

# Whether this call GATES the merge, decided once and driving what a failed run costs: an advisory
# reviewer costs a third opinion, a gating one costs the merge.
# Advisory is a property of the MODE, not of one backend: a probe gates nothing whichever reviewer
# answers it, so telling its operator to "escalate, do not merge" would contradict the contract.
if [ -n "$ASK" ] || [ "$REVIEWER" = deepseek ]; then
  ADVISORY=1
  FAIL_NOTE="advisory pass — record the failure and carry on"
else
  ADVISORY=0
  FAIL_NOTE="escalate, do not merge"
fi

# Refuse a range that yields no code, before any reviewer is paid to look at it. An unresolvable
# ref or an empty diff would otherwise reach the reviewer as a prompt with nothing under it, and a
# reviewer with nothing to find returns APPROVED — a green round over code nobody read. `--quiet`
# answers this without materializing the diff, which the Codex round never inlines.
# `|| DIFF_STATUS=$?`, not `; DIFF_STATUS=$?`: under `set -e` a bare failing command ends the
# script before its status can be read, which would turn every diagnosis below into a silent exit.
DIFF_STATUS=0
git diff --quiet "$DIFF_RANGE" 2>/dev/null || DIFF_STATUS=$?
case "$DIFF_STATUS" in
  1) ;;   # differences exist — the only case worth reviewing
  0) echo "no changes vs $BASE — nothing to review (a reviewer handed an empty diff approves it)" >&2; exit 1;;
  *) echo "could not diff $DIFF_RANGE — unknown ref? try 'git fetch origin', or pass --base" >&2; exit 1;;
esac

# The diff body, for the paths that inline it into a prompt. Built ONCE, here, with its status
# read: inside a `$(...)` in a prompt string a failure is invisible, and the reviewer would receive
# a prompt with nothing under it and return a confident verdict on an empty diff. The Codex round
# is excluded because `review --base` re-derives the diff itself and would pay for one it never sends.
DIFF=""
if [ -n "$ASK" ] || [ "$REVIEWER" != codex ]; then
  DIFF="$(git --no-pager diff "$DIFF_RANGE")" \
    || { echo "could not read the diff for $DIFF_RANGE — $FAIL_NOTE" >&2; exit 1; }
  [ -n "$DIFF" ] || { echo "the diff for $DIFF_RANGE came back empty — $FAIL_NOTE" >&2; exit 1; }
fi

# An output path that already holds something is refused, never overwritten: a round's two files
# are its only copy until the caller posts them (see SKILL.md), so a reused path destroys an
# unposted round. The test is content, not existence — a reviewer that dies leaves the empty stub
# its output redirection created, and that stub must not lock the round out of being re-run.
for occupied in "$OUT" "$FULL" "$QUESTION"; do
  if [ -s "$occupied" ]; then
    echo "output path already holds a round: $occupied — give this round its own path" >&2
    exit 2
  fi
done

# The CLI a reviewer speaks through is its own name, except DeepSeek's, which is opencode.
# opencode installs to ~/.opencode/bin, which a non-login shell does not carry on PATH, so this
# resolves the binary itself rather than requiring the caller to have sourced a profile.
if [ "$REVIEWER" = deepseek ]; then
  OPENCODE="${OPENCODE_BIN:-$(command -v opencode || true)}"
  [ -n "$OPENCODE" ] || OPENCODE="$HOME/.opencode/bin/opencode"
  [ -x "$OPENCODE" ] \
    || { echo "opencode not executable at '$OPENCODE' (set OPENCODE_BIN) — $FAIL_NOTE" >&2; exit 1; }
  command -v jq >/dev/null \
    || { echo "jq not found (the deepseek branch parses opencode's NDJSON with it) — $FAIL_NOTE" >&2; exit 1; }
else
  command -v "$REVIEWER" >/dev/null \
    || { echo "reviewer CLI '$REVIEWER' not found — $FAIL_NOTE" >&2; exit 1; }
fi

# Optional: pull the issue spec so the reviewer can check acceptance criteria.
SPEC=""
if [ -n "${ISSUE:-}" ] && [ -n "${REPO_SLUG:-}" ] && command -v gh >/dev/null; then
  SPEC="$(gh issue view "$ISSUE" -R "$REPO_SLUG" 2>/dev/null || true)"
fi

BLOCKING_DEF="BLOCKING = a correctness bug, a security or data-loss risk, a broken \
public contract/API, a regression, or an unmet acceptance criterion from the issue. \
Everything else (style, naming, formatting, subjective preference, optional \
refactors, doc wording, speculative 'could also') is a NIT and must NOT block."

# The adversarial contract every SINGLE-CALL reviewer speaks — same tags, same severity rule, same
# closing VERDICT line — so a DeepSeek round reads exactly like a Claude one and the caller parses
# one shape. Built on demand rather than up front: the Codex path drives its own `review --base`
# and would pay for a diff it never inlines.
adversarial_prompt() {
  printf '%s' "You are an ADVERSARIAL code reviewer. Review ONLY the branch diff below
(\`git diff ${DIFF_RANGE}\`) for THIS repo. Read AGENTS.md first. Triage every
finding with a tag: [BLOCKER] / [SHOULD] / [NIT]. ${BLOCKING_DEF}
Be concrete: cite file:line and say what is wrong and what 'good' looks like.
Output a tagged findings list, then EXACTLY ONE final line:
'VERDICT: APPROVED' if there are no [BLOCKER]s, else 'VERDICT: CHANGES_REQUESTED'.
${SPEC:+=== ISSUE SPEC (check acceptance criteria) ===
$SPEC
}=== BRANCH DIFF UNDER REVIEW ===
$DIFF"
}

# A directed probe: one aimed question about the same diff. No tags and no VERDICT — a probe is
# not a round, and a verdict line here would be a second gate wearing the review's clothes.
probe_prompt() {
  printf '%s' "You are an ADVERSARIAL code reviewer. Answer the QUESTION below about the branch
diff (\`git diff ${DIFF_RANGE}\`) for THIS repo. Read AGENTS.md first.
Answer ONLY what was asked: cite file:line, say what would falsify your answer, and say plainly
when the diff does not settle the question rather than filling the gap. Do not review anything the
question did not ask about, and do not emit a VERDICT line.
=== QUESTION ===
$ASK
=== BRANCH DIFF ===
$DIFF"
}

# DeepSeek inlines the whole diff and its window is far shorter than the gating reviewers', so an
# oversized branch is REFUSED rather than sent. Truncating would yield an answer that reads as
# complete over code the model never saw — the one failure an advisory pass must not have, because
# nobody re-checks it.
deepseek_diff_guard() {
  [ "${#DIFF}" -le "$DEEPSEEK_MAX_DIFF" ] && return 0
  echo "diff is ${#DIFF}B, over DEEPSEEK_MAX_DIFF=${DEEPSEEK_MAX_DIFF}B (narrow --base, or raise the cap deliberately) — $FAIL_NOTE" >&2
  return 1
}

# The attempt functions, one per CLI. They read `$PROMPT`, which the caller sets before dispatching
# — the same convention plan-critique.sh and concept-check.sh use — so a round and a probe share one
# wrapper per backend, and a retried call reuses the prompt instead of rebuilding it.
_call_claude()   { claude -p --dangerously-skip-permissions "$PROMPT" >"$1" 2>/dev/null; }
_call_deepseek() { "$OPENCODE" run --pure --format json -m "$DEEPSEEK_MODEL" "$PROMPT" 2>/dev/null \
                     | jq -r 'select(.type=="text") | .part.text' >"$1"; }
# Only this one takes --retry: `-s read-only` is a mechanical write boundary.
# `--dangerously-skip-permissions` is the opposite of one, and `--pure` blocks plugins, not writes.
_probe_codex()   { codex exec -m "$CODEX_MODEL" -c model_reasoning_effort="${CODEX_EFFORT:-xhigh}" \
                     -s read-only -o "$1" "$PROMPT" >/dev/null 2>&1; }

# --- directed probe: one aimed question, then done ---------------------------------------------
if [ -n "$ASK" ]; then
  # Write the question BEFORE asking it. The supervisor cannot name a prompt inside arbitrary argv,
  # so preserving it is the caller's job — and a probe that dies is exactly when it is needed.
  # The path is derived from --out, so it is predictable: refuse a symlink rather than truncate
  # whatever it points at, and create the file private, since a question quotes the work under review.
  [ ! -L "$QUESTION" ] \
    || { echo "refusing to write the question through a symlink: $QUESTION" >&2; exit 2; }
  ( umask 077; printf '%s\n' "$ASK" > "$QUESTION" ) \
    || { echo "could not record the question at $QUESTION — not asking it" >&2; exit 1; }
  PROMPT="$(probe_prompt)"
  case "$REVIEWER" in
    claude)   model_call --label "directed probe (claude)" --out "$OUT" -- _call_claude;;
    codex)    model_call --label "directed probe (codex)" --out "$OUT" --retry -- _probe_codex;;
    deepseek) deepseek_diff_guard && model_call --label "directed probe (deepseek)" --out "$OUT" -- _call_deepseek;;
    *) echo "unknown reviewer '$REVIEWER' (expected claude|codex|deepseek)" >&2; exit 2;;
  esac || {
    echo "directed probe produced no answer — the question is preserved at $QUESTION;" >&2
    echo "record it on the PR as UNANSWERED (it gates nothing and consumes no review round)" >&2
    exit 1
  }
  [ -s "$OUT" ] || { echo "directed probe returned an empty answer — record it as UNANSWERED ($QUESTION)" >&2; exit 1; }
  echo "reviewer=$REVIEWER base=$BASE probe=$OUT question=$QUESTION" >&2
  exit 0
fi

case "$REVIEWER" in
  claude)
    # Claude emits the VERDICT line natively from the adversarial prompt — 1 call.
    PROMPT="$(adversarial_prompt)"
    model_call --label "review round $ROUND (claude)" --out "$OUT" -- _call_claude \
      || { echo "claude reviewer failed — $FAIL_NOTE" >&2; exit 1; }
    ;;

  codex)
    # Effort by round: the FIRST round runs ultra (max reasoning + automatic task
    # delegation) so the fresh full-diff sweep finds the most; later rounds re-review a
    # narrower fix-up, so they drop to xhigh. CODEX_EFFORT forces one tier for every round.
    # Only the REVIEW call scales — the classifier below is mechanical triage, left at the
    # inherited default. (ultra needs a sol/terra model; the default CODEX_MODEL is sol.)
    if [ -n "${CODEX_EFFORT:-}" ]; then EFFORT="$CODEX_EFFORT"
    elif [ "$ROUND" -le 1 ]; then EFFORT="ultra"
    else EFFORT="xhigh"; fi
    # Codex's --base review is mutually exclusive with a custom [PROMPT] (clap
    # rejects the combo) -> 2 calls: (1) the review — the session transcript goes
    # to a scratch log while -o captures ONLY the final review message,
    # (2) a classifier that turns that message into the structured VERDICT line.
    LOG="$(mktemp -t adv-review-log.XXXXXX)"
    PROSE="$(mktemp -t adv-review-prose.XXXXXX)"
    # `review --base` carries no sandbox flag, so it is bounded but NOT retried: retry is granted
    # only where a mechanical write boundary makes a second run cost no more than the first.
    _review_codex() { codex exec review -m "$CODEX_MODEL" -c model_reasoning_effort="$EFFORT" --base "$BASE" -o "$1" >"$LOG" 2>&1; }
    model_call --label "review round $ROUND (codex review)" --out "$PROSE" -- _review_codex \
      || { echo "codex review failed — escalate, do not merge" >&2; rm -f "$LOG" "$PROSE"; exit 1; }
    # -o wrote nothing? Fall back to everything after the LAST `codex` marker line
    # of the session log; still empty -> fail. Never feed the whole log onward.
    if [ ! -s "$PROSE" ]; then
      MARK="$(grep -n '^codex$' "$LOG" | tail -1 | cut -d: -f1 || true)"
      [ -z "$MARK" ] || tail -n "+$((MARK + 1))" "$LOG" >"$PROSE"
    fi
    [ -s "$PROSE" ] \
      || { echo "codex review produced no final message — escalate, do not merge" >&2; rm -f "$LOG" "$PROSE"; exit 1; }
    CLASSIFY="Triage this code review. List ONLY the BLOCKING findings (${BLOCKING_DEF}).
End with EXACTLY one line: 'VERDICT: APPROVED' if there are no blocking findings,
else 'VERDICT: CHANGES_REQUESTED'. Review:
$(cat "$PROSE")"
    # The classifier runs under `-s read-only`, so it earns --retry.
    _classify_codex() { codex exec -m "$CODEX_MODEL" -s read-only -o "$1" "$CLASSIFY" >/dev/null 2>&1; }
    model_call --label "review round $ROUND (codex classifier)" --out "$OUT" --retry -- _classify_codex \
      || { echo "codex classifier failed — escalate, do not merge" >&2; rm -f "$LOG" "$PROSE"; exit 1; }
    # Keep --out COMPACT (classifier blocking findings + VERDICT). The final review
    # message goes to the sibling .full.md for PR provenance; the session log is
    # deleted — never published, never appended to --out.
    cp "$PROSE" "$FULL"
    { echo; echo "(final Codex review: $FULL — for PR provenance, not needed to fix)"; } >>"$OUT"
    rm -f "$LOG" "$PROSE"
    ;;

  deepseek)
    # DeepSeek speaks through opencode, which streams NDJSON events; the reviewer's message is the
    # `text` parts in order. Like the claude branch this is ONE call — the model closes with the
    # VERDICT line itself, so nothing has to re-structure prose afterwards.
    deepseek_diff_guard || exit 1
    # --pure keeps the review a function of this repo and the model alone: no external opencode
    # plugin can reshape a verdict depending on whose machine it ran on. It is not a write
    # boundary, though, so this pass is bounded and not retried.
    PROMPT="$(adversarial_prompt)"
    model_call --label "review round $ROUND (deepseek)" --out "$OUT" -- _call_deepseek \
      || { echo "deepseek reviewer failed — $FAIL_NOTE" >&2; exit 1; }
    ;;

  *) echo "unknown reviewer '$REVIEWER' (expected claude|codex|deepseek)" >&2; exit 2;;
esac

# The Claude and DeepSeek reviewers write their (already compact, tagged) review straight to --out
# and produce no separate raw transcript, so mirror it to .full.md — the caller can always
# `cat` a .full.md for the PR <details>, whichever reviewer ran. Keyed on content for the same
# reason the occupancy check above is: an empty file is a dead run's leftover, not a review, and
# treating it as one would hand the PR a blank <details>.
[ -s "$FULL" ] || cp "$OUT" "$FULL"

# The verdict line, tolerant of the markdown emphasis a reviewer may wrap it in (`**VERDICT: …**`)
# and normalized back to the bare form. The contract asks for a plain line, but a reviewer that
# reached a verdict and then formatted it has not failed — treating that as "no verdict" would
# discard a real review over styling. Normalizing here means every caller parses one shape no
# matter which reviewer ran.
VERDICT="$(sed -nE 's/^[[:space:]]*[*_]{0,2}VERDICT:[[:space:]]*([A-Z]+(_[A-Z]+)*).*$/VERDICT: \1/p' "$OUT" | tail -1 || true)"
echo "reviewer=$REVIEWER base=$BASE round=$ROUND advisory=$ADVISORY effort=${EFFORT:-inherited} review=$OUT full=$FULL" >&2
# A reviewer that produced no parseable verdict is a failure, not an approval.
[ -n "$VERDICT" ] || { echo "no VERDICT line in review — $FAIL_NOTE" >&2; exit 1; }
echo "$VERDICT"
