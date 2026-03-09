#!/usr/bin/env bash
# 解析支持 unified diff(-u) 的 diff 实现，避免被 PATH 中不兼容的工具链同名命令污染。

resolve_unified_diff_bin() {
    local candidates=()

    candidates+=("/usr/bin/diff" "/opt/homebrew/bin/gdiff" "/usr/local/bin/gdiff")

    if [ -n "${TIDYFLOW_DIFF_BIN:-}" ]; then
        candidates+=("$TIDYFLOW_DIFF_BIN")
    fi

    if command -v diff >/dev/null 2>&1; then
        candidates+=("$(command -v diff)")
    fi

    local probe_dir
    probe_dir="$(mktemp -d)"
    trap 'rm -rf "$probe_dir"' RETURN
    printf 'left\n' > "$probe_dir/left"
    printf 'right\n' > "$probe_dir/right"

    local candidate
    local status
    for candidate in "${candidates[@]}"; do
        [ -n "$candidate" ] || continue
        [ -x "$candidate" ] || continue
        "$candidate" -u "$probe_dir/left" "$probe_dir/right" > "$probe_dir/out" 2>/dev/null
        status=$?
        if [ "$status" -le 1 ] && grep -Eq '^--- |^\+\+\+ ' "$probe_dir/out"; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done

    echo "[diff_compat] ERROR: 未找到支持 unified diff(-u) 的 diff 实现。" >&2
    echo "[diff_compat] ERROR: 可通过 TIDYFLOW_DIFF_BIN 指定可用命令路径。" >&2
    return 1
}

run_unified_diff() {
    local left="$1"
    local right="$2"
    local output="$3"

    local diff_bin
    diff_bin="$(resolve_unified_diff_bin)" || return 1
    "$diff_bin" -u "$left" "$right" > "$output"
}
