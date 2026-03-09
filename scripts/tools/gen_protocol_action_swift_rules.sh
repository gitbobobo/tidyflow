#!/usr/bin/env bash
# 从 schema/protocol/v{PROTOCOL_VERSION}/action_rules.csv 生成 Swift/JS 侧 action 规则表
#
# 用法：
#   ./scripts/tools/gen_protocol_action_swift_rules.sh
#   ./scripts/tools/gen_protocol_action_swift_rules.sh --check

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$PROJECT_ROOT"

source "$PROJECT_ROOT/scripts/tools/diff_compat.sh"

PROTOCOL_FILE="core/src/server/protocol/mod.rs"
PROTOCOL_VERSION="$(
    sed -n 's/^pub const PROTOCOL_VERSION: u32 = \([0-9][0-9]*\);/\1/p' "$PROTOCOL_FILE" | head -n1
)"
SCHEMA_FILE="schema/protocol/v${PROTOCOL_VERSION}/action_rules.csv"
TARGET_FILE="app/TidyFlow/Networking/WSClient+Send.swift"
BEGIN_MARKER="// BEGIN AUTO-GENERATED: protocol_action_rules"
END_MARKER="// END AUTO-GENERATED: protocol_action_rules"
RECEIVE_TARGET_FILE="app/TidyFlow/Networking/WSClient+Receive+DomainRouting.swift"
RECEIVE_BEGIN_MARKER="// BEGIN AUTO-GENERATED: protocol_receive_action_rules"
RECEIVE_END_MARKER="// END AUTO-GENERATED: protocol_receive_action_rules"
WEB_TARGET_FILE="app/TidyFlow/Web/main/protocol-rules.js"
WEB_BEGIN_MARKER="// BEGIN AUTO-GENERATED: protocol_action_rules"
WEB_END_MARKER="// END AUTO-GENERATED: protocol_action_rules"

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
if [ ! -f "$RECEIVE_TARGET_FILE" ]; then
    echo "[gen_swift_rules] ERROR: 未找到 $RECEIVE_TARGET_FILE"
    exit 1
fi

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

exact_rules="$tmp_dir/exact.rules"
prefix_rules="$tmp_dir/prefix.rules"
contains_rules="$tmp_dir/contains.rules"
block_file="$tmp_dir/block.swift"
generated_file="$tmp_dir/WSClient+Send.swift"
receive_block_file="$tmp_dir/receive_block.swift"
generated_receive_file="$tmp_dir/WSClient+Receive+DomainRouting.swift"
web_exact_rules="$tmp_dir/web_exact.rules"
web_prefix_rules="$tmp_dir/web_prefix.rules"
web_contains_rules="$tmp_dir/web_contains.rules"
web_block_file="$tmp_dir/web_block.js"
generated_web_file="$tmp_dir/protocol-rules.js"

> "$exact_rules"
> "$prefix_rules"
> "$contains_rules"
> "$web_exact_rules"
> "$web_prefix_rules"
> "$web_contains_rules"

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
        exact)
            echo "        (\"$domain\", \"$value\")," >> "$exact_rules"
            echo "        [\"$domain\", \"$value\"]," >> "$web_exact_rules"
            ;;
        prefix)
            echo "        (\"$domain\", \"$value\")," >> "$prefix_rules"
            echo "        [\"$domain\", \"$value\"]," >> "$web_prefix_rules"
            ;;
        contains)
            echo "        (\"$domain\", \"$value\")," >> "$contains_rules"
            echo "        [\"$domain\", \"$value\"]," >> "$web_contains_rules"
            ;;
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

cat > "$receive_block_file" <<EOF
    $RECEIVE_BEGIN_MARKER
    private var receiveProtocolExactRules: [(domain: String, action: String)] {
        [
$(cat "$exact_rules")
        ]
    }

    private var receiveProtocolPrefixRules: [(domain: String, prefix: String)] {
        [
$(cat "$prefix_rules")
        ]
    }

    private var receiveProtocolContainsRules: [(domain: String, needle: String)] {
        [
$(cat "$contains_rules")
        ]
    }
    $RECEIVE_END_MARKER
EOF

cat > "$web_block_file" <<EOF
  $WEB_BEGIN_MARKER
  TF.protocolExactRules = [
$(cat "$web_exact_rules")
  ];

  TF.protocolPrefixRules = [
$(cat "$web_prefix_rules")
  ];

  TF.protocolContainsRules = [
$(cat "$web_contains_rules")
  ];
  $WEB_END_MARKER
EOF

if ! rg -q "$BEGIN_MARKER" "$TARGET_FILE" || ! rg -q "$END_MARKER" "$TARGET_FILE"; then
    echo "[gen_swift_rules] ERROR: 未找到生成标记，请先在 $TARGET_FILE 中添加:"
    echo "  $BEGIN_MARKER"
    echo "  $END_MARKER"
    exit 1
fi
if ! rg -q "$RECEIVE_BEGIN_MARKER" "$RECEIVE_TARGET_FILE" || ! rg -q "$RECEIVE_END_MARKER" "$RECEIVE_TARGET_FILE"; then
    echo "[gen_swift_rules] ERROR: 未找到生成标记，请先在 $RECEIVE_TARGET_FILE 中添加:"
    echo "  $RECEIVE_BEGIN_MARKER"
    echo "  $RECEIVE_END_MARKER"
    exit 1
fi
if [ ! -f "$WEB_TARGET_FILE" ]; then
    echo "[gen_swift_rules] ERROR: 未找到 $WEB_TARGET_FILE"
    exit 1
fi
if ! rg -q "$WEB_BEGIN_MARKER" "$WEB_TARGET_FILE" || ! rg -q "$WEB_END_MARKER" "$WEB_TARGET_FILE"; then
    echo "[gen_swift_rules] ERROR: 未找到生成标记，请先在 $WEB_TARGET_FILE 中添加:"
    echo "  $WEB_BEGIN_MARKER"
    echo "  $WEB_END_MARKER"
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

awk -v begin="$RECEIVE_BEGIN_MARKER" -v end="$RECEIVE_END_MARKER" -v block_file="$receive_block_file" '
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
' "$RECEIVE_TARGET_FILE" > "$generated_receive_file"

awk -v begin="$WEB_BEGIN_MARKER" -v end="$WEB_END_MARKER" -v block_file="$web_block_file" '
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
' "$WEB_TARGET_FILE" > "$generated_web_file"

if [ "$MODE" = "check" ]; then
    if ! run_unified_diff "$TARGET_FILE" "$generated_file" "$tmp_dir/diff.out"; then
        echo "[gen_swift_rules] ERROR: Swift 规则未同步，请先执行："
        echo "  ./scripts/tools/gen_protocol_action_swift_rules.sh"
        if [ -f "$tmp_dir/diff.out" ]; then
            cat "$tmp_dir/diff.out"
        fi
        exit 1
    fi
    if ! run_unified_diff "$RECEIVE_TARGET_FILE" "$generated_receive_file" "$tmp_dir/diff.receive.out"; then
        echo "[gen_swift_rules] ERROR: Swift 接收 catalog 未同步，请先执行："
        echo "  ./scripts/tools/gen_protocol_action_swift_rules.sh"
        if [ -f "$tmp_dir/diff.receive.out" ]; then
            cat "$tmp_dir/diff.receive.out"
        fi
        exit 1
    fi
    if ! run_unified_diff "$WEB_TARGET_FILE" "$generated_web_file" "$tmp_dir/diff.web.out"; then
        echo "[gen_swift_rules] ERROR: Web 规则未同步，请先执行："
        echo "  ./scripts/tools/gen_protocol_action_swift_rules.sh"
        if [ -f "$tmp_dir/diff.web.out" ]; then
            cat "$tmp_dir/diff.web.out"
        fi
        exit 1
    fi
    echo "[gen_swift_rules] OK: Swift/Web action 规则与 schema 同步"
    exit 0
fi

cp "$generated_file" "$TARGET_FILE"
cp "$generated_receive_file" "$RECEIVE_TARGET_FILE"
cp "$generated_web_file" "$WEB_TARGET_FILE"
echo "[gen_swift_rules] Generated blocks in:"
echo "  - $TARGET_FILE"
echo "  - $RECEIVE_TARGET_FILE"
echo "  - $WEB_TARGET_FILE"
