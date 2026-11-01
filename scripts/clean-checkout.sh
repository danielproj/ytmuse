#!/bin/bash
# W30 (T30.1): proves a FRESH checkout builds and tests with no Google or signing secrets, by running scripts/ci.sh in a clean clone, then deleting the clone.
#   scripts/clean-checkout.sh [--keep] [--snapshot]
# With --snapshot the clone is replaced by the PUBLIC SNAPSHOT (scripts/make-public-snapshot.sh: the committed tree without the harness evidence, plus the few harness
# files the tests read, scanned): the proof that what would be published builds and passes every headless test by itself, with no .git.
# The clone is made with `git clone --no-local` from this repository's committed state (so uncommitted work is not in it; the script says so), under ~/Projects
# (never /tmp: a build under /tmp is not where UI tests may run), in a directory named with this run's pid and a random suffix. It runs with `env -i`: only HOME, PATH
# and TMPDIR reach the build, so no token, credential, YTMUSE_* or GOOGLE_* variable of the caller can. It checks the clone holds no private developer file, runs the CI
# steps, requires the clone's tracked files to be unmodified afterwards, and removes exactly the directory it made (its .build is regenerable and large).
# Heavy: a full Debug build and every headless test. Follow the memory rules in Docs/Harness-Brief.md (pressure level 1, at least 25% memory free) before starting.
set -euo pipefail
cd "$(dirname "$0")/.."
source_repo="$PWD"
keep=0; snapshot=0
for argument in "$@"; do case "$argument" in --keep) keep=1;; --snapshot) snapshot=1;; *) echo "unknown argument: $argument" >&2; exit 64;; esac; done
projects="$HOME/Projects"
[[ -d "$projects" ]] || { echo "clean-checkout: $projects does not exist" >&2; exit 66; }
dirty="$(git status --porcelain --untracked-files=no | wc -l | tr -d ' ')"
[[ "$dirty" == 0 ]] || echo "clean-checkout: note: $dirty uncommitted change(s) are NOT in the clone (it is the committed state)"
dir="$(mktemp -d "$projects/.ytmuse-clean-checkout.$$.XXXXXX")"
real_dir="$(cd "$dir" && pwd -P)"
[[ "$real_dir" == "$(cd "$projects" && pwd -P)"/.ytmuse-clean-checkout.$$.* ]] || { echo "clean-checkout: unexpected clone location" >&2; rmdir "$dir"; exit 65; }
log="$real_dir/ci.log"
remove_clone() {
  # Only the directory this run made: under ~/Projects, carrying this run's prefix and pid, and not a symlink.
  [[ -d "$real_dir" && ! -L "$dir" && "$real_dir" == "$(cd "$projects" && pwd -P)"/.ytmuse-clean-checkout.$$.* ]] && rm -rf "$real_dir"
}
finish() { local s=$?; if [[ $keep == 1 ]]; then echo "clean-checkout: kept $real_dir"; else remove_clone; echo "clean-checkout: removed the clone"; fi; exit $s; }
trap finish EXIT
manifest() { find . \( -name .build -o -name DerivedData -o -name .git -o -name __pycache__ -o -name .swiftpm \) -prune -o -type f -print0 | sort -z | xargs -0 shasum -a 256; }
if [[ $snapshot == 1 ]]; then
  "$source_repo/scripts/make-public-snapshot.sh" "$real_dir/checkout"
  cd "$real_dir/checkout"
  echo "clean-checkout: public snapshot of $(git -C "$source_repo" rev-parse --short HEAD) ($(find . -type f | wc -l | tr -d ' ') files, no .git)"
  found="$(find . \( -name '.env' -o -name '.env.*' -o -name '*.p12' -o -name '*.mobileprovision' -o -name '*.pem' -o -name '*.key' -o -name '*.keychain-db' \) -print | head -1)"
  [[ -z "$found" ]] || { echo "clean-checkout: a private-looking file is in the snapshot: $found" >&2; exit 65; }
else
  git clone --no-local --quiet "$source_repo" "$real_dir/checkout"
  cd "$real_dir/checkout"
  git checkout --quiet "$(git -C "$source_repo" rev-parse HEAD)"
  echo "clean-checkout: cloned $(git rev-parse --short HEAD) ($(git ls-files | wc -l | tr -d ' ') files)"
  # No private developer file may be in a fresh checkout.
  for pattern in '.env' '.env.*' '*.p12' '*.mobileprovision' '*.pem' '*.key' '*.keychain-db'; do
    found="$(git ls-files "$pattern" | head -1)"
    [[ -z "$found" ]] || { echo "clean-checkout: a private-looking file is tracked: $found" >&2; exit 65; }
  done
fi
manifest > "$real_dir/manifest-before.txt"
echo "clean-checkout: environment reaching the build: HOME PATH TMPDIR (nothing else)"
set +e
env -i HOME="$HOME" PATH="/usr/bin:/bin:/usr/sbin:/sbin" TMPDIR="${TMPDIR:-/tmp}" ./scripts/ci.sh 2>&1 | tee "$log"
status=${PIPESTATUS[0]}
set -e
[[ $status == 0 ]] || { echo "clean-checkout: the CI steps FAILED in a clean clone (exit $status)" >&2; exit $status; }
manifest > "$real_dir/manifest-after.txt"
diff "$real_dir/manifest-before.txt" "$real_dir/manifest-after.txt" > "$real_dir/manifest.diff" || { echo "clean-checkout: the build or tests changed, added or removed source files:" >&2; head -20 "$real_dir/manifest.diff" >&2; exit 1; }
if [[ $snapshot == 0 ]]; then
  modified="$(git status --porcelain --untracked-files=no | wc -l | tr -d ' ')"
  [[ "$modified" == 0 ]] || { echo "clean-checkout: the build or tests changed tracked files ($modified)" >&2; git status --porcelain --untracked-files=no | head >&2; exit 1; }
fi
echo 'clean-checkout: ok — a fresh clone builds and passes the CI steps with no secrets in its environment'
