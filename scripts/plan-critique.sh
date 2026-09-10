#!/usr/bin/env bash
# Critique-only adversarial pass over a task plan, for the INTERACTIVE harden loop
# (/iharden). The AUTHOR is the main session; this script is ONLY the independent
# CRITIC — it never revises the plan.
#
#   plan-critique.sh (--issue <N> | --body-file <f>) [--thread <file>] [--out <file>] [--comment]
#
# Reads the CURRENT plan (issue body via gh, or a local file), invokes the critic
# (the complementary tool — Codex by default) ONCE using the plan-reviewer.md beside it,
# and emits tagged [BLOCKER]/[SHOULD]/[NIT] findings followed by EXACTLY ONE
# `VERDICT: APPROVED|CHANGES_REQUESTED` line (the final line).
#
# Output is SPLIT for context hygiene (like run-review.sh): --out gets the COMPACT
# critique — the findings + the VERDICT, i.e. what the session reads — while the FULL
# critique (concept ledger + findings) goes to <out>.full.md and, with --comment, to the
# issue. The split point is the reviewer's `--- FINDINGS ---` delimiter; absent it, --out
# gets the full text (lossless fallback).
#
# With --thread, the prior transcript is passed as context (so resolved findings aren't
# re-raised) and this round (full) is appended to it. With --comment (requires --issue),
# the round's FULL critique — concept ledger, findings, verdict — is posted as a comment
# on the issue, so the hardening trail lives on the issue, not just the ephemeral scratch.
#
# Exit codes:
#   0  ran and emitted a well-formed verdict (read APPROVED vs CHANGES_REQUESTED from
#      the OUTPUT, not the exit code).
#   1  the critic failed to run, OR no single parseable `VERDICT:` line was produced
#      (parse-failure). Callers MUST treat nonzero as a reviewer failure and escalate,
#      never as an implicit verdict.
#   2  usage error.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
. "$HERE/lib.sh"
# shellcheck source=model-call.sh
. "$HERE/model-call.sh"

usage() {
  cat <<'EOF' >&2
Usage:
  plan-critique.sh (--issue <N> | --body-file <f>) [--thread <file>] [--out <file>] [--comment]

One adversarial critique round over a plan. Emits tagged findings + exactly one
VERDICT line. Exit 0 = well-formed verdict (read it from the output); nonzero =
critic failure / unparseable verdict (escalate, don't guess).

--comment (requires --issue) also posts the round's critique as an issue comment.
EOF
  exit 2
}

ISSUE=""; BODY_FILE=""; THREAD=""; OUT=""; COMMENT=0
while [ $# -gt 0 ]; do
  case "$1" in
    --issue)     ISSUE="${2:?--issue requires a value}"; shift 2;;
    --body-file) BODY_FILE="${2:?--body-file requires a path}"; shift 2;;
    --thread)    THREAD="${2:?--thread requires a path}"; shift 2;;
    --out)       OUT="${2:?--out requires a path}"; shift 2;;
    --comment)   COMMENT=1; shift;;
    -h|--help)   usage;;
    *) echo "unknown arg: $1" >&2; usage;;
  esac
done

if [ -n "$ISSUE" ] && [ -n "$BODY_FILE" ]; then
  echo "--issue and --body-file are mutually exclusive" >&2; usage
fi
[ -n "$ISSUE" ] || [ -n "$BODY_FILE" ] || { echo "need --issue <N> or --body-file <f>" >&2; usage; }
[ -z "$ISSUE" ] || case "$ISSUE" in ''|*[!0-9]*) echo "--issue must be a number" >&2; usage;; esac
if [ "$COMMENT" = 1 ] && [ -z "$ISSUE" ]; then echo "--comment requires --issue" >&2; usage; fi

# The interactive hardening critic is Codex BY CONTRACT (the main session is the plan
# author, so the independent adversary is the complementary tool, Codex). Override
# explicitly with CRITIC=claude if ever needed. The Codex critic is pinned to a
# frontier model (CODEX_MODEL, default gpt-5.6-sol) so the gate doesn't drift with the
# global ~/.codex default. Reasoning effort scales by round like the code review: the
# FIRST critique (empty --thread) runs ultra for the deep initial read, later rounds
# xhigh; CODEX_EFFORT forces one tier for all rounds.
CRITIC="${CRITIC:-codex}"
command -v "$CRITIC" >/dev/null || { echo "critic tool '$CRITIC' not on PATH" >&2; exit 1; }
# The critic prompt ships beside this script, so it is found wherever the harness is installed
# — a plugin root or a repo's own scripts/. Looking under $REPO_DIR would demand that the repo
# under review carry a copy of the prompt.
TEMPLATE="$HERE/plan-reviewer.md"
[ -f "$TEMPLATE" ] || { echo "missing $TEMPLATE" >&2; exit 1; }

PLAN="$(mktemp)"; RAW="$(mktemp)"; COMPACT="$(mktemp)"
trap 'rm -f "$PLAN" "$RAW" "$RAW.norm" "$COMPACT"' EXIT HUP INT TERM

# Load the plan under review.
if [ -n "$ISSUE" ]; then
  require_gh
  gh issue view "$ISSUE" -R "$ISSUES_REPO" --json body -q .body > "$PLAN" 2>/dev/null \
    || { echo "could not fetch issue #$ISSUE from $ISSUES_REPO" >&2; exit 1; }
  [ -s "$PLAN" ] || { echo "issue #$ISSUE has an empty body" >&2; exit 1; }
else
  [ -f "$BODY_FILE" ] || { echo "no such body file: $BODY_FILE" >&2; exit 1; }
  cp "$BODY_FILE" "$PLAN"
fi

PRIOR="(none)"
if [ -n "$THREAD" ] && [ -f "$THREAD" ] && [ -s "$THREAD" ]; then PRIOR="$(cat "$THREAD")"; fi

# Effort by round (Codex critic): the first critique — no prior thread — runs ultra for
# the deep initial read of the whole plan; later rounds re-critique a revision at xhigh.
# CODEX_EFFORT forces one tier for every round.
if [ -n "${CODEX_EFFORT:-}" ]; then EFFORT="$CODEX_EFFORT"
elif [ "$PRIOR" = "(none)" ]; then EFFORT="ultra"
else EFFORT="xhigh"; fi

PROMPT="$(cat "$TEMPLATE")
================= PLAN UNDER REVIEW =================
$(cat "$PLAN")
================= PRIOR REVIEW THREAD (do NOT re-raise resolved items) =============
$PRIOR
==============================================================
Read AGENTS.md and the specs in this repo for conventions. Produce your tagged
findings for THIS round only, then the final VERDICT line. Do not re-raise items
already resolved in the thread."

# Both critics run under model_call (see model-call.sh): bounded, with a failed attempt's
# output discarded rather than published. Only the Codex call takes --retry — it runs under
# `-s read-only`, a mechanical write boundary, which `claude -p --dangerously-skip-permissions`
# is the opposite of.
_critique_codex() {
  codex exec -m "${CODEX_MODEL:-gpt-5.6-sol}" -c model_reasoning_effort="$EFFORT" \
    --cd "$REPO_DIR" -s read-only -o "$1" "$PROMPT" >/dev/null 2>&1
}
_critique_claude() {
  claude -p --dangerously-skip-permissions "$PROMPT" >"$1" 2>/dev/null
}

case "$CRITIC" in
  codex)  model_call --label "plan critique (codex)" --out "$RAW" --retry -- _critique_codex \
            || { echo "codex critic failed to run — escalate, do not guess a verdict" >&2; exit 1; } ;;
  claude) model_call --label "plan critique (claude)" --out "$RAW" -- _critique_claude \
            || { echo "claude critic failed to run — escalate, do not guess a verdict" >&2; exit 1; } ;;
  *) echo "unknown critic '$CRITIC' (expected claude|codex)" >&2; exit 2;;
esac

# Normalize markdown noise on an otherwise-well-formed verdict line ("**VERDICT:
# APPROVED**", "> VERDICT: CHANGES_REQUESTED") to the bare form before parsing — the
# same tolerance concept-check.sh applies; the exactly-one-final-line contract below
# is unchanged.
sed -E 's/^[[:space:]*_#>]*VERDICT:[[:space:]]*(APPROVED|CHANGES_REQUESTED)[[:space:]*_]*$/VERDICT: \1/' "$RAW" > "$RAW.norm" \
  && mv "$RAW.norm" "$RAW"

# Enforce EXACTLY ONE well-formed verdict line. Zero, multiple, or a malformed value is
# a parse-failure (escalate) — never silently take the last line or guess an approval.
VCOUNT="$(grep -cE '^VERDICT:' "$RAW" 2>/dev/null || true)"
if [ "$VCOUNT" != "1" ]; then
  echo "expected exactly one VERDICT line, found ${VCOUNT:-0} — escalate, do not guess" >&2
  exit 1
fi
VERDICT="$(grep -E '^VERDICT:' "$RAW")"
case "$VERDICT" in
  "VERDICT: APPROVED"|"VERDICT: CHANGES_REQUESTED") ;;
  *) echo "malformed verdict line ('$VERDICT'; expected APPROVED|CHANGES_REQUESTED) — escalate" >&2; exit 1;;
esac
# Per contract the VERDICT must be the FINAL line — anything after it (trailing prose,
# a second thought) means the output is malformed; escalate rather than trust a verdict
# the critic kept editing past. Compare against the last non-blank line.
LASTLINE="$(grep -vE '^[[:space:]]*$' "$RAW" | tail -n1)"
if [ "$LASTLINE" != "$VERDICT" ]; then
  echo "VERDICT is not the final line (trailing content after it) — escalate, do not guess" >&2
  exit 1
fi

# Split for context hygiene: the session reads a COMPACT view (findings + VERDICT); the
# full critique (concept ledger included) is preserved for the trail. Drop everything above
# the reviewer's `--- FINDINGS ---` delimiter; if it's absent, keep the full text (lossless).
if grep -qE '^-{2,}[[:space:]]*FINDINGS[[:space:]]*-{2,}$' "$RAW"; then
  awk 'f{print} /^-{2,}[[:space:]]*FINDINGS[[:space:]]*-{2,}$/{f=1}' "$RAW" > "$COMPACT"
else
  cp "$RAW" "$COMPACT"
fi

if [ -n "$OUT" ]; then
  cp "$COMPACT" "$OUT"               # COMPACT (findings + verdict) — what the session reads
  cp "$RAW" "${OUT%.md}.full.md"     # FULL (ledger + findings) — trail/provenance; never Read into context
else
  cat "$COMPACT"
fi
if [ -n "$THREAD" ]; then
  { echo "## Critique round — $CRITIC"; echo; cat "$RAW"; echo; } >> "$THREAD"
fi
# Record this round on the issue itself (the --out/--thread files are ephemeral scratch).
# Fail SOFT: the verdict already succeeded, so a comment hiccup warns but never loses it.
if [ "$COMMENT" = 1 ]; then
  { printf '🤖 Plan critique · `%s` · %s\n\n' "$CRITIC" "${VERDICT#VERDICT: }"; cat "$RAW"; } \
    | gh issue comment "$ISSUE" -R "$ISSUES_REPO" -F - >/dev/null \
    || echo "warning: verdict produced but posting it as a comment on issue #$ISSUE failed — post it manually" >&2
fi
echo "critic=$CRITIC effort=$EFFORT verdict=${VERDICT#VERDICT: }" >&2
exit 0
