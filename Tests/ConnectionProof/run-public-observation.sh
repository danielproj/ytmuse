#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
export E01_OBSERVATION_ROOT="$PWD/artifacts/harness/nodes/E01/observations"
swift test --package-path Packages/NativeMusic --scratch-path "$PWD/.build/e01" --filter ConnectionTests.liveAnonymousObservation
