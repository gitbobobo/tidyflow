#!/usr/bin/env bash
# 校验 schema/protocol 与 Core/App 实现是否一致

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$PROJECT_ROOT"

schema_file="schema/protocol/v3/domains.yaml"
protocol_file="core/src/server/protocol/mod.rs"
dispatch_file="core/src/server/ws/dispatch.rs"
swift_send_file="app/TidyFlow/Networking/WSClient+Send.swift"

for f in "$schema_file" "$protocol_file" "$dispatch_file" "$swift_send_file"; do
    if [ ! -f "$f" ]; then
        echo "[check_schema_sync] ERROR: 未找到 $f"
        exit 1
    fi
done

schema_version="$(sed -n 's/^protocol_version:[[:space:]]*\([0-9][0-9]*\)$/\1/p' "$schema_file" | head -n1)"
core_version="$(sed -n 's/^pub const PROTOCOL_VERSION: u32 = \([0-9][0-9]*\);/\1/p' "$protocol_file" | head -n1)"

if [ -z "$schema_version" ] || [ -z "$core_version" ]; then
    echo "[check_schema_sync] ERROR: 无法解析协议版本 (schema/core)"
    exit 1
fi
if [ "$schema_version" != "$core_version" ]; then
    echo "[check_schema_sync] ERROR: 协议版本不一致"
    echo "  schema protocol_version: $schema_version"
    echo "  core   PROTOCOL_VERSION: $core_version"
    exit 1
fi

schema_domains="$(
    sed -n 's/^[[:space:]]*-[[:space:]]*id:[[:space:]]*\([a-z_][a-z_]*\)$/\1/p' "$schema_file" | sort -u
)"
dispatch_domains="$(
    rg '^[[:space:]]*"[a-z_][a-z_]*"[[:space:]]*=>[[:space:]]*Some\(DomainRoute::' "$dispatch_file" -N \
        | sed -E 's/^[[:space:]]*"([a-z_][a-z_]*)".*$/\1/' \
        | sort -u
)"
swift_domains="$(
    awk '
        /private let protocolExactRules/ {mode=1; next}
        /private let protocolPrefixRules/ {mode=1; next}
        /private let protocolContainsRules/ {mode=1; next}
        mode == 1 && /\]/ {mode=0; next}
        mode == 1 && /\(".*", ".*"\)/ {
            line=$0
            gsub(/^[[:space:]]*\("/, "", line)
            gsub(/", ".*$/, "", line)
            gsub(/"/, "", line)
            print line
        }
    ' "$swift_send_file" | sort -u
)"

if [ -z "$schema_domains" ] || [ -z "$dispatch_domains" ] || [ -z "$swift_domains" ]; then
    echo "[check_schema_sync] ERROR: 无法解析 domain 集合"
    exit 1
fi

if [ "$schema_domains" != "$dispatch_domains" ]; then
    echo "[check_schema_sync] ERROR: schema domains 与 Core dispatch domains 不一致"
    echo "--- schema"
    echo "$schema_domains"
    echo "--- core"
    echo "$dispatch_domains"
    exit 1
fi

# App 允许保留 misc 兜底域；规则表中的域必须覆盖 schema 中的全部域。
swift_domains_without_misc="$(printf "%s\n" "$swift_domains" | sed '/^misc$/d')"
if [ "$schema_domains" != "$swift_domains_without_misc" ]; then
    echo "[check_schema_sync] ERROR: schema domains 与 App domainForAction 返回域不一致"
    echo "--- schema"
    echo "$schema_domains"
    echo "--- app (without misc)"
    echo "$swift_domains_without_misc"
    echo "--- app (full)"
    echo "$swift_domains"
    exit 1
fi

echo "[check_schema_sync] OK: schema/core/app domain 与版本一致 (v$core_version)"
