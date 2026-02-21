#!/usr/bin/env bash
# 版本一致性检查
# 规则：MARKETING_VERSION == core/Cargo.toml version

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$PROJECT_ROOT"

PBXPROJ="app/TidyFlow.xcodeproj/project.pbxproj"
CARGO_TOML="core/Cargo.toml"

if [ ! -f "$PBXPROJ" ]; then
    echo "[check_version] ERROR: 未找到 $PBXPROJ"
    exit 1
fi
if [ ! -f "$CARGO_TOML" ]; then
    echo "[check_version] ERROR: 未找到 $CARGO_TOML"
    exit 1
fi

marketing_versions_str="$(
    rg "MARKETING_VERSION =" "$PBXPROJ" -N | sed -E 's/.*= ([^;]+);/\1/' | sort -u
)"
build_versions_str="$(
    rg "CURRENT_PROJECT_VERSION =" "$PBXPROJ" -N | sed -E 's/.*= ([^;]+);/\1/' | sort -u
)"

marketing_count="$(printf "%s\n" "$marketing_versions_str" | sed '/^$/d' | wc -l | tr -d ' ')"
build_count="$(printf "%s\n" "$build_versions_str" | sed '/^$/d' | wc -l | tr -d ' ')"

if [ "$marketing_count" -ne 1 ]; then
    echo "[check_version] ERROR: MARKETING_VERSION 存在多个值: ${marketing_versions_str:-<empty>}"
    exit 1
fi
if [ "$build_count" -ne 1 ]; then
    echo "[check_version] ERROR: CURRENT_PROJECT_VERSION 存在多个值: ${build_versions_str:-<empty>}"
    exit 1
fi

app_version="$marketing_versions_str"
build_number="$build_versions_str"
core_version="$(
    rg '^version = "' "$CARGO_TOML" -N | head -n1 | sed -E 's/version = "([^"]+)"/\1/'
)"

if [ -z "$core_version" ]; then
    echo "[check_version] ERROR: 无法解析 core/Cargo.toml version"
    exit 1
fi

if [ "$app_version" != "$core_version" ]; then
    echo "[check_version] ERROR: 版本不一致"
    echo "  app MARKETING_VERSION: $app_version"
    echo "  core version: $core_version"
    exit 1
fi

echo "[check_version] OK: app/core 版本一致: $app_version (build=$build_number)"
