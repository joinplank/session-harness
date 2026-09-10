#!/usr/bin/env bash
# Shared helpers for the interactive-session system. Sourced, not executed.
#
# Model: this repo IS the product repo. An interactive session runs in an independent
# CLONE of this repo (scripts/session.sh — a reused, numbered slot pool under $WT_BASE),
# on branch session/<slug>, renamed to task/<issue#>-<slug> when the plan is filed. Each clone's
# origin is this repo's GitHub remote, so the session pushes its branch and opens a PR
# for a human to merge.

# --- Config (all overridable via env) ---------------------------------------
# The PRODUCT repo a session is cut from — resolved from the current directory, not from
# where these scripts happen to live. The two coincide in a repo that vendored the harness
# under scripts/, and differ when it is installed as a plugin: there the scripts live in the
# plugin root, whose parent is nobody's product repo. Deriving this from the script's own
# path would clone the plugin instead of the work.
# The fallback keeps the vendored layout working outside a git checkout at all (a bare
# `session.sh --help`, a scripts/ copy under test) rather than exiting from a sourced file.
harness_repo_dir() {
  local d
  if d="$(git rev-parse --show-toplevel 2>/dev/null)" && [ -n "$d" ]; then
    printf '%s' "$d"; return 0
  fi
  ( cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd )
}
REPO_DIR="${REPO_DIR:-$(harness_repo_dir)}"
REPO_SLUG="${REPO_SLUG:-$(git -C "$REPO_DIR" remote get-url origin 2>/dev/null | sed -E 's#^(git@[^:]+:|[a-z+]+://[^/]+/)##; s#\.git$##' || true)}"  # owner/name, derived from origin (empty until a remote exists — callers under set -e must not die here)
REPO_NAME="${REPO_NAME:-${REPO_SLUG##*/}}"        # repo name, namespaces the session slot pool
[ -n "$REPO_NAME" ] || REPO_NAME="$(basename "$REPO_DIR")"  # no origin remote yet — fall back to the dir name
ISSUES_REPO="${ISSUES_REPO:-$REPO_SLUG}"          # issues live in this repo
WT_BASE="${WT_BASE:-$HOME/work}"                  # where session clone slots live

# Default branch: prefer local origin/HEAD, then gh, then main.
default_branch() {
  local b
  b="$(git -C "$REPO_DIR" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null | sed 's|^origin/||' || true)"
  [ -n "$b" ] || b="$(gh repo view "$REPO_SLUG" --json defaultBranchRef -q .defaultBranchRef.name 2>/dev/null)"
  [ -n "$b" ] || b="main"
  printf '%s' "$b"
}

# --- Tool guards ------------------------------------------------------------
require_jq()  { command -v jq  >/dev/null || { echo "jq is required (brew install jq)" >&2; exit 1; }; }
require_gh()  { command -v gh  >/dev/null || { echo "gh CLI is required" >&2; exit 1; }; }
require_git() { command -v git >/dev/null || { echo "git is required" >&2; exit 1; }; }

# --- Clone helpers ----------------------------------------------------------
# URL the session clones track. Default: this repo's origin (a GitHub remote, so the
# session can push its branch and open a PR). Override with CLONE_URL.
clone_url() {
  local url="${CLONE_URL:-}"
  [ -n "$url" ] || url="$(git -C "$REPO_DIR" remote get-url origin 2>/dev/null)"
  [ -n "$url" ] || { echo "no origin remote on $REPO_DIR and no CLONE_URL set" >&2; return 1; }
  printf '%s' "$url"
}

# Provision a slot for a task: clone on first use (reuse thereafter), fetch, and
# check out a fresh task branch off the default branch. Reused slots are fully
# normalized first so orphaned/dirty clones cannot leak tracked, untracked, or
# ignored files into the next task. (This is the COLD path — warm session reuse
# lives in session.sh recycle_clone, which keeps node_modules.)
provision_slot() {
  local branch="$1" path="$2" base url
  base="$(default_branch)"
  url="$(clone_url)" || return 1
  # Re-clone when the dir isn't a clone, OR when an existing clone tracks a
  # DIFFERENT origin than expected (a slot left over from another repo, or a
  # changed CLONE_URL). Operating on the wrong repo's clone is never acceptable.
  if [ ! -d "$path/.git" ] \
     || [ "$(git -C "$path" remote get-url origin 2>/dev/null)" != "$url" ]; then
    rm -rf "$path"                       # clear any stale, non-clone, or wrong-origin dir
    git clone "$url" "$path"
  else
    git -C "$path" rebase --abort >/dev/null 2>&1 || true
    git -C "$path" merge --abort >/dev/null 2>&1 || true
    git -C "$path" cherry-pick --abort >/dev/null 2>&1 || true
    git -C "$path" revert --abort >/dev/null 2>&1 || true
    git -C "$path" reset --hard HEAD >/dev/null 2>&1 || true
    git -C "$path" clean -ffdx
  fi
  git -C "$path" fetch origin --prune
  git -C "$path" checkout -B "$branch" "origin/$base"
  git -C "$path" reset --hard "origin/$base"
  git -C "$path" clean -ffdx
  seed_env "$path"
}

# Seed local secrets into a freshly-provisioned clone. .env is gitignored, so it's never in
# the clone via git and is wiped by provision_slot's `clean -ffdx` — but the green-light build
# (`npm run build`) and runtime need it. Copy it from the source repo (REPO_DIR). It stays
# gitignored IN the clone (the tracked .gitignore ignores .env there too), so it can never be
# committed or pushed. Re-run on every provision so reused slots always get the current secrets.
seed_env() {
  local path="$1"
  [ -f "$REPO_DIR/.env" ] || return 0
  if cp -p "$REPO_DIR/.env" "$path/.env"; then
    echo "  seeded .env into $path" >&2
  else
    echo "  WARN: failed to copy .env into $path (clone will build without it)" >&2
  fi
}

# Close a cmux workspace by display name. No-op if not found. The stored name can end
# on a space; `cmux workspace list` trims trailing space in its display, so we strip
# trailing whitespace before matching — otherwise a verbatim `grep -F "$name"` silently
# misses and the merged session's space is orphaned. The trailing `|| true` swallows
# grep's exit-1 on no-match under `set -o pipefail`.
close_cmux_workspace() {
  local name="$1" ref
  [ -n "$name" ] || return 0
  command -v cmux >/dev/null || return 0
  name="$(printf '%s' "$name" | sed -E 's/[[:space:]]+$//')"   # match cmux's trimmed display
  [ -n "$name" ] || return 0
  ref="$(cmux workspace list 2>/dev/null | grep -F -- "$name" | grep -oE 'workspace:[0-9]+' | head -1 || true)"
  if [ -n "$ref" ]; then
    cmux workspace close --workspace "$ref" >/dev/null 2>&1 \
      && echo "  closed cmux workspace ($ref)" \
      || echo "  failed to close cmux workspace ($ref)"
  fi
}
