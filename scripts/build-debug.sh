#!/bin/bash
# Builds the Debug app (no tests run) into the same derived data the UI runs use. Capped like every other build (scripts/bin first on PATH).
set -euo pipefail
cd "$(dirname "$0")/.."
export PATH="$PWD/scripts/bin:$PATH"
./scripts/check-toolchain.sh
derived="${BUILD_DIR:-$PWD/.build/xcode}"
xcodebuild -project App/NativeMusic.xcodeproj -scheme NativeMusic -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath "$derived" -disableAutomaticPackageResolution build "$@"
