#!/bin/bash
# W44-prep: the gated indicative performance run (optimized Debug, isolated, synthetic PERF04 data). NOT the official W44 measurement (see Docs/Performance-Runbook.md).
#
#   scripts/perf-run.sh headless [--out DIR]   model-layer measurements at 50k / 10k / 5k on an optimized Debug build (no UI, no lock)
#   scripts/perf-run.sh ui [--out DIR]         the native performance UI tests: ONE gated job. Preflight must exit 0, the console must have been idle for
#                                              YTMUSE_UI_MIN_IDLE_SECONDS (default 300), memory pressure must be level 1 with at least 25% free, the UI lock is
#                                              held for the whole job, both real-state snapshots are taken before and after and must be unchanged.
#
# Environment: YTMUSE_PERF_LAUNCHES (default 10), YTMUSE_PERF_ITERATIONS (default 5). Raw files land in --out (default
# artifacts/harness/nodes/W44-prep/runs/<UTC stamp>-<mode>); `scripts/perf-report.py` turns them into report.md / result.json.
# Release is never built: the UI part builds Debug with SWIFT_OPTIMIZATION_LEVEL=-O under .build/perf-xcode.
set -euo pipefail
cd "$(dirname "$0")/.."
export PATH="$PWD/scripts/bin:$PATH"
source scripts/perf-lib.sh
if [[ ${1:-} == --self-test ]]; then perf_self_test; exit $?; fi
mode=${1:-}; [[ $# -gt 0 ]] && shift
out=""
while [[ $# -gt 0 ]]; do
  case "$1" in --out) out=$2; shift 2 ;; *) echo "unknown argument $1" >&2; exit 64 ;; esac
done
[[ $mode == headless || $mode == ui ]] || { echo 'Usage: scripts/perf-run.sh headless|ui [--out DIR]' >&2; exit 64; }
[[ -n $out ]] || out="artifacts/harness/nodes/W44-prep/runs/$(date -u +%Y%m%dT%H%M%SZ)-$mode"
mkdir -p "$out"; out=$(cd "$out" && pwd)
# A UI run starts only in an empty directory: the verdict reads files this run writes, and an earlier attempt's marker or diff result must not decide it.
[[ $mode == ui ]] && { perf_refuse_nonempty_out "$out" || exit 64; }
snapshots=artifacts/harness/nodes/W09/integration
[[ -f $snapshots/real-state-snapshot.py && -f $snapshots/extended-real-state-snapshot.py ]] || { echo 'real-state snapshot scripts are missing' >&2; exit 1; }

headroom() {   # pressure level 1, at least 25% of memory free and a 1-minute load average below 18 (operator rule 2026-11-01), or report and stop
  local level free load
  load=$(sysctl -n vm.loadavg | awk '{print int($2)}')
  if [[ $load -ge 18 ]]; then echo "perf-run: load average ${load} is 18 or more (other work on this Mac); timings would be worthless. Wait and retry" >&2; exit 75; fi
  level=$(sysctl -n kern.memorystatus_vm_pressure_level)
  free=$(memory_pressure | awk '/System-wide memory free percentage/ {gsub("%", "", $NF); print $NF}')
  if [[ $level != 1 || -z $free || $free -lt 25 ]]; then
    echo "perf-run: not enough memory headroom (pressure level $level, ${free:-?}% free); wait and retry" >&2
    exit 75
  fi
}
env_manifest() {   # what the numbers were measured on (PERF09 conditions are only logged here; the official run varies them)
  {
    echo "{"
    echo "  \"mode\": \"$mode\", \"stamp\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\", \"commit\": \"$(git rev-parse HEAD)\","
    echo "  \"build\": \"optimized Debug (SWIFT_OPTIMIZATION_LEVEL=-O / -Xswiftc -O), isolated, synthetic data; NOT a Release build\","
    echo "  \"macOS\": \"$(sw_vers -productVersion) ($(sw_vers -buildVersion))\", \"model\": \"$(sysctl -n hw.model)\", \"cpu\": \"$(sysctl -n machdep.cpu.brand_string)\", \"logicalCores\": $(sysctl -n hw.logicalcpu), \"memoryGiB\": $(( $(sysctl -n hw.memsize) / 1073741824 )),"
    echo "  \"powerSource\": \"$(pmset -g batt | head -1 | sed 's/.*drawing from//; s/[^A-Za-z ]//g; s/^ *//')\", \"lowPowerMode\": \"$(pmset -g | awk '/lowpowermode/ {print $2}')\", \"thermal\": \"$(pmset -g therm 2>/dev/null | tr '\n' ' ' | sed 's/"/'"'"'/g')\","
    echo "  \"xcode\": \"$(xcodebuild -version 2>/dev/null | tr '\n' ' ')\", \"swift\": \"$(swift --version 2>&1 | head -1 | sed 's/"/'"'"'/g')\""
    echo "}"
  } > "$out/environment.json"
}

if [[ $mode == headless ]]; then
  headroom
  env_manifest
  rm -f "$out/benchmarks.jsonl"
  set +e
  T44P_HEADLESS=1 YTMUSE_PERF_BENCH_OUT="$out" bash scripts/test.sh --suite T44P 2>&1 | tee "$out/headless.log"
  status=${PIPESTATUS[0]}
  set -e
  python3 scripts/perf-report.py --dir "$out" --out "$out/report.md" --json "$out/result.json"
  echo "perf-run headless: exit $status; report in $out/report.md"
  exit "$status"
fi

# ---- ui: one gated job -------------------------------------------------------------------------------------------------------------------------------
min_idle=${YTMUSE_UI_MIN_IDLE_SECONDS:-300}
python3 scripts/ui-preflight.py || { echo 'perf-run: UI preflight did not exit 0; not starting' >&2; exit 75; }
idle=$(ioreg -c IOHIDSystem | awk '/HIDIdleTime/ && !seen {v=int($NF/1000000000); seen=1} END {print v}')
[[ -z $idle || $idle -ge $min_idle ]] || { echo "perf-run: account holder active (idle ${idle}s < ${min_idle}s); not starting" >&2; exit 75; }
headroom
env_manifest
perf_dir=$(mktemp -d "${TMPDIR%/}/ytmuse-perf-XXXXXX")     # this run's own folder; the only path the app may write the interval log into
chmod 700 "$perf_dir"
stop_file="$perf_dir/stop-sampling"
export snapshots YTMUSE_PERF_DIR="$perf_dir" YTMUSE_PERF_STOP="$stop_file" PERF_OUT="$out" PERF_APP_PREFIX="$PWD/.build/perf-xcode/Build/Products/Debug/YTMuse.app/"
export BUILD_DIR="$PWD/.build/perf-xcode"

job() {   # runs inside the UI lock
  export YTMUSE_UI_LOCK_HELD=1
  # No baseline, no run: if either before snapshot fails, stop before the sampler or any test starts (and say so with a marker, so the verdict does not call it an incident).
  if ! python3 "$snapshots/real-state-snapshot.py" "$PERF_OUT/basic-before.json" > /dev/null || ! python3 "$snapshots/extended-real-state-snapshot.py" "$PERF_OUT/extended-before.json" > /dev/null; then
    echo 'perf-run: a before snapshot failed; not starting the sampler or any test' >&2
    : > "$PERF_OUT/job-not-started"
    return 70
  fi
  python3 scripts/perf-sample.py --app-path-prefix "$PERF_APP_PREFIX" --out "$PERF_OUT/process-samples.jsonl" --stop-file "$YTMUSE_PERF_STOP" --interval 2 > "$PERF_OUT/sampler.log" 2>&1 &
  local sampler=$!    # a process this job started; it is stopped through its stop file, never by name
  set +e
  # ONE xcodebuild run for all the scripted tests: the idle gate is checked once, at its start (the tests' own synthetic input resets the idle clock, so a
  # per-test gate could never pass twice). The app writes the running test's name into its log; a watcher reads it to time the stack captures.
  (
    last="" ; started=0
    while [[ ! -e "$YTMUSE_PERF_STOP" ]]; do
      cur=$(grep -h '"session"' "$YTMUSE_PERF_DIR/performance-intervals.jsonl" 2>/dev/null | tail -1 | sed -E 's/.*"test":"([^"]*)".*/\1/')
      if [[ $cur != "$last" ]]; then last=$cur; started=$SECONDS; fi
      if [[ $last == testW44PLibraryScroll || $last == testW44PBigPlaylist ]]; then
        for at in 50 110; do
          if (( SECONDS - started >= at )) && [[ ! -e "$PERF_OUT/$last.at$at.sample.txt" ]]; then
            # Read-only: the process is only identified by its executable path inside this worktree's perf build, never signalled.
            pid=$(ps -axo pid=,command= | awk -v p="$PERF_APP_PREFIX" '{id=$1; $1=""; sub(/^ /, ""); if (index($0, p) == 1) {print id; exit}}')
            [[ -z $pid ]] || /usr/bin/sample "$pid" 8 -file "$PERF_OUT/$last.at$at.sample.txt" > /dev/null 2>&1
          fi
        done
      fi
      sleep 2
    done
  ) &
  local watcher=$!
  set +e
  TEST_RESULT_PATH="$PERF_OUT/T44P.xcresult" T44P_UI_ONLY=1 bash scripts/test.sh --suite T44P 2>&1 | tee "$PERF_OUT/ui.log"
  local status=${PIPESTATUS[0]}
  : > "$YTMUSE_PERF_STOP"
  wait "$watcher" 2>/dev/null || true
  wait "$sampler" 2>/dev/null || true
  # Always compare, whatever the test step did (set +e is in force; the comparison writes both results itself).
  python3 "$snapshots/real-state-snapshot.py" "$PERF_OUT/basic-after.json" > /dev/null || true
  python3 "$snapshots/extended-real-state-snapshot.py" "$PERF_OUT/extended-after.json" > /dev/null || true
  perf_compare_snapshots "$PERF_OUT"
  return "$status"
}
export -f job perf_compare_snapshots
set +e
./scripts/ui-run-lock.sh bash -c 'source scripts/perf-lib.sh; job'
status=$?
set -e
# Collect this run's raw interval log, then remove the folder this script created (and nothing else).
[[ -f "$perf_dir/performance-intervals.jsonl" ]] && cp "$perf_dir/performance-intervals.jsonl" "$out/performance-intervals.jsonl"
rm -rf -- "$perf_dir"
python3 scripts/perf-report.py --dir "$out" --out "$out/report.md" --json "$out/result.json" || true
# The snapshot verdict comes first and does not depend on the test status or on errexit.
set +e
perf_verdict "$out" "$status"
verdict=$?
set -e
echo "perf-run ui: test step exit $status; basic snapshot diff $(cat "$out/basic-diff-exit" 2>/dev/null || echo missing), extended $(cat "$out/extended-diff-exit" 2>/dev/null || echo missing); report in $out/report.md"
exit "$verdict"
