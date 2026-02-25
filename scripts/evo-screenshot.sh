#!/usr/bin/env bash
# Evolution 双端三态截图采集（真实证据模式）
# 说明：
# - 只接收真实截图输入，不再生成 synthetic/占位截图；
# - 若缺少截图输入，直接失败并记录缺口，交由 direction/verify/judge 处理证据不足。

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_ROOT"

CYCLE_ID=""
RUN_ID=""
CHECK_ID="v-4"
SOURCE_DIR=""

LOG_DIR="$HOME/.tidyflow/logs"
LOG_DAY="$(date +%Y-%m-%d)"
DEV_LOG_FILE="$LOG_DIR/$LOG_DAY-dev.log"

usage() {
    cat <<'USAGE'
用法:
  ./scripts/evo-screenshot.sh --cycle <cycle_id> [--run-id <run_id>] [--check-id v-4] [--source-dir <dir>]

说明:
  - source-dir 需包含 6 张真实截图：
    macos-empty.png macos-loading.png macos-ready.png
    ios-empty.png   ios-loading.png   ios-ready.png
USAGE
}

ensure_log_file() {
    mkdir -p "$LOG_DIR"
    touch "$DEV_LOG_FILE"
}

write_event_log() {
    local event_name="$1"
    local detail="$2"
    ensure_log_file
    local ts
    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf '{"ts":"%s","event":"%s","cycle_id":"%s","run_id":"%s","check_id":"%s","detail":"%s"}\n' \
        "$ts" "$event_name" "$CYCLE_ID" "$RUN_ID" "$CHECK_ID" "$detail" >>"$DEV_LOG_FILE"
}

while [ $# -gt 0 ]; do
    case "$1" in
        --cycle)
            CYCLE_ID="${2:-}"
            shift 2
            ;;
        --run-id)
            RUN_ID="${2:-}"
            shift 2
            ;;
        --check-id)
            CHECK_ID="${2:-}"
            shift 2
            ;;
        --source-dir)
            SOURCE_DIR="${2:-}"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "[evo-screenshot] 未知参数: $1" >&2
            usage >&2
            exit 1
            ;;
    esac
done

if [ -z "$CYCLE_ID" ]; then
    echo "[evo-screenshot] 缺少必填参数 --cycle" >&2
    exit 1
fi

if [ -z "$RUN_ID" ]; then
    RUN_ID="$(date -u +%Y%m%d-%H%M%S)"
fi

if [ -z "$SOURCE_DIR" ]; then
    SOURCE_DIR=".tidyflow/evolution/$CYCLE_ID/screenshot-source"
fi

EVIDENCE_DIR=".tidyflow/evolution/$CYCLE_ID/evidence/screenshots"
mkdir -p "$EVIDENCE_DIR"

platforms=("macos" "ios")
states=("empty" "loading" "ready")
missing=()

for platform in "${platforms[@]}"; do
    for state in "${states[@]}"; do
        input_file="$SOURCE_DIR/${platform}-${state}.png"
        if [ ! -f "$input_file" ]; then
            missing+=("$input_file")
        fi
    done
done

if [ "${#missing[@]}" -gt 0 ]; then
    detail="missing_sources=$(printf '%s;' "${missing[@]}")"
    write_event_log "screenshot_capture_unavailable" "$detail"
    echo "[evo-screenshot] 缺少真实截图输入，未执行采集。source-dir=$SOURCE_DIR" >&2
    exit 2
fi

get_png_size() {
    local path="$1"
    local width height
    width="$(sips -g pixelWidth "$path" 2>/dev/null | awk '/pixelWidth/ {print $2}')"
    height="$(sips -g pixelHeight "$path" 2>/dev/null | awk '/pixelHeight/ {print $2}')"
    printf '%sx%s' "${width:-0}" "${height:-0}"
}

for platform in "${platforms[@]}"; do
    for state in "${states[@]}"; do
        src="$SOURCE_DIR/${platform}-${state}.png"
        utc_ts="$(date -u +%Y%m%dT%H%M%SZ)"
        filename="screenshot-${CYCLE_ID}-${CHECK_ID}-${platform}-${state}-${utc_ts}.png"
        dst="$EVIDENCE_DIR/$filename"
        cp "$src" "$dst"

        size_text="$(get_png_size "$dst")"
        width="${size_text%x*}"
        height="${size_text#*x}"
        if [ "${width:-0}" -lt 200 ] || [ "${height:-0}" -lt 200 ]; then
            write_event_log "screenshot_capture_rejected" "platform=$platform state=$state path=evidence/screenshots/$filename reason=resolution_too_small size=$size_text"
            echo "[evo-screenshot] 截图分辨率过低: $dst ($size_text)" >&2
            exit 3
        fi

        sha256="$(shasum -a 256 "$dst" | awk '{print $1}')"
        echo "[evo-screenshot] imported $dst"
        write_event_log "cross_platform_screenshot_captured" "platform=$platform state=$state path=evidence/screenshots/$filename mode=real_capture size=$size_text sha256=$sha256"
        sleep 1
    done
done

echo "[evo-screenshot] completed cycle_id=$CYCLE_ID run_id=$RUN_ID check_id=$CHECK_ID"
