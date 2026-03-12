#!/usr/bin/env bash
# 协议一致性检查
# 失败即退出非 0，供 CI 与发布前门禁使用。

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$PROJECT_ROOT"

protocol_file="core/src/server/protocol/mod.rs"
docs_protocol="docs/PROTOCOL.md"
app_readme="app/README.md"
app_config="app/TidyFlow/AppConfig.swift"
evo_arch="docs/evolution/ARCHITECTURE.md"
evo_delta="docs/evolution/PROTOCOL_DELTA.md"

if [ ! -f "$protocol_file" ]; then
    echo "[check_protocol] ERROR: 未找到 $protocol_file"
    exit 1
fi

core_version="$(
    sed -n 's/^pub const PROTOCOL_VERSION: u32 = \([0-9][0-9]*\);/\1/p' "$protocol_file" | head -n1
)"
if [ -z "$core_version" ]; then
    echo "[check_protocol] ERROR: 无法解析 Core 协议版本"
    exit 1
fi

expect_token="PROTOCOL_VERSION = $core_version"
if ! rg -q "$expect_token" "$docs_protocol"; then
    echo "[check_protocol] ERROR: $docs_protocol 未包含 \"$expect_token\""
    exit 1
fi

if ! rg -q "Protocol v$core_version" "$app_readme"; then
    echo "[check_protocol] ERROR: $app_readme 未声明 Protocol v$core_version"
    exit 1
fi

if ! rg -q "static let protocolVersion: Int = $core_version" "$app_config"; then
    echo "[check_protocol] ERROR: $app_config 中 AppConfig.protocolVersion 与 Core 不一致（期望 $core_version）"
    exit 1
fi

legacy_scan_targets=("$app_readme")
[ -f "$evo_arch" ] && legacy_scan_targets+=("$evo_arch")
[ -f "$evo_delta" ] && legacy_scan_targets+=("$evo_delta")

if rg -q "Protocol v2|MessagePack v2" "${legacy_scan_targets[@]}"; then
    echo "[check_protocol] ERROR: 检测到过期协议描述（v2），请改为当前版本 v$core_version"
    exit 1
fi

echo "[check_protocol] OK: 协议版本一致 (v$core_version)"
# 协调层域检查：schema 与文档必须同时声明 coordinator 域
schema_file="schema/protocol/v7/domains.yaml"
if [ ! -f "$schema_file" ]; then
    echo "[check_protocol] WARNING: schema 文件 $schema_file 不存在，跳过 coordinator 域检查"
else
    if ! rg -q "id: coordinator" "$schema_file"; then
        echo "[check_protocol] ERROR: $schema_file 未声明 coordinator 域"
        exit 1
    fi
    if ! rg -q "coordinator" "$docs_protocol"; then
        echo "[check_protocol] ERROR: $docs_protocol 未包含 coordinator 域说明"
        exit 1
    fi
    # 验证 coordinator 域在文档中包含必要的多工作区边界约束说明
    if ! rg -q "global_key|project:workspace" "$docs_protocol"; then
        echo "[check_protocol] ERROR: $docs_protocol 缺少 coordinator 域的多工作区边界字段说明"
        exit 1
    fi
    echo "[check_protocol] OK: coordinator 域一致性检查通过"
fi
