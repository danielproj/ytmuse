#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
swift build --package-path Packages/NativeMusic
mkdir -p .build/w05
products="$PWD/Packages/NativeMusic/.build/debug"
swiftc -parse-as-library -target arm64-apple-macos27.0 -I "$products" -L "$products" -lQueue -lPersistence -lDomain -lsqlite3 Packages/NativeMusic/Tests/QueueTests/Workers/CrashWorker.swift -o .build/w05/crash-worker
