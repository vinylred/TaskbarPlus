#!/bin/bash
# Unit tests for the pure logic (no app, no private APIs). Builds a tiny test binary.
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p .build-direct
swiftc -O -target arm64-apple-macosx14.0 \
    Sources/TaskbarPlus/SpaceLayout.swift Sources/TaskbarPlus/Updater.swift \
    Tests/SpaceLayoutTests/main.swift \
    -o .build-direct/SpaceLayoutTests
.build-direct/SpaceLayoutTests
