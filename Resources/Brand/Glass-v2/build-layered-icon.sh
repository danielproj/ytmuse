#!/bin/bash
# Render the actual layered document with the selected Xcode's bundled renderer.
set -euo pipefail
cd "$(dirname "$0")/../../.."
output="${1:-artifacts/harness/nodes/V01/raw/final-icons}"
mkdir -p "$output"
composer="$(xcode-select -p)/../Applications/Icon Composer.app/Contents/Executables/ictool"
for mode in Default Dark Mono; do
  for size in 16 32 64 128 256 512 1024; do
    "$composer" Resources/Brand/Glass-v2/YTMuse.icon --export-image --output-file "$output/$mode-$size.png" --platform macOS --rendition "$mode" --width "$size" --height "$size" --scale 1
  done
done
