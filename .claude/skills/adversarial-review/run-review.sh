#!/usr/bin/env bash
# One adversarial code-review round over the current branch diff, by the
# COMPLEMENTARY tool. Prints exactly one `VERDICT:` line on stdout and writes a
# COMPACT review (blocking findings + VERDICT) to --out, plus the reviewer's
# FINAL review message to a sibling <out>.full.md (the review itself — the raw
# session transcript stays in a scratch file and is deleted, never published).
# The caller READS --out (small — keeps its context clean) and only `cat`s the
# .full.md into a PR <details> for provenance. This is the implementation-review
# mirror of the /iharden plan critique (scripts/plan-critique.sh); the bounded
# LOOP (fix blocking -> green-light -> re-review, to convergence or
# REVIEW_MAX_ROUNDS) is driven by the caller — see SKILL.md. Severity call stays
# on the reviewer: only correctness/security/data-loss/broken-contract/
# regression/unmet-AC are BLOCKING; the rest are NITs.
#
# Usage:
#   run-review.sh [--reviewer claude|codex] [--base <ref>] [--out <file>] [--round <N>]
#     --round <N>  the loop round (default 1); selects the Codex effort tier (see CODEX_EFFORT).
#
# Env (repo defaults shown):
#   REVIEWER           claude|codex      (default: codex — the session authors, Codex reviews)
#   CODEX_MODEL        <codex model>     (default: gpt-5.6-sol — frontier tier; pins the Codex review gate)
#   CODEX_EFFORT       <effort tier>     (optional; forces ONE reasoning tier for every round. Unset =
#                                         round policy: --round 1 = ultra (deep first sweep), 2+ = xhigh)
#   BASE               <git ref>         (default: origin/<default-branch>, else origin/main)
#   ISSUE              <number>          (optional; lets the claude reviewer check acceptance criteria)
#   REPO_SLUG          owner/name        (optional; used with ISSUE to fetch the spec)
#
# Exit: 0 = a VERDICT line was produced (read it to branch) · 1 = reviewer failed ·
#       2 = usage error
set -euo pipefail

REVIEWER="${REVIEWER:-}"
BASE="${BASE:-}"
OUT=""
ROUND=1
while [ $# -gt 0 ]; do
  case "$1" in
    --reviewer) REVIEWER="$2"; shift 2;;
    --base)     BASE="$2"; shift 2;;
    --out)      OUT="$2"; shift 2;;
    --round)    ROUND="$2"; shift 2;;
    -h|--help)  grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0;;
    *) echo "unknown arg: $1" >&2; exit 2;;
  esac
done
case "$ROUND" in ''|*[!0-9]*) echo "--round must be a positive integer" >&2; exit 2;; esac
[ "$ROUND" -ge 1 ] || { echo "--round must be >= 1" >&2; exit 2; }

# Default reviewer: Codex — the interactive session (Claude) authors, so the
# COMPLEMENTARY tool reviews. Pass --reviewer claude only when Codex authored.
REVIEWER="${REVIEWER:-codex}"

# Default BASE to origin/<default-branch>.
if [ -z "$BASE" ]; then
  DEF="$(git symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's#^origin/##')"
  BASE="origin/${DEF:-main}"
fi

OUT="${OUT:-$(mktemp -t adv-review.XXXXXX).md}"
FULL="${OUT%.md}.full.md"     # sibling: the raw prose review, for PR provenance only (never Read)
DIFF_RANGE="${BASE}...HEAD"   # three-dot: branch changes since the merge-base

command -v "$REVIEWER" >/dev/null \
  || { echo "reviewer CLI '$REVIEWER' not found — escalate, do not merge" >&2; exit 1; }

# Optional: pull the issue spec so the reviewer can check acceptance criteria.
SPEC=""
if [ -n "${ISSUE:-}" ] && [ -n "${REPO_SLUG:-}" ] && command -v gh >/dev/null; then
  SPEC="$(gh issue view "$ISSUE" -R "$REPO_SLUG" 2>/dev/null || true)"
fi

BLOCKING_DEF="BLOCKING = a correctness bug, a security or data-loss risk, a broken \
public contract/API, a regression, or an unmet acceptance criterion from the issue. \
Everything else (style, naming, formatting, subjective preference, optional \
refactors, doc wording, speculative 'could also') is a NIT and must NOT block."

case "$REVIEWER" in
  claude)
    # Claude emits the VERDICT line natively from the adversarial prompt — 1 call.
    PROMPT="You are an ADVERSARIAL code reviewer. Review ONLY the branch diff below
(\`git diff ${DIFF_RANGE}\`) for THIS repo. Read AGENTS.md first. Triage every
finding with a tag: [BLOCKER] / [SHOULD] / [NIT]. ${BLOCKING_DEF}
Be concrete: cite file:line and say what is wrong and what 'good' looks like.
Output a tagged findings list, then EXACTLY ONE final line:
'VERDICT: APPROVED' if there are no [BLOCKER]s, else 'VERDICT: CHANGES_REQUESTED'.
${SPEC:+=== ISSUE SPEC (check acceptance criteria) ===
$SPEC
}=== BRANCH DIFF UNDER REVIEW ===
$(git --no-pager diff "$DIFF_RANGE")"
    claude -p --dangerously-skip-permissions "$PROMPT" </dev/null >"$OUT" 2>/dev/null \
      || { echo "claude reviewer failed — escalate, do not merge" >&2; exit 1; }
    ;;

  codex)
    # Pin the gate to a chosen Codex model (frontier by default) instead of inheriting
    # whatever ~/.codex/config.toml is set to, so the review stays reproducible and
    # doesn't silently drift with the global default. Override with CODEX_MODEL.
    CODEX_MODEL="${CODEX_MODEL:-gpt-5.6-sol}"
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
    codex exec review -m "$CODEX_MODEL" -c model_reasoning_effort="$EFFORT" --base "$BASE" -o "$PROSE" >"$LOG" 2>&1 \
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
    codex exec -m "$CODEX_MODEL" -s read-only -o "$OUT" "$CLASSIFY" </dev/null >/dev/null 2>&1 \
      || { echo "codex classifier failed — escalate, do not merge" >&2; rm -f "$LOG" "$PROSE"; exit 1; }
    # Keep --out COMPACT (classifier blocking findings + VERDICT). The final review
    # message goes to the sibling .full.md for PR provenance; the session log is
    # deleted — never published, never appended to --out.
    cp "$PROSE" "$FULL"
    { echo; echo "(final Codex review: $FULL — for PR provenance, not needed to fix)"; } >>"$OUT"
    rm -f "$LOG" "$PROSE"
    ;;

  *) echo "unknown reviewer '$REVIEWER' (expected claude|codex)" >&2; exit 2;;
esac

# The Claude reviewer writes its (already compact, tagged) review straight to --out and
# produces no separate raw transcript, so mirror it to .full.md — the caller can always
# `cat` a .full.md for the PR <details>, whichever reviewer ran.
[ -f "$FULL" ] || cp "$OUT" "$FULL"

VERDICT="$(grep -E '^VERDICT:' "$OUT" | tail -1 || true)"
echo "reviewer=$REVIEWER base=$BASE round=$ROUND effort=${EFFORT:-inherited} review=$OUT full=$FULL" >&2
# A reviewer that produced no parseable verdict is a failure, not an approval.
[ -n "$VERDICT" ] || { echo "no VERDICT line in review — escalate, do not merge" >&2; exit 1; }
echo "$VERDICT"
