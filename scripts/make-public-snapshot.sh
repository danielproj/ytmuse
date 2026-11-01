#!/bin/bash
# W30 (SEC10, BUILD03): builds the publishable source snapshot in a NEW directory and scans it.
#   scripts/make-public-snapshot.sh /absolute/path/to/new-empty-dir
# The snapshot is `git archive HEAD` minus Docs/public-snapshot-excludes.txt, plus the few harness files the tests read (Docs/public-snapshot-keep.txt). It has no history and no .git. Nothing is pushed, published or created
# anywhere else; the directory is the only thing written, and it must not exist yet (so nothing of anyone else's can be deleted or overwritten).
set -euo pipefail
cd "$(dirname "$0")/.."
root="$PWD"
dest="${1:-}"
[[ -n "$dest" && "$dest" == /* ]] || { echo 'usage: make-public-snapshot.sh /absolute/path/to/new-directory' >&2; exit 64; }
[[ ! -e "$dest" ]] || { echo "refusing: $dest already exists" >&2; exit 65; }
case "$dest/" in "$root"/*) echo 'refusing: the snapshot must be outside the repository' >&2; exit 65;; esac
git diff --quiet HEAD -- . || { echo 'refusing: uncommitted changes (the snapshot is built from HEAD)' >&2; exit 66; }
mkdir -p "$dest"
git archive HEAD | tar -x -C "$dest"
while IFS= read -r line; do
  [[ -z "$line" || "$line" == \#* ]] && continue
  [[ "$line" != /* && "$line" != *..* ]] || { echo "bad exclude: $line" >&2; exit 65; }
  rm -rf "$dest/$line"
done < Docs/public-snapshot-excludes.txt
# The few harness files the tests and scripts read are put back (Docs/public-snapshot-keep.txt): artifacts/ is excluded as a whole, but a snapshot whose tests fail is not a snapshot.
keep=()
while IFS= read -r line; do [[ -z "$line" || "$line" == \#* ]] && continue; [[ "$line" != /* && "$line" != *..* ]] || { echo "bad keep path: $line" >&2; exit 65; }; keep+=("$line"); done < Docs/public-snapshot-keep.txt
if [[ ${#keep[@]} -gt 0 ]]; then git archive HEAD -- "${keep[@]}" | tar -x -C "$dest"; fi
python3 scripts/scan-repository.py --tree-dir "$dest" --fail-on medium
echo "snapshot ready: $dest ($(find "$dest" -type f | wc -l | tr -d ' ') files). Nothing was published."
