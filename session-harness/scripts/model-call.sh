#!/usr/bin/env bash
# The one supervisor for UNATTENDED model-CLI execution in the interactive flow.
# Sourced, not executed: scripts/plan-critique.sh, scripts/concept-check.sh and
# .claude/skills/adversarial-review/run-review.sh route every critique, review,
# checker and probe call through model_call.
#
# An unsupervised model call has two failure modes, and both end as a round that
# silently did not happen: it hangs forever, or it dies mid-stream having produced
# nothing. model_call bounds the call, retries it where a retry is provably safe,
# isolates each attempt's output, and fails loudly enough that the caller can
# REPORT the loss instead of omitting it.
#
#   model_call --label <text> --out <file> [--retry] -- <fn>
#
# <fn> is a shell FUNCTION, not a command line: model_call invokes it with exactly
# one argument, the path this attempt must write its answer to. A function is what
# lets one supervisor drive call sites whose output plumbing differs — `codex -o`
# writes the file itself, `claude -p` redirects stdout, `opencode | jq` is a
# pipeline — without model_call having to know which.
#
# Only an attempt that SUCCEEDS is published to --out. A failed attempt's bytes
# never reach the caller, so a partial answer cannot splice into the retry's and
# produce a plausible, corrupted review — a failure far worse than the hang this
# supervisor exists to remove, because nothing downstream can see it.
#
# --retry is OPT-IN, and belongs only to a call the CLI runs under a mechanical
# read-only sandbox flag. A review-shaped prompt is not a boundary: a retry runs
# the call a second time, so whatever it could write once, it could write twice.
# A call that hits the BOUND is never retried whatever its sandbox — it has
# already spent the whole time budget, and a second attempt turns one stall into
# two.
#
# Exit: 0 = an attempt succeeded; its output is at --out.
#       1 = the bound fired, or every attempt died. Nothing is written to --out.
#       2 = usage error.

# The bound, in seconds. The longest call the flow makes is a round-1 `ultra`
# review over a full branch diff, which runs in minutes; 30 minutes is an order of
# magnitude above that, so it is a bound only a call that has STOPPED can reach.
# A slow-but-working review is protected by that headroom.
MODEL_CALL_TIMEOUT_S="${MODEL_CALL_TIMEOUT_S:-1800}"

# Kill an attempt and everything it spawned. A model CLI spawns children, so the
# target is the attempt's whole process GROUP — which `set -m` gave it — not its
# leader: a group outlives its leader for exactly as long as a descendant does,
# which is the case this has to cover. TERM first, then KILL for whatever ignored
# it.
# Groups belonging to an attempt that is currently in flight. An attempt runs in its
# OWN process group, which is what makes it killable as a unit — and also what stops
# the terminal delivering ^C to it. Without this, interrupting the session would
# leave the model call running and billing, which is the failure this file exists to
# remove, wearing a different hat.
_model_call_inflight=""
# The in-flight call's scratch dir. A RETURN trap cannot clean it here: a shell killed
# by a signal never runs one, so an interrupted call would leave its partial model
# output on disk — output that was isolated precisely because it is not fit to keep.
_model_call_scratch=""

_model_call_on_signal() {
  local sig="$1" p
  for p in $_model_call_inflight; do _model_call_kill_group "$p"; done
  _model_call_inflight=""
  # After the writers are dead, so nothing recreates what this removes.
  [ -z "$_model_call_scratch" ] || rm -rf "$_model_call_scratch"
  _model_call_scratch=""
  # Re-raise with the handler cleared, so the caller sees the ordinary
  # killed-by-signal exit rather than a swallowed interrupt.
  trap - "$sig"
  kill -"$sig" $$
}

_model_call_kill_group() {
  local pgid="$1"
  # A group with no members left is the common case — the call simply finished —
  # and costs nothing: TERM fails and there is no shutdown to wait for.
  kill -TERM "-$pgid" 2>/dev/null || return 0
  # Otherwise give it a moment to leave on its own, then insist. Waiting on group
  # liveness instead would hang on the leader's own zombie, which lingers until
  # the caller reaps it and is not something to escalate against.
  sleep 0.5
  kill -KILL "-$pgid" 2>/dev/null || true
}

# One bounded attempt. Returns the function's exit status, or 124 if the bound
# fired. A watchdog rather than a poll loop: the attempt is a background job of
# this shell, so it stays a zombie until waited for and would answer `kill -0`
# long after it exited — `wait` is the only reading of "finished" that is not a
# race.
_model_call_attempt() {
  local fn="$1" out="$2" bound="$3" marker="$4"
  local pid watchdog rc prev_int prev_term prev_hup
  # Saved and restored around the attempt: callers set their own traps (a scratch-dir
  # cleanup, typically) and this must not outlive the call it protects.
  prev_int="$(trap -p INT)"; prev_term="$(trap -p TERM)"; prev_hup="$(trap -p HUP)"

  # `set -m` makes the fork below a process-group leader, which is what makes the
  # whole attempt killable as one unit. `set +m` INSIDE that fork is what keeps it
  # one unit: job control is inherited, so without it a child the attempt
  # backgrounds would lead a group of its own and survive the kill.
  # Handlers go in BEFORE the forks. Installed afterwards, a signal arriving during
  # startup would take the default action — kill this shell and leave the attempt,
  # which is in a group of its own and so never receives the terminal's signal,
  # running and billing. Each pid is recorded the moment it exists.
  trap '_model_call_on_signal INT' INT
  trap '_model_call_on_signal TERM' TERM
  trap '_model_call_on_signal HUP' HUP

  set -m
  # `umask 077` inside the fork: the attempt holds a plan, a branch diff or a review,
  # and whatever the CLI creates for it is readable only by this user. The mode
  # survives the move to the caller's path, which a default umask would have widened.
  { set +m; umask 077; "$fn" "$out"; } </dev/null &
  pid=$!
  _model_call_inflight="$pid"
  # The watchdog leads its own group for the same reason the attempt does: its
  # `sleep` is a child of the subshell, so killing the subshell alone would leave a
  # timer running for the rest of the bound — on EVERY call, including the ones
  # that succeed in a second.
  { set +m; sleep "$bound"; printf 'timed out\n' > "$marker"; _model_call_kill_group "$pid"; } &
  watchdog=$!
  _model_call_inflight="$pid $watchdog"
  set +m

  # Job control is on for these forks, so the shell would announce a killed attempt
  # ("Terminated") on stderr. The supervisor reports the failure itself, in terms a
  # caller can act on; the raw notice is noise on top of that.
  wait "$pid" 2>/dev/null && rc=0 || rc=$?
  # Stop the watchdog, then sweep its group once it has been reaped. The sweep is
  # not redundant: an attempt that finishes immediately can have the signal land
  # while the watchdog sits between its own start and forking its timer, so the
  # timer is created after the group was signalled and would otherwise outlive the
  # call by the entire bound. Once the watchdog is reaped there is no such window.
  kill -TERM "-$watchdog" 2>/dev/null || true
  wait "$watchdog" 2>/dev/null || true
  _model_call_kill_group "$watchdog"
  # Sweep even a clean exit: a leader that returned 0 can still have left a child,
  # and one that outlives the round would race the next attempt.
  _model_call_kill_group "$pid"

  _model_call_inflight=""
  eval "${prev_int:-trap - INT}"
  eval "${prev_term:-trap - TERM}"
  eval "${prev_hup:-trap - HUP}"

  # The marker decides, not the exit status. It is written before the kill, so its
  # presence means the bound elapsed and this call was killed — and a CLI that traps
  # the signal can still exit 0 over a half-written answer. Trusting the status there
  # would publish truncated output as a complete review, which nothing downstream can
  # tell from the real thing. The cost is that a call finishing in the same instant
  # the bound expires is reported as a timeout: a false timeout is loud and the caller
  # can re-run it, which a quietly truncated answer is not.
  [ ! -f "$marker" ] || return 124
  [ "$rc" != 0 ] || return 0
  return "$rc"
}

model_call() {
  local label="" out="" retry=0 fn=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --label) label="${2:?model_call: --label requires a value}"; shift 2;;
      --out)   out="${2:?model_call: --out requires a path}"; shift 2;;
      --retry) retry=1; shift;;
      --)      shift; fn="${1:-}"; break;;
      *) echo "model_call: unknown arg: $1" >&2; return 2;;
    esac
  done
  [ -n "$label" ] || { echo "model_call: --label is required" >&2; return 2; }
  [ -n "$out" ]   || { echo "model_call: --out is required" >&2; return 2; }
  [ -n "$fn" ]    || { echo "model_call: no attempt function given after --" >&2; return 2; }
  declare -F "$fn" >/dev/null \
    || { echo "model_call: '$fn' is not a shell function" >&2; return 2; }
  case "$MODEL_CALL_TIMEOUT_S" in
    ''|*[!0-9]*) echo "model_call: MODEL_CALL_TIMEOUT_S must be a whole number of seconds" >&2; return 2;;
  esac

  local attempts=1
  [ "$retry" = 0 ] || attempts=2

  local scratch marker attempt_out i=1 rc
  # Without private scratch there is no attempt isolation, so there is nothing safe to
  # run: a failure here must stop the call, not start one that publishes straight to
  # the caller's artifact.
  scratch="$(mktemp -d)" && [ -n "$scratch" ] && [ -d "$scratch" ] || {
    # This return precedes the RETURN trap below, so anything a partial allocation
    # left behind has to be cleaned here or nothing ever will.
    [ -z "$scratch" ] || rm -rf "$scratch"
    echo "$label: could not create scratch space for attempt isolation — not calling the model" >&2
    return 1
  }
  # Covers the ordinary returns below; the signal handler covers the interrupted ones.
  _model_call_scratch="$scratch"
  trap 'rm -rf "$scratch"; _model_call_scratch=""' RETURN
  marker="$scratch/bound-fired"

  while [ "$i" -le "$attempts" ]; do
    rm -f "$marker"
    attempt_out="$scratch/attempt-$i"
    # Created here, so its mode is this shell's umask rather than the attempt's — and
    # a CLI that truncates the file instead of replacing it keeps that mode all the
    # way to the caller's path.
    : > "$attempt_out" && chmod 600 "$attempt_out" || {
      echo "$label: could not create a private attempt file — not calling the model" >&2
      return 1
    }
    _model_call_attempt "$fn" "$attempt_out" "$MODEL_CALL_TIMEOUT_S" "$marker" && rc=0 || rc=$?
    if [ "$rc" = 0 ]; then
      # Reporting success without publishing would hand the caller an answer that does
      # not exist — the model was called, paid for, and its output dropped somewhere
      # only this line could have noticed.
      mv "$attempt_out" "$out" || {
        # `mv` is only atomic within a filesystem. Across one it copies then unlinks,
        # so a failure can leave a whole or partial answer at the destination — which
        # would publish output from a call this function is about to report as
        # failed, the exact splice the per-attempt isolation exists to prevent.
        rm -f "$out"
        echo "$label: the call succeeded but its answer could not be written to $out" >&2
        return 1
      }
      return 0
    fi
    if [ "$rc" = 124 ]; then
      echo "$label: TIMED OUT after ${MODEL_CALL_TIMEOUT_S}s on attempt $i/$attempts — no answer produced" >&2
      return 1
    fi
    # An attempt killed by a signal was stopped by someone — an operator's ^C, a
    # supervisor above this one — and a retry would restart work that was
    # deliberately abandoned. Retry answers the transient death (a CLI that exits
    # nonzero on its own), not an instruction to stop.
    if [ "$rc" -gt 128 ]; then
      echo "$label: attempt $i/$attempts was terminated by signal $((rc - 128)) — not retrying" >&2
      return 1
    fi
    echo "$label: attempt $i/$attempts DIED (exit $rc) before the ${MODEL_CALL_TIMEOUT_S}s bound" >&2
    i=$((i + 1))
  done

  echo "$label: no answer produced after $attempts attempt(s)" >&2
  return 1
}
