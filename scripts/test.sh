#!/bin/bash
# Runs the reproducible test suite with all caches inside the project.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD="$ROOT/build"
export TMPDIR="$BUILD/tmp"
export CLANG_MODULE_CACHE_PATH="$BUILD/clang-module-cache"
export SWIFT_MODULE_CACHE_PATH="$BUILD/swift-module-cache"
mkdir -p "$TMPDIR" "$CLANG_MODULE_CACHE_PATH" "$SWIFT_MODULE_CACHE_PATH"
# Setting TMPDIR does not move FileManager.temporaryDirectory in this process (measured).
# The test target also falls back to <project>/build/test-data on its own, so this
# variable only pins the location explicitly.
export RING_TEST_DATA_DIR="$BUILD/test-data"
mkdir -p "$RING_TEST_DATA_DIR"
rm -rf "$RING_TEST_DATA_DIR"/RingTests-* 2>/dev/null || true

swift test --scratch-path "$BUILD/scratch-test" \
    --cache-path "$BUILD/swiftpm-cache" \
    --config-path "$BUILD/swiftpm-config" \
    --security-path "$BUILD/swiftpm-security" 2>&1 | tee "$BUILD/test.log"
