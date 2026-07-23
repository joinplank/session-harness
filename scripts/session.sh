#!/usr/bin/env bash
# Interactive-session provisioner. An interactive session is a CHECKED-OUT, INDEPENDENT
# CLONE (scripts/lib.sh provision_slot — NOT a git worktree). Clones live in a REUSED,
# NUMBERED slot pool ($WT_BASE/<repo>-session-NN) with stable, reusable slot identities.
#
# The slot NUMBER is the stable dir identity; the human-facing SLUG lives in .session.json, NOT
# the dir name. That's the point: a reused slot's directory never has to be renamed when it moves
# from one feature to the next (renaming a dir would break any shell/Claude rooted in it).
#
#   session.sh new --slug <s> [--force] [--launch [--message <msg>]]
#   session.sh adopt-issue [--slug <s>] --issue <N>
#   session.sh release <slug|path|branch> [--force] [--purge]
#   session.sh list
#   session.sh reap [--quiet]
#   session.sh path [--slug <s>]                   # print a session's clone path (lookup by slug)
#   session.sh status                              # print the /iship goal-loop token: READY|ESCALATED|IN-PROGRESS
#
# --launch opens a cmux workspace rooted in the slot running an interactive `claude` seeded with a
# KICKOFF PROMPT that frames --message in the interactive flow (plan first: discuss -> /iharden ->
# /iship, NOT codegen), and records the workspace in .session.json so reap/release close it. The
# message is passed via a gitignored seed file, so any characters in it survive. The launched claude
# is PINNED to --model SESSION_MODEL at --effort SESSION_EFFORT (defaults fable[1m] @ max — the
# strongest authoring model on its 1M-token context window, so long sessions don't hit early
# compaction). Pinning makes the authoring model a
# deliberate harness choice, never the ambient /model default of whoever launched; the pairing is
# stamped into .session.json (shown by `list`) so a session's output can be traced to who authored it.
#
# Warm reuse: `reap`/`release` don't delete a finished session — they RESET its slot to an idle
# warm clone (node_modules/.next kept) IN PLACE, and `new` reclaims an idle slot before cloning
# cold, so the expensive first `npm install` is amortized across tasks. `--purge` removes a slot
# to reclaim disk.
#
# Env (defaults):
#   SESSION_PREFIX   slot dir prefix    (default: <repo>-session-, under $WT_BASE from lib.sh)
#   SESSION_MAX      max total slots    (default: 6; active + idle)
#   SESSION_MODEL    claude --model  for --launch sessions (default: fable[1m]; e.g. opus | sonnet)
#   SESSION_EFFORT   claude --effort for --launch sessions (default: max;  e.g. high | xhigh)
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
. "$HERE/lib.sh"   # REPO_NAME, WT_BASE, clone_url, default_branch, provision_slot, seed_env, require_*

SESSION_PREFIX="${SESSION_PREFIX:-${REPO_NAME}-session-}"
SESSION_MAX="${SESSION_MAX:-6}"   # cap on total session slots (active + idle)

usage() {
  cat <<'EOF' >&2
Usage:
  session.sh new --slug <s> [--force] [--launch [--message <msg>]]
  session.sh adopt-issue [--slug <s>] --issue <N>
  session.sh release <slug|path|branch> [--force] [--purge]
  session.sh list
  session.sh reap [--quiet]
  session.sh path [--slug <s>]
  session.sh status

Provisions/recycles INDEPENDENT clones for the interactive flow in a reused, NUMBERED
slot pool ($WT_BASE/<repo>-session-NN). The slot NUMBER is the dir identity; the SLUG
lives in .session.json (so a reused slot is never renamed). `reap`/`release` reset a
finished slot to a warm idle clone (node_modules kept) that `new` reclaims before
cloning cold; `--purge` removes a slot for disk.
EOF
  exit 2
}

require_git; require_jq

# sanitize_slug <raw> -> kebab slug (lowercase, alnum+dash, <=40 chars)
sanitize_slug() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9' '-' \
    | sed 's/^-*//;s/-*$//' | cut -c1-40
}

# write_state <dir> <slug> <branch> <base> <issue-json> <phase>
# Preserves existing .cmux/.model/.effort fields (the launched workspace and its authoring pairing)
# across phase transitions, so adopt-issue/harden don't drop them — reap/release need the workspace
# handle to close it, and `list` shows the pairing.
write_state() {
  local dir="$1" slug="$2" branch="$3" base="$4" issue="$5" phase="$6" now tmp cmux="" model="" effort=""
  now="$(date -u +%FT%TZ 2>/dev/null || echo unknown)"
  if [ -f "$dir/.session.json" ]; then
    cmux="$(jq -r '.cmux // ""' "$dir/.session.json" 2>/dev/null || echo "")"
    model="$(jq -r '.model // ""' "$dir/.session.json" 2>/dev/null || echo "")"
    effort="$(jq -r '.effort // ""' "$dir/.session.json" 2>/dev/null || echo "")"
  fi
  tmp="$(mktemp)"
  jq -n --arg slug "$slug" --arg branch "$branch" --arg base "$base" --arg path "$dir" \
        --argjson issue "$issue" --arg phase "$phase" --arg now "$now" --arg cmux "$cmux" \
        --arg model "$model" --arg effort "$effort" \
    '{slug:$slug, branch:$branch, base:$base, path:$path, issue:$issue, phase:$phase, cmux:$cmux, model:$model, effort:$effort, created_at:$now}' \
    > "$tmp" && mv "$tmp" "$dir/.session.json"
}

# set_cmux <dir> <name> -- record (or clear, with "") the cmux workspace name in .session.json.
set_cmux() {
  local dir="$1" name="$2" tmp; tmp="$(mktemp)"
  jq --arg c "$name" '.cmux = $c' "$dir/.session.json" > "$tmp" && mv "$tmp" "$dir/.session.json"
}

# set_pairing <dir> <model> <effort> -- record (or clear, with "") the authoring pairing — which
# model at which effort drives this session's claude. The paper trail behind `list`'s PAIRING
# column: a quality question about a session's output starts from who authored it.
set_pairing() {
  local dir="$1" model="$2" effort="$3" tmp; tmp="$(mktemp)"
  jq --arg m "$model" --arg e "$effort" '.model = $m | .effort = $e' "$dir/.session.json" > "$tmp" \
    && mv "$tmp" "$dir/.session.json"
}

# resolve_session_root -> abs path of the clone root holding a .session.json, from cwd.
resolve_session_root() {
  local top
  top="$(git rev-parse --show-toplevel 2>/dev/null)" \
    || { echo "not inside a git repository" >&2; return 1; }
  [ -f "$top/.session.json" ] \
    || { echo "not inside an interactive session clone (no .session.json) — run /isession first" >&2; return 1; }
  printf '%s' "$top"
}

# ensure_session_ignored <dir> -- belt-and-suspenders: ignore .session.json in this clone
# even if the cloned base branch predates the .gitignore entry (clone-local info/exclude).
ensure_session_ignored() {
  local dir="$1" gd
  git -C "$dir" check-ignore -q .session.json 2>/dev/null && return 0
  # Use the ABSOLUTE git dir: --git-path returns a path relative to the clone, but this
  # function runs from the caller's cwd (the main repo), so a relative path would append to
  # the wrong repo's exclude file.
  gd="$(git -C "$dir" rev-parse --absolute-git-dir 2>/dev/null || true)"
  [ -n "$gd" ] && [ -d "$gd/info" ] && printf '%s\n' '.session.json' >> "$gd/info/exclude"
  return 0
}

# safe_under_session_base <dir> -- true if <dir> is inside our session namespace, so an
# rm -rf can never escape it (guards against a surprising SESSION_PREFIX/empty value).
safe_under_session_base() {
  case "$1" in "$WT_BASE/$SESSION_PREFIX"?*) return 0;; *) return 1;; esac
}

# --- Slot pool (numbered, reused) -------------------------------------------
# slot_dir <NN> -> the clone dir for numbered slot NN (zero-padded). Stable identity.
slot_dir() { printf '%s/%s%02d' "$WT_BASE" "$SESSION_PREFIX" "$1"; }

# all_session_dirs -> every session clone dir (each holding a .session.json).
# Always returns 0 (an empty pool is not a failure to set -e).
all_session_dirs() {
  local d
  for d in "$WT_BASE/$SESSION_PREFIX"*; do
    [ -d "$d" ] && [ -f "$d/.session.json" ] && printf '%s\n' "$d"
  done
  return 0
}

# dir_for_slug <slug> -> the ACTIVE (non-idle) clone dir whose .session.json records that slug;
# prints it and returns 0, or prints nothing and returns 1. Slug is metadata, so this is a scan.
dir_for_slug() {
  local want="$1" d
  while IFS= read -r d; do
    [ -n "$d" ] || continue
    [ "$(jq -r '.phase // ""' "$d/.session.json" 2>/dev/null)" = "idle" ] && continue
    if [ "$(jq -r '.slug // ""' "$d/.session.json" 2>/dev/null)" = "$want" ]; then
      printf '%s' "$d"; return 0
    fi
  done < <(all_session_dirs)
  return 1
}

# dir_for_branch <branch> -> clone dir whose .session.json records that branch (active or idle).
dir_for_branch() {
  local want="$1" d
  while IFS= read -r d; do
    [ -n "$d" ] || continue
    if [ "$(jq -r '.branch // ""' "$d/.session.json" 2>/dev/null)" = "$want" ]; then
      printf '%s' "$d"; return 0
    fi
  done < <(all_session_dirs)
  return 1
}

# first_idle_dir -> the lowest idle (warm, reclaimable) slot dir, or nothing (+ return 1).
first_idle_dir() {
  local d
  while IFS= read -r d; do
    [ -n "$d" ] || continue
    if [ "$(jq -r '.phase // ""' "$d/.session.json" 2>/dev/null)" = "idle" ]; then
      printf '%s' "$d"; return 0
    fi
  done < <(all_session_dirs | sort)
  return 1
}

# count_idle -> number of idle warm slots.
count_idle() {
  local d n=0
  while IFS= read -r d; do
    [ -n "$d" ] || continue
    [ "$(jq -r '.phase // ""' "$d/.session.json" 2>/dev/null)" = "idle" ] && n=$((n + 1))
  done < <(all_session_dirs)
  printf '%s' "$n"
}

# lowest_free_slot_dir -> lowest-numbered slot dir (00..SESSION_MAX-1) that doesn't exist yet,
# or nothing (+ return 1) if every numbered slot is occupied (pool full).
lowest_free_slot_dir() {
  local i d
  for i in $(seq 0 $((SESSION_MAX - 1))); do
    d="$(slot_dir "$i")"
    [ -e "$d" ] || { printf '%s' "$d"; return 0; }
  done
  return 1
}

# clean_keep_warm <dir> -- `git clean -ffdx` but PRESERVE the expensive untracked build caches
# (node_modules, .next), so a recycled slot stays warm and the next green-light does an
# incremental `npm install` instead of a cold one. .env is NOT preserved here (it's re-seeded).
clean_keep_warm() { git -C "$1" clean -ffdx -e node_modules -e .next >/dev/null 2>&1; }

# recycle_clone <dir> <target-branch> <drop-branch> -- reset an EXISTING clone onto origin/<base>
# as <target-branch>, keeping warm caches, and drop <drop-branch> if given. The warm-reuse
# counterpart to lib.sh provision_slot — DON'T use provision_slot for reuse: its `clean -ffdx`
# wipes node_modules, defeating the point. Re-seeds .env at the end.
recycle_clone() {
  local dir="$1" target="$2" drop="${3:-}" base
  base="$(default_branch)"
  git -C "$dir" rebase --abort      >/dev/null 2>&1 || true
  git -C "$dir" merge --abort       >/dev/null 2>&1 || true
  git -C "$dir" cherry-pick --abort >/dev/null 2>&1 || true
  git -C "$dir" fetch origin --prune >/dev/null 2>&1 || true
  git -C "$dir" checkout -B "$target" "origin/$base" >/dev/null 2>&1
  git -C "$dir" reset --hard "origin/$base" >/dev/null 2>&1
  clean_keep_warm "$dir"
  if [ -n "$drop" ] && [ "$drop" != "$target" ] && [ "$drop" != "$base" ]; then
    git -C "$dir" branch -D "$drop" >/dev/null 2>&1 || true
  fi
  seed_env "$dir"   # from lib.sh — clean_keep_warm removed the old .env; restore current secrets
}

# launch_cmux <dir> <slug> <message> -- open a cmux workspace rooted in the clone running an
# interactive `claude` seeded with a kickoff prompt framing <message> in the interactive flow
# (plan-first), and record the workspace name in
# .session.json so reap/release can close it later. The message is passed via a GITIGNORED seed
# file (`claude "$(cat .session-task.txt)"`) so ANY characters in it survive — no fragile inline
# quoting in the cmux --command string. Soft-skips (warns) if cmux isn't installed.
launch_cmux() {
  local dir="$1" slug="$2" msg="$3" name cmd gd model="${SESSION_MODEL:-fable[1m]}" effort="${SESSION_EFFORT:-max}"
  command -v cmux >/dev/null 2>&1 \
    || { echo "  cmux not installed — skipping auto-launch; cd into $dir and run claude yourself" >&2; return 0; }
  name="session: $slug"
  if [ -n "$msg" ]; then
    # Seed a KICKOFF prompt that frames the task inside the interactive flow — NOT the bare
    # one-liner. A fresh claude handed just "fix dark mode" jumps straight to codegen; this tells
    # it to plan first (discuss -> /iharden -> /iship) and not edit files yet.
    {
      printf 'You are in an INTERACTIVE %s session.\n\nTASK: %s\n\n' "$REPO_NAME" "$msg"
      cat <<'TXT'
Do NOT start writing or editing code yet — this task runs through the interactive flow, plan first:
  1. DISCUSS with me to converge on the approach. Read the relevant code first, ask clarifying
     questions, and propose a plan.
  2. /iharden — file the plan as an issue and adversarially harden it (it pauses to ask me on real forks).
  3. /iship — implement under the goal bar, run the adversarial code-review rounds, then open a PR for me to merge.

Bias every phase toward SIMPLE (the AGENTS.md author disposition): the fewest concepts that meet
the acceptance criteria — prefer narrowing scope or reusing an existing concept over adding one.

Begin with step 1 (discuss). Do not jump to implementation, file an issue, or edit files until we have agreed on the plan.
TXT
    } > "$dir/.session-task.txt"
    git -C "$dir" check-ignore -q .session-task.txt 2>/dev/null || {
      gd="$(git -C "$dir" rev-parse --absolute-git-dir 2>/dev/null || true)"
      [ -n "$gd" ] && [ -d "$gd/info" ] && printf '%s\n' '.session-task.txt' >> "$gd/info/exclude"
    }
    # $model/$effort expand here (concrete values); \$(cat …) stays literal so the workspace shell
    # reads the seed file. The model is single-quoted in the generated command because the default
    # fable[1m] carries glob characters that zsh would otherwise try to expand. fable[1m] @ max is
    # the default pairing — SESSION_MODEL / SESSION_EFFORT override per session for a task that
    # rewards a different one.
    cmd="claude --model '$model' --effort $effort \"\$(cat .session-task.txt)\""
  else
    cmd="claude --model '$model' --effort $effort"
  fi
  if cmux new-workspace --cwd "$dir" --name "$name" \
       --description "Interactive session '$slug'" --command "$cmd" --focus true >/dev/null 2>&1; then
    set_cmux "$dir" "$name"
    set_pairing "$dir" "$model" "$effort"
    echo "  opened cmux workspace \"$name\" with claude${msg:+ (seeded with your task)}" >&2
  else
    echo "  WARN: cmux new-workspace failed — cd into $dir and run claude yourself" >&2
  fi
}

cmd_new() {
  local slug="" force=0 launch=0 msg=""
  while [ $# -gt 0 ]; do case "$1" in
    --slug)    slug="${2:?--slug requires a value}"; shift 2;;
    --force)   force=1; shift;;
    --launch)  launch=1; shift;;
    --message) msg="${2:-}"; shift 2;;
    -h|--help) usage;;
    *) echo "unknown arg: $1" >&2; usage;;
  esac; done
  [ -n "$slug" ] || { echo "--slug is required" >&2; usage; }
  slug="$(sanitize_slug "$slug")"
  [ -n "$slug" ] || { echo "slug sanitizes to empty; pass a usable --slug" >&2; exit 1; }

  local branch base dir
  branch="session/$slug"; base="$(default_branch)"
  mkdir -p "$WT_BASE"

  # Reopen an existing ACTIVE session for this slug (idempotent /isession re-run), unless --force.
  if dir="$(dir_for_slug "$slug")"; then
    if [ "$force" = 1 ]; then
      safe_under_session_base "$dir" || { echo "refusing to rm unexpected dir '$dir'" >&2; exit 1; }
      rm -rf "$dir"
    else
      printf '%s\n' "$dir"
      echo "session '$slug' already exists at $dir (slot $(basename "$dir")) — reopening; --force to recreate." >&2
      return 0
    fi
  fi

  # 1) Reclaim a warm idle slot IN PLACE (no rename) — amortize node_modules across tasks.
  if dir="$(first_idle_dir)"; then
    recycle_clone "$dir" "$branch" ""
    write_state "$dir" "$slug" "$branch" "$base" "null" "discuss"
    ensure_session_ignored "$dir"
    printf '%s\n' "$dir"
    echo "Provisioned '$slug' by reclaiming warm idle slot $(basename "$dir") (kept node_modules), branch $branch off $base." >&2
    if [ "$launch" = 1 ]; then launch_cmux "$dir" "$slug" "$msg"; else echo "cd into it, discuss to converge, then run /iharden." >&2; fi
    return 0
  fi

  # 2) No warm slot — allocate a fresh numbered slot (cold clone). provision_slot clones from
  #    clone_url (this repo's origin) so the session can push and open a PR; first npm install is slow.
  if ! dir="$(lowest_free_slot_dir)"; then
    echo "no free session slots — all $SESSION_MAX are active. Release or reap one (or raise SESSION_MAX)." >&2
    exit 1
  fi
  provision_slot "$branch" "$dir" >&2
  write_state "$dir" "$slug" "$branch" "$base" "null" "discuss"
  ensure_session_ignored "$dir"
  printf '%s\n' "$dir"                  # stdout = clone path (machine-readable)
  echo "Provisioned interactive session '$slug' at slot $(basename "$dir") (fresh clone, branch $branch off $base)." >&2
  if [ "$launch" = 1 ]; then launch_cmux "$dir" "$slug" "$msg"; else echo "cd into it, discuss to converge, then run /iharden." >&2; fi
}

cmd_adopt_issue() {
  local slug="" issue=""
  while [ $# -gt 0 ]; do case "$1" in
    --slug)  slug="${2:?--slug requires a value}"; shift 2;;
    --issue) issue="${2:?--issue requires a value}"; shift 2;;
    -h|--help) usage;;
    *) echo "unknown arg: $1" >&2; usage;;
  esac; done
  [ -n "$issue" ] || { echo "--issue is required" >&2; usage; }
  case "$issue" in ''|*[!0-9]*) echo "--issue must be a number" >&2; exit 1;; esac

  local dir
  if [ -n "$slug" ]; then
    dir="$(dir_for_slug "$(sanitize_slug "$slug")")" \
      || { echo "no active session for slug '$slug'" >&2; exit 1; }
  else
    dir="$(resolve_session_root)" || exit 1
  fi
  [ -f "$dir/.session.json" ] || { echo "no .session.json at '$dir'" >&2; exit 1; }

  local cur_slug cur_branch base cur_issue newbranch
  cur_slug="$(jq -r '.slug' "$dir/.session.json")"
  cur_branch="$(jq -r '.branch' "$dir/.session.json")"
  base="$(jq -r '.base' "$dir/.session.json")"
  cur_issue="$(jq -r '.issue' "$dir/.session.json")"
  # task/<N>-<slug>: the number keys the branch to its issue (unique, lifecycle-prefixed);
  # the slug keeps it readable in branch lists. Nothing parses the name — reap/release/iship
  # read issue + branch from .session.json — so the suffix is purely for humans.
  if [ -n "$cur_slug" ] && [ "$cur_slug" != "null" ]; then
    newbranch="task/${issue}-${cur_slug}"
  else
    newbranch="task/$issue"
  fi

  # Re-adopt guard (state contract): a session adopts exactly ONE issue.
  if [ "$cur_issue" != "null" ] && [ -n "$cur_issue" ] && [ "$cur_issue" != "$issue" ]; then
    echo "session already adopted issue #$cur_issue — refusing to re-adopt as #$issue (state contract)" >&2
    exit 1
  fi
  if [ "$cur_branch" = "$newbranch" ]; then
    echo "session already on $newbranch — nothing to do" >&2; return 0
  fi
  # Don't clobber an existing task branch (e.g. another session's). Check this clone's
  # local heads + remote-tracking, then the authoritative remote — FAIL CLOSED on a lookup
  # error so a network blip can't be read as "absent" and skip the guard.
  if git -C "$dir" show-ref --verify --quiet "refs/heads/$newbranch" \
     || git -C "$dir" show-ref --verify --quiet "refs/remotes/origin/$newbranch"; then
    echo "branch $newbranch already exists locally — refusing to clobber (it may be another session's branch)" >&2
    exit 1
  fi
  local rc=0
  git -C "$dir" ls-remote --exit-code --heads origin "$newbranch" >/dev/null 2>&1 || rc=$?
  case "$rc" in
    0) echo "branch $newbranch exists on origin — refusing to clobber (it may be another session's branch)" >&2; exit 1;;
    2) : ;;  # reached origin, branch absent — safe to proceed
    *) echo "could not verify origin for $newbranch (ls-remote exit $rc) — refusing; retry once origin is reachable" >&2; exit 1;;
  esac
  # The clone must actually BE on the session branch we're about to rename — otherwise we'd
  # record the task branch while the checkout sits elsewhere, and /iship would commit on the
  # wrong branch. Assert it, rename (which moves HEAD since it's the current branch), then
  # confirm HEAD really landed on it (belt-and-suspenders if git's HEAD-follow ever changes).
  local actual; actual="$(git -C "$dir" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")"
  if [ "$actual" != "$cur_branch" ]; then
    echo "clone is checked out on '$actual', not the recorded session branch '$cur_branch' — refusing to adopt (inconsistent state)" >&2
    exit 1
  fi
  git -C "$dir" branch -m "$cur_branch" "$newbranch"
  [ "$(git -C "$dir" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")" = "$newbranch" ] \
    || git -C "$dir" checkout -q "$newbranch"
  write_state "$dir" "$cur_slug" "$newbranch" "$base" "$issue" "harden"
  echo "adopted issue #$issue: renamed branch $cur_branch -> $newbranch (clone now on $newbranch)" >&2
}

# release a session: by default RESET its slot to a warm idle clone (reused by the next `new`);
# with --purge, remove the slot dir to reclaim disk. The data-loss guard (skipped by --force)
# refuses to reset/remove over local commits that aren't pushed or merged by ancestry.
cmd_release() {
  local target="" force=0 purge=0
  while [ $# -gt 0 ]; do case "$1" in
    --force) force=1; shift;;
    --purge) purge=1; shift;;
    -h|--help) usage;;
    *) if [ -z "$target" ]; then target="$1"; shift; else echo "unexpected arg: $1" >&2; usage; fi;;
  esac; done
  [ -n "$target" ] || { echo "release requires <slug|path|branch>" >&2; usage; }

  # Resolve the clone dir from a path, a branch (task/N or session/slug), or a slug.
  local dir=""
  if [ -d "$target" ] && [ -f "$target/.session.json" ]; then
    dir="$(cd "$target" && pwd)"
  elif case "$target" in */*) true;; *) false;; esac && dir="$(dir_for_branch "$target" || true)" && [ -n "$dir" ]; then
    : # resolved by branch
  else
    dir="$(dir_for_slug "$(sanitize_slug "$target")" || true)"
  fi
  [ -n "$dir" ] && [ -d "$dir" ] || { echo "no session clone found for '$target'" >&2; exit 1; }
  [ -f "$dir/.session.json" ] || { echo "'$dir' is not an interactive session clone (no .session.json) — refusing" >&2; exit 1; }

  local slug branch; slug="$(jq -r '.slug // "?"' "$dir/.session.json" 2>/dev/null || echo "?")"
  branch="$(jq -r '.branch // ""' "$dir/.session.json" 2>/dev/null || echo "")"

  # Data-loss guard (skipped by --force): resetting/removing destroys local commits not
  # preserved elsewhere. Safe == clean tree AND the current HEAD is contained by ancestry in
  # origin/<branch> (fully pushed) or origin/<default> (merged ff/rebase). A squash merge isn't
  # an ancestor by hash, so after one, clean up with --force.
  if [ "$force" != 1 ] && [ -d "$dir/.git" ]; then
    if [ -n "$(git -C "$dir" status --porcelain 2>/dev/null)" ]; then
      echo "session clone '$dir' has uncommitted changes — commit & push, or pass --force" >&2
      exit 1
    fi
    if ! git -C "$dir" fetch --prune origin >/dev/null 2>&1; then
      echo "session clone '$dir': can't reach origin to verify the branch is pushed — retry, or pass --force" >&2
      exit 1
    fi
    local def; def="$(default_branch)"
    if ! { [ -n "$branch" ] && git -C "$dir" merge-base --is-ancestor HEAD "refs/remotes/origin/$branch" >/dev/null 2>&1; } \
       && ! git -C "$dir" merge-base --is-ancestor HEAD "refs/remotes/origin/$def" >/dev/null 2>&1; then
      echo "session clone '$dir' has local commits not pushed or merged by ancestry (branch $branch)." >&2
      echo "Push them first; or if the PR was squash-merged, clean up with --force." >&2
      exit 1
    fi
  fi

  safe_under_session_base "$dir" || { echo "refusing to touch unexpected path '$dir'" >&2; exit 1; }
  # Close the launched cmux workspace (if any) before recycling/removing the slot.
  local cmux_ws; cmux_ws="$(jq -r '.cmux // ""' "$dir/.session.json" 2>/dev/null || echo "")"
  [ -n "$cmux_ws" ] && close_cmux_workspace "$cmux_ws" >&2
  if [ "$purge" = 1 ]; then
    rm -rf "$dir"
    echo "purged interactive session '$slug' ($dir)." >&2
  else
    local base; base="$(default_branch)"
    recycle_clone "$dir" "$base" "$branch"      # reset to clean main, keep node_modules
    write_state "$dir" "$slug" "$base" "$base" "null" "idle"
    set_cmux "$dir" ""                          # workspace closed above — clear the stale handle
    set_pairing "$dir" "" ""                    # an idle slot runs no claude — no authoring pairing
    ensure_session_ignored "$dir"
    echo "released '$slug' -> warm idle slot $(basename "$dir") (kept node_modules; reused by next new). --purge to remove." >&2
  fi
}

# List the interactive sessions — no central registry; discover them by scanning for .session.json.
cmd_list() {
  [ $# -eq 0 ] || { echo "list takes no args" >&2; usage; }
  local d slug branch issue phase pairing found=0
  while IFS= read -r d; do
    [ -n "$d" ] || continue
    if [ "$found" = 0 ]; then printf '%-12s  %-18s  %-22s  %-5s  %-8s  %-12s  %s\n' SLOT SLUG BRANCH ISSUE PHASE PAIRING PATH; found=1; fi
    slug="$(jq -r '.slug // "?"' "$d/.session.json" 2>/dev/null)"
    branch="$(jq -r '.branch // "?"' "$d/.session.json" 2>/dev/null)"
    issue="$(jq -r 'if .issue == null then "-" else (.issue|tostring) end' "$d/.session.json" 2>/dev/null)"
    phase="$(jq -r '.phase // "?"' "$d/.session.json" 2>/dev/null)"
    pairing="$(jq -r '[.model, .effort] | map(select(. != null and . != "")) | if length == 0 then "-" else join("@") end' "$d/.session.json" 2>/dev/null)"
    printf '%-12s  %-18s  %-22s  %-5s  %-8s  %-12s  %s\n' "$(basename "$d" | sed "s/^${SESSION_PREFIX}//")" "$slug" "$branch" "$issue" "$phase" "$pairing" "$d"
  done < <(all_session_dirs | sort)
  [ "$found" = 1 ] || echo "no interactive sessions under $WT_BASE/${SESSION_PREFIX}*" >&2
}

cmd_path() {
  local slug=""
  while [ $# -gt 0 ]; do case "$1" in
    --slug) slug="${2:?--slug requires a value}"; shift 2;;
    *) echo "unknown arg: $1" >&2; usage;;
  esac; done
  if [ -n "$slug" ]; then
    local d
    if d="$(dir_for_slug "$(sanitize_slug "$slug")")"; then printf '%s\n' "$d"
    else echo "no active session for slug '$slug'" >&2; exit 1; fi
  else
    resolve_session_root && echo
  fi
}

# status: report the session's TERMINAL state for the /iship goal loop, as ONE stdout token the
# built-in `/goal` evaluator can read straight from the transcript (it runs no tools of its own):
#   READY        an OPEN, non-draft PR for this branch exists — step 4 flipped it ready-for-merge,
#                which it does ONLY after the green-light passed, the concept pass ran, and the
#                review converged; so READY already implies the whole bar (success).
#   ESCALATED    issue #N carries interactive:escalated — step 3 stopped for a human (PR kept draft).
#   IN-PROGRESS  neither terminal state yet — OR a gh/network lookup failed.
# Fail SAFE for the loop: any lookup error reports IN-PROGRESS (keep working), NEVER a false
# READY/ESCALATED that would stop the loop early. Resolves the session from the current clone.
cmd_status() {
  [ $# -eq 0 ] || { echo "status takes no args" >&2; usage; }
  local dir; dir="$(resolve_session_root)" || exit 1
  require_gh
  local issue branch
  issue="$(jq -r '.issue'         "$dir/.session.json" 2>/dev/null)"
  branch="$(jq -r '.branch // ""' "$dir/.session.json" 2>/dev/null)"
  if [ "$issue" = "null" ] || [ -z "$issue" ]; then
    echo "IN-PROGRESS — no issue adopted yet (run /iharden before /iship)"; return 0
  fi

  # ESCALATED wins: it's the explicit "stop for a human" latch (step 3 keeps the PR a draft).
  local labels
  if ! labels="$(gh issue view "$issue" -R "$ISSUES_REPO" --json labels -q '.labels[].name' 2>/dev/null)"; then
    echo "IN-PROGRESS — couldn't reach GitHub to check issue #$issue labels (retry)"; return 0
  fi
  if printf '%s\n' "$labels" | grep -qx interactive:escalated; then
    echo "ESCALATED — issue #$issue labeled interactive:escalated (stopped for a human)"; return 0
  fi

  # READY: an OPEN, non-draft PR for this branch — step 4's draft->ready flip is the success latch.
  local pr_json num draft
  if ! pr_json="$(gh pr list -R "$ISSUES_REPO" --head "$branch" --state open --json number,isDraft 2>/dev/null)"; then
    echo "IN-PROGRESS — couldn't reach GitHub to check the PR for $branch (retry)"; return 0
  fi
  num="$(printf '%s' "$pr_json"   | jq -r '.[0].number  // empty' 2>/dev/null || true)"
  draft="$(printf '%s' "$pr_json" | jq -r '.[0].isDraft' 2>/dev/null || true)"
  if [ -n "$num" ] && [ "$draft" = "false" ]; then
    echo "READY — non-draft PR #$num closes #$issue (ready for human merge)"; return 0
  fi
  if [ -n "$num" ]; then
    echo "IN-PROGRESS — draft PR #$num open for $branch, not yet flipped ready"; return 0
  fi
  echo "IN-PROGRESS — no open PR for $branch yet"; return 0
}

# Reap merged interactive sessions: reset each finished slot to a warm idle clone (node_modules
# kept) IN PLACE so the next `new` reclaims it instead of cloning cold. Reapable == adopted
# (issue set) AND the branch's PR is MERGED AND the tree is clean. FAIL CLOSED on any lookup
# error (leave it). Finishes by fast-forwarding the main checkout to merged work (when safe).
cmd_reap() {
  local quiet=0
  while [ $# -gt 0 ]; do case "$1" in
    --quiet)   quiet=1; shift;;
    -h|--help) usage;;
    *) echo "unknown arg: $1" >&2; usage;;
  esac; done
  require_gh
  say() { [ "$quiet" = 1 ] || echo "$@"; }

  local base reaped=0 d slug issue branch phase state merged cmux_ws
  base="$(default_branch)"

  while IFS= read -r d; do
    [ -n "$d" ] || continue
    slug="$(jq -r '.slug // "?"'    "$d/.session.json" 2>/dev/null)"
    issue="$(jq -r '.issue'         "$d/.session.json" 2>/dev/null)"
    branch="$(jq -r '.branch // ""' "$d/.session.json" 2>/dev/null)"
    phase="$(jq -r '.phase // ""'   "$d/.session.json" 2>/dev/null)"
    cmux_ws="$(jq -r '.cmux // ""'  "$d/.session.json" 2>/dev/null)"
    [ "$phase" = "idle" ] && continue                                  # already a warm idle slot
    if [ "$issue" = "null" ] || [ -z "$issue" ]; then
      say "  $slug: not adopted yet (no issue) — leaving"; continue
    fi
    # FAIL CLOSED: only reap on a CONFIRMED merge. Any gh/network error leaves the session.
    if ! state="$(gh issue view "$issue" -R "$ISSUES_REPO" --json state -q .state 2>/dev/null)"; then
      say "  $slug (#$issue): can't check issue state — leaving"; continue
    fi
    [ "$state" = "CLOSED" ] || { say "  $slug (#$issue): issue $state — leaving"; continue; }
    # Issue closed != merged (a human can close without merging). Require a MERGED PR for the
    # branch so we never reset --hard over commits that never landed.
    if ! merged="$(gh pr list -R "$ISSUES_REPO" --head "$branch" --state merged --json number -q 'length' 2>/dev/null)"; then
      say "  $slug (#$issue): can't check PR merge state — leaving"; continue
    fi
    case "$merged" in ''|*[!0-9]*) merged=0;; esac
    [ "$merged" -ge 1 ] || { say "  $slug (#$issue): closed but no MERGED PR for $branch — leaving (escalated/abandoned?)"; continue; }
    # Never destroy uncommitted work, even post-merge.
    if [ -n "$(git -C "$d" status --porcelain 2>/dev/null)" ]; then
      say "  $slug (#$issue): merged but working tree is dirty — leaving (commit/discard, or release --force)"; continue
    fi

    [ -n "$cmux_ws" ] && close_cmux_workspace "$cmux_ws" >&2   # close the session's cmux workspace
    recycle_clone "$d" "$base" "$branch"         # reset to clean main, keep node_modules, drop the task branch
    write_state "$d" "$slug" "$base" "$base" "null" "idle"
    set_cmux "$d" ""                             # workspace closed — clear the stale handle
    set_pairing "$d" "" ""                       # an idle slot runs no claude — no authoring pairing
    ensure_session_ignored "$d"
    say "  $slug (#$issue): merged — recycled to warm idle slot $(basename "$d") (kept node_modules)"
    reaped=$((reaped + 1))
  done < <(all_session_dirs)

  say "Reaped $reaped session(s); $(count_idle) warm idle slot(s) available for reuse."

  # Keep the local main checkout in sync with merged work. Fast-forward ONLY, and only
  # when unambiguously safe: on the default branch, a clean tree, and origin strictly
  # ahead with no divergence. Anything else → notify and skip (never merge, rebase, or
  # touch a dirty/feature-branch tree). Disable with REAP_SYNC_MAIN=false.
  [ "${REAP_SYNC_MAIN:-true}" = "true" ] || return 0
  [ "$(git -C "$REPO_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null)" = "$base" ] || return 0
  [ -z "$(git -C "$REPO_DIR" status --porcelain 2>/dev/null)" ] \
    || { say "  (local $base is dirty — skipped auto-sync)"; return 0; }
  git -C "$REPO_DIR" fetch -q origin "$base" 2>/dev/null || return 0
  local head remote
  head="$(git -C "$REPO_DIR" rev-parse HEAD 2>/dev/null)" || return 0
  remote="$(git -C "$REPO_DIR" rev-parse "origin/$base" 2>/dev/null)" || return 0
  [ "$head" != "$remote" ] || return 0                                  # already in sync
  if git -C "$REPO_DIR" merge-base --is-ancestor "$head" "$remote" 2>/dev/null; then
    git -C "$REPO_DIR" merge --ff-only "origin/$base" >/dev/null 2>&1 \
      && say "  synced local $base → $(git -C "$REPO_DIR" rev-parse --short "$remote")" \
      || say "  (auto-sync fast-forward failed — pull manually)"
  else
    say "  (local $base diverged from origin — skipped auto-sync; reconcile manually)"
  fi
}

[ $# -ge 1 ] || usage
SUB="$1"; shift
case "$SUB" in
  new)         cmd_new "$@";;
  adopt-issue) cmd_adopt_issue "$@";;
  release)     cmd_release "$@";;
  list)        cmd_list "$@";;
  reap)        cmd_reap "$@";;
  path)        cmd_path "$@";;
  status)      cmd_status "$@";;
  -h|--help)   usage;;
  *) echo "unknown subcommand: $SUB" >&2; usage;;
esac
