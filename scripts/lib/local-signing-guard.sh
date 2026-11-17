#!/bin/bash
# A published package must state nothing about a local signing identity: one key, or a key with
# an empty value, is still a promise this Mac made about its own identity, and a DMG carrying it
# would hand that promise to everyone who downloads it.

# Returns 0 when <app> states no RingLocalSigning* key, 1 otherwise. Never writes.
ring_reject_local_signing_keys() {
    local app="$1"
    local where="${2:-$1}"
    local plist="${app}/Contents/Info.plist"
    if [[ ! -f "$plist" ]]; then
        printf 'Ring: %s 没有 Contents/Info.plist\n' "$where" >&2
        return 1
    fi
    local dump
    dump="$(/usr/bin/plutil -p "$plist" 2>&1)" || {
        printf 'Ring: 无法读取 %s 的 Info.plist：%s\n' "$where" "$dump" >&2
        return 1
    }
    if grep -q '"RingLocalSigning' <<< "$dump"; then
        printf 'Ring: %s 带有本机签名策略键，拒绝发布：\n' "$where" >&2
        grep '"RingLocalSigning' <<< "$dump" >&2
        return 1
    fi
    return 0
}
