#!/bin/bash
set -euo pipefail
[[ "$(uname -m)" == arm64 ]]
[[ "$(xcodebuild -version)" == $'Xcode 27.2\nBuild version 27B52' ]]
[[ "$(swift --version)" == *'Apple Swift version 6.4.2 '* ]]
[[ "$(xcrun --sdk macosx --show-sdk-version)" == 27.2 ]]
