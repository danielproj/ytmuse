#!/bin/bash
# Serialises native UI suites across harness lanes: only one XCUITest run may own the console.
# Usage: scripts/ui-run-lock.sh <command...>   (waits for the lock, records owner, releases on exit)
# Waiters queue first come, first served: each takes a ticket and may take the lock only while its ticket is the
# oldest live one, so a lane running suites back to back cannot starve a waiter (seen in the W18 round 2 review).
set -euo pipefail
LOCK="${YTMUSE_UI_LOCK:-$HOME/Projects/DP/youtube-music-worktrees/.ui-run.lock}"
QUEUE="$LOCK.queue"
mkdir -p "$QUEUE"
ticket="$(python3 -c 'import time; print(time.time_ns())')-$$"
: > "$QUEUE/$ticket"
trap 'rm -f "$QUEUE/$ticket"' EXIT
# The oldest ticket whose owner is still alive; tickets of dead waiters are removed on the way.
first_live_ticket() {
  local t pid
  for t in $(ls "$QUEUE" | sort); do
    pid=${t##*-}
    if [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null; then echo "$t"; return; fi
    rm -f "$QUEUE/$t"
  done
}
announced=""
until [[ "$(first_live_ticket)" == "$ticket" ]] && mkdir "$LOCK" 2>/dev/null; do
  if [[ -d "$LOCK" ]]; then
    owner=$(cat "$LOCK/owner" 2>/dev/null || echo unknown)
    pid=$(cut -d' ' -f1 <<<"$owner")
    if [[ "$pid" =~ ^[0-9]+$ ]] && ! kill -0 "$pid" 2>/dev/null; then rm -rf "$LOCK"; continue; fi
    [[ "$announced" == "$owner" ]] || { echo "UI lock held by: $owner — waiting in queue" >&2; announced=$owner; }
  fi
  sleep 2
done
echo "$$ $(pwd) $(date -u +%FT%TZ)" > "$LOCK/owner"
rm -f "$QUEUE/$ticket"
trap 'rm -rf "$LOCK"' EXIT
export YTMUSE_UI_LOCK_HELD=1
"$@"
