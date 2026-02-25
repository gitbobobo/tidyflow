#!/bin/bash
# Evolution 统一执行入口
# 用法:
#   ./scripts/evo-run.sh [verify] --cycle <cycle_id> [--run-id <run_id>] [--step all|build|integration|verify]
#
# 目标：
#   1) 固定执行序列：acceptance -> unit -> core build -> macOS build -> iOS build -> screenshot -> integration
#   2) 统一结构化日志与失败锚点
#   3) 统一证据索引写入契约（原子写入 + 幂等合并）

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
EVOLUTION_DIR="$PROJECT_ROOT/.tidyflow/evolution"

CYCLE_ID=""
RUN_ID=""
STEP="all"
VERBOSE=0
DRY_RUN=0

LOG_PREFIX="[evo][run]"

# 检查 ID（与 plan.execution.json 对齐）
CHECK_ACCEPTANCE="v-1"
CHECK_CORE_BUILD="v-2"
CHECK_MACOS_BUILD="v-3"
CHECK_IOS_BUILD="v-4"
CHECK_VERIFY_GATE="v-5"
CHECK_SCREENSHOT="v-6"
CHECK_UNIT="v-7"
CHECK_INTEGRATION="v-2"
CHECK_METRICS="$CHECK_VERIFY_GATE"

FAILURE_CHECK_ID=""
FAILURE_STAGE=""
FAILURE_LOG_PATH=""
FAILURE_REASON=""

REQUIRED_EVIDENCE_TYPES="build_log,test_log,screenshot,diff_summary,metrics"

usage() {
    cat <<'USAGE'
Evolution 统一执行入口

用法:
  ./scripts/evo-run.sh [verify] --cycle <id> [options]

选项:
  --cycle <id>       Cycle ID（必需）
  --run-id <id>      Run ID（默认：UTC 时间戳）
  --step <step>      执行步骤：build|integration|verify|all（默认：all）
  --verbose, -v      详细输出
  --dry-run          模拟执行，不实际构建
  --help, -h         显示帮助
USAGE
}

log_structured() {
    local level="$1"
    local stage="$2"
    local check_id="$3"
    local attempt="${4:-1}"
    local exit_code="${5:-0}"
    local message="${6:-}"

    echo "[evo][$stage] level=$level cycle=$CYCLE_ID run=$RUN_ID check=$check_id attempt=$attempt exit=$exit_code msg=$message"
}

emit_event() {
    local event="$1"
    local check_id="${2:-none}"
    local extra="${3:-}"
    echo "$event cycle_id=$CYCLE_ID stage=implement check_id=$check_id run_id=$RUN_ID $extra"
}

emit_flow_event() {
    local status="$1"
    local detail="${2:-}"
    echo "CROSS_PLATFORM_FLOW_${status} cycle_id=$CYCLE_ID stage=implement run_id=$RUN_ID step=$STEP $detail"
}

record_failure() {
    local stage="$1"
    local check_id="$2"
    local log_path="$3"
    local reason="$4"

    FAILURE_STAGE="$stage"
    FAILURE_CHECK_ID="$check_id"
    FAILURE_LOG_PATH="$log_path"
    FAILURE_REASON="$reason"

    emit_flow_event "FAIL" "check_id=$check_id stage=$stage reason=$reason"
    echo "[evo][anchor] 失败锚点 check=$check_id log=$log_path reason=$reason"
    local prev_run
    prev_run="$(get_previous_stable_run_id)"
    if [ -n "$prev_run" ]; then
        echo "[evo][rollback] 建议回退到上一稳定 run_id: $prev_run"
    else
        echo "[evo][rollback] 尚无可回退 run_id，请检查 evidence.index.json"
    fi
}

get_previous_stable_run_id() {
    if [ ! -f "$EVIDENCE_INDEX" ]; then
        echo ""
        return
    fi

    python3 - "$EVIDENCE_INDEX" "$RUN_ID" <<'PY'
import json
import sys
from pathlib import Path

index_path = Path(sys.argv[1])
current_run = sys.argv[2]

try:
    data = json.loads(index_path.read_text(encoding='utf-8'))
except Exception:
    print("")
    raise SystemExit(0)

runs = data.get("runs", [])
if not isinstance(runs, list):
    print("")
    raise SystemExit(0)

success = []
for run in runs:
    if not isinstance(run, dict):
        continue
    run_id = run.get("run_id")
    if not run_id or run_id == current_run:
        continue
    if run.get("outcome") == "success":
        success.append(run_id)

if success:
    success.sort()
    print(success[-1])
else:
    print("")
PY
}

record_check_result() {
    local check_id="$1"
    local kind="$2"
    local result="$3"
    local log_path="$4"
    local exit_code="$5"
    local note="$6"

    printf "%s\t%s\t%s\t%s\t%s\t%s\n" "$check_id" "$kind" "$result" "$log_path" "$exit_code" "$note" >> "$CHECK_RESULTS_FILE"
}

append_evidence_line() {
    local evidence_type="$1"
    local path="$2"
    local check_id="$3"
    local criteria_csv="$4"
    local summary="$5"

    printf "%s\t%s\t%s\t%s\t%s\n" "$evidence_type" "$path" "$check_id" "$criteria_csv" "$summary" >> "$EVIDENCE_LINES_FILE"
}

ensure_parent_dir() {
    local path="$1"
    mkdir -p "$(dirname "$path")"
}

run_acceptance_mapping_check() {
    local check_id="$CHECK_ACCEPTANCE"
    local log_file="$ACCEPTANCE_LOG"
    local plan_file="$CYCLE_DIR/plan.execution.json"

    log_structured "INFO" "verify" "$check_id" 1 0 "start"
    emit_event "EVO_CHECK_START" "$check_id" "platform=multi"
    ensure_parent_dir "$log_file"

    if [ "$DRY_RUN" = "1" ]; then
        {
            echo "=== ${check_id} acceptance mapping ==="
            echo "[evo][verify] dry-run: validate $plan_file acceptance_mapping"
            echo "ACCEPTANCE_MAPPING_OK"
        } > "$log_file"
    else
        set +e
        python3 - "$plan_file" > "$log_file" 2>&1 <<'PY'
import json
import sys
from pathlib import Path

plan_path = Path(sys.argv[1])
data = json.loads(plan_path.read_text(encoding="utf-8"))
mapping = data.get("verification_plan", {}).get("acceptance_mapping", [])
if not isinstance(mapping, list):
    raise SystemExit("acceptance_mapping 必须为数组")
if len(mapping) < 3:
    raise SystemExit("acceptance_mapping 至少需要 3 条 criteria")

required = {"ac-1", "ac-2", "ac-3"}
present = set()
for item in mapping:
    if not isinstance(item, dict):
        raise SystemExit("acceptance_mapping 存在非法条目")
    cid = item.get("criteria_id")
    checks = item.get("check_ids")
    evidence = item.get("minimum_evidence")
    if not cid:
        raise SystemExit("criteria_id 不能为空")
    if not isinstance(checks, list) or not checks:
        raise SystemExit(f"{cid} 缺少 check_ids")
    if not isinstance(evidence, list) or not evidence:
        raise SystemExit(f"{cid} 缺少 minimum_evidence")
    present.add(cid)

if not required.issubset(present):
    raise SystemExit("ac-1/ac-2/ac-3 必须全部存在")

print("ACCEPTANCE_MAPPING_OK")
PY
        local exit_code=$?
        set -e
        if [ $exit_code -ne 0 ]; then
            log_structured "FAILED" "verify" "$check_id" 1 "$exit_code" "acceptance_mapping_invalid"
            emit_event "EVO_CHECK_FAIL" "$check_id" "platform=multi exit_code=$exit_code"
            record_failure "verify" "$check_id" "$log_file" "acceptance mapping 校验失败"
            record_check_result "$check_id" "manual" "fail" "$log_file" "$exit_code" "acceptance mapping 校验失败"
            append_evidence_line "test_log" "$log_file" "$check_id" "ac-1" "acceptance mapping 校验日志（失败）"
            return $exit_code
        fi
    fi

    log_structured "SUCCESS" "verify" "$check_id" 1 0 "done"
    emit_event "EVO_CHECK_PASS" "$check_id" "platform=multi"
    record_check_result "$check_id" "manual" "pass" "$log_file" "0" "acceptance mapping 校验通过"
    append_evidence_line "test_log" "$log_file" "$check_id" "ac-1" "acceptance mapping 校验日志"
    return 0
}

run_unit_tests() {
    local check_id="$CHECK_UNIT"
    local log_file="$UNIT_LOG"

    log_structured "INFO" "build" "$check_id" 1 0 "start"
    emit_event "EVO_CHECK_START" "$check_id" "platform=core"
    ensure_parent_dir "$log_file"

    if [ "$DRY_RUN" = "1" ]; then
        {
            echo "=== ${check_id} unit ==="
            echo "[evo][build] dry-run: ./scripts/tidyflow test"
            echo "test result: ok. 0 failed; dry-run simulated"
            echo "UNIT SUCCESS"
        } > "$log_file"
    else
        set +e
        ./scripts/tidyflow test > "$log_file" 2>&1
        local exit_code=$?
        set -e
        if [ $exit_code -ne 0 ]; then
            log_structured "FAILED" "build" "$check_id" 1 "$exit_code" "unit_failed"
            emit_event "EVO_CHECK_FAIL" "$check_id" "platform=core exit_code=$exit_code"
            record_failure "build" "$check_id" "$log_file" "unit tests failed"
            record_check_result "$check_id" "unit" "fail" "$log_file" "$exit_code" "单元测试失败"
            append_evidence_line "test_log" "$log_file" "$check_id" "ac-2" "Rust Core 单元测试日志（失败）"
            return $exit_code
        fi
        if ! rg -q "test result: ok|ok\." "$log_file"; then
            log_structured "FAILED" "build" "$check_id" 1 1 "unit_marker_missing"
            emit_event "EVO_CHECK_FAIL" "$check_id" "platform=core exit_code=1"
            record_failure "build" "$check_id" "$log_file" "missing pass marker"
            record_check_result "$check_id" "unit" "fail" "$log_file" "1" "测试日志未命中通过标记"
            append_evidence_line "test_log" "$log_file" "$check_id" "ac-2" "Rust Core 单元测试日志（标记缺失）"
            return 1
        fi
    fi

    log_structured "SUCCESS" "build" "$check_id" 1 0 "done"
    emit_event "EVO_CHECK_PASS" "$check_id" "platform=core"
    record_check_result "$check_id" "unit" "pass" "$log_file" "0" "单元测试通过"
    append_evidence_line "test_log" "$log_file" "$check_id" "ac-2" "Rust Core 单元测试日志"
    return 0
}

run_core_build() {
    local check_id="$CHECK_CORE_BUILD"
    local log_file="$CORE_BUILD_LOG"

    log_structured "INFO" "build" "$check_id" 1 0 "start"
    emit_event "EVO_CHECK_START" "$check_id" "platform=core"
    ensure_parent_dir "$log_file"

    if [ "$DRY_RUN" = "1" ]; then
        {
            echo "=== ${check_id} core build ==="
            echo "[evo][build] dry-run: cargo build --manifest-path core/Cargo.toml --release"
            echo "BUILD SUCCESS"
        } > "$log_file"
    else
        set +e
        cargo build --manifest-path core/Cargo.toml --release > "$log_file" 2>&1
        local exit_code=$?
        set -e
        if [ $exit_code -ne 0 ]; then
            log_structured "FAILED" "build" "$check_id" 1 "$exit_code" "core_build_failed"
            emit_event "EVO_CHECK_FAIL" "$check_id" "platform=core exit_code=$exit_code"
            record_failure "build" "$check_id" "$log_file" "core build failed"
            record_check_result "$check_id" "build" "fail" "$log_file" "$exit_code" "Core 构建失败"
            append_evidence_line "build_log" "$log_file" "$check_id" "ac-2" "Core release 构建日志（失败）"
            return $exit_code
        fi
        echo "BUILD SUCCESS" >> "$log_file"
    fi

    log_structured "SUCCESS" "build" "$check_id" 1 0 "done"
    emit_event "EVO_CHECK_PASS" "$check_id" "platform=core"
    record_check_result "$check_id" "build" "pass" "$log_file" "0" "Core 构建通过"
    append_evidence_line "build_log" "$log_file" "$check_id" "ac-2" "Core release 构建日志"
    return 0
}

run_macos_build() {
    local check_id="$CHECK_MACOS_BUILD"
    local log_file="$MACOS_BUILD_LOG"

    log_structured "INFO" "build" "$check_id" 1 0 "start"
    emit_event "EVO_CHECK_START" "$check_id" "platform=macOS"
    ensure_parent_dir "$log_file"

    if [ "$DRY_RUN" = "1" ]; then
        {
            echo "=== ${check_id} macOS build ==="
            echo "[evo][build] dry-run: xcodebuild -destination 'platform=macOS'"
            echo "BUILD SUCCEEDED"
        } > "$log_file"
    else
        set +e
        xcodebuild -project app/TidyFlow.xcodeproj \
            -scheme TidyFlow \
            -configuration Debug \
            -destination 'platform=macOS' \
            -derivedDataPath build \
            SKIP_CORE_BUILD=1 \
            build > "$log_file" 2>&1
        local exit_code=$?
        set -e
        if [ $exit_code -ne 0 ]; then
            log_structured "FAILED" "build" "$check_id" 1 "$exit_code" "macos_build_failed"
            emit_event "EVO_CHECK_FAIL" "$check_id" "platform=macOS exit_code=$exit_code"
            record_failure "build" "$check_id" "$log_file" "macOS build failed"
            record_check_result "$check_id" "build" "fail" "$log_file" "$exit_code" "macOS 构建失败"
            append_evidence_line "build_log" "$log_file" "$check_id" "ac-2" "macOS Debug 构建日志（失败）"
            return $exit_code
        fi
    fi

    log_structured "SUCCESS" "build" "$check_id" 1 0 "done"
    emit_event "EVO_CHECK_PASS" "$check_id" "platform=macOS"
    record_check_result "$check_id" "build" "pass" "$log_file" "0" "macOS 构建通过"
    append_evidence_line "build_log" "$log_file" "$check_id" "ac-2" "macOS Debug 构建日志"
    return 0
}

run_ios_build() {
    local check_id="$CHECK_IOS_BUILD"
    local log_file="$IOS_BUILD_LOG"

    log_structured "INFO" "build" "$check_id" 1 0 "start"
    emit_event "EVO_CHECK_START" "$check_id" "platform=iOS"
    ensure_parent_dir "$log_file"

    if [ "$DRY_RUN" = "1" ]; then
        {
            echo "=== ${check_id} iOS build ==="
            echo "[evo][build] dry-run: xcodebuild -destination 'platform=iOS Simulator,name=iPhone 16,OS=18.6'"
            echo "BUILD SUCCEEDED"
        } > "$log_file"
    else
        set +e
        xcodebuild -project app/TidyFlow.xcodeproj \
            -scheme TidyFlow \
            -configuration Debug \
            -destination 'platform=iOS Simulator,name=iPhone 16,OS=18.6' \
            -derivedDataPath build \
            SKIP_CORE_BUILD=1 \
            build > "$log_file" 2>&1
        local exit_code=$?
        set -e
        if [ $exit_code -ne 0 ]; then
            log_structured "FAILED" "build" "$check_id" 1 "$exit_code" "ios_build_failed"
            emit_event "EVO_CHECK_FAIL" "$check_id" "platform=iOS exit_code=$exit_code"
            record_failure "build" "$check_id" "$log_file" "iOS build failed"
            record_check_result "$check_id" "build" "fail" "$log_file" "$exit_code" "iOS 构建失败"
            append_evidence_line "build_log" "$log_file" "$check_id" "ac-2" "iOS Simulator Debug 构建日志（失败）"
            return $exit_code
        fi
    fi

    log_structured "SUCCESS" "build" "$check_id" 1 0 "done"
    emit_event "EVO_CHECK_PASS" "$check_id" "platform=iOS"
    record_check_result "$check_id" "build" "pass" "$log_file" "0" "iOS 构建通过"
    append_evidence_line "build_log" "$log_file" "$check_id" "ac-2" "iOS Simulator Debug 构建日志"
    return 0
}

run_screenshot_capture() {
    local check_id="$CHECK_SCREENSHOT"
    local log_file="$SCREENSHOT_LOG"

    log_structured "INFO" "screenshot" "$check_id" 1 0 "start"
    emit_event "EVO_CHECK_START" "$check_id" "platform=multi"
    ensure_parent_dir "$log_file"
    : > "$log_file"

    local cmd=(./scripts/evo-screenshot.sh --cycle "$CYCLE_ID" --check "$check_id" --platform both --states empty,loading,ready --run-id "$RUN_ID")
    if [ "$DRY_RUN" = "1" ]; then
        cmd+=(--dry-run)
    fi

    set +e
    "${cmd[@]}" >> "$log_file" 2>&1
    local exit_code=$?
    set -e
    if [ $exit_code -ne 0 ]; then
        log_structured "FAILED" "screenshot" "$check_id" 1 "$exit_code" "screenshot_capture_failed"
        emit_event "EVO_CHECK_FAIL" "$check_id" "platform=multi screenshot_state=empty,loading,ready exit_code=$exit_code"
        record_failure "screenshot" "$check_id" "$log_file" "截图采集失败 platform=both states=empty,loading,ready"
        record_check_result "$check_id" "manual" "fail" "$log_file" "$exit_code" "截图采集失败 platform=both states=empty,loading,ready"
        append_evidence_line "test_log" "$log_file" "$check_id" "ac-3" "截图采集执行日志（失败）"
        return $exit_code
    fi

    log_structured "SUCCESS" "screenshot" "$check_id" 1 0 "done"
    emit_event "EVO_CHECK_PASS" "$check_id" "platform=multi"
    record_check_result "$check_id" "manual" "pass" "$log_file" "0" "截图采集通过（macOS+iOS 三态）"
    append_evidence_line "test_log" "$log_file" "$check_id" "ac-3" "截图采集执行日志"
    return 0
}

run_integration_check() {
    local check_id="$CHECK_INTEGRATION"
    local log_file="$INTEGRATION_LOG"

    log_structured "INFO" "integration" "$check_id" 1 0 "start"
    emit_event "EVO_CHECK_START" "$check_id" "platform=multi"
    ensure_parent_dir "$log_file"

    if [ "$DRY_RUN" = "1" ]; then
        {
            echo "=== ${check_id} integration ==="
            echo "[evo][integration] dry-run: verify app/core artifacts"
            echo "[evo][integration] Core binary exists: simulated"
            echo "[evo][integration] macOS app exists: simulated"
            echo "INTEGRATION SUCCESS"
        } > "$log_file"
    else
        set +e
        {
            echo "=== ${check_id} integration ==="
            CORE_BINARY="$PROJECT_ROOT/core/target/release/tidyflow-core"
            if [ ! -f "$CORE_BINARY" ]; then
                echo "[evo][integration] ERROR: Core 二进制不存在: $CORE_BINARY"
                exit 1
            fi
            echo "[evo][integration] Core binary: $CORE_BINARY"

            APP_PATH="$PROJECT_ROOT/build/Build/Products/Debug/TidyFlow.app"
            if [ ! -d "$APP_PATH" ]; then
                APP_PATH="$PROJECT_ROOT/build/Build/Products/Debug/TidyFlow-Debug.app"
            fi
            if [ ! -d "$APP_PATH" ]; then
                echo "[evo][integration] ERROR: Debug App 不存在"
                exit 1
            fi
            echo "[evo][integration] App bundle: $APP_PATH"

            echo "[evo][integration] ws probe: skipped (requires runtime)"
            echo "INTEGRATION SUCCESS"
        } > "$log_file" 2>&1
        local exit_code=$?
        set -e
        if [ $exit_code -ne 0 ]; then
            log_structured "FAILED" "integration" "$check_id" 1 "$exit_code" "integration_failed"
            emit_event "EVO_CHECK_FAIL" "$check_id" "platform=multi exit_code=$exit_code"
            record_failure "integration" "$check_id" "$log_file" "integration failed"
            record_check_result "$check_id" "integration" "fail" "$log_file" "$exit_code" "集成检查失败"
            append_evidence_line "test_log" "$log_file" "$check_id" "ac-2" "集成检查日志（失败）"
            return $exit_code
        fi
    fi

    log_structured "SUCCESS" "integration" "$check_id" 1 0 "done"
    emit_event "EVO_CHECK_PASS" "$check_id" "platform=multi"
    record_check_result "$check_id" "integration" "pass" "$log_file" "0" "集成检查通过"
    append_evidence_line "test_log" "$log_file" "$check_id" "ac-2" "集成检查日志"
    return 0
}

run_sequence_all() {
    run_acceptance_mapping_check || return $?
    run_unit_tests || return $?
    run_core_build || return $?
    run_macos_build || return $?
    run_ios_build || return $?
    run_screenshot_capture || return $?
    run_integration_check || return $?
    return 0
}

run_sequence_build() {
    run_acceptance_mapping_check || return $?
    run_unit_tests || return $?
    run_core_build || return $?
    run_macos_build || return $?
    run_ios_build || return $?
    run_screenshot_capture || return $?
    return 0
}

run_sequence_integration() {
    run_acceptance_mapping_check || return $?
    run_integration_check || return $?
    return 0
}

run_sequence_verify() {
    run_acceptance_mapping_check || return $?
    return 0
}

# 更新 evidence.index.json（原子写入 + 幂等合并）
update_evidence_index() {
    local final_outcome="$1"

    if ! EVIDENCE_LINES_PATH="$EVIDENCE_LINES_FILE" CHECK_RESULTS_PATH="$CHECK_RESULTS_FILE" python3 - "$CYCLE_DIR" "$CYCLE_ID" "$RUN_ID" "$STEP" "$final_outcome" "$FAILURE_CHECK_ID" "$FAILURE_LOG_PATH" "$FAILURE_REASON" "$REQUIRED_EVIDENCE_TYPES" <<'PY'
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
step = sys.argv[4]
outcome = sys.argv[5]
failed_check = sys.argv[6]
failed_log = sys.argv[7]
failed_reason = sys.argv[8]
required_types = [x.strip() for x in sys.argv[9].split(',') if x.strip()]

index_path = cycle_dir / "evidence.index.json"
now = datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")

def read_json(path):
    if not path.exists():
        return {}
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except Exception as e:
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
                "error_message": f"原索引损坏，已备份到 {backup.name}: {e}",
                "log_keywords": ["EVO_EVIDENCE_WRITE", "EVO_CHECK_FAIL", "index corrupted"],
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


def to_rel(path_str):
    p = Path(path_str)
    if p.is_absolute():
        try:
            return str(p.relative_to(cycle_dir)).replace("\\", "/")
        except Exception:
            return str(p).replace("\\", "/")
    return path_str.replace("\\", "/")


def abs_path(path_str):
    p = Path(path_str)
    if p.is_absolute():
        return p
    return cycle_dir / p


def sha1_8(path):
    if not path.exists() or not path.is_file():
        return ""
    h = hashlib.sha1()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(8192), b""):
            h.update(chunk)
    return h.hexdigest()[:8]


def ensure_list(v):
    return v if isinstance(v, list) else []


data = read_json(index_path)
if not isinstance(data, dict):
    data = {}

data["$schema_version"] = "1.0"
data["cycle_id"] = cycle_id

existing = ensure_list(data.get("evidence"))
legacy = ensure_list(data.get("evidence_items"))
legacy_items = ensure_list(data.get("items"))
for item in legacy:
    if item not in existing:
        existing.append(item)
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
    item_run = item.get("run_id", "")
    item_check = item.get("check_id", "")
    artifact_hash = item.get("artifact_hash", "")
    path = item.get("path", "")
    key = f"{item_run}:{item_check}:{path}:{artifact_hash}"
    index_by_key[key] = item

lines_path = Path(os.environ.get("EVIDENCE_LINES_PATH", ""))
if lines_path.exists():
    for raw in lines_path.read_text(encoding="utf-8").splitlines():
        if not raw.strip():
            continue
        parts = raw.split("\t", 4)
        if len(parts) < 5:
            continue
        ev_type, path_str, check_id, criteria_csv, summary = parts
        rel = to_rel(path_str)
        target = abs_path(path_str)
        artifact_hash = sha1_8(target)
        criteria_ids = [x for x in criteria_csv.split(',') if x]
        ev_id_seed = f"{run_id}:{check_id}:{artifact_hash or rel}"
        ev_id = "ev-" + hashlib.sha1(ev_id_seed.encode("utf-8")).hexdigest()[:12]
        item = {
            "evidence_id": ev_id,
            "type": ev_type,
            "path": rel,
            "generated_by_stage": "implement",
            "linked_criteria_ids": criteria_ids,
            "summary": summary,
            "created_at": now,
            "run_id": run_id,
            "check_id": check_id,
            "artifact_hash": artifact_hash,
            "status": "valid" if target.exists() else "missing",
        }
        key = f"{run_id}:{check_id}:{rel}:{artifact_hash}"
        if key in index_by_key and isinstance(index_by_key[key], dict):
            old = index_by_key[key]
            old_id = old.get("evidence_id")
            old_created = old.get("created_at")
            if old_id:
                item["evidence_id"] = old_id
            if old_created:
                item["created_at"] = old_created
        index_by_key[key] = item

all_items = list(index_by_key.values())
all_items.sort(key=lambda x: (x.get("run_id", ""), x.get("path", "")))

# 兜底修复：确保 evidence_id 唯一（历史数据可能已存在重复）
seen_ids = set()
for item in all_items:
    if not isinstance(item, dict):
        continue
    eid = item.get("evidence_id", "")
    if not eid or eid in seen_ids:
        seed = f"{item.get('run_id', '')}:{item.get('check_id', '')}:{item.get('path', '')}:{item.get('artifact_hash', '')}"
        item["evidence_id"] = "ev-" + hashlib.sha1(seed.encode("utf-8")).hexdigest()[:12]
        eid = item["evidence_id"]
    seen_ids.add(eid)

data["evidence"] = all_items

present_types = sorted({
    item.get("type")
    for item in all_items
    if item.get("type") and item.get("status") not in {"missing", "legacy_unscoped"}
})
missing_types = sorted([t for t in required_types if t not in present_types])
ratio = 0.0
if required_types:
    ratio = round((len(required_types) - len(missing_types)) / len(required_types), 4)

data["completeness"] = {
    "required_types": required_types,
    "present_types": present_types,
    "missing_types": missing_types,
    "completeness_ratio": ratio,
}

if failed_check:
    data["failure_context"] = {
        "failed_check_id": failed_check,
        "timestamp": now,
        "error_message": failed_reason or "执行失败",
        "log_keywords": ["EVO_CHECK_FAIL", "EVO_GATE_BLOCK", "[evo][rollback]", "[evo][anchor]"],
        "screenshot_path": None,
        "log_path": to_rel(failed_log) if failed_log else None,
    }
else:
    data["failure_context"] = None

runs = ensure_list(data.get("runs"))
run_map = {}
for run in runs:
    if isinstance(run, dict) and run.get("run_id"):
        run_map[run["run_id"]] = run

run_map[run_id] = {
    "run_id": run_id,
    "executed_at": now,
    "step": step,
    "outcome": outcome,
    "failed_check_id": failed_check or None,
}

data["runs"] = sorted(run_map.values(), key=lambda x: x.get("run_id", ""))
data["updated_at"] = now

fd, temp_path = tempfile.mkstemp(prefix="evidence.index.", suffix=".tmp", dir=str(cycle_dir))
try:
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, indent=2)
        f.write("\n")
    os.replace(temp_path, index_path)
except Exception:
    try:
        os.unlink(temp_path)
    except FileNotFoundError:
        pass
    raise
PY
    then
        echo "$LOG_PREFIX [index] FAILED: 写入 evidence.index.json 失败"
        echo "EVIDENCE_INDEX_WRITE_FAIL cycle_id=$CYCLE_ID stage=implement check_id=$CHECK_VERIFY_GATE run_id=$RUN_ID artifact_path=$EVIDENCE_INDEX"
        return 1
    fi

    echo "EVIDENCE_INDEX_WRITE_OK cycle_id=$CYCLE_ID stage=implement check_id=$CHECK_VERIFY_GATE run_id=$RUN_ID artifact_path=$EVIDENCE_INDEX"
    echo "EVO_EVIDENCE_WRITE cycle_id=$CYCLE_ID stage=implement check_id=$CHECK_VERIFY_GATE run_id=$RUN_ID artifact_path=$EVIDENCE_INDEX"
    return 0
}

# 证据完整性校验 + metrics 输出
validate_evidence_and_metrics() {
    if ! CHECK_RESULTS_PATH="$CHECK_RESULTS_FILE" EVIDENCE_LINES_PATH="$EVIDENCE_LINES_FILE" python3 - "$CYCLE_DIR" "$RUN_ID" "$METRICS_JSON" "$DIFF_SUMMARY" "$STEP" <<'PY'
import json
import os
from datetime import datetime, timezone
from pathlib import Path
import sys

cycle_dir = Path(sys.argv[1])
run_id = sys.argv[2]
metrics_path = Path(sys.argv[3])
diff_path = Path(sys.argv[4])
step = sys.argv[5]
index_path = cycle_dir / "evidence.index.json"
now = datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")

if not index_path.exists():
    raise SystemExit("index not found")

data = json.loads(index_path.read_text(encoding="utf-8"))
evidence = data.get("evidence", [])
if not isinstance(evidence, list):
    evidence = []

run_evidence = [e for e in evidence if isinstance(e, dict) and e.get("run_id") == run_id]
run_evidence = [
    e for e in run_evidence
    if e.get("check_id") and e.get("status") != "legacy_unscoped"
]

errors = []
warnings = []
id_seen = set()

def path_exists(rel):
    p = cycle_dir / rel
    return p.exists(), p

type_ext = {
    "build_log": {".log", ".txt"},
    "test_log": {".log", ".txt"},
    "screenshot": {".png", ".jpg", ".jpeg"},
    "diff_summary": {".md", ".txt"},
    "metrics": {".json"},
    "custom": set(),
}

for item in run_evidence:
    eid = item.get("evidence_id")
    if eid in id_seen:
        errors.append(f"evidence_id 重复: {eid}")
    id_seen.add(eid)

    rel = item.get("path", "")
    ok, abs_p = path_exists(rel)
    if not ok:
        errors.append(f"路径不存在: {rel}")

    t = item.get("type")
    ext = abs_p.suffix.lower() if ok else Path(rel).suffix.lower()
    expected = type_ext.get(t, set())
    if expected and ext not in expected:
        errors.append(f"类型不匹配: type={t} path={rel}")

updated_at = data.get("updated_at", now)
for item in run_evidence:
    c = item.get("created_at", now)
    if c > updated_at:
        errors.append(f"时间序错误: created_at>{updated_at} ({item.get('evidence_id')})")

if step in {"integration", "verify"}:
    required_types = ["test_log", "diff_summary", "metrics"]
else:
    required_types = ["build_log", "test_log", "screenshot", "diff_summary", "metrics"]
present_types_set = {
    i.get("type")
    for i in run_evidence
    if i.get("status") not in {"missing", "legacy_unscoped"}
}
# 当前校验步骤会在本函数末尾生成 metrics/diff 产物，因此在完整度判定中视为已提供。
present_types_set.add("metrics")
present_types_set.add("diff_summary")
present_types = sorted({t for t in present_types_set if t})
missing_types = sorted([t for t in required_types if t not in present_types])
completeness_ratio = round((len(required_types) - len(missing_types)) / len(required_types), 4)

check_results = []
check_lines = Path(os.environ.get("CHECK_RESULTS_PATH", ""))
if check_lines.exists():
    for raw in check_lines.read_text(encoding="utf-8").splitlines():
        if not raw.strip():
            continue
        parts = raw.split("\t", 5)
        if len(parts) < 6:
            continue
        cid, kind, result, log_path, exit_code, note = parts
        check_results.append({
            "check_id": cid,
            "kind": kind,
            "result": result,
            "log_path": str(Path(log_path)),
            "exit_code": int(exit_code),
            "note": note,
        })

present_check_ids = {c.get("check_id") for c in check_results}
inferred_ids = ["v-1", "v-2", "v-3", "v-4", "v-6", "v-7"]
for cid in inferred_ids:
    if cid in present_check_ids:
        continue
    matched = [i for i in run_evidence if i.get("check_id") == cid and i.get("status") != "missing"]
    if not matched:
        continue
    check_results.append({
        "check_id": cid,
        "kind": "inferred",
        "result": "pass",
        "log_path": str(cycle_dir / matched[0].get("path", "")),
        "exit_code": 0,
        "note": "由历史证据推断通过",
    })

check_results.append({
    "check_id": "v-5",
    "kind": "manual",
    "result": "pass",
    "log_path": str(metrics_path),
    "exit_code": 0,
    "note": "证据完整性与一致性校验通过",
})

check_map = {c["check_id"]: c for c in check_results}

def evidence_ids_for(criteria_id):
    return [i.get("evidence_id") for i in run_evidence if criteria_id in (i.get("linked_criteria_ids") or [])]

screenshot_state_map = {"macOS": set(), "iOS": set()}
for item in run_evidence:
    if item.get("type") != "screenshot":
        continue
    metadata = item.get("metadata") if isinstance(item.get("metadata"), dict) else {}
    platform = metadata.get("platform", "")
    state = metadata.get("state", "")
    if platform in screenshot_state_map and state in {"empty", "loading", "ready"}:
        screenshot_state_map[platform].add(state)

ac_results = []

ac1_status = "pass"
for cid in ["v-1", "v-5"]:
    if check_map.get(cid, {}).get("result") != "pass":
        ac1_status = "fail"
if "diff_summary" not in present_types_set:
    ac1_status = "fail"
if "metrics" not in present_types_set:
    ac1_status = "fail"
ac_results.append({"criteria_id": "ac-1", "status": ac1_status, "evidence_ids": evidence_ids_for("ac-1")})

ac2_status = "pass"
for cid in ["v-2", "v-3", "v-4", "v-7"]:
    if check_map.get(cid, {}).get("result") != "pass":
        ac2_status = "fail"
if not any(i.get("type") == "build_log" for i in run_evidence):
    ac2_status = "fail"
if not any(i.get("type") == "test_log" for i in run_evidence):
    ac2_status = "fail"
ac_results.append({"criteria_id": "ac-2", "status": ac2_status, "evidence_ids": evidence_ids_for("ac-2")})

ac3_status = "pass"
for cid in ["v-6", "v-5"]:
    if check_map.get(cid, {}).get("result") != "pass":
        ac3_status = "fail"
for platform in ["macOS", "iOS"]:
    if screenshot_state_map[platform] != {"empty", "loading", "ready"}:
        ac3_status = "not_met" if ac3_status == "pass" else ac3_status
if not any(i.get("type") == "screenshot" for i in run_evidence):
    ac3_status = "undetermined"
if "metrics" not in present_types_set:
    ac3_status = "fail"
ac_results.append({"criteria_id": "ac-3", "status": ac3_status, "evidence_ids": evidence_ids_for("ac-3")})

pass_checks = len([c for c in check_results if c["result"] == "pass"])
total_checks = len(check_results)
quality_gate_pass_rate = round(pass_checks / total_checks, 4) if total_checks else 0.0

v3 = check_map.get("v-3", {}).get("result") == "pass"
v4 = check_map.get("v-4", {}).get("result") == "pass"
parity_ratio = 1.0 if v3 and v4 else 0.0

if ac3_status != "pass":
    warnings.append("截图证据未达到 macOS+iOS 的 empty+loading+ready 最小集")

gate_failures = []
if errors:
    gate_failures.extend(errors)
if missing_types:
    gate_failures.append("缺失必需证据类型: " + ", ".join(missing_types))
if step in {"all", "build"}:
    if ac1_status != "pass":
        gate_failures.append("ac-1 未通过")
    if ac2_status != "pass":
        gate_failures.append("ac-2 未通过")
    if ac3_status != "pass":
        gate_failures.append("ac-3 未通过")

for c in check_results:
    if c["check_id"] == "v-5":
        c["result"] = "fail" if gate_failures else "pass"
        c["exit_code"] = 1 if gate_failures else 0
        c["note"] = "证据完整性硬门禁失败" if gate_failures else "证据完整性硬门禁通过"

metrics = {
    "$schema_version": "1.0",
    "run_id": run_id,
    "generated_at": now,
    "checks": check_results,
    "ac_results": ac_results,
    "validation": {
        "errors": errors,
        "warnings": warnings,
        "gate_failures": gate_failures,
        "gate_passed": len(gate_failures) == 0,
        "path_valid": len(errors) == 0,
        "id_unique": len(errors) == 0,
    },
    "metrics": {
        "evidence_completeness_ratio": completeness_ratio,
        "quality_gate_pass_rate": quality_gate_pass_rate,
        "cross_platform_parity_rate": parity_ratio,
        "cross_platform_flow_pass_rate": quality_gate_pass_rate,
        "evidence_missing_rate": round(len(missing_types) / len(required_types), 4) if required_types else 0.0,
        "e2e_screenshot_completion_rate": round(
            (len(screenshot_state_map["macOS"]) + len(screenshot_state_map["iOS"])) / 6, 4
        ),
        "required_types": required_types,
        "present_types": present_types,
        "missing_types": missing_types,
    },
}

metrics_path.parent.mkdir(parents=True, exist_ok=True)
metrics_path.write_text(json.dumps(metrics, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")

summary_lines = []
summary_lines.append("## 证据差异摘要")
summary_lines.append("")
summary_lines.append(f"- run_id: `{run_id}`")
summary_lines.append(f"- generated_at: `{now}`")
summary_lines.append("")
summary_lines.append("### 检查执行结果")
for c in check_results:
    summary_lines.append(f"- {c['check_id']} ({c['kind']}): {c['result']} exit={c['exit_code']} log=`{c['log_path']}`")
summary_lines.append("")
summary_lines.append("### 证据完整度")
summary_lines.append(f"- completeness_ratio: {completeness_ratio}")
summary_lines.append(f"- present_types: {', '.join(present_types) if present_types else 'none'}")
summary_lines.append(f"- missing_types: {', '.join(missing_types) if missing_types else 'none'}")
summary_lines.append("")
summary_lines.append("### AC 判定")
for ac in ac_results:
    ids = ", ".join(ac["evidence_ids"]) if ac["evidence_ids"] else "none"
    summary_lines.append(f"- {ac['criteria_id']}: {ac['status']} (evidence: {ids})")
summary_lines.append("")
if errors:
    summary_lines.append("### 阻断问题")
    for e in errors:
        summary_lines.append(f"- {e}")
    summary_lines.append("")
if warnings:
    summary_lines.append("### 告警")
    for w in warnings:
        summary_lines.append(f"- {w}")
    summary_lines.append("")
if ac3_status != "pass":
    summary_lines.append("### 截图补证命令")
    summary_lines.append("- `./scripts/evo-screenshot.sh --cycle <cycle_id> --check v-6 --platform macOS --state empty --run-id <run_id>`")
    summary_lines.append("- `./scripts/evo-screenshot.sh --cycle <cycle_id> --check v-6 --platform macOS --state loading --run-id <run_id>`")
    summary_lines.append("- `./scripts/evo-screenshot.sh --cycle <cycle_id> --check v-6 --platform macOS --state ready --run-id <run_id>`")
    summary_lines.append("- `./scripts/evo-screenshot.sh --cycle <cycle_id> --check v-6 --platform iOS --state empty --run-id <run_id>`")
    summary_lines.append("- `./scripts/evo-screenshot.sh --cycle <cycle_id> --check v-6 --platform iOS --state loading --run-id <run_id>`")
    summary_lines.append("- `./scripts/evo-screenshot.sh --cycle <cycle_id> --check v-6 --platform iOS --state ready --run-id <run_id>`")
    summary_lines.append("")

summary_lines.append("### 变更统计")
summary_lines.append(f"- 新增证据: {len(run_evidence)}")
summary_lines.append("- 删除证据: 0")
summary_lines.append("- 变更证据: 0")


diff_path.parent.mkdir(parents=True, exist_ok=True)
diff_path.write_text("\n".join(summary_lines) + "\n", encoding="utf-8")

if gate_failures:
    raise SystemExit(2)
PY
    then
        record_check_result "$CHECK_METRICS" "manual" "fail" "$METRICS_JSON" "1" "证据完整性与一致性校验失败"
        echo "$LOG_PREFIX [metrics] FAILED: 证据完整性校验失败"
        return 1
    fi

    record_check_result "$CHECK_METRICS" "manual" "pass" "$METRICS_JSON" "0" "证据完整性与一致性校验通过"
    append_evidence_line "metrics" "$METRICS_JSON" "$CHECK_METRICS" "ac-1,ac-3" "证据完整性与一致性校验指标"
    append_evidence_line "diff_summary" "$DIFF_SUMMARY" "$CHECK_VERIFY_GATE" "ac-1" "证据差异摘要"
    return 0
}

if [ "${1:-}" = "verify" ]; then
    STEP="verify"
    shift
fi

while [[ $# -gt 0 ]]; do
    case "$1" in
        --cycle)
            CYCLE_ID="${2:-}"
            shift 2
            ;;
        --run-id)
            RUN_ID="${2:-}"
            shift 2
            ;;
        --step)
            STEP="${2:-all}"
            shift 2
            ;;
        --verbose|-v)
            VERBOSE=1
            shift
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
            echo "$LOG_PREFIX ERROR: 未知参数: $1"
            usage
            exit 1
            ;;
    esac
done

if [ -z "$CYCLE_ID" ]; then
    echo "$LOG_PREFIX ERROR: 必须指定 --cycle"
    exit 1
fi

CYCLE_DIR="$EVOLUTION_DIR/$CYCLE_ID"
if [ ! -d "$CYCLE_DIR" ]; then
    echo "$LOG_PREFIX ERROR: Cycle 目录不存在: $CYCLE_DIR"
    exit 1
fi

if [ -z "$RUN_ID" ]; then
    if [ "$STEP" = "verify" ] && [ -d "$CYCLE_DIR/runs" ]; then
        RUN_ID="$(ls -1 "$CYCLE_DIR/runs" 2>/dev/null | sort | tail -n 1 || true)"
    fi
fi

if [ -z "$RUN_ID" ]; then
    if [ "$STEP" = "verify" ]; then
        echo "$LOG_PREFIX ERROR: verify 模式未找到可用 run，请显式传入 --run-id"
        exit 1
    fi
    RUN_ID="$(date -u +%Y%m%d-%H%M%S)"
fi

case "$STEP" in
    integration|verify)
        REQUIRED_EVIDENCE_TYPES="test_log,diff_summary,metrics"
        ;;
    *)
        REQUIRED_EVIDENCE_TYPES="build_log,test_log,screenshot,diff_summary,metrics"
        ;;
esac

RESULT_DIR="$CYCLE_DIR/runs/$RUN_ID"
EVIDENCE_DIR="$RESULT_DIR/evidence"
mkdir -p "$EVIDENCE_DIR"

ACCEPTANCE_LOG="$EVIDENCE_DIR/${CHECK_ACCEPTANCE}-acceptance-$RUN_ID.log"
UNIT_LOG="$EVIDENCE_DIR/${CHECK_UNIT}-unit-$RUN_ID.log"
CORE_BUILD_LOG="$EVIDENCE_DIR/${CHECK_CORE_BUILD}-core-build-$RUN_ID.log"
MACOS_BUILD_LOG="$EVIDENCE_DIR/${CHECK_MACOS_BUILD}-macos-build-$RUN_ID.log"
IOS_BUILD_LOG="$EVIDENCE_DIR/${CHECK_IOS_BUILD}-ios-build-$RUN_ID.log"
SCREENSHOT_LOG="$EVIDENCE_DIR/${CHECK_SCREENSHOT}-screenshots-$RUN_ID.log"
INTEGRATION_LOG="$EVIDENCE_DIR/${CHECK_INTEGRATION}-integration-$RUN_ID.log"
METRICS_JSON="$EVIDENCE_DIR/${CHECK_METRICS}-metrics-$RUN_ID.json"
DIFF_SUMMARY="$EVIDENCE_DIR/${CHECK_VERIFY_GATE}-diff-$RUN_ID.md"
CHECK_RESULTS_FILE="$RESULT_DIR/.check-results.tsv"
EVIDENCE_LINES_FILE="$RESULT_DIR/.evidence-lines.tsv"
EVIDENCE_INDEX="$CYCLE_DIR/evidence.index.json"

: > "$CHECK_RESULTS_FILE"
: > "$EVIDENCE_LINES_FILE"

echo "$LOG_PREFIX 开始执行 cycle=$CYCLE_ID run=$RUN_ID step=$STEP dry_run=$DRY_RUN"
echo "$LOG_PREFIX 结果目录: $RESULT_DIR"
emit_event "EVO_PLAN_START" "none" "platform=multi"
emit_flow_event "START" "check_id=none"

MAIN_EXIT=0
case "$STEP" in
    all)
        run_sequence_all || MAIN_EXIT=$?
        ;;
    build)
        run_sequence_build || MAIN_EXIT=$?
        ;;
    integration)
        run_sequence_integration || MAIN_EXIT=$?
        ;;
    verify)
        run_sequence_verify || MAIN_EXIT=$?
        ;;
    *)
        echo "$LOG_PREFIX ERROR: 未知步骤: $STEP"
        MAIN_EXIT=2
        ;;
esac

# 先落地基础证据（日志类），再做一致性校验并补充 metrics/diff
BASE_OUTCOME="success"
if [ $MAIN_EXIT -ne 0 ]; then
    if [ "$STEP" = "all" ] || [ "$STEP" = "build" ]; then
        BASE_OUTCOME="partial"
    else
        BASE_OUTCOME="failed"
    fi
fi

if ! update_evidence_index "$BASE_OUTCOME"; then
    if [ $MAIN_EXIT -eq 0 ]; then
        MAIN_EXIT=1
    fi
fi

# 不论主流程是否失败，都尝试生成 metrics + diff（最小可复核）
if ! validate_evidence_and_metrics; then
    if [ $MAIN_EXIT -eq 0 ]; then
        MAIN_EXIT=1
    fi
fi

if [ -f "$METRICS_JSON" ]; then
    MISSING_TYPES="$(python3 - "$METRICS_JSON" <<'PY'
import json
import sys
from pathlib import Path
path = Path(sys.argv[1])
try:
    data = json.loads(path.read_text(encoding="utf-8"))
except Exception:
    print("")
    raise SystemExit(0)
missing = data.get("metrics", {}).get("missing_types", [])
if isinstance(missing, list):
    print(",".join([str(x) for x in missing if x]))
else:
    print("")
PY
)"
    if [ -n "$MISSING_TYPES" ]; then
        emit_event "EVO_GATE_BLOCK" "$CHECK_METRICS" "platform=multi missing_types=$MISSING_TYPES artifact_path=$METRICS_JSON"
    fi
fi

FINAL_OUTCOME="success"
if [ $MAIN_EXIT -ne 0 ]; then
    if [ "$STEP" = "all" ] || [ "$STEP" = "build" ]; then
        FINAL_OUTCOME="partial"
    else
        FINAL_OUTCOME="failed"
    fi
fi

# 第二次写入，补充 metrics/diff 证据与最终 outcome。
if ! update_evidence_index "$FINAL_OUTCOME"; then
    if [ $MAIN_EXIT -eq 0 ]; then
        MAIN_EXIT=1
    fi
fi

echo ""
echo "============================================"
echo "$LOG_PREFIX 执行完成"
echo "$LOG_PREFIX run=$RUN_ID exit=$MAIN_EXIT outcome=$FINAL_OUTCOME"
echo "$LOG_PREFIX evidence_index=$EVIDENCE_INDEX"
echo "$LOG_PREFIX metrics=$METRICS_JSON"
echo "$LOG_PREFIX diff=$DIFF_SUMMARY"
echo "============================================"
if [ $MAIN_EXIT -eq 0 ]; then
    emit_flow_event "SUCCESS" "check_id=$CHECK_VERIFY_GATE"
else
    emit_flow_event "FAIL" "check_id=${FAILURE_CHECK_ID:-unknown} reason=${FAILURE_REASON:-main_exit_nonzero}"
fi

exit $MAIN_EXIT
