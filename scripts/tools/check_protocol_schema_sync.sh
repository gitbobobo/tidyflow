#!/usr/bin/env bash
# 校验 schema/protocol 与 Core/App 实现是否一致

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$PROJECT_ROOT"

protocol_file="core/src/server/protocol/mod.rs"
domain_table_file="core/src/server/protocol/domain_table.rs"
swift_send_file="app/TidyFlow/Networking/WSClient+Send.swift"
web_rules_file="app/TidyFlow/Web/main/protocol-rules.js"

for f in "$protocol_file" "$domain_table_file" "$swift_send_file" "$web_rules_file"; do
    if [ ! -f "$f" ]; then
        echo "[check_schema_sync] ERROR: 未找到 $f"
        exit 1
    fi
done

core_version="$(sed -n 's/^pub const PROTOCOL_VERSION: u32 = \([0-9][0-9]*\);/\1/p' "$protocol_file" | head -n1)"
schema_file="schema/protocol/v${core_version}/domains.yaml"

if [ ! -f "$schema_file" ]; then
    echo "[check_schema_sync] ERROR: 未找到 $schema_file"
    exit 1
fi

schema_version="$(sed -n 's/^protocol_version:[[:space:]]*\([0-9][0-9]*\)$/\1/p' "$schema_file" | head -n1)"

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
    rg '^[[:space:]]*"[a-z_][a-z_]*",[[:space:]]*$' "$domain_table_file" -N \
        | sed -E 's/^[[:space:]]*"([a-z_][a-z_]*)",[[:space:]]*$/\1/' \
        | sort -u
)"
swift_domains="$(
    awk '
        /private (let|var) protocolExactRules/ {mode=1; next}
        /private (let|var) protocolPrefixRules/ {mode=1; next}
        /private (let|var) protocolContainsRules/ {mode=1; next}
        mode == 1 && /^[[:space:]]*];/ {mode=0; next}
        mode == 1 && /\(".*", ".*"\)/ {
            line=$0
            gsub(/^[[:space:]]*\("/, "", line)
            gsub(/", ".*$/, "", line)
            gsub(/"/, "", line)
            print line
        }
    ' "$swift_send_file" | sort -u
)"
web_domains="$(
    awk '
        /TF\.protocolExactRules[[:space:]]*=[[:space:]]*\[/ {mode=1; next}
        /TF\.protocolPrefixRules[[:space:]]*=[[:space:]]*\[/ {mode=1; next}
        /TF\.protocolContainsRules[[:space:]]*=[[:space:]]*\[/ {mode=1; next}
        mode == 1 && /^[[:space:]]*];/ {mode=0; next}
        mode == 1 {
            if (match($0, /"[^"]+", "[^"]+"/)) {
                line = substr($0, RSTART, RLENGTH)
                gsub(/^"/, "", line)
                gsub(/", ".*$/, "", line)
                print line
            }
        }
    ' "$web_rules_file" | sort -u
)"

if [ -z "$schema_domains" ] || [ -z "$dispatch_domains" ] || [ -z "$swift_domains" ] || [ -z "$web_domains" ]; then
    echo "[check_schema_sync] ERROR: 无法解析 domain 集合"
    exit 1
fi

if [ "$schema_domains" != "$dispatch_domains" ]; then
    echo "[check_schema_sync] ERROR: schema domains 与 Core domain_table domains 不一致"
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

web_domains_without_misc="$(printf "%s\n" "$web_domains" | sed '/^misc$/d')"
if [ "$schema_domains" != "$web_domains_without_misc" ]; then
    echo "[check_schema_sync] ERROR: schema domains 与 Web domainForAction 返回域不一致"
    echo "--- schema"
    echo "$schema_domains"
    echo "--- web (without misc)"
    echo "$web_domains_without_misc"
    echo "--- web (full)"
    echo "$web_domains"
    exit 1
fi

echo "[check_schema_sync] OK: schema/core/app domain 与版本一致 (v$core_version)"
