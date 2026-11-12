#!/bin/bash
# Minimal guard for build output locations: the build script deletes and recreates
# <output>/Ring.app, so the output must physically live inside the project.

# Physical path of a possibly non-existent path: resolve the deepest existing
# ancestor (following symlinks) and re-append the rest.
ring_resolve_physical() {
    local path="$1"
    local tail=""
    while [ ! -e "$path" ]; do
        local base
        base="$(basename "$path")"
        if [ "$base" = "/" ] || [ "$base" = "." ]; then
            break
        fi
        tail="/$base$tail"
        path="$(dirname "$path")"
    done
    local resolved
    resolved="$(cd -P "$path" 2>/dev/null && pwd -P)" || return 1
    printf '%s%s' "$resolved" "$tail"
}

# Returns 0 when <candidate> is inside <root>, 1 otherwise. Never touches files.
ring_guard_output_dir() {
    local root="$1"
    local candidate="$2"
    local root_phys candidate_phys
    root_phys="$(cd -P "$root" 2>/dev/null && pwd -P)" || {
        printf 'Ring: 无法解析项目根：%s\n' "$root" >&2
        return 1
    }
    candidate_phys="$(ring_resolve_physical "$candidate")" || {
        printf 'Ring: 无法解析输出目录：%s\n' "$candidate" >&2
        return 1
    }
    case "$candidate_phys" in
        "$root_phys"/*) return 0 ;;
        *)
            printf 'Ring: 拒绝输出到项目外：%s（解析为 %s，项目根 %s）\n' \
                "$candidate" "$candidate_phys" "$root_phys" >&2
            return 1
            ;;
    esac
}
