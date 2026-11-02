#!/bin/bash
# W44-prep: the real-state snapshot comparison and the incident verdict of scripts/perf-run.sh ui, kept apart so they can be tested with planted files.
# Sourced; never run on its own. Rules (critic round 1, M1): both diffs are ALWAYS computed and their exit codes ALWAYS written, whatever the other diff, the
# test step or `set -e` did; a changed, missing or uncomparable snapshot is an incident whatever the test step's status was.

# perf_compare_snapshots <dir>: writes <dir>/basic.diff, extended.diff and basic-diff-exit, extended-diff-exit (0 same, 1 changed, 2 not comparable).
perf_compare_snapshots() {
  local dir=$1 kind rc
  for kind in basic extended; do
    rc=0
    if [[ -f $dir/$kind-before.json && -f $dir/$kind-after.json ]]; then
      diff "$dir/$kind-before.json" "$dir/$kind-after.json" > "$dir/$kind.diff" || rc=$?
    else
      : > "$dir/$kind.diff"; rc=2
    fi
    echo "$rc" > "$dir/$kind-diff-exit"
  done
  return 0
}

# perf_verdict <dir> <test status>: prints the incident line when either snapshot comparison is not "unchanged" and returns non-zero then; otherwise returns the
# test status. A job that never took its first snapshot did not run, and says so instead of claiming an incident.
perf_verdict() {
  local dir=$1 status=$2 basic extended
  # The job writes this marker when it stopped itself because a BEFORE snapshot failed: no sampler and no test had been started, so nothing could have changed.
  # A marker left by an EARLIER attempt in a reused directory must never excuse a run that went on to take snapshots or compare them, so it counts only when no
  # after-snapshot and no comparison result exists next to it (perf-run.sh ui also refuses a non-empty --out; this is the second line).
  if [[ -e $dir/job-not-started ]] && ! compgen -G "$dir/*-after.json" > /dev/null && ! compgen -G "$dir/*-diff-exit" > /dev/null; then
    echo "perf-run: a before snapshot failed, so the UI job stopped before starting anything (exit $status); no test ran" >&2
    return "$status"
  fi
  # "Did not start" is claimed only when the run left no snapshot of either kind. A run that has an after-snapshot (or only part of a baseline) did run, and a
  # run without a comparable baseline is an incident, never a run that never happened.
  if ! compgen -G "$dir/*-before.json" > /dev/null && ! compgen -G "$dir/*-after.json" > /dev/null; then
    echo "perf-run: the UI job did not start (exit $status); nothing was run and no real-state snapshot was taken" >&2
    return $(( status == 0 ? 1 : status ))
  fi
  basic=$(cat "$dir/basic-diff-exit" 2>/dev/null || echo missing)
  extended=$(cat "$dir/extended-diff-exit" 2>/dev/null || echo missing)
  if [[ $basic != 0 || $extended != 0 ]]; then
    echo "perf-run: INCIDENT: a real-state snapshot CHANGED or could not be compared (basic diff: $basic, extended diff: $extended; 1 = changed, 2/missing = not comparable). Report to the operator at once; the test step exited $status" >&2
    return 1
  fi
  if [[ $status != 0 ]]; then
    echo "perf-run: the test step failed (exit $status); both real-state snapshots are unchanged" >&2
    return "$status"
  fi
  return 0
}

# perf_refuse_nonempty_out <dir>: the verdict reads files the job writes (markers, snapshots, diff results); a directory that already holds anything could let an
# earlier attempt's files decide this run's verdict, so a UI run starts only in an empty one.
perf_refuse_nonempty_out() {
  if [[ -n $(ls -A "$1" 2>/dev/null) ]]; then
    echo "perf-run: --out '$1' is not empty; a UI run needs a fresh directory (an earlier attempt's marker or diff result could decide this run's verdict)" >&2
    return 64
  fi
  return 0
}

# perf_self_test: plants snapshot files in a fresh directory under the temporary directory and checks the verdicts under `set -e`. No app, no real snapshot.
perf_self_test() {
  local root; root=$(mktemp -d "${TMPDIR%/}/ytmuse-perf-selftest-XXXXXX") || return 1
  local lib; lib="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/perf-lib.sh"
  local failures=0
  check_only() { # name expected_rc expected_incident(0/1) dir status: the verdict ALONE (a job killed before the comparison ran), nothing recomputed
    local name=$1 want=$2 incident=$3 dir=$4 status=$5 msg rc=0
    msg=$(bash -e -c 'source "$1"; perf_verdict "$2" "$3"' _ "$lib" "$dir" "$status" 2>&1 >/dev/null) || rc=$?
    local has=0; [[ $msg == *INCIDENT* ]] && has=1
    if [[ $rc != "$want" || $has != "$incident" ]]; then echo "perf-lib self-test FAILED: $name (exit $rc want $want; incident line $has want $incident): $msg" >&2; failures=$((failures + 1)); fi
  }
  plant() { # dir basic_after extended_after (content; empty string = file missing)
    mkdir -p "$1"; echo '{"a":1}' > "$1/basic-before.json"; echo '{"b":1}' > "$1/extended-before.json"
    [[ -z $2 ]] || echo "$2" > "$1/basic-after.json"; [[ -z $3 ]] || echo "$3" > "$1/extended-after.json"
  }
  check() { # name expected_rc expected_incident(0/1) dir status
    local name=$1 want=$2 incident=$3 dir=$4 status=$5 msg rc
    rc=0; msg=$(bash -e -c 'source "$1"; perf_compare_snapshots "$2"; perf_verdict "$2" "$3"' _ "$lib" "$dir" "$status" 2>&1 >/dev/null) || rc=$?
    local has=0; [[ $msg == *INCIDENT* ]] && has=1
    if [[ $rc != "$want" || $has != "$incident" ]]; then echo "perf-lib self-test FAILED: $name (exit $rc want $want; incident line $has want $incident): $msg" >&2; failures=$((failures + 1)); fi
    # both diff exit files are always written, even when the first comparison differs
    [[ -f $dir/basic-diff-exit && -f $dir/extended-diff-exit ]] || { echo "perf-lib self-test FAILED: $name did not write both diff results" >&2; failures=$((failures + 1)); }
  }
  plant "$root/changed-and-test-failed" '{"a":2}' '{"b":1}';     check 'changed snapshot plus a failing test step' 1 1 "$root/changed-and-test-failed" 1
  plant "$root/extended-changed"        '{"a":1}' '{"b":2}';     check 'only the extended snapshot changed' 1 1 "$root/extended-changed" 0
  plant "$root/both-changed"            '{"a":2}' '{"b":2}';     check 'both changed (the second diff is still written)' 1 1 "$root/both-changed" 0
  plant "$root/after-missing"           ''        '{"b":1}';     check 'a missing after-snapshot is an incident' 1 1 "$root/after-missing" 0
  plant "$root/clean-test-failed"       '{"a":1}' '{"b":1}';     check 'unchanged snapshots, failing test: the test status, no incident' 3 0 "$root/clean-test-failed" 3
  plant "$root/clean-ok"                '{"a":1}' '{"b":1}';     check 'unchanged snapshots, passing test' 0 0 "$root/clean-ok" 0
  mkdir -p "$root/never-started";                                 check 'a job that never started claims no incident' 75 0 "$root/never-started" 75
  # critic round 2, N1: a run with NO baseline but after-snapshots present did run; it is an incident, not "never started" (with a failing and a passing test step)
  plant "$root/no-baseline-failed" '{"a":1}' '{"b":1}'; rm "$root/no-baseline-failed"/*-before.json; check 'no before-snapshots but after-snapshots present, failing test' 1 1 "$root/no-baseline-failed" 1
  plant "$root/no-baseline-ok" '{"a":1}' '{"b":1}';     rm "$root/no-baseline-ok"/*-before.json;     check 'no before-snapshots but after-snapshots present, passing test' 1 1 "$root/no-baseline-ok" 0
  # only one before-snapshot is missing: not comparable, an incident
  plant "$root/one-baseline" '{"a":1}' '{"b":1}'; rm "$root/one-baseline/extended-before.json";     check 'one before-snapshot missing' 1 1 "$root/one-baseline" 0
  # the job stopped itself on a failed before-snapshot (marker file): reported as such, no incident, its own status
  mkdir -p "$root/stopped"; : > "$root/stopped/job-not-started";                                    check_only 'a job that stopped on a failed before-snapshot claims no incident (it never compared)' 70 0 "$root/stopped" 70
  mkdir -p "$root/stopped-half"; echo '{"a":1}' > "$root/stopped-half/basic-before.json"; : > "$root/stopped-half/job-not-started"; check_only 'stopped after only one before-snapshot: still no incident, nothing ran' 70 0 "$root/stopped-half" 70 70
  # critic round 3, P1: a stale marker from an earlier attempt next to a run that took snapshots and found a CHANGE must still be an incident
  plant "$root/stale-marker-changed" '{"a":2}' '{"b":1}'; : > "$root/stale-marker-changed/job-not-started"; check 'stale marker next to a changed snapshot' 1 1 "$root/stale-marker-changed" 0
  plant "$root/stale-marker-changed-failed" '{"a":2}' '{"b":1}'; : > "$root/stale-marker-changed-failed/job-not-started"; check 'stale marker, changed snapshot, failing test' 1 1 "$root/stale-marker-changed-failed" 1
  # critic round 3, N1d / L-1: the verdict alone, with snapshots present but no comparison result (the job died after the tests): a missing result is never "unchanged"
  plant "$root/no-compare" '{"a":1}' '{"b":1}';           check_only 'missing diff results read as not comparable, never as unchanged' 1 1 "$root/no-compare" 0
  plant "$root/no-compare-marker" '{"a":1}' '{"b":1}'; : > "$root/no-compare-marker/job-not-started"; check_only 'missing diff results plus a stale marker' 1 1 "$root/no-compare-marker" 0
  # a fresh --out is accepted; one holding anything is refused (the refusal runs before the job could start)
  mkdir -p "$root/fresh" "$root/used"; : > "$root/used/job-not-started"
  ( perf_refuse_nonempty_out "$root/fresh" ) 2>/dev/null || { echo 'perf-lib self-test FAILED: an empty --out was refused' >&2; failures=$((failures + 1)); }
  rc=0; ( perf_refuse_nonempty_out "$root/used" ) 2>/dev/null || rc=$?
  [[ $rc == 64 ]] || { echo "perf-lib self-test FAILED: a non-empty --out was accepted (exit $rc)" >&2; failures=$((failures + 1)); }
  # Only the directory this function made is removed, by its exact path.
  [[ $root == "${TMPDIR%/}"/ytmuse-perf-selftest-* ]] && rm -rf -- "$root"
  if [[ $failures == 0 ]]; then echo 'perf-lib self-test: ok'; return 0; fi
  return 1
}
