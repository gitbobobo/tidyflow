#!/usr/bin/env bash
# 协议 action 规则同步检查
#
# 现阶段 Core/App 规则均由生成器产出，因此这里做两类检查：
# 1) 生成器一致性（--check）
# 2) 关键接线点仍然存在（避免生成器通过但调用方脱节）

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$PROJECT_ROOT"

protocol_file="core/src/server/protocol/mod.rs"
protocol_version="$(
    sed -n 's/^pub const PROTOCOL_VERSION: u32 = \([0-9][0-9]*\);/\1/p' "$protocol_file" | head -n1
)"
schema_file="schema/protocol/v${protocol_version}/action_rules.csv"
core_file="core/src/server/protocol/action_table.rs"
dispatch_file=""
dispatch_candidates=(
    "core/src/server/ws/dispatch/mod.rs"
    "core/src/server/ws/dispatch.rs"
)
domain_table_file="core/src/server/protocol/domain_table.rs"
app_file="app/TidyFlow/Networking/WSClient+Send.swift"
app_receive_file="app/TidyFlow/Networking/WSClient+Receive+DomainRouting.swift"
web_rules_file="app/TidyFlow/Web/main/protocol-rules.js"

for candidate in "${dispatch_candidates[@]}"; do
    if [ -f "$candidate" ]; then
        dispatch_file="$candidate"
        break
    fi
done

if [ -z "$dispatch_file" ]; then
    echo "[check_action_sync] ERROR: 未找到 Core dispatch 文件（尝试路径: ${dispatch_candidates[*]}）"
    exit 1
fi

for f in "$schema_file" "$core_file" "$domain_table_file" "$app_file" "$app_receive_file" "$web_rules_file"; do
    if [ ! -f "$f" ]; then
        echo "[check_action_sync] ERROR: 未找到 $f"
        exit 1
    fi
done

# 1) 规则生成一致性
./scripts/tools/gen_protocol_action_table.sh --check >/dev/null
./scripts/tools/gen_protocol_action_swift_rules.sh --check >/dev/null
./scripts/tools/gen_protocol_domain_table.sh --check >/dev/null

# 2) 关键接线点检查
if ! rg -q 'action_matches_domain\(|matches_action_domain\(' "$dispatch_file"; then
    echo "[check_action_sync] ERROR: Core dispatch 未使用协议规则表匹配函数"
    exit 1
fi
if ! rg -q 'parse_domain_route\(&envelope\.domain\)' "$dispatch_file"; then
    echo "[check_action_sync] ERROR: Core dispatch 未接入 domain_table 解析"
    exit 1
fi
if ! rg -q 'BEGIN AUTO-GENERATED: protocol_action_rules' "$app_file"; then
    echo "[check_action_sync] ERROR: App 未包含自动生成规则标记块"
    exit 1
fi
if ! rg -q 'protocolExactRules|protocolPrefixRules|protocolContainsRules' "$app_file"; then
    echo "[check_action_sync] ERROR: App 未接入生成规则常量"
    exit 1
fi
if ! rg -q 'BEGIN AUTO-GENERATED: protocol_receive_action_rules' "$app_receive_file"; then
    echo "[check_action_sync] ERROR: App 接收路由未包含自动生成规则标记块"
    exit 1
fi
if ! rg -q 'receiveProtocolExactRules|receiveProtocolPrefixRules|receiveProtocolContainsRules' "$app_receive_file"; then
    echo "[check_action_sync] ERROR: App 接收路由未接入生成规则常量"
    exit 1
fi
if ! rg -q 'BEGIN AUTO-GENERATED: protocol_action_rules' "$web_rules_file"; then
    echo "[check_action_sync] ERROR: Web 未包含自动生成规则标记块"
    exit 1
fi
if ! rg -q 'protocolExactRules|protocolPrefixRules|protocolContainsRules' "$web_rules_file"; then
    echo "[check_action_sync] ERROR: Web 未接入生成规则常量"
    exit 1
fi

echo "[check_action_sync] OK: 生成器与接线点检查通过"
