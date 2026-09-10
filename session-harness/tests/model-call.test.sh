#!/usr/bin/env bash
# Gate for scripts/model-call.sh, run offline against STAND-IN CLIs. Invoked by build.sh
# against the copy the bundle ships.
#
# The supervisor's guarantees are the ones nothing else can observe: a real model
# call that hangs costs 30 minutes to watch, and a spliced answer looks like a
# review. Stand-ins reproduce both in seconds and cost no model call.
#
# It belongs to the BUILD, not to a deployment check. Every assertion spawns processes,
# signals them, kills process groups and reads the process table, so it measures the host's
# process model: a minimal container image has no `ps` and the leak assertion would refuse to
# pass over a missing tool, and process startup under container scheduling loses the timing
# race the cancellation assertions need. Neither outcome would say anything about the
# supervisor. This runs where the supervisor actually runs — a developer machine.
#
# Every assertion here is structural — attempt counts, published bytes, live
# processes. None is a wall-clock measurement: a gate that fails on a loaded
# machine would block merges on work it never examined.
#
# Exit: 0 = every property holds · 1 = a property failed.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
# The supervisor under test. build.sh passes the shipped copy explicitly; the default is the
# bundle's own, so the suite is runnable by hand from this directory.
MODEL_CALL="${1:-$HERE/../scripts/model-call.sh}"
[ -f "$MODEL_CALL" ] || { echo "no model-call.sh at $MODEL_CALL" >&2; exit 1; }
# shellcheck source=../scripts/model-call.sh
. "$MODEL_CALL"

W="$(mktemp -d)"
trap 'rm -rf "$W"' EXIT HUP INT TERM
FAILED=0

ok()   { # ok <condition-result> <label>
  if [ "$1" = 0 ]; then echo "  ok  $2"; else echo "  FAIL  $2" >&2; FAILED=1; fi
}
alive() { kill -0 "$1" 2>/dev/null; }

# A short bound: these stand-ins are built to hit it, so the gate must not sit on
# the production value.
export MODEL_CALL_TIMEOUT_S=1

# --- stand-ins ---------------------------------------------------------------

count_attempt() {
  local n
  n=$(( $(cat "$W/attempts") + 1 ))
  echo "$n" > "$W/attempts"
  printf '%s' "$n"
}

# Hangs forever, having first backgrounded a descendant. The descendant is the
# point: killing a leaf proves nothing about a CLI that spawns.
stub_hang() {
  count_attempt >/dev/null
  sleep 300 &
  echo "$!" > "$W/child.pid"
  sleep 300
}

# Attempt 1 writes a sentinel and dies mid-stream; attempt 2 answers properly.
stub_partial_then_ok() {
  local out="$1"
  if [ "$(count_attempt)" = 1 ]; then
    printf 'SENTINEL-PARTIAL-ATTEMPT\n' > "$out"
    exit 1
  fi
  printf 'GOOD-ANSWER\n' > "$out"
}

stub_fast() { printf 'ANSWER\n' > "$1"; }

# --- the bound fires, loudly, and leaves nothing running ---------------------

echo "model-call.test: bound + no orphans"
echo 0 > "$W/attempts"; rm -f "$W/child.pid"
model_call --label "stand-in hang" --out "$W/hang.out" -- stub_hang 2>"$W/hang.err"; RC=$?
[ "$RC" = 1 ]; ok $? "a call that hits the bound exits 1"
grep -q 'TIMED OUT' "$W/hang.err"; ok $? "the failure says TIMED OUT, not nothing"
grep -q "${MODEL_CALL_TIMEOUT_S}s" "$W/hang.err"; ok $? "the failure names the bound it hit"
[ ! -s "$W/hang.out" ]; ok $? "a timed-out call publishes nothing to --out"

if [ -f "$W/child.pid" ]; then
  CHILD="$(cat "$W/child.pid")"
  for _ in 1 2 3 4 5 6 7 8 9 10; do alive "$CHILD" || break; sleep 0.1; done
  if alive "$CHILD"; then
    kill -KILL "$CHILD" 2>/dev/null
    ok 1 "the attempt's descendant died with it (no leaked process group)"
  else
    ok 0 "the attempt's descendant died with it (no leaked process group)"
  fi
else
  ok 1 "stand-in recorded its descendant"
fi

# --- a timed-out call is not retried -----------------------------------------
# Asserted by attempt COUNT, not elapsed time: the property is "one attempt", and
# a clock reading would make a busy machine look like a broken supervisor.

echo "model-call.test: the bound is not retried"
echo 0 > "$W/attempts"
model_call --label "stand-in hang, retryable" --out "$W/hang2.out" --retry -- stub_hang 2>"$W/hang2.err"
[ "$(cat "$W/attempts")" = 1 ]; ok $? "a timed-out call runs once even with --retry (ran $(cat "$W/attempts"))"
grep -q 'attempt 1/2' "$W/hang2.err"; ok $? "the timeout reports which attempt it was"

# --- a death is retried, and the dead attempt's bytes never surface -----------

echo "model-call.test: retry + no spliced output"
echo 0 > "$W/attempts"
model_call --label "stand-in partial" --out "$W/splice.out" --retry -- stub_partial_then_ok 2>/dev/null
ok $? "a call that dies before the bound is retried and succeeds"
grep -q 'GOOD-ANSWER' "$W/splice.out"; ok $? "the successful attempt's answer is published"
if grep -q 'SENTINEL-PARTIAL-ATTEMPT' "$W/splice.out"; then
  ok 1 "the dead attempt's bytes never reach --out"
else
  ok 0 "the dead attempt's bytes never reach --out"
fi
[ "$(cat "$W/attempts")" = 2 ]; ok $? "exactly 2 attempts ran (saw $(cat "$W/attempts"))"

# --- retry is opt-in ---------------------------------------------------------

echo "model-call.test: retry is opt-in"
echo 0 > "$W/attempts"
model_call --label "stand-in partial, no retry" --out "$W/noretry.out" -- stub_partial_then_ok 2>/dev/null; RC=$?
[ "$RC" = 1 ]; ok $? "without --retry a dying call fails"
[ "$(cat "$W/attempts")" = 1 ]; ok $? "without --retry exactly 1 attempt runs (saw $(cat "$W/attempts"))"
[ ! -s "$W/noretry.out" ]; ok $? "a failed call publishes nothing to --out"

# --- the supervisor's own timer does not outlive the call --------------------
# A watchdog whose sleep is merely orphaned would keep a process alive for the
# whole bound after every successful call — the leak is invisible at the default
# 30-minute bound precisely because nothing waits around to see it.

echo "model-call.test: the watchdog leaves nothing behind"
# The bound doubles as this run's sentinel, so it is derived from the PID: the check looks for
# timers process-wide, and a concurrent build (parallel session slots are normal here) would
# otherwise be caught by this one's assertion and fail a build over another's processes.
SENTINEL_BOUND=$(( 20000 + $$ % 10000 ))
MODEL_CALL_TIMEOUT_S="$SENTINEL_BOUND" model_call --label "stand-in fast" --out "$W/fast.out" -- stub_fast 2>/dev/null
ok $? "a fast call succeeds"
sleep 0.2
# Match the timer's argv exactly. A substring search over full command lines also
# hits any shell whose own command line quotes this script, which would report a
# leak that is not there.
# Prove the listing works before trusting an empty result from it: `ps` that cannot see this very
# shell would report every leak as zero, turning the assertion into one that cannot fail.
if ps -A -o pid= 2>/dev/null | tr -d ' ' | grep -qx "$$"; then
  LEAKED="$(ps -A -o command= 2>/dev/null | awk -v b="$SENTINEL_BOUND" '$1=="sleep" && $2==b' | wc -l | tr -d ' ')"
  [ "$LEAKED" = 0 ]; ok $? "no watchdog timer survives the call it was bounding (found $LEAKED)"
else
  ok 1 "process listing works — without it a leaked timer cannot be observed, so this is unproven, not passing"
fi

# --- the bound outranks a zero exit status ------------------------------------
# A CLI that traps the kill can exit 0 over a half-written answer. If the exit status won that
# contest, a truncated review would publish as a complete one.

echo "model-call.test: a fired bound is not overruled by exit 0"
stub_survives_kill() {
  trap 'printf "PARTIAL\n" > "$1"; exit 0' TERM
  sleep 300
}
model_call --label "stand-in traps TERM" --out "$W/trap.out" -- stub_survives_kill 2>"$W/trap.err"; TRAP_RC=$?
[ "$TRAP_RC" = 1 ]; ok $? "a call killed at the bound fails even when it exits 0"
grep -q 'TIMED OUT' "$W/trap.err"; ok $? "it is reported as a timeout, not a success"
[ ! -s "$W/trap.out" ]; ok $? "its half-written answer is not published"

# --- the answer is not left readable by other users --------------------------
# The published artifact holds a plan, a branch diff or a review.

echo "model-call.test: the published answer is private"
model_call --label "stand-in perms" --out "$W/perm.out" -- stub_fast 2>/dev/null
ok $? "the call succeeds"
PERM="$(ls -l "$W/perm.out" 2>/dev/null | cut -c1-10)"
[ "$PERM" = "-rw-------" ]; ok $? "the answer is readable only by its owner (mode $PERM)"

# --- a call with no private destination is not made --------------------------
# The attempt file is where the answer lands. Without it, or without its mode, the call would be
# paid for and its output either lost or left readable.

echo "model-call.test: no private destination, no call"
(
  chmod() { return 1; }
  stub_reports_call() { printf 'CALLED\n' >> "$W/should-not-run"; printf 'A\n' > "$1"; }
  rm -f "$W/should-not-run"
  model_call --label "stand-in no-dest" --out "$W/nodest.out" -- stub_reports_call 2>/dev/null
) ; NODEST_RC=$?
[ "$NODEST_RC" = 1 ]; ok $? "a call whose attempt file cannot be secured fails"
[ ! -f "$W/should-not-run" ]; ok $? "the model is never invoked in that case"

# --- a failed publication leaves nothing behind ------------------------------
# `mv` is atomic only within a filesystem; across one it copies then unlinks, so a failure can
# leave a whole or partial answer at the destination. Reporting failure while the destination holds
# output is the same splice the per-attempt scratch exists to prevent, arriving one step later.

echo "model-call.test: a failed publish publishes nothing"
(
  # Stand in for a cross-filesystem move: destination written, then failure.
  mv() { command cp "$1" "$2" 2>/dev/null; return 1; }
  model_call --label "stand-in publish-fail" --out "$W/pub.out" -- stub_fast 2>/dev/null
) ; PUB_RC=$?
[ "$PUB_RC" = 1 ]; ok $? "a call whose answer cannot be published reports failure"
[ ! -s "$W/pub.out" ]; ok $? "a failed publish leaves no answer at --out"

# --- an interrupted supervisor takes its call with it ------------------------
# The attempt runs in its own process group, so the terminal does not deliver ^C to it. A model
# call that outlived the session that cancelled it would keep running, and keep billing.

echo "model-call.test: cancelling the supervisor cancels the call"
# The stand-in reports the scratch dir it was handed: its output path lives inside it, which is the
# only way to name that directory from outside. Scanning the system temp dir instead would depend
# on `mktemp` honouring TMPDIR (BSD's does not) and would collide with a concurrent build.
cat > "$W/cancel.sh" <<EOF
. "$MODEL_CALL"
stub() {
  dirname "\$1" > "$W/cancel-scratch.path"
  sleep 300 & echo \$! > "$W/cancel-child.pid"
  sleep 300
}
MODEL_CALL_TIMEOUT_S=600 model_call --label "stand-in cancel" --out "$W/cancel.out" -- stub
EOF
rm -f "$W/cancel-child.pid" "$W/cancel-scratch.path"
bash "$W/cancel.sh" >/dev/null 2>&1 &
CANCEL_PID=$!
# Wait for the stand-in to be running before interrupting it. The interrupt has to land while a
# call is in flight, so a fixed short wait turns slow process startup into a failed assertion about
# cancellation — a different claim than the one being tested. 15s is far past any real startup.
CANCEL_READY=0
for _ in $(seq 1 150); do
  if [ -s "$W/cancel-child.pid" ] && [ -s "$W/cancel-scratch.path" ]; then CANCEL_READY=1; break; fi
  sleep 0.1
done
[ "$CANCEL_READY" = 1 ]; ok $? "the cancel stand-in started, so the interrupt lands on a live call"
kill -TERM "$CANCEL_PID" 2>/dev/null
wait "$CANCEL_PID" 2>/dev/null
sleep 0.4
if [ -s "$W/cancel-child.pid" ]; then
  CANCEL_CHILD="$(cat "$W/cancel-child.pid")"
  if alive "$CANCEL_CHILD"; then
    kill -KILL "$CANCEL_CHILD" 2>/dev/null
    ok 1 "an interrupted supervisor leaves no model call running"
  else
    ok 0 "an interrupted supervisor leaves no model call running"
  fi
else
  ok 1 "the cancel stand-in started before the interrupt"
fi
# A shell killed by a signal never runs a RETURN trap, so the interrupted call's scratch — holding
# a partial answer — is only cleaned if the signal handler does it.
if [ -s "$W/cancel-scratch.path" ]; then
  CANCEL_SCRATCH="$(cat "$W/cancel-scratch.path")"
  [ ! -d "$CANCEL_SCRATCH" ]
  ok $? "an interrupted call leaves no scratch dir of partial output behind ($CANCEL_SCRATCH)"
  rm -rf "$CANCEL_SCRATCH"
else
  ok 1 "the cancel stand-in reported the scratch dir it was given"
fi

if [ "$FAILED" = 0 ]; then
  echo "model-call.test: OK"
  exit 0
fi
echo "model-call.test: FAILED" >&2
exit 1
