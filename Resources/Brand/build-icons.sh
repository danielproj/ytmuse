#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p YTMuse.iconset
for points in 16 32 128 256 512; do
  for scale in 1 2; do
    pixels=$((points * scale))
    suffix=""
    if [[ "$scale" == 2 ]]; then suffix="@2x"; fi
    sips -z "$pixels" "$pixels" YTMuse-AppIcon-master-v1.png --out "YTMuse.iconset/icon_${points}x${points}${suffix}.png" >/dev/null
  done
done
iconutil -c icns YTMuse.iconset -o YTMuse.icns
sips -z 18 18 YTMuse-MenuTemplate-master-v1.png --out YTMuseMenuTemplate.png >/dev/null
sips -z 36 36 YTMuse-MenuTemplate-master-v1.png --out YTMuseMenuTemplate@2x.png >/dev/null
