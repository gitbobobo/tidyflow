#!/usr/bin/env bash
# 协议一致性检查
# 失败即退出非 0，供 CI 与发布前门禁使用。

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$PROJECT_ROOT"

protocol_file="core/src/server/protocol/mod.rs"
docs_protocol="docs/PROTOCOL.md"
app_readme="app/README.md"
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

if rg -q "Protocol v2|MessagePack v2" "$app_readme" "$evo_arch" "$evo_delta"; then
    echo "[check_protocol] ERROR: 检测到过期协议描述（v2），请改为当前版本 v$core_version"
    exit 1
fi

echo "[check_protocol] OK: 协议版本一致 (v$core_version)"
