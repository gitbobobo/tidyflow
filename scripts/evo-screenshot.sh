#!/bin/bash
# Evolution 截图采集辅助脚本
# 用法:
#   ./scripts/evo-screenshot.sh --cycle <cycle_id> --check <check_id> --platform macOS|iOS|both --state empty|loading|ready [--run-id <run_id>] [--dry-run]
#   ./scripts/evo-screenshot.sh --cycle <cycle_id> --check <check_id> --platform both --states empty,loading,ready [--run-id <run_id>] [--dry-run]

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
EVOLUTION_DIR="$PROJECT_ROOT/.tidyflow/evolution"

CYCLE_ID=""
CHECK_ID="v-3"
PLATFORM="macOS"
STATE=""
STATES=""
RUN_ID=""
DRY_RUN=0

usage() {
    cat <<'USAGE'
Evolution 截图采集辅助脚本

用法:
  ./scripts/evo-screenshot.sh --cycle <cycle_id> --platform <macOS|iOS|both|macos|ios> --state <state> [options]
  ./scripts/evo-screenshot.sh --cycle <cycle_id> --platform both --states <s1,s2,...> [options]

选项:
  --cycle <id>       Cycle ID（必需）
  --check <id>       检查项 ID（默认：v-3）
  --platform <name>  平台：macOS|iOS|both|macos|ios（默认：macOS）
  --state <state>    状态：empty|loading|ready（兼容 initial|processing|complete|error）
  --states <list>    逗号分隔状态列表，如 empty,loading,ready（与 --state 二选一）
  --run-id <id>      关联 run_id（可选，默认最新）
  --dry-run          生成占位截图（用于无 GUI 场景）
  --help, -h         显示帮助
USAGE
}

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
        --platform)
            PLATFORM="${2:-macOS}"
            shift 2
            ;;
        --state)
            STATE="${2:-}"
            shift 2
            ;;
        --states)
            STATES="${2:-}"
            shift 2
            ;;
        --run-id)
            RUN_ID="${2:-}"
            shift 2
            ;;
        --dry-run)
            DRY_RUN=1
            shift
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            echo "[evo][evidence] ERROR: 未知参数: $1"
            usage
            exit 1
            ;;
    esac
done

if [ -z "$CYCLE_ID" ]; then
    echo "[evo][evidence] ERROR: 必须指定 --cycle"
    exit 1
fi

case "$PLATFORM" in
    macOS|macos)
        PLATFORM="macOS"
        ;;
    iOS|ios)
        PLATFORM="iOS"
        ;;
    both)
        PLATFORM="both"
        ;;
    *)
        echo "[evo][evidence] ERROR: --platform 仅支持 macOS|iOS|both|macos|ios"
        exit 1
        ;;
esac

if [ -n "$STATE" ] && [ -n "$STATES" ]; then
    echo "[evo][evidence] ERROR: --state 与 --states 不能同时指定"
    exit 1
fi

if [ -z "$STATE" ] && [ -z "$STATES" ]; then
    echo "[evo][evidence] ERROR: 必须指定 --state 或 --states"
    exit 1
fi

declare -a TARGET_STATES=()
if [ -n "$STATE" ]; then
    TARGET_STATES=("$STATE")
else
    IFS=',' read -r -a TARGET_STATES <<< "$STATES"
fi

normalize_state() {
    local input="$1"
    case "$input" in
        empty|loading|ready)
            echo "$input"
            return 0
            ;;
        initial)
            echo "empty"
            return 0
            ;;
        processing)
            echo "loading"
            return 0
            ;;
        complete|error)
            echo "ready"
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

declare -a NORMALIZED_STATES=()
for s in "${TARGET_STATES[@]}"; do
    normalized="$(normalize_state "$s" || true)"
    if [ -z "$normalized" ]; then
        echo "[evo][evidence] ERROR: 状态仅支持 empty|loading|ready（兼容 initial|processing|complete|error），当前: $s"
        exit 1
    fi
    if [ "$normalized" != "$s" ]; then
        echo "[evo][evidence] WARN: 旧状态 '$s' 已映射为 '$normalized'（deprecated）"
    fi
    NORMALIZED_STATES+=("$normalized")
done
TARGET_STATES=("${NORMALIZED_STATES[@]}")

declare -a TARGET_PLATFORMS=()
if [ "$PLATFORM" = "both" ]; then
    TARGET_PLATFORMS=("macOS" "iOS")
else
    TARGET_PLATFORMS=("$PLATFORM")
fi

CYCLE_DIR="$EVOLUTION_DIR/$CYCLE_ID"
if [ ! -d "$CYCLE_DIR" ]; then
    echo "[evo][evidence] ERROR: Cycle 目录不存在: $CYCLE_DIR"
    exit 1
fi

if [ -z "$RUN_ID" ] && [ -d "$CYCLE_DIR/runs" ]; then
    RUN_ID="$(ls -1 "$CYCLE_DIR/runs" 2>/dev/null | sort | tail -n 1 || true)"
fi
if [ -z "$RUN_ID" ]; then
    RUN_ID="manual-$(date -u +%Y%m%d-%H%M%S)"
fi

capture_one() {
    local platform="$1"
    local state="$2"
    local screenshot_dir="$CYCLE_DIR/artifacts/screenshots/$platform"
    mkdir -p "$screenshot_dir"

    local utc_ts filename filepath rel_path platform_lower related_log_rel
    utc_ts="$(date -u +%Y%m%dT%H%M%SZ)"
    filename="screenshot-${RUN_ID}-${CHECK_ID}-${platform}-${state}-${utc_ts}.png"
    filepath="$screenshot_dir/$filename"
    rel_path="artifacts/screenshots/$platform/$filename"
    platform_lower="$(echo "$platform" | tr '[:upper:]' '[:lower:]')"
    related_log_rel="runs/$RUN_ID/evidence/${platform_lower}-${CHECK_ID}-$RUN_ID.log"

    local capture_success=0
    local capture_mode="screen"
    if [ "$DRY_RUN" = "1" ]; then
        python3 - "$filepath" <<'PY'
import base64
import sys
from pathlib import Path

# 64x64 PNG（避免 1x1 占位导致 verify 无法复核）
png_b64 = "iVBORw0KGgoAAAANSUhEUgAAAEAAAABACAIAAAAlC+aJAAAAV0lEQVR4nO3PQQ0AIBDAsAP/nkEEj4ZkVbDtmVk/OzrgVQNaA1oDWgNaA1oDWgNaA1oDWgNaA1oDWgNaA1oDWgNaA1oDWgNaA1oDWgNaA1oDWgPaBRMVAhQf2R4wAAAAAElFTkSuQmCC"
out = Path(sys.argv[1])
out.write_bytes(base64.b64decode(png_b64))
PY
        capture_success=1
        capture_mode="dry_run"
    else
        if screencapture -x "$filepath" 2>/dev/null; then
            if [ -f "$filepath" ] && [ -s "$filepath" ]; then
                capture_success=1
            fi
        fi
    fi

    if [ "$capture_success" != "1" ]; then
        echo "[evo][evidence] CROSS_PLATFORM_FLOW_FAIL cycle_id=$CYCLE_ID check_id=$CHECK_ID run_id=$RUN_ID platform=$platform state=$state reason=screenshot_capture_failed"
        echo "[evo][evidence] failed_check_id=$CHECK_ID log_path=runs/$RUN_ID/evidence/${CHECK_ID}-screenshots-$RUN_ID.log screenshot_path=$rel_path"
        echo "[evo][evidence] ERROR: 截图失败"
        echo "[evo][evidence] 重试命令: ./scripts/evo-screenshot.sh --cycle $CYCLE_ID --check $CHECK_ID --platform $platform --state $state --run-id $RUN_ID"

        DIFF_PATH="$CYCLE_DIR/runs/$RUN_ID/evidence/diff-$RUN_ID.md"
        mkdir -p "$(dirname "$DIFF_PATH")"
        {
            echo ""
            echo "### 截图缺失记录"
            echo "- platform: $platform"
            echo "- state: $state"
            echo "- reason: screenshot capture failed"
            echo "- retry: ./scripts/evo-screenshot.sh --cycle $CYCLE_ID --check $CHECK_ID --platform $platform --state $state --run-id $RUN_ID"
        } >> "$DIFF_PATH"
        return 1
    fi

    echo "[evo][evidence] 截图保存成功: $filepath"

    if ! python3 - "$CYCLE_DIR" "$CYCLE_ID" "$RUN_ID" "$CHECK_ID" "$platform" "$state" "$rel_path" "$related_log_rel" "$capture_mode" <<'PY'
import hashlib
import json
import os
import tempfile
from datetime import datetime, timezone
from pathlib import Path
import sys

cycle_dir = Path(sys.argv[1])
cycle_id = sys.argv[2]
run_id = sys.argv[3]
check_id = sys.argv[4]
platform = sys.argv[5]
state = sys.argv[6]
rel_path = sys.argv[7]
related_log_rel = sys.argv[8]
capture_mode = sys.argv[9]

index_path = cycle_dir / "evidence.index.json"
now = datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")

required_types = ["build_log", "test_log", "screenshot", "diff_summary", "metrics"]

def read_index(path):
    if not path.exists():
        return {
            "$schema_version": "1.0",
            "cycle_id": cycle_id,
            "updated_at": now,
            "evidence": [],
            "failure_context": None,
            "completeness": {
                "required_types": required_types,
                "present_types": [],
                "missing_types": required_types,
                "completeness_ratio": 0.0,
            },
            "runs": [],
        }
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except Exception:
        backup = path.with_name(path.name + ".corrupted." + datetime.now(timezone.utc).strftime("%Y%m%d%H%M%S"))
        path.rename(backup)
        return {
            "$schema_version": "1.0",
            "cycle_id": cycle_id,
            "updated_at": now,
            "evidence": [],
            "failure_context": {
                "failed_check_id": "index-load",
                "timestamp": now,
                "error_message": f"原索引损坏，已备份到 {backup.name}",
                "log_keywords": ["[evo][evidence]", "index corrupted"],
                "screenshot_path": None,
            },
            "completeness": {
                "required_types": required_types,
                "present_types": [],
                "missing_types": required_types,
                "completeness_ratio": 0.0,
            },
            "runs": [],
        }


def sha1_8(path: Path) -> str:
    if not path.exists() or not path.is_file():
        return ""
    h = hashlib.sha1()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(8192), b""):
            h.update(chunk)
    return h.hexdigest()[:8]


data = read_index(index_path)
if not isinstance(data, dict):
    data = {}

data["$schema_version"] = "1.0"
data["cycle_id"] = cycle_id

existing = data.get("evidence", [])
if not isinstance(existing, list):
    existing = []
legacy = data.get("evidence_items", [])
if isinstance(legacy, list):
    for item in legacy:
        if item not in existing:
            existing.append(item)
legacy_items = data.get("items", [])
if isinstance(legacy_items, list):
    for item in legacy_items:
        if item not in existing:
            existing.append(item)

index_by_key = {}
for item in existing:
    if not isinstance(item, dict):
        continue
    if not item.get("run_id") or not item.get("check_id"):
        if item.get("status") not in {"missing", "legacy_unscoped"}:
            item["status"] = "legacy_unscoped"
    meta = item.get("metadata") if isinstance(item.get("metadata"), dict) else {}
    key = f"{item.get('run_id', '')}:{item.get('check_id', '')}:{meta.get('platform', '')}:{meta.get('state', '')}"
    if key.endswith(":") or key.count(":") < 3:
        key = f"{item.get('run_id', '')}:{item.get('check_id', '')}:{item.get('path', '')}:{item.get('artifact_hash', '')}"
    index_by_key[key] = item

artifact_path = cycle_dir / rel_path
artifact_hash = sha1_8(artifact_path)
seed = f"{run_id}:{check_id}:{platform}:{state}"
evidence_id = "ev-" + hashlib.sha1(seed.encode("utf-8")).hexdigest()[:12]

item = {
    "evidence_id": evidence_id,
    "type": "screenshot",
    "path": rel_path,
    "generated_by_stage": "implement",
    "linked_criteria_ids": ["ac-1", "ac-3"],
    "summary": f"截图证据 platform={platform} state={state} check={check_id}",
    "created_at": now,
    "run_id": run_id,
    "check_id": check_id,
    "artifact_hash": artifact_hash,
    "status": "valid",
    "metadata": {
        "platform": platform,
        "state": state,
        "related_test_log": related_log_rel,
        "capture_mode": capture_mode,
    },
}

key = f"{run_id}:{check_id}:{platform}:{state}"
if key in index_by_key and isinstance(index_by_key[key], dict):
    old = index_by_key[key]
    if old.get("evidence_id"):
        item["evidence_id"] = old["evidence_id"]
    if old.get("created_at"):
        item["created_at"] = old["created_at"]

index_by_key[key] = item
all_items = list(index_by_key.values())
all_items.sort(key=lambda x: (x.get("run_id", ""), x.get("path", "")))

data["evidence"] = all_items

present_types = sorted({
    i.get("type")
    for i in all_items
    if i.get("status") not in {"missing", "legacy_unscoped"}
})
missing_types = sorted([t for t in required_types if t not in present_types])
ratio = round((len(required_types) - len(missing_types)) / len(required_types), 4)

data["completeness"] = {
    "required_types": required_types,
    "present_types": present_types,
    "missing_types": missing_types,
    "completeness_ratio": ratio,
}

data["updated_at"] = now

fd, tmp_path = tempfile.mkstemp(prefix="evidence.index.", suffix=".tmp", dir=str(cycle_dir))
try:
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, indent=2)
        f.write("\n")
    os.replace(tmp_path, index_path)
except Exception:
    try:
        os.unlink(tmp_path)
    except FileNotFoundError:
        pass
    raise
PY
    then
        echo "[evo][evidence] EVIDENCE_INDEX_WRITE_FAIL cycle_id=$CYCLE_ID check_id=$CHECK_ID run_id=$RUN_ID platform=$platform state=$state"
        return 1
    fi

    echo "[evo][evidence] EVIDENCE_INDEX_WRITE_OK cycle_id=$CYCLE_ID check_id=$CHECK_ID run_id=$RUN_ID platform=$platform state=$state"
    echo "[evo][evidence] check=$CHECK_ID platform=$platform state=$state run_id=$RUN_ID"
    echo "[evo][evidence] related_log=$related_log_rel"
    return 0
}

echo "[evo][evidence] CROSS_PLATFORM_FLOW_START cycle_id=$CYCLE_ID check_id=$CHECK_ID run_id=$RUN_ID platform=$PLATFORM states=${TARGET_STATES[*]}"
for platform in "${TARGET_PLATFORMS[@]}"; do
    for state in "${TARGET_STATES[@]}"; do
        capture_one "$platform" "$state" || exit 1
    done
done
echo "[evo][evidence] CROSS_PLATFORM_FLOW_SUCCESS cycle_id=$CYCLE_ID check_id=$CHECK_ID run_id=$RUN_ID platform=$PLATFORM states=${TARGET_STATES[*]}"
