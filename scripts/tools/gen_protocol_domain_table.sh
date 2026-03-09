#!/usr/bin/env bash
# 从 schema/protocol/v{PROTOCOL_VERSION}/domains.yaml 生成 Core domain 路由表
#
# 用法：
#   ./scripts/tools/gen_protocol_domain_table.sh
#   ./scripts/tools/gen_protocol_domain_table.sh --check

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$PROJECT_ROOT"

source "$PROJECT_ROOT/scripts/tools/diff_compat.sh"

PROTOCOL_FILE="core/src/server/protocol/mod.rs"
PROTOCOL_VERSION="$(
    sed -n 's/^pub const PROTOCOL_VERSION: u32 = \([0-9][0-9]*\);/\1/p' "$PROTOCOL_FILE" | head -n1
)"
SCHEMA_FILE="schema/protocol/v${PROTOCOL_VERSION}/domains.yaml"
OUTPUT_FILE="core/src/server/protocol/domain_table.rs"

MODE="write"
if [ "${1:-}" = "--check" ]; then
    MODE="check"
fi

if [ ! -f "$SCHEMA_FILE" ]; then
    echo "[gen_domain_table] ERROR: 未找到 $SCHEMA_FILE"
    exit 1
fi

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

domains_file="$tmp_dir/domains.txt"
generated="$tmp_dir/domain_table.rs"

sed -n 's/^[[:space:]]*-[[:space:]]*id:[[:space:]]*\([a-z_][a-z_]*\)$/\1/p' "$SCHEMA_FILE" > "$domains_file"

if [ ! -s "$domains_file" ]; then
    echo "[gen_domain_table] ERROR: $SCHEMA_FILE 未解析到任何 domain id"
    exit 1
fi

snake_to_pascal() {
    local input="$1"
    local part
    local out=""
    local old_ifs="$IFS"
    IFS='_'
    read -r -a parts <<< "$input"
    IFS="$old_ifs"
    for part in "${parts[@]}"; do
        out+="$(tr '[:lower:]' '[:upper:]' <<< "${part:0:1}")${part:1}"
    done
    echo "$out"
}

variants_file="$tmp_dir/variants.txt"
parse_arms_file="$tmp_dir/parse_arms.txt"
id_arms_file="$tmp_dir/id_arms.txt"
list_items_file="$tmp_dir/list_items.txt"

> "$variants_file"
> "$parse_arms_file"
> "$id_arms_file"
> "$list_items_file"

while IFS= read -r domain; do
    [ -z "$domain" ] && continue
    variant="$(snake_to_pascal "$domain")"
    echo "    $variant," >> "$variants_file"
    echo "        \"$domain\" => Some(DomainRoute::$variant)," >> "$parse_arms_file"
    echo "        DomainRoute::$variant => \"$domain\"," >> "$id_arms_file"
    echo "    \"$domain\"," >> "$list_items_file"
done < "$domains_file"

cat > "$generated" <<EOF2
//! 自动生成文件，请勿手改。
//!
//! 来源：\`schema/protocol/v${PROTOCOL_VERSION}/domains.yaml\`
//! 生成命令：\`./scripts/tools/gen_protocol_domain_table.sh\`

#[derive(Copy, Clone, Debug, Eq, PartialEq)]
pub enum DomainRoute {
$(cat "$variants_file")
}

pub const DOMAIN_IDS: &[&str] = &[
$(cat "$list_items_file")
];

pub fn parse_domain_route(domain: &str) -> Option<DomainRoute> {
    match domain {
$(cat "$parse_arms_file")
        _ => None,
    }
}

pub fn domain_route_id(route: DomainRoute) -> &'static str {
    match route {
$(cat "$id_arms_file")
    }
}
EOF2

if [ "$MODE" = "check" ]; then
    if ! run_unified_diff "$OUTPUT_FILE" "$generated" "$tmp_dir/diff.out"; then
        echo "[gen_domain_table] ERROR: 生成结果与仓库文件不一致，请先执行："
        echo "  ./scripts/tools/gen_protocol_domain_table.sh"
        if [ -f "$tmp_dir/diff.out" ]; then
            cat "$tmp_dir/diff.out"
        fi
        exit 1
    fi
    echo "[gen_domain_table] OK: domain_table.rs 与 schema 同步"
    exit 0
fi

cp "$generated" "$OUTPUT_FILE"
echo "[gen_domain_table] Generated: $OUTPUT_FILE"
