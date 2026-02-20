#!/bin/bash
# Evolution 截图采集辅助脚本
# 用法:
#   ./scripts/evo-screenshot.sh --cycle <cycle_id> --state <state>
#   ./scripts/evo-screenshot.sh --cycle <cycle_id> --check v-3 --state initial

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
EVOLUTION_DIR="$PROJECT_ROOT/.tidyflow/evolution"

CYCLE_ID=""
CHECK_ID="v-3"
STATE=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --cycle)
            CYCLE_ID="${2:-}"
            shift 2
            ;;
        --check)
            CHECK_ID="${2:-v-3}"
            shift 2
            ;;
        --state)
            STATE="${2:-}"
            shift 2
            ;;
        --help|-h)
            echo "Evolution 截图采集辅助脚本"
            echo ""
            echo "用法:"
            echo "  $0 --cycle <cycle_id> --state <state> [options]"
            echo ""
            echo "选项:"
            echo "  --cycle <id>    Cycle ID（必需）"
            echo "  --check <id>    检查项 ID（默认：v-3）"
            echo "  --state <state> 状态：initial|processing|complete|error（必需）"
            echo "  --help, -h      显示帮助"
            exit 0
            ;;
        *)
            echo "[evo][evidence] ERROR: 未知参数: $1"
            exit 1
            ;;
    esac
done

if [ -z "$CYCLE_ID" ]; then
    echo "[evo][evidence] ERROR: 必须指定 --cycle"
    exit 1
fi

if [ -z "$STATE" ]; then
    echo "[evo][evidence] ERROR: 必须指定 --state (initial|processing|complete|error)"
    exit 1
fi

CYCLE_DIR="$EVOLUTION_DIR/$CYCLE_ID"
if [ ! -d "$CYCLE_DIR" ]; then
    echo "[evo][evidence] ERROR: Cycle 目录不存在: $CYCLE_DIR"
    exit 1
fi

EVIDENCE_DIR="$CYCLE_DIR/evidence"
mkdir -p "$EVIDENCE_DIR"

TIMESTAMP=$(date +%Y%m%d-%H%M%S)
FILENAME="screenshot-${CHECK_ID}-${STATE}.png"
FILEPATH="$EVIDENCE_DIR/$FILENAME"

screencapture -x "$FILEPATH"

if [ -f "$FILEPATH" ] && [ -s "$FILEPATH" ]; then
    echo "[evo][evidence] 截图保存成功: $FILEPATH"
    echo "[evo][evidence] 检查项: $CHECK_ID"
    echo "[evo][evidence] 状态: $STATE"
    echo "[evo][evidence] 时间: $TIMESTAMP"
else
    echo "[evo][evidence] ERROR: 截图保存失败"
    exit 1
fi
