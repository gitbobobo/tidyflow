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

# 生成 cycle_id 短码（取前8位）
CYCLE_ID_SHORT="${CYCLE_ID:0:8}"

# 生成 UTC 时间戳
UTC_TS=$(date -u +%Y%m%d-%H%M%S)

FILENAME="screenshot-${CYCLE_ID_SHORT}-${CHECK_ID}-${STATE}-${UTC_TS}.png"
FILEPATH="$EVIDENCE_DIR/$FILENAME"

# 捕获截图
echo "[evo][evidence] 正在捕获截图..."
if screencapture -x "$FILEPATH" 2>/dev/null; then
    if [ -f "$FILEPATH" ] && [ -s "$FILEPATH" ]; then
        echo "[evo][evidence] 截图保存成功: $FILEPATH"
    else
        echo "[evo][evidence] ERROR: 截图保存失败（文件为空或不存在）"
        echo "[evo][evidence] 重试命令: ./scripts/evo-screenshot.sh --cycle $CYCLE_ID --check $CHECK_ID --state $STATE"
        exit 1
    fi
else
    echo "[evo][evidence] ERROR: 截图保存失败"
    echo "[evo][evidence] 重试命令: ./scripts/evo-screenshot.sh --cycle $CYCLE_ID --check $CHECK_ID --state $STATE"
    exit 1
fi

# 更新 evidence.index.json
update_evidence_index() {
    python3 - "$CYCLE_DIR" "$CYCLE_ID" "$CYCLE_ID_SHORT" "$CHECK_ID" "$STATE" "$FILENAME" <<'PY'
import sys
import json
import os
from datetime import datetime, timezone

cycle_dir, cycle_id, cycle_id_short, check_id, state, filename = sys.argv[1:7]
index_path = os.path.join(cycle_dir, "evidence.index.json")
now = datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")

def load_index(path):
    if not os.path.exists(path):
        return {}
    try:
        with open(path, "r", encoding="utf-8") as f:
            return json.load(f) or {}
    except Exception:
        return {}

data = load_index(index_path)
if not isinstance(data, dict):
    data = {}

data["$schema_version"] = "1.0"
data["cycle_id"] = cycle_id

evidence_items = data.get("evidence_items", [])
if not isinstance(evidence_items, list):
    evidence_items = []

index_by_path = {}
for item in evidence_items:
    if not isinstance(item, dict):
        continue
    path = item.get("path")
    if path:
        index_by_path[path] = item

rel_path = f"evidence/{filename}"
screenshot_id = f"scr-{cycle_id_short}-{check_id}-{state}"

item = {
    "evidence_id": screenshot_id,
    "type": "screenshot",
    "path": rel_path,
    "check_id": check_id,
    "state": state,
    "cycle_id_short": cycle_id_short,
    "created_at": now,
}
index_by_path[rel_path] = item

data["evidence_items"] = sorted(index_by_path.values(), key=lambda x: x.get("path", ""))
data["updated_at"] = now

with open(index_path, "w", encoding="utf-8") as f:
    json.dump(data, f, ensure_ascii=False, indent=2)
    f.write("\n")
PY
    return $?
}

if update_evidence_index; then
    echo "[evo][evidence] 索引更新成功"
else
    echo "[evo][evidence] WARNING: 索引更新失败，但截图已保存"
    echo "[evo][evidence] 重试命令: ./scripts/evo-screenshot.sh --cycle $CYCLE_ID --check $CHECK_ID --state $STATE"
fi

echo "[evo][evidence] 检查项: $CHECK_ID"
echo "[evo][evidence] 状态: $STATE"
echo "[evo][evidence] 时间(UTC): $UTC_TS"
