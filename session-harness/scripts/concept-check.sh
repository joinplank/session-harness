#!/usr/bin/env bash
# One CONCEPT-MINIMALISM pass over the current branch diff, for /iship — run ONCE
# after the FIRST adversarial review round, before the remaining rounds (so it
# audits reviewed code, and the later rounds re-review whatever it simplified).
# A fresh-context checker (claude by default: this is a parsimony audit, not the
# correctness review, which stays with the complementary tool) builds a concept ledger from
# the diff and verdicts each added concept (KEEP / MERGE / DERIVE / DELETE),
# ending in exactly one final line:
#
#   VERDICT: MINIMAL | SIMPLIFY
#
# The CALLER dispositions the findings (apply or decline-with-rationale), records
# the ledger in the PR's Concepts section, and posts it as a PR comment (the
# paper trail). Advisory by design: one round,
# never a merge gate — but a nonzero exit is a checker FAILURE to surface in the
# PR, never an implicit MINIMAL.
#
# Usage:
#   concept-check.sh [--issue <N> | --plan-file <f>] [--base <ref>] [--out <file>]
#
# Env:
#   CHECKER    claude|codex  (default: claude)
#   CODEX_MODEL <codex model> (default: gpt-5.6-sol; used only when CHECKER=codex)
#   BASE       <git ref>     (default: origin/<default-branch>, else origin/main)
#   REPO_SLUG  owner/name    (optional; where to fetch --issue from — defaults to
#                             the current repo per `gh repo view`)
#   MODEL_CALL_TIMEOUT_S <seconds> (default: 1800 — the per-call bound, see model-call.sh)
#
# Portable: no repo-specific paths or slugs; works from any git checkout.
#
# Exit: 0 = well-formed verdict in the output (read MINIMAL vs SIMPLIFY there) ·
#       1 = checker failed / unparseable verdict · 2 = usage error.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
TEMPLATE="$HERE/concept-reviewer.md"
# shellcheck source=model-call.sh
. "$HERE/model-call.sh"

ISSUE=""; PLAN_FILE=""; BASE="${BASE:-}"; OUT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --issue)     ISSUE="${2:?--issue requires a value}"; shift 2;;
    --plan-file) PLAN_FILE="${2:?--plan-file requires a path}"; shift 2;;
    --base)      BASE="${2:?--base requires a ref}"; shift 2;;
    --out)       OUT="${2:?--out requires a path}"; shift 2;;
    -h|--help)   grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0;;
    *) echo "unknown arg: $1" >&2; exit 2;;
  esac
done
if [ -n "$ISSUE" ] && [ -n "$PLAN_FILE" ]; then
  echo "--issue and --plan-file are mutually exclusive" >&2; exit 2
fi

[ -f "$TEMPLATE" ] || { echo "missing $TEMPLATE" >&2; exit 1; }
CHECKER="${CHECKER:-claude}"
command -v "$CHECKER" >/dev/null || { echo "checker CLI '$CHECKER' not found" >&2; exit 1; }
ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || { echo "not inside a git repository" >&2; exit 1; }

if [ -z "$BASE" ]; then
  DEF="$(git symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's#^origin/##' || true)"
  BASE="origin/${DEF:-main}"
fi

# The plan whose acceptance criteria set the KEEP bar. --plan-file wins; else
# --issue (explicit, so a fetch failure is fatal); else the session clone's
# .session.json issue (implicit — degrade with a warning if it can't be fetched);
# else the checker judges against the change's own stated intent.
PLAN="(none provided — judge added concepts against the change's own stated intent)"
EXPLICIT_ISSUE="$ISSUE"
if [ -z "$PLAN_FILE" ] && [ -z "$ISSUE" ] && [ -f "$ROOT/.session.json" ] && command -v jq >/dev/null; then
  ISSUE="$(jq -r '.issue // empty' "$ROOT/.session.json" 2>/dev/null || true)"
  [ "$ISSUE" = "null" ] && ISSUE=""
fi
fetch_issue() {
  local slug
  slug="${REPO_SLUG:-$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || true)}"
  [ -n "$slug" ] || return 1
  gh issue view "$1" -R "$slug" --json title,body -q '"# " + .title + "\n\n" + .body' 2>/dev/null
}
if [ -n "$PLAN_FILE" ]; then
  [ -f "$PLAN_FILE" ] || { echo "no such plan file: $PLAN_FILE" >&2; exit 1; }
  PLAN="$(cat "$PLAN_FILE")"
elif [ -n "$ISSUE" ]; then
  if FETCHED="$(fetch_issue "$ISSUE")" && [ -n "$FETCHED" ]; then
    PLAN="$FETCHED"
  elif [ -n "$EXPLICIT_ISSUE" ]; then
    echo "could not fetch issue #$ISSUE — pass --plan-file, or fix gh/REPO_SLUG" >&2; exit 1
  else
    echo "warning: could not fetch session issue #$ISSUE — running without the plan" >&2
  fi
fi

# The branch diff vs the merge-base. Lockfiles are never concepts — exclude them
# so a regenerated lockfile can't drown the signal.
DIFFSTAT="$(git -C "$ROOT" diff --stat "$BASE...HEAD" -- ':(exclude)package-lock.json' ':(exclude)*.lock' 2>/dev/null || true)"
DIFF="$(git -C "$ROOT" diff "$BASE...HEAD" -- ':(exclude)package-lock.json' ':(exclude)*.lock' 2>/dev/null)" \
  || { echo "git diff against $BASE failed — unknown ref? fetch origin?" >&2; exit 1; }
[ -n "$DIFF" ] || { echo "empty diff vs $BASE — nothing to check" >&2; exit 1; }
MAX=400000
if [ "${#DIFF}" -gt "$MAX" ]; then
  DIFF="${DIFF:0:$MAX}
[diff truncated at $MAX chars — see the diffstat above for full scope]"
fi

PROMPT="$(cat "$TEMPLATE")
================= PLAN THE CHANGE WAS MADE UNDER (acceptance criteria = the KEEP bar) =================
$PLAN
================= BRANCH DIFF (vs merge-base with $BASE; lockfiles excluded) =================
$DIFFSTAT

$DIFF
==============================================================
Produce the CONCEPT LEDGER, the per-concept verdicts, then the final VERDICT line."

RAW="$(mktemp)"; NORM="$(mktemp)"
trap 'rm -f "$RAW" "$NORM"' EXIT HUP INT TERM
# Bounded through model_call (model-call.sh). Only the Codex checker takes --retry: it runs
# under `-s read-only`, a mechanical write boundary, so running it twice can write no more
# than running it once.
_concept_claude() {
  claude -p --dangerously-skip-permissions "$PROMPT" >"$1" 2>/dev/null
}
_concept_codex() {
  codex exec -m "${CODEX_MODEL:-gpt-5.6-sol}" --cd "$ROOT" -s read-only -o "$1" "$PROMPT" >/dev/null 2>&1
}

case "$CHECKER" in
  claude) model_call --label "concept check (claude)" --out "$RAW" -- _concept_claude \
            || { echo "claude checker failed to run — surface this in the PR, do not guess a verdict" >&2; exit 1; } ;;
  codex)  model_call --label "concept check (codex)" --out "$RAW" --retry -- _concept_codex \
            || { echo "codex checker failed to run — surface this in the PR, do not guess a verdict" >&2; exit 1; } ;;
  *) echo "unknown checker '$CHECKER' (expected claude|codex)" >&2; exit 2;;
esac

# Normalize markdown noise on an otherwise-well-formed verdict line ("**VERDICT:
# SIMPLIFY**", "> VERDICT: MINIMAL") to the bare form, then enforce EXACTLY ONE
# verdict as the FINAL line — same contract as plan-critique.sh. Zero, multiple,
# malformed, or trailing content = parse failure.
sed -E 's/^[[:space:]*_#>]*VERDICT:[[:space:]]*(MINIMAL|SIMPLIFY)[[:space:]*_]*$/VERDICT: \1/' "$RAW" > "$NORM"
VCOUNT="$(grep -cE '^VERDICT:' "$NORM" 2>/dev/null || true)"
if [ "$VCOUNT" != "1" ]; then
  echo "expected exactly one VERDICT line, found ${VCOUNT:-0} — checker output unusable" >&2
  exit 1
fi
VERDICT="$(grep -E '^VERDICT:' "$NORM")"
case "$VERDICT" in
  "VERDICT: MINIMAL"|"VERDICT: SIMPLIFY") ;;
  *) echo "malformed verdict line ('$VERDICT'; expected MINIMAL|SIMPLIFY)" >&2; exit 1;;
esac
LASTLINE="$(grep -vE '^[[:space:]]*$' "$NORM" | tail -n1)"
if [ "$LASTLINE" != "$VERDICT" ]; then
  echo "VERDICT is not the final line (trailing content after it) — checker output unusable" >&2
  exit 1
fi

if [ -n "$OUT" ]; then cp "$NORM" "$OUT"; else cat "$NORM"; fi
echo "checker=$CHECKER verdict=${VERDICT#VERDICT: }" >&2
exit 0
