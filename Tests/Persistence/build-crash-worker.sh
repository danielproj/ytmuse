#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
products="$PWD/Packages/NativeMusic/.build/debug"
mkdir -p .build/w03
swiftc -parse-as-library -target arm64-apple-macos27.0 -I "$products" -L "$products" -lDomain -lsqlite3 Packages/NativeMusic/Sources/Persistence/*.swift Tests/Persistence/CrashWorker.swift -o .build/w03/crash-worker
