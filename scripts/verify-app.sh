#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
app="${1:-.build/xcode/Build/Products/Release/YTMuse.app}"
binary="$app/Contents/MacOS/YTMuse"
[[ "$(lipo -archs "$binary")" == arm64 ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$app/Contents/Info.plist")" == 27.0 ]]
xcrun vtool -show-build "$binary"
otool -L "$binary"
if find "$app" -type f | /usr/bin/grep -Ei '(electron|chromium|python|node_modules|webkit|\.py$|\.js$)'; then
  echo 'Unexpected bundled runtime' >&2
  exit 1
fi
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$app/Contents/Info.plist")" == YTMuse ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleName' "$app/Contents/Info.plist")" == YTMuse ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconFile' "$app/Contents/Info.plist")" == YTMuse ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconName' "$app/Contents/Info.plist")" == YTMuse ]]
[[ -s "$app/Contents/Resources/Assets.car" && -s "$app/Contents/Resources/YTMuse.icns" ]]
cmp Resources/Brand/Glass-v2/YTMuseGlass.icns "$app/Contents/Resources/YTMuseGlass.icns"
xcrun assetutil --info "$app/Contents/Resources/Assets.car" | python3 -c '
import json,sys
assets=json.load(sys.stdin)
stacks=[x for x in assets if x.get("AssetType")=="IconImageStack" and x.get("Name")=="YTMuse"]
assert {x.get("Appearance") for x in stacks} >= {"NSAppearanceNameAqua", "NSAppearanceNameDarkAqua", "ISAppearanceTintable"}
assert any(x.get("AssetType")=="Vector" and "Musical-M" in x.get("Name", "") for x in assets)
print("PASS: compiled native icon stacks (Aqua/Dark/Tintable) and musical M foreground")
'
for resource in YTMuseMenuTemplate.png YTMuseMenuTemplate@2x.png; do
  cmp "Resources/Brand/$resource" "$app/Contents/Resources/$resource"
done
[[ ! -e "$app/Contents/Resources/Brand" ]]
codesign --verify --deep --strict "$app"
echo 'PASS: arm64, macOS 27 floor, native bundle and valid local signature'
