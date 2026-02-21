#!/usr/bin/env bash
# 从 schema/protocol/v{PROTOCOL_VERSION}/action_rules.csv 生成 Swift 侧 action 规则表
#
# 用法：
#   ./scripts/tools/gen_protocol_action_swift_rules.sh
#   ./scripts/tools/gen_protocol_action_swift_rules.sh --check

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$PROJECT_ROOT"

PROTOCOL_FILE="core/src/server/protocol/mod.rs"
PROTOCOL_VERSION="$(
    sed -n 's/^pub const PROTOCOL_VERSION: u32 = \([0-9][0-9]*\);/\1/p' "$PROTOCOL_FILE" | head -n1
)"
SCHEMA_FILE="schema/protocol/v${PROTOCOL_VERSION}/action_rules.csv"
TARGET_FILE="app/TidyFlow/Networking/WSClient+Send.swift"
BEGIN_MARKER="// BEGIN AUTO-GENERATED: protocol_action_rules"
END_MARKER="// END AUTO-GENERATED: protocol_action_rules"

MODE="write"
if [ "${1:-}" = "--check" ]; then
    MODE="check"
fi

if [ ! -f "$SCHEMA_FILE" ]; then
    echo "[gen_swift_rules] ERROR: 未找到 $SCHEMA_FILE"
    exit 1
fi
if [ ! -f "$TARGET_FILE" ]; then
    echo "[gen_swift_rules] ERROR: 未找到 $TARGET_FILE"
    exit 1
fi

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

exact_rules="$tmp_dir/exact.rules"
prefix_rules="$tmp_dir/prefix.rules"
contains_rules="$tmp_dir/contains.rules"
block_file="$tmp_dir/block.swift"
generated_file="$tmp_dir/WSClient+Send.swift"

> "$exact_rules"
> "$prefix_rules"
> "$contains_rules"

trim() {
    echo "$1" | sed -E 's/^[[:space:]]+|[[:space:]]+$//g'
}

line_no=0
while IFS= read -r line || [ -n "$line" ]; do
    line_no=$((line_no + 1))
    raw="$(trim "$line")"
    [ -z "$raw" ] && continue
    case "$raw" in
        \#*) continue ;;
    esac

    IFS=',' read -r kind domain value extra <<< "$raw"
    kind="$(trim "${kind:-}")"
    domain="$(trim "${domain:-}")"
    value="$(trim "${value:-}")"
    extra="$(trim "${extra:-}")"

    if [ -n "$extra" ] || [ -z "$kind" ] || [ -z "$domain" ] || [ -z "$value" ]; then
        echo "[gen_swift_rules] ERROR: CSV 格式错误 (line $line_no): $line"
        exit 1
    fi

    case "$kind" in
        exact) echo "        (\"$domain\", \"$value\")," >> "$exact_rules" ;;
        prefix) echo "        (\"$domain\", \"$value\")," >> "$prefix_rules" ;;
        contains) echo "        (\"$domain\", \"$value\")," >> "$contains_rules" ;;
        *)
            echo "[gen_swift_rules] ERROR: 不支持的 kind '$kind' (line $line_no)"
            exit 1
            ;;
    esac
done < "$SCHEMA_FILE"

cat > "$block_file" <<EOF
    $BEGIN_MARKER
    private var protocolExactRules: [(domain: String, action: String)] {
        [
$(cat "$exact_rules")
        ]
    }

    private var protocolPrefixRules: [(domain: String, prefix: String)] {
        [
$(cat "$prefix_rules")
        ]
    }

    private var protocolContainsRules: [(domain: String, needle: String)] {
        [
$(cat "$contains_rules")
        ]
    }
    $END_MARKER
EOF

if ! rg -q "$BEGIN_MARKER" "$TARGET_FILE" || ! rg -q "$END_MARKER" "$TARGET_FILE"; then
    echo "[gen_swift_rules] ERROR: 未找到生成标记，请先在 $TARGET_FILE 中添加:"
    echo "  $BEGIN_MARKER"
    echo "  $END_MARKER"
    exit 1
fi

awk -v begin="$BEGIN_MARKER" -v end="$END_MARKER" -v block_file="$block_file" '
BEGIN {
    while ((getline line < block_file) > 0) {
        block = block line ORS
    }
    close(block_file)
}
{
    if (index($0, begin) > 0) {
        print block
        in_block = 1
        next
    }
    if (in_block == 1) {
        if (index($0, end) > 0) {
            in_block = 0
            skip_next_blank = 1
        }
        next
    }
    if (skip_next_blank == 1) {
        skip_next_blank = 0
        if ($0 == "") {
            next
        }
    }
    print $0
}
' "$TARGET_FILE" > "$generated_file"

if [ "$MODE" = "check" ]; then
    if ! diff -u "$TARGET_FILE" "$generated_file" > "$tmp_dir/diff.out"; then
        echo "[gen_swift_rules] ERROR: Swift 规则未同步，请先执行："
        echo "  ./scripts/tools/gen_protocol_action_swift_rules.sh"
        cat "$tmp_dir/diff.out"
        exit 1
    fi
    echo "[gen_swift_rules] OK: Swift action 规则与 schema 同步"
    exit 0
fi

cp "$generated_file" "$TARGET_FILE"
echo "[gen_swift_rules] Generated block in: $TARGET_FILE"
