#!/bin/bash
# Checks the public package guard: a bundle that states any local signing policy key must be
# refused, including a single key and a key with an empty value. Uses only fake bundles inside
# the project; nothing outside is read or written.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/scripts/lib/local-signing-guard.sh"

fixtures="$ROOT/build/local-signing-guard-test"
rm -rf "$fixtures"
mkdir -p "$fixtures"

pass=0
fail=0

# make_app <name> [key=value]...
make_app() {
    local name="$1"
    shift
    local app="$fixtures/$name/Ring.app"
    mkdir -p "$app/Contents/MacOS"
    cp "$ROOT/Packaging/Info.plist" "$app/Contents/Info.plist"
    local pair key value
    for pair in "$@"; do
        key="${pair%%=*}"
        value="${pair#*=}"
        /usr/libexec/PlistBuddy -c "Add :${key} string ${value}" "$app/Contents/Info.plist" >/dev/null
    done
    printf '%s\n' "$app"
}

expect_accept() {
    local label="$1"
    local app="$2"
    if ring_reject_local_signing_keys "$app" "$label" 2>/dev/null; then
        echo "ok   accept  $label"; pass=$((pass+1))
    else
        echo "FAIL accept  $label"; fail=$((fail+1))
    fi
}

expect_reject() {
    local label="$1"
    local app="$2"
    if ring_reject_local_signing_keys "$app" "$label" 2>/dev/null; then
        echo "FAIL reject  $label (guard accepted it)"; fail=$((fail+1))
    else
        echo "ok   reject  $label"; pass=$((pass+1))
    fi
}

sha1="0123456789ABCDEF0123456789ABCDEF01234567"
sha256="0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF"

expect_accept "公开包（无策略键）" "$(make_app public)"
expect_reject "两个策略键" "$(make_app both "RingLocalSigningIdentitySHA1=${sha1}" "RingLocalSigningCertificateSHA256=${sha256}")"
expect_reject "只有身份键" "$(make_app identity "RingLocalSigningIdentitySHA1=${sha1}")"
expect_reject "只有证书键" "$(make_app certificate "RingLocalSigningCertificateSHA256=${sha256}")"
expect_reject "身份键空值" "$(make_app empty "RingLocalSigningIdentitySHA1=")"

missing="$fixtures/missing/Ring.app"
mkdir -p "$missing"
expect_reject "缺少 Info.plist" "$missing"

rm -rf "$fixtures"

echo "----"
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
