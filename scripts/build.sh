#!/bin/bash
# Builds Ring.app as a Universal 2 bundle inside this project.
# Every output and cache path stays under <project>/build.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD="$ROOT/build"
# RING_OUTPUT_DIR lets an independent rebuild land elsewhere inside the project
# (for example build/verification) instead of replacing a delivered app.
OUTPUT="${RING_OUTPUT_DIR:-$BUILD}"

# shellcheck source=lib/output-guard.sh
source "$ROOT/scripts/lib/output-guard.sh"
# Checked before anything is deleted: this script removes <output>/Ring.app, so a
# path outside the project (or a symlink leading out) must be refused outright.
if ! ring_guard_output_dir "$ROOT" "$OUTPUT"; then
    echo "==> 已拒绝构建：输出目录必须在 $ROOT 内" >&2
    exit 2
fi

APP="$OUTPUT/Ring.app"
DEPLOYMENT_TARGET="${RING_DEPLOYMENT_TARGET:-13.0}"

export TMPDIR="$BUILD/tmp"
export CLANG_MODULE_CACHE_PATH="$BUILD/clang-module-cache"
export SWIFT_MODULE_CACHE_PATH="$BUILD/swift-module-cache"
mkdir -p "$TMPDIR" "$CLANG_MODULE_CACHE_PATH" "$SWIFT_MODULE_CACHE_PATH"

# SwiftPM keeps its own caches outside --scratch-path unless told otherwise.
SPM_PATHS=(--cache-path "$BUILD/swiftpm-cache"
           --config-path "$BUILD/swiftpm-config"
           --security-path "$BUILD/swiftpm-security")

ARCHS="${RING_ARCHS:-x86_64 arm64}"

for arch in $ARCHS; do
    triple="$arch-apple-macos$DEPLOYMENT_TARGET"
    echo "==> compiling $arch ($triple)"
    swift build --scratch-path "$BUILD/scratch-release" -c release "${SPM_PATHS[@]}" \
        -Xswiftc -target -Xswiftc "$triple" \
        -Xcc -target -Xcc "$triple"
    bin_dir="$(swift build --scratch-path "$BUILD/scratch-release" -c release "${SPM_PATHS[@]}" --show-bin-path \
        -Xswiftc -target -Xswiftc "$triple" -Xcc -target -Xcc "$triple")"
    mkdir -p "$OUTPUT/slices/$arch"
    cp "$bin_dir/Ring" "$OUTPUT/slices/$arch/Ring"
    lipo -info "$OUTPUT/slices/$arch/Ring"
done

echo "==> merging slices"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
lipo -create $(for arch in $ARCHS; do printf "%s " "$OUTPUT/slices/$arch/Ring"; done) -output "$APP/Contents/MacOS/Ring"
chmod +x "$APP/Contents/MacOS/Ring"
cp "$ROOT/Packaging/Info.plist" "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "==> bundling app icon"
if [ ! -f "$ROOT/Packaging/Ring.icns" ]; then
    echo "缺少图标资源：$ROOT/Packaging/Ring.icns（先运行 scripts/make-icon.sh）" >&2
    exit 1
fi
cp "$ROOT/Packaging/Ring.icns" "$APP/Contents/Resources/Ring.icns"

echo "==> ad-hoc signing the bundle"
codesign --force --sign - --timestamp=none "$APP"

echo "==> verifying"
lipo -info "$APP/Contents/MacOS/Ring"
file "$APP/Contents/MacOS/Ring"
codesign --verify --strict "$APP"
codesign -dv "$APP" 2>&1 | grep -E 'Identifier|Signature|Format' || true

echo "==> icon"
ls -l "$APP/Contents/Resources/Ring.icns"
/usr/libexec/PlistBuddy -c 'Print :CFBundleIconFile' "$APP/Contents/Info.plist"

echo "==> bundled binaries (must each be universal)"
find "$APP" -type f -perm -111 -print0 | while IFS= read -r -d '' f; do
    printf '%s: ' "${f#$APP/}"
    lipo -archs "$f"
done

echo "==> done: $APP"
echo "==> output dir: $OUTPUT"
