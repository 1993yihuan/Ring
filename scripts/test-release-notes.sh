#!/bin/bash
# Checks scripts/release-notes.sh against what it actually promises: the two fixed sections,
# their order, at least one entry each, equal entry counts, and a short keyword list that
# keeps internal test and build reports out. It does not check meaning, so a human still
# reads the notes. Every refusal must exit 2 and print nothing on stdout, so a broken file
# can never leak a partial release body.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$ROOT/build/tmp/release-notes-test"
NOTES="$WORK/notes"
rm -rf "$WORK"
mkdir -p "$NOTES"

checks=0
failures=0
check() {
    local name="$1" ok="$2" detail="${3:-}"
    checks=$((checks + 1))
    if [ "$ok" = "1" ]; then
        printf 'PASS %s%s\n' "$name" "${detail:+ — $detail}"
    else
        printf 'FAIL %s%s\n' "$name" "${detail:+ — $detail}"
        failures=$((failures + 1))
    fi
}

render() { RING_RELEASE_NOTES_DIR="$NOTES" "$ROOT/scripts/release-notes.sh" "$1"; }

# 拒绝：退出码必须正好是 2，stdout 必须一个字节都没有，stderr 必须说原因。
expect_refusal() {
    local name="$1" tag="$2" code stdout_text stderr_text detail=""
    set +e
    stdout_text="$(render "$tag" 2>"$WORK/stderr")"
    code=$?
    set -e
    stderr_text="$(cat "$WORK/stderr")"
    [ "$code" -eq 2 ] || detail="退出码 ${code}，应为 2"
    [ -z "$stdout_text" ] || detail="${detail:+${detail}；}stdout 泄漏正文"
    [ -n "$stderr_text" ] || detail="${detail:+${detail}；}stderr 没说原因"
    check "$name（exit=2，stdout 为空）" "$([ -z "$detail" ] && echo 1 || echo 0)" "${detail:-$(printf '%s' "$stderr_text" | tail -1)}"
}

# 1. 仓库里每一版的正文都要能生成：中英条数一致，且尾句是中性的下载说明。
for file in "$ROOT"/docs/release-notes/v*.md; do
    tag="$(basename "$file" .md)"
    output=""
    if output="$(RING_RELEASE_NOTES_DIR="$ROOT/docs/release-notes" "$ROOT/scripts/release-notes.sh" "$tag" 2>&1)"; then
        zh="$(printf '%s\n' "$output" | awk '/^## 新增与改进/{f=1;next} /^## What/{f=0} f && /^- /{n++} END{print n+0}')"
        en="$(printf '%s\n' "$output" | awk '/^## What/{f=1;next} /^---$/{f=0} f && /^- /{n++} END{print n+0}')"
        links="$(printf '%s\n' "$output" | grep -c "/blob/$tag/README.md")"
        ok=0
        [ "$zh" -gt 0 ] && [ "$zh" = "$en" ] && [ "$links" -ge 1 ] && ok=1
        check "$tag 正文可生成，中英 $zh/$en 条，带该版 README 链接" "$ok" "$links 处链接"
    else
        check "$tag 正文可生成" 0 "$(printf '%s' "$output" | tail -1)"
    fi
done

# 2. 尾句不把今天的打包方式写进历史版本。
good="v9.9.8"
cat > "$NOTES/$good.md" <<'EOF'
## 新增与改进

- 中文条目一
- 中文条目二

## What's New & Improved

- English entry one
- English entry two
EOF
if output="$(render "$good" 2>&1)"; then
    check "格式正确时生成正文" 1
    printf '%s\n' "$output" | grep -q "## 新增与改进" \
        && check "正文保留中文小节" 1 || check "正文保留中文小节" 0
    printf '%s\n' "$output" | grep -q "## What's New & Improved" \
        && check "正文保留英文小节" 1 || check "正文保留英文小节" 0
    printf '%s\n' "$output" | grep -q "从下方附件下载" && ! printf '%s\n' "$output" | grep -q "DMG" \
        && check "尾句是中性的下载说明，不写 DMG 或机型" 1 \
        || check "尾句是中性的下载说明，不写 DMG 或机型" 0 "$(printf '%s\n' "$output" | tail -2 | tr '\n' ' ')"
else
    check "格式正确时生成正文" 0 "$(printf '%s' "$output" | tail -1)"
fi

# 3. 七条规则各一个用例，外加英文内部报告一条。
cat > "$NOTES/v9.9.7.md" <<'EOF'
## What's New & Improved

- English entry

## 新增与改进

- 中文条目
EOF
expect_refusal "小节顺序颠倒" "v9.9.7"

cat > "$NOTES/v9.9.6.md" <<'EOF'
## 新增与改进

- 中文条目

## What's New & Improved

- English entry

## 下载与升级

- 多出来的小节
EOF
expect_refusal "多出第三个小节" "v9.9.6"

cat > "$NOTES/v9.9.5.md" <<'EOF'
## 新增与改进

- 中文条目

## What's New & Improved

- English entry

这一版还顺手整理了仓库。
EOF
expect_refusal "小节外多出说明文字" "v9.9.5"

cat > "$NOTES/v9.9.4.md" <<'EOF'
## 新增与改进

## What's New & Improved

- English entry
EOF
expect_refusal "中文小节没有条目" "v9.9.4"

cat > "$NOTES/v9.9.3.md" <<'EOF'
## 新增与改进

- 中文条目一
- 中文条目二

## What's New & Improved

- English entry one
EOF
expect_refusal "中英条数不一致" "v9.9.3"

cat > "$NOTES/v9.9.2.md" <<'EOF'
## 新增与改进

- 中文条目
- 测试 214 个测试全部通过

## What's New & Improved

- English entry one
- English entry two
EOF
expect_refusal "混入中文内部测试信息" "v9.9.2"

cat > "$NOTES/v9.9.1.md" <<'EOF'
## 新增与改进

- 中文条目
- 中文条目二

## What's New & Improved

- English entry one
- 214 tests passed, 0 failures
EOF
expect_refusal "混入英文内部测试信息" "v9.9.1"

expect_refusal "缺少该版本的说明文件" "v9.9.9"

if [ "$failures" -eq 0 ]; then
    echo "== $checks 项检查全部通过（9 版正文 + 1 个正确样例 3 项 + 8 个拒绝用例）"
else
    echo "== 失败 $failures 项（共 $checks 项检查）"
    exit 1
fi
