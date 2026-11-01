#!/bin/bash
# W26 UI job: ONE background job. Waits until the console is quiet (ui-preflight exits 0, HID idle >= 600 s, memory pressure level 1), then holds this lane's
# build lock and the cross-lane UI lock, takes the two real-state snapshots, runs the UI suites through scripts/test.sh (default idle gate, never
# YTMUSE_UI_MIN_IDLE_SECONDS=0), takes the snapshots again and diffs them. Exit 75 from a suite is recorded (the environment was blocked), not retried.
# Usage: artifacts/harness/nodes/W26/ui/run-ui.sh [max-wait-seconds] [suite ...]     (default suites: T26 T21 T23)
set -u
cd "$(dirname "$0")/../../../../.."
OUT="$PWD/artifacts/harness/nodes/W26/ui"
LOG="$OUT/ui-job.log"  # appended to: one job per suite
MAX_WAIT=${1:-14400}; shift || true
SUITES=("$@"); [[ ${#SUITES[@]} -gt 0 ]] || SUITES=(T26 T21 T23)
TAG=$(IFS=-; echo "${SUITES[*]}")   # the snapshot files carry the suites they surround; a UI suite's own synthetic input resets the idle clock, so run ONE suite per job
BUILD_LOCK="${W26_BUILD_LOCK:-/tmp/ytmuse-w26-build.lockdir}"
say() { echo "$(date -u +%FT%TZ) $*" | tee -a "$LOG"; }
start=$(date +%s)
say "waiting for a quiet console (preflight ok, HID idle >= 600 s, pressure 1); gives up after ${MAX_WAIT}s"
while true; do
  idle=$(ioreg -c IOHIDSystem | awk '/HIDIdleTime/ && !seen {v=int($NF/1000000000); seen=1} END {print v}')
  pressure=$(sysctl -n kern.memorystatus_vm_pressure_level)
  free=$(memory_pressure | awk '/free percentage/ {gsub("%","",$NF); print $NF}')
  if [[ ${idle:-0} -ge 600 && "$pressure" == 1 && ${free:-0} -ge 25 ]] && python3 scripts/ui-preflight.py >/dev/null 2>&1; then break; fi
  if (( $(date +%s) - start > MAX_WAIT )); then say "GAVE UP waiting (idle=${idle}s pressure=$pressure free=${free}%): not run"; echo 75 > "$OUT/exit-code.$TAG"; exit 75; fi
  sleep 60
done
say "conditions met (idle=${idle}s pressure=$pressure free=${free}%); taking the build lock"
# The lock may be held by this lane's own headless run for minutes, and the console owner may come back meanwhile: the conditions are checked AGAIN once
# the lock is ours, and if they no longer hold the lock is given back and the wait resumes (an earlier version ran into the idle gate and got exit 75).
until mkdir "$BUILD_LOCK" 2>/dev/null; do sleep 5; done
idle=$(ioreg -c IOHIDSystem | awk '/HIDIdleTime/ && !seen {v=int($NF/1000000000); seen=1} END {print v}')
if [[ ${idle:-0} -lt 600 ]]; then rmdir "$BUILD_LOCK"; say "the console was used while waiting for the build lock (idle=${idle}s): waiting again"; exec "$0" "$((MAX_WAIT - ($(date +%s) - start)))" "${SUITES[@]}"; fi
trap 'rmdir "$BUILD_LOCK" 2>/dev/null' EXIT
export YTMUSE_UI_LOCK_HELD   # set by ui-run-lock.sh below
status=0
scripts/ui-run-lock.sh bash -c '
  set -u
  OUT="'"$OUT"'"; TAG="'"$TAG"'"; LOG="'"$LOG"'"
  say() { echo "$(date -u +%FT%TZ) $*" | tee -a "$LOG"; }
  python3 artifacts/harness/nodes/W09/integration/real-state-snapshot.py "$OUT/real-before.$TAG.json" && python3 artifacts/harness/nodes/W09/integration/extended-real-state-snapshot.py "$OUT/extended-before.$TAG.json"
  rc=0
  for suite in '"${SUITES[*]}"'; do
    say "== scripts/test.sh --suite $suite"
    scripts/test.sh --suite "$suite" > "$OUT/$suite.log" 2>&1
    code=$?
    say "== $suite exit=$code"
    echo "$suite $code" >> "$OUT/suite-exits.txt"
    if [[ $code == 75 ]]; then say "$suite: environment blocked (75): recorded, continuing headless"; fi
    [[ $code == 0 || $code == 75 ]] || rc=1
  done
  python3 artifacts/harness/nodes/W09/integration/real-state-snapshot.py "$OUT/real-after.$TAG.json" && python3 artifacts/harness/nodes/W09/integration/extended-real-state-snapshot.py "$OUT/extended-after.$TAG.json"
  diff -u "$OUT/real-before.$TAG.json" "$OUT/real-after.$TAG.json" > "$OUT/real.$TAG.diff" && say "real-state snapshot: IDENTICAL" || say "real-state snapshot: DIFFERENT (see real.diff)"
  diff -u "$OUT/extended-before.$TAG.json" "$OUT/extended-after.$TAG.json" > "$OUT/extended.$TAG.diff" && say "extended snapshot: IDENTICAL" || say "extended snapshot: DIFFERENT (see extended.diff)"
  exit $rc
'
status=$?
echo $status > "$OUT/exit-code.$TAG"
say "job finished, status=$status"
exit $status
