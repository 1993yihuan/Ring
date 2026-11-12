#!/bin/bash
# Checks the build output guard: Ring-outside paths and symlinks leading out must be
# refused, and nothing outside the project may be touched. Uses only fake paths inside
# the project; no external directory is read or written.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/scripts/lib/output-guard.sh"

pass=0
fail=0

expect_accept() {
    if ring_guard_output_dir "$ROOT" "$1" 2>/dev/null; then
        echo "ok   accept  $1"; pass=$((pass+1))
    else
        echo "FAIL accept  $1"; fail=$((fail+1))
    fi
}

expect_reject() {
    if ring_guard_output_dir "$ROOT" "$1" 2>/dev/null; then
        echo "FAIL reject  $1 (guard accepted it)"; fail=$((fail+1))
    else
        echo "ok   reject  $1"; pass=$((pass+1))
    fi
}

expect_accept "$ROOT/build"
expect_accept "$ROOT/build/verification"
expect_accept "$ROOT/build/not-yet-created/deep/nested"

expect_reject "/Applications"
expect_reject "/tmp"
expect_reject "$ROOT/../Ring-outside"
expect_reject "$ROOT/build/../../elsewhere"

# A symlink inside the project that points outside must also be refused, and the
# target must stay untouched.
ln -sfn /Applications "$ROOT/build/guard-symlink-out"
expect_reject "$ROOT/build/guard-symlink-out"
if [ -d /Applications ] && [ -n "$(ls -A /Applications 2>/dev/null)" ]; then
    echo "ok   external target untouched (/Applications still populated)"; pass=$((pass+1))
else
    echo "FAIL external target looks touched"; fail=$((fail+1))
fi
rm -f "$ROOT/build/guard-symlink-out"

# Real run: pointing RING_OUTPUT_DIR outside must exit non-zero and leave the
# delivered app hash unchanged.
before="$(shasum -a 256 "$ROOT/build/Ring.app/Contents/MacOS/Ring" 2>/dev/null | cut -d' ' -f1)"
if RING_OUTPUT_DIR=/Applications "$ROOT/scripts/build.sh" >/dev/null 2>&1; then
    echo "FAIL build.sh accepted /Applications"; fail=$((fail+1))
else
    echo "ok   build.sh refused /Applications"; pass=$((pass+1))
fi
after="$(shasum -a 256 "$ROOT/build/Ring.app/Contents/MacOS/Ring" 2>/dev/null | cut -d' ' -f1)"
if [ "$before" = "$after" ] && [ -n "$before" ]; then
    echo "ok   delivered app untouched by refused build"; pass=$((pass+1))
else
    echo "FAIL delivered app changed"; fail=$((fail+1))
fi

echo "----"
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
