#!/bin/bash
# Prints the GitHub Release body for one tag, or refuses to.
#
# The body is docs/release-notes/<tag>.md: the same two sections every time, Chinese
# first and English second, one entry per change in each. After them this script adds
# one short download line per language, so no release carries the old install tutorial.
# A missing file, a missing section, an unbalanced entry count or an internal report
# line fails the release; there is no fallback to generated install text.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NOTES_DIR="${RING_RELEASE_NOTES_DIR:-$ROOT/docs/release-notes}"
TAG="${1:-}"

usage() { echo "用法：scripts/release-notes.sh <tag>；tag 形如 v0.1.10。" >&2; }
fail() { echo "拒绝生成发布说明：$1" >&2; exit 2; }

[ -n "$TAG" ] || { usage; exit 2; }
[[ "$TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || { usage; fail "“$TAG” 不是 vX.Y.Z 形式的版本标签"; }

FILE="$NOTES_DIR/$TAG.md"
if [ ! -f "$FILE" ]; then
    fail "缺少 $TAG 的发布说明（$FILE）。先按 docs/release-notes/README.md 的格式写这一版，不会退回安装说明。"
fi

zh_section=0
en_section=0
zh_entries=0
en_entries=0
section=""
line_no=0
while IFS= read -r line || [ -n "$line" ]; do
    line_no=$((line_no + 1))
    case "$line" in
        "## 新增与改进")
            [ -z "$section" ] || fail "第 $line_no 行：小节顺序不对，先「## 新增与改进」，再「## What's New & Improved」"
            section="zh"; zh_section=1 ;;
        "## What's New & Improved")
            [ "$section" = "zh" ] || fail "第 $line_no 行：缺少「## 新增与改进」，或标题重复"
            section="en"; en_section=1 ;;
        "")
            ;;
        "## "*|"# "*)
            fail "第 $line_no 行：只允许两个小节标题，多出「$line」" ;;
        "- "*)
            case "$section" in
                zh) zh_entries=$((zh_entries + 1)) ;;
                en) en_entries=$((en_entries + 1)) ;;
                *) fail "第 $line_no 行：条目必须写在小节标题下面" ;;
            esac
            case "$line" in
                *个测试*|*独立复验*|*测试*通过*|*build\ [0-9]*|*sha256:*|*tests\ passed*|*test\ suite*|*all\ tests*)
                    fail "第 $line_no 行：内部测试、构建或摘要信息不属于发布说明——$line" ;;
            esac ;;
        *)
            fail "第 $line_no 行：只允许小节标题和「- 」条目，这里是「$line」" ;;
    esac
done < "$FILE"

[ "$zh_section" = 1 ] || fail "缺少「## 新增与改进」小节"
[ "$en_section" = 1 ] || fail "缺少「## What's New & Improved」小节"
[ "$zh_entries" -gt 0 ] || fail "「## 新增与改进」没有条目"
[ "$en_entries" -gt 0 ] || fail "「## What's New & Improved」没有条目"
[ "$zh_entries" = "$en_entries" ] || fail "中英文条目数不一致：中文 $zh_entries 条，英文 $en_entries 条"

cat "$FILE"
# Neutral on purpose: early versions shipped a universal zip, later ones two DMGs. Naming
# the assets here would put today's packaging into an old version's notes.
cat <<EOF

---

下载与安装：从下方附件下载，安装步骤见 [${TAG} 使用说明](https://github.com/1993yihuan/Ring/blob/${TAG}/README.md)。安装包未做公证，首次打开如被 macOS 拦截，请按说明放行。

Download and install: use the assets below; setup steps are in the [${TAG} README](https://github.com/1993yihuan/Ring/blob/${TAG}/README.md). The build is not notarized, so follow that page if macOS blocks the first launch.
EOF
