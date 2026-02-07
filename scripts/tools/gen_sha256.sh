#!/bin/bash
# 生成文件的 SHA256 校验值
# 用法: ./scripts/tools/gen_sha256.sh <file>

set -euo pipefail

if [ "$#" -ne 1 ]; then
    echo "[gen_sha256] ERROR: 需要 1 个参数：文件路径"
    echo "Usage: ./scripts/tools/gen_sha256.sh <file>"
    exit 1
fi

INPUT_PATH="$1"
if [ ! -f "$INPUT_PATH" ]; then
    echo "[gen_sha256] ERROR: 文件不存在: $INPUT_PATH"
    exit 1
fi

OUTPUT_PATH="${INPUT_PATH}.sha256"

# macOS 与 Linux 都兼容
if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$INPUT_PATH" > "$OUTPUT_PATH"
elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$INPUT_PATH" > "$OUTPUT_PATH"
else
    echo "[gen_sha256] ERROR: 未找到 shasum/sha256sum"
    exit 1
fi

echo "[gen_sha256] SUCCESS: $OUTPUT_PATH"
