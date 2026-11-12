#!/bin/bash
# Derives the standard iconset from the chosen source PNG and packs Ring.icns.
# The source image is read-only here: it is never resized in place or replaced.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE="$ROOT/assets/icon/ring-icon-v1.png"
WORK="$ROOT/build/icon"
ICONSET="$WORK/Ring.iconset"
OUTPUT="$ROOT/Packaging/Ring.icns"

[ -f "$SOURCE" ] || { echo "缺少源图：$SOURCE" >&2; exit 1; }

rm -rf "$WORK"
mkdir -p "$ICONSET"

# name:size pairs required by iconutil
for pair in icon_16x16:16 icon_16x16@2x:32 icon_32x32:32 icon_32x32@2x:64 \
            icon_128x128:128 icon_128x128@2x:256 icon_256x256:256 icon_256x256@2x:512 \
            icon_512x512:512 icon_512x512@2x:1024; do
    name="${pair%%:*}"
    size="${pair##*:}"
    sips -s format png -z "$size" "$size" "$SOURCE" --out "$ICONSET/$name.png" >/dev/null
done

count="$(find "$ICONSET" -name '*.png' | wc -l | tr -d ' ')"
if [ "$count" -ne 10 ]; then
    echo "iconset 尺寸不完整：期望 10 个，实际 $count" >&2
    exit 1
fi

iconutil -c icns "$ICONSET" -o "$OUTPUT"

# Re-open the packed icns and confirm it still yields the full standard set.
CHECK="$WORK/verify/Ring.iconset"
rm -rf "$WORK/verify"
mkdir -p "$WORK/verify"
iconutil -c iconset "$OUTPUT" -o "$CHECK"
verify_count="$(find "$CHECK" -name '*.png' | wc -l | tr -d ' ')"
if [ "$verify_count" -ne 10 ]; then
    echo "icns 校验失败：解出的尺寸数量为 $verify_count" >&2
    exit 1
fi

echo "==> 源图：$SOURCE"
sips -g pixelWidth -g pixelHeight "$SOURCE" | sed -n '2,3p'
echo "==> iconset：$ICONSET（$count 个尺寸）"
echo "==> icns：$OUTPUT"
ls -l "$OUTPUT"
