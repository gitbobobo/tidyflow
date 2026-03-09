#!/usr/bin/env bash
# 从 schema/protocol/v{PROTOCOL_VERSION}/action_rules.csv 生成 Core 协议规则表
#
# 用法：
#   ./scripts/tools/gen_protocol_action_table.sh
#   ./scripts/tools/gen_protocol_action_table.sh --check

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$PROJECT_ROOT"

source "$PROJECT_ROOT/scripts/tools/diff_compat.sh"

PROTOCOL_FILE="core/src/server/protocol/mod.rs"
PROTOCOL_VERSION="$(
    sed -n 's/^pub const PROTOCOL_VERSION: u32 = \([0-9][0-9]*\);/\1/p' "$PROTOCOL_FILE" | head -n1
)"
SCHEMA_FILE="schema/protocol/v${PROTOCOL_VERSION}/action_rules.csv"
OUTPUT_FILE="core/src/server/protocol/action_table.rs"

MODE="write"
if [ "${1:-}" = "--check" ]; then
    MODE="check"
fi

if [ ! -f "$SCHEMA_FILE" ]; then
    echo "[gen_action_table] ERROR: 未找到 $SCHEMA_FILE"
    exit 1
fi

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

exact_rules="$tmp_dir/exact.rules"
prefix_rules="$tmp_dir/prefix.rules"
contains_rules="$tmp_dir/contains.rules"
generated="$tmp_dir/action_table.rs"

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
        echo "[gen_action_table] ERROR: CSV 格式错误 (line $line_no): $line"
        exit 1
    fi

    case "$kind" in
        exact) echo "    (\"$domain\", \"$value\")," >> "$exact_rules" ;;
        prefix) echo "    (\"$domain\", \"$value\")," >> "$prefix_rules" ;;
        contains) echo "    (\"$domain\", \"$value\")," >> "$contains_rules" ;;
        *)
            echo "[gen_action_table] ERROR: 不支持的 kind '$kind' (line $line_no)"
            exit 1
            ;;
    esac
done < "$SCHEMA_FILE"

cat > "$generated" <<EOF
//! 自动生成文件，请勿手改。
//!
//! 来源：\`schema/protocol/v${PROTOCOL_VERSION}/action_rules.csv\`
//! 生成命令：\`./scripts/tools/gen_protocol_action_table.sh\`

EOF

cat >> "$generated" <<EOF
pub const EXACT_RULES: &[(&str, &str)] = &[
$(cat "$exact_rules")
];

pub const PREFIX_RULES: &[(&str, &str)] = &[
$(cat "$prefix_rules")
];

pub const CONTAINS_RULES: &[(&str, &str)] = &[
$(cat "$contains_rules")
];

/// 根据规则表判断 action 是否属于给定 domain。
pub fn matches_action_domain(domain: &str, action: &str) -> bool {
    if EXACT_RULES
        .iter()
        .any(|(d, value)| *d == domain && action == *value)
    {
        return true;
    }
    if PREFIX_RULES
        .iter()
        .any(|(d, value)| *d == domain && action.starts_with(*value))
    {
        return true;
    }
    if CONTAINS_RULES
        .iter()
        .any(|(d, value)| *d == domain && action.contains(*value))
    {
        return true;
    }
    false
}
EOF

if [ "$MODE" = "check" ]; then
    if ! run_unified_diff "$OUTPUT_FILE" "$generated" "$tmp_dir/diff.out"; then
        echo "[gen_action_table] ERROR: 生成结果与仓库文件不一致，请先执行："
        echo "  ./scripts/tools/gen_protocol_action_table.sh"
        if [ -f "$tmp_dir/diff.out" ]; then
            cat "$tmp_dir/diff.out"
        fi
        exit 1
    fi
    echo "[gen_action_table] OK: action_table.rs 与 schema 同步"
    exit 0
fi

cp "$generated" "$OUTPUT_FILE"
echo "[gen_action_table] Generated: $OUTPUT_FILE"
