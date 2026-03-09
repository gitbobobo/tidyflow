#!/usr/bin/env bash
# Core target 目录守护：
# - 回收可安全重建的旧缓存，避免构建产物无限增长
# - 提供只读统计，帮助定位 target 目录膨胀来源

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CORE_TARGET="$PROJECT_ROOT/core/target"
STATE_DIR="$CORE_TARGET/.tidyflow-target-guard"
LOG_FILE="$STATE_DIR/actions.log"
MIGRATION_STAMP="$STATE_DIR/debug-cache-migrated"

mkdir -p "$STATE_DIR"

log_action() {
    local message="$1"
    local timestamp
    local tmp_log
    mkdir -p "$STATE_DIR"
    timestamp="$(date '+%Y-%m-%dT%H:%M:%S%z')"
    printf '%s %s\n' "$timestamp" "$message" >>"$LOG_FILE"
    tmp_log="$(mktemp "$STATE_DIR/actions.XXXXXX.tmp")"
    tail -n 50 "$LOG_FILE" >"$tmp_log"
    mv "$tmp_log" "$LOG_FILE"
}

dir_size_kb() {
    local path="$1"
    if [ -e "$path" ]; then
        du -sk "$path" | awk '{print $1}'
    else
        echo 0
    fi
}

human_size() {
    local kb="$1"
    awk -v size_kb="$kb" '
        BEGIN {
            if (size_kb >= 1048576) {
                printf "%.1fG", size_kb / 1048576
            } else if (size_kb >= 1024) {
                printf "%.1fM", size_kb / 1024
            } else {
                printf "%dK", size_kb
            }
        }
    '
}

list_dirs_sorted_desc() {
    local base_dir="$1"
    local pattern="$2"
    if [ ! -d "$base_dir" ]; then
        return 0
    fi
    find "$base_dir" -mindepth 1 -maxdepth 1 -type d -name "$pattern" -exec stat -f '%m %N' {} \; \
        2>/dev/null | sort -nr | sed 's/^[0-9][0-9]* //'
}

prune_dirs_keep_newest() {
    local base_dir="$1"
    local pattern="$2"
    local keep_count="$3"
    [ -d "$base_dir" ] || return 0

    local index=0
    while IFS= read -r path; do
        [ -n "$path" ] || continue
        index=$((index + 1))
        if [ "$index" -le "$keep_count" ]; then
            continue
        fi
        rm -rf "$path"
        log_action "pruned $path"
    done < <(list_dirs_sorted_desc "$base_dir" "$pattern")
}

prune_file_like_dirs() {
    local base_dir="$1"
    local pattern="$2"
    local keep_count="$3"
    [ -d "$base_dir" ] || return 0

    local index=0
    while IFS= read -r path; do
        [ -n "$path" ] || continue
        index=$((index + 1))
        if [ "$index" -le "$keep_count" ]; then
            continue
        fi
        rm -rf "$path"
        log_action "pruned $path"
    done < <(
        find "$base_dir" -mindepth 1 -maxdepth 1 -name "$pattern" -exec stat -f '%m %N' {} \; \
            2>/dev/null | sort -nr | sed 's/^[0-9][0-9]* //'
    )
}

remove_matching_files() {
    local base_dir="$1"
    local pattern="$2"
    [ -d "$base_dir" ] || return 0

    while IFS= read -r path; do
        [ -n "$path" ] || continue
        rm -f "$path"
        log_action "pruned $path"
    done < <(find "$base_dir" -mindepth 1 -maxdepth 1 -type f -name "$pattern" 2>/dev/null)
}

legacy_debug_cache_needs_reset() {
    [ -f "$MIGRATION_STAMP" ] && return 1

    if find "$CORE_TARGET/debug/deps" -mindepth 1 -maxdepth 1 \
        \( -name 'manager_test-*' -o -name 'protocol_unit_tests-*' -o -name 'workspace_unit_tests-*' -o -name 'workspace_cache_benchmark_smoke-*' \) \
        -print -quit 2>/dev/null | grep -q .; then
        return 0
    fi

    local fingerprint_count
    fingerprint_count="$(find "$CORE_TARGET/debug/.fingerprint" -mindepth 1 -maxdepth 1 -name 'tidyflow-core-*' 2>/dev/null | wc -l | tr -d ' ')"
    if [ "${fingerprint_count:-0}" -gt 24 ]; then
        return 0
    fi

    local debug_deps_kb
    debug_deps_kb="$(dir_size_kb "$CORE_TARGET/debug/deps")"
    [ "${debug_deps_kb:-0}" -gt $((20 * 1024 * 1024)) ]
}

reset_legacy_debug_cache() {
    if ! legacy_debug_cache_needs_reset; then
        return 0
    fi

    rm -rf \
        "$CORE_TARGET/debug/deps" \
        "$CORE_TARGET/debug/.fingerprint" \
        "$CORE_TARGET/debug/incremental" \
        "$CORE_TARGET/release/incremental"
    touch "$MIGRATION_STAMP"
    log_action "reset legacy debug cache layout"
}

trim_debug_caches() {
    reset_legacy_debug_cache

    prune_dirs_keep_newest "$CORE_TARGET/debug/incremental" "*" 12
    prune_dirs_keep_newest "$CORE_TARGET/release/incremental" "*" 4
    prune_dirs_keep_newest "$CORE_TARGET/bench-target/debug/incremental" "*" 6
    prune_dirs_keep_newest "$CORE_TARGET/bench-target/release/incremental" "*" 4

    prune_file_like_dirs "$CORE_TARGET/debug/.fingerprint" "tidyflow-core-*" 24
    prune_file_like_dirs "$CORE_TARGET/debug/.fingerprint" "protocol_*" 16
    prune_file_like_dirs "$CORE_TARGET/release/.fingerprint" "tidyflow-core-*" 8

    remove_matching_files "$CORE_TARGET/debug/deps" "manager_test-*"
    remove_matching_files "$CORE_TARGET/debug/deps" "protocol_unit_tests-*"
    remove_matching_files "$CORE_TARGET/debug/deps" "workspace_unit_tests-*"
    remove_matching_files "$CORE_TARGET/debug/deps" "workspace_cache_benchmark_smoke-*"
}

reset_coverage_target() {
    rm -rf "$CORE_TARGET/llvm-cov-target" "$CORE_TARGET/llvm-cov-report"
    log_action "reset coverage target directories"
}

reset_bench_reports() {
    rm -rf "$CORE_TARGET/criterion" "$CORE_TARGET/bench-target/criterion"
    log_action "reset benchmark reports"
}

prepare_for_action() {
    local action="$1"
    trim_debug_caches
    case "$action" in
        bench)
            reset_bench_reports
            ;;
        coverage)
            reset_coverage_target
            ;;
    esac
    log_action "prepared for $action"
}

finalize_action() {
    local action="$1"
    trim_debug_caches
    log_action "finalized $action"
}

print_stats() {
    local total_kb debug_kb release_kb bench_kb cov_target_kb cov_report_kb
    total_kb="$(dir_size_kb "$CORE_TARGET")"
    debug_kb="$(dir_size_kb "$CORE_TARGET/debug")"
    release_kb="$(dir_size_kb "$CORE_TARGET/release")"
    bench_kb="$(dir_size_kb "$CORE_TARGET/bench-target")"
    cov_target_kb="$(dir_size_kb "$CORE_TARGET/llvm-cov-target")"
    cov_report_kb="$(dir_size_kb "$CORE_TARGET/llvm-cov-report")"

    cat <<EOF
Core target 概览
  总计: $(human_size "$total_kb")
  debug: $(human_size "$debug_kb")
  release: $(human_size "$release_kb")
  bench-target: $(human_size "$bench_kb")
  llvm-cov-target: $(human_size "$cov_target_kb")
  llvm-cov-report: $(human_size "$cov_report_kb")

缓存目录
  debug/incremental: $(find "$CORE_TARGET/debug/incremental" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')
  release/incremental: $(find "$CORE_TARGET/release/incremental" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')
  bench-target/debug/incremental: $(find "$CORE_TARGET/bench-target/debug/incremental" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')
  bench-target/release/incremental: $(find "$CORE_TARGET/bench-target/release/incremental" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')

高频变体
  debug/.fingerprint/tidyflow-core-*: $(find "$CORE_TARGET/debug/.fingerprint" -mindepth 1 -maxdepth 1 -name 'tidyflow-core-*' 2>/dev/null | wc -l | tr -d ' ')
  debug/deps/tidyflow_core-* 文件数: $(find "$CORE_TARGET/debug/deps" -mindepth 1 -maxdepth 1 -name 'tidyflow_core-*' 2>/dev/null | wc -l | tr -d ' ')
  debug/deps/libtidyflow_core-*.rlib: $(find "$CORE_TARGET/debug/deps" -mindepth 1 -maxdepth 1 -name 'libtidyflow_core-*.rlib' 2>/dev/null | wc -l | tr -d ' ')
EOF

    if [ -f "$LOG_FILE" ]; then
        echo ""
        echo "最近回收动作"
        tail -n 10 "$LOG_FILE"
    fi
}

check_health() {
    local debug_incr fingerprint_count
    debug_incr="$(find "$CORE_TARGET/debug/incremental" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')"
    fingerprint_count="$(find "$CORE_TARGET/debug/.fingerprint" -mindepth 1 -maxdepth 1 -name 'tidyflow-core-*' 2>/dev/null | wc -l | tr -d ' ')"

    if [ "$debug_incr" -gt 12 ]; then
        echo "[target-guard] FAIL: debug/incremental 目录数过多: $debug_incr"
        return 1
    fi
    if [ "$fingerprint_count" -gt 24 ]; then
        echo "[target-guard] FAIL: tidyflow-core fingerprint 目录数过多: $fingerprint_count"
        return 1
    fi
    echo "[target-guard] PASS: 目标目录结构处于预期范围"
}

command="${1:-}"
if [ -z "$command" ]; then
    echo "用法: $0 <prepare|finalize|stats> [action|--check]"
    exit 1
fi
shift || true

case "$command" in
    prepare)
        prepare_for_action "${1:-test}"
        ;;
    finalize)
        finalize_action "${1:-test}"
        ;;
    stats)
        print_stats
        if [ "${1:-}" = "--check" ]; then
            check_health
        fi
        ;;
    *)
        echo "未知命令: $command"
        exit 1
        ;;
esac
