#!/bin/bash
# Build one architecture of Ring.app and pack it into a compressed DMG.
#
# Usage: scripts/package-dmg.sh <x86_64|arm64> <output.dmg>
#
# Calls scripts/build.sh with RING_ARCHS set to that single architecture.
# build.sh ad-hoc signs with `codesign --sign -`. This script does not
# notarize, does not use a Developer ID, and does not put a zip in the image.
#
# The DMG is created with `hdiutil create -format UDZO`. Its volume root is
# Ring.app (open the image and drag or run the app). After hdiutil returns,
# the script attaches that file and requires all of:
#   codesign --verify --strict
#   Signature=adhoc
#   lipo -archs equal to the requested architecture and nothing else
#
# RING_OUTPUT_DIR selects where Ring.app is written. It must stay inside the
# project. Default: <project>/build/package-<arch>
#
# hdiutil, codesign, and lipo are macOS tools. The release job runs this on
# the macos-26 runner; it is not expected to succeed on Linux.
set -euo pipefail

if [[ $# -ne 2 ]]; then
    echo "usage: scripts/package-dmg.sh <x86_64|arm64> <output.dmg>" >&2
    exit 1
fi

arch="$1"
dmg_arg="$2"

case "$arch" in
    x86_64|arm64) ;;
    *)
        echo "Architecture must be x86_64 or arm64 (one slice), got: ${arch}" >&2
        exit 1
        ;;
esac

# lipo -archs prints a space-separated list. Exactly one token must match.
require_exact_arch() {
    local raw="$1"
    local expected="$2"
    local where="$3"
    local count=0
    local only=""
    local slice
    set -f
    # Intentional split on whitespace: one token per architecture.
    # shellcheck disable=SC2086
    for slice in $raw; do
        count=$((count + 1))
        only="$slice"
    done
    set +f
    if [[ "$count" -ne 1 || "$only" != "$expected" ]]; then
        echo "${where}: expected lipo -archs to be exactly '${expected}', got: '${raw}'" >&2
        return 1
    fi
}

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/output-guard.sh
source "$ROOT/scripts/lib/output-guard.sh"

caller_pwd="$(pwd)"
mkdir -p -- "$(dirname -- "$dmg_arg")"
dmg="$(cd -- "$(dirname -- "$dmg_arg")" && pwd)/$(basename -- "$dmg_arg")"
case "$dmg" in
    *.dmg) ;;
    *)
        echo "Output must be a .dmg path, got: ${dmg}" >&2
        exit 1
        ;;
esac

if [[ -n "${RING_OUTPUT_DIR:-}" ]]; then
    case "$RING_OUTPUT_DIR" in
        /*) output_dir="$RING_OUTPUT_DIR" ;;
        *) output_dir="${caller_pwd}/${RING_OUTPUT_DIR}" ;;
    esac
else
    output_dir="${ROOT}/build/package-${arch}"
fi

# Refuse before deleting anything. build.sh also checks, but this script
# removes Ring.app and slices itself.
if ! ring_guard_output_dir "$ROOT" "$output_dir"; then
    echo "==> 已拒绝打包：输出目录必须在 ${ROOT} 内" >&2
    exit 2
fi

# build.sh always reuses <project>/build/scratch-release. Drop that scratch
# and the module caches first, after the same in-project check, so a second
# architecture cannot link objects compiled for the first. Do not follow a
# build/ symlink that leaves the project.
for cache_path in \
    "${ROOT}/build/scratch-release" \
    "${ROOT}/build/swift-module-cache" \
    "${ROOT}/build/clang-module-cache"
do
    if ! ring_guard_output_dir "$ROOT" "$cache_path"; then
        echo "==> 已拒绝清理构建缓存：${cache_path}" >&2
        exit 2
    fi
    rm -rf "$cache_path"
done

rm -rf "${output_dir}/Ring.app" "${output_dir}/slices"
mkdir -p -- "$output_dir"

cd "$ROOT"
echo "==> building ${arch} -> ${output_dir}"
RING_ARCHS="$arch" RING_OUTPUT_DIR="$output_dir" "${ROOT}/scripts/build.sh"

app="${output_dir}/Ring.app"
if [[ ! -d "${app}/Contents/MacOS" ]]; then
    echo "build.sh did not produce ${app}" >&2
    exit 1
fi

built_raw="$(lipo -archs "${app}/Contents/MacOS/Ring")"
require_exact_arch "$built_raw" "$arch" "build.sh"

stage_dir=""
mountpoint=""
cleanup() {
    if [[ -n "$mountpoint" ]]; then
        hdiutil detach "$mountpoint" >/dev/null 2>&1 \
            || hdiutil detach -force "$mountpoint" >/dev/null 2>&1 \
            || true
        rm -rf "$mountpoint"
        mountpoint=""
    fi
    if [[ -n "$stage_dir" ]]; then
        rm -rf "$stage_dir"
        stage_dir=""
    fi
}
trap cleanup EXIT

# A parent directory is required: hdiutil -srcfolder copies the folder's
# children onto the volume root. Passing Ring.app itself would unpack the
# bundle (Contents/ at the root) instead of leaving Ring.app.
# ditto keeps the bundle layout and the ad-hoc signature; a zip would not.
stage_dir="$(mktemp -d "${TMPDIR:-/tmp}/ring-dmg-stage.XXXXXX")"
ditto "$app" "${stage_dir}/Ring.app"

zip_in_stage="$(find "$stage_dir" -name '*.zip' -print)"
if [[ -n "$zip_in_stage" ]]; then
    echo "Refusing to put a zip inside the DMG" >&2
    printf '%s\n' "$zip_in_stage" >&2
    exit 1
fi

echo "==> hdiutil create -volname Ring -srcfolder ${stage_dir} -ov -format UDZO ${dmg}"
rm -f -- "$dmg"
hdiutil create \
    -volname "Ring" \
    -srcfolder "$stage_dir" \
    -ov \
    -format UDZO \
    "$dmg"

rm -rf "$stage_dir"
stage_dir=""

if [[ ! -s "$dmg" ]]; then
    echo "hdiutil did not create ${dmg}" >&2
    exit 1
fi

mountpoint="$(mktemp -d "${TMPDIR:-/tmp}/ring-dmg-mount.XXXXXX")"
echo "==> attaching ${dmg}"
hdiutil attach -nobrowse -readonly -mountpoint "$mountpoint" "$dmg"

bundled="${mountpoint}/Ring.app"
if [[ ! -d "${bundled}/Contents/MacOS" ]]; then
    echo "DMG is missing a top-level Ring.app bundle" >&2
    ls -la "$mountpoint" >&2
    exit 1
fi

zip_in_image="$(find "$mountpoint" -name '*.zip' -print)"
if [[ -n "$zip_in_image" ]]; then
    echo "DMG contains a zip:" >&2
    printf '%s\n' "$zip_in_image" >&2
    exit 1
fi

echo "==> codesign --verify --strict ${bundled}"
codesign --verify --strict "$bundled"
# Read codesign to completion, then match the saved text. Do not pipe
# codesign into grep -q; closing that pipe early is what aborted xcodebuild.
signature="$(codesign -dv "$bundled" 2>&1)"
printf '%s\n' "$signature"
if ! grep -q 'Signature=adhoc' <<< "$signature"; then
    echo "Expected Signature=adhoc" >&2
    exit 1
fi

binary="${bundled}/Contents/MacOS/Ring"
raw="$(lipo -archs "$binary")"
echo "lipo -archs: [${raw}]"
require_exact_arch "$raw" "$arch" "mounted DMG"

hdiutil detach "$mountpoint"
detached="$mountpoint"
mountpoint=""
rm -rf "$detached"

echo "==> verified ${dmg} (${arch}, adhoc)"
