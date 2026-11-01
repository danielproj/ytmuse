#!/bin/bash
# Builds the Debug and Release app products the W19 isolation proof inspects (static + built-binary checks). No tests run here.
set -euo pipefail
cd "$(dirname "$0")/.."
derived="${BUILD_DIR:-$PWD/.build/xcode}"
for configuration in Debug Release; do
  xcodebuild -project App/NativeMusic.xcodeproj -scheme NativeMusic -configuration "$configuration" -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath "$derived" -disableAutomaticPackageResolution build > /dev/null
done
