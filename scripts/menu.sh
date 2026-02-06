#!/bin/bash
# 脚本菜单选择器
# 功能：列出同目录下的可执行脚本，通过方向键选择并执行

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CURRENT_SCRIPT="$(basename "${BASH_SOURCE[0]}")"

# ANSI 转义序列
BOLD='\033[1m'
DIM='\033[2m'
GREEN='\033[32m'
CYAN='\033[36m'
YELLOW='\033[33m'
RESET='\033[0m'
HIGHLIGHT='\033[7m'
HIDE_CURSOR='\033[?25l'
SHOW_CURSOR='\033[?25h'

# 全局数组
declare -a SCRIPT_NAMES
declare -a SCRIPT_DESCS

# 清理函数
cleanup() {
    printf "${SHOW_CURSOR}"
    tput cnorm 2>/dev/null || true
}
trap cleanup EXIT

# 获取脚本描述（从文件第二行注释提取）
get_script_desc() {
    local file="$1"
    local desc=$(sed -n '2s/^#[[:space:]]*//p' "$file" 2>/dev/null)
    [[ -z "$desc" ]] && desc="无描述"
    echo "$desc"
}

# 收集脚本列表
collect_scripts() {
    SCRIPT_NAMES=()
    SCRIPT_DESCS=()

    for script in "${SCRIPT_DIR}"/*.sh; do
        [[ ! -f "$script" ]] && continue
        local name=$(basename "$script")
        # 排除自身
        [[ "$name" == "$CURRENT_SCRIPT" ]] && continue

        SCRIPT_NAMES+=("$name")
        SCRIPT_DESCS+=("$(get_script_desc "$script")")
    done
}

# 绘制菜单
draw_menu() {
    local selected=$1
    local total=${#SCRIPT_NAMES[@]}

    clear
    printf "${BOLD}=== 脚本菜单 ===${RESET}\n\n"

    if [[ $total -eq 0 ]]; then
        printf "${YELLOW}当前目录下没有其他脚本${RESET}\n"
        return 1
    fi

    printf "${DIM}使用 ↑↓ 或 j/k 选择，Enter 执行，q 退出${RESET}\n\n"

    for i in "${!SCRIPT_NAMES[@]}"; do
        if [[ $i -eq $selected ]]; then
            printf "  ${HIGHLIGHT} → ${SCRIPT_NAMES[$i]} ${RESET}\n"
            printf "      ${DIM}${SCRIPT_DESCS[$i]}${RESET}\n"
        else
            printf "    ${SCRIPT_NAMES[$i]}\n"
            printf "      ${DIM}${SCRIPT_DESCS[$i]}${RESET}\n"
        fi
    done
}

# 读取按键
read_key() {
    local key extra
    IFS= read -rsn1 key 2>/dev/null

    if [[ "$key" == $'\x1b' ]]; then
        IFS= read -rsn1 -t 1 extra 2>/dev/null
        if [[ "$extra" == "[" ]]; then
            IFS= read -rsn1 -t 1 extra 2>/dev/null
            case "$extra" in
                'A') echo "up"; return ;;
                'B') echo "down"; return ;;
            esac
        fi
        echo "other"
    elif [[ "$key" == "" ]]; then
        echo "enter"
    elif [[ "$key" == "q" || "$key" == "Q" ]]; then
        echo "quit"
    elif [[ "$key" == "k" || "$key" == "K" ]]; then
        echo "up"
    elif [[ "$key" == "j" || "$key" == "J" ]]; then
        echo "down"
    else
        echo "other"
    fi
}

# 交互式选择
interactive_select() {
    local selected=0
    local total=${#SCRIPT_NAMES[@]}

    [[ $total -eq 0 ]] && return 255

    printf "${HIDE_CURSOR}"

    while true; do
        draw_menu $selected

        case "$(read_key)" in
            up)   [[ $selected -gt 0 ]] && ((selected--)) || true ;;
            down) [[ $selected -lt $((total - 1)) ]] && ((selected++)) || true ;;
            enter)
                printf "${SHOW_CURSOR}"
                return $selected
                ;;
            quit)
                printf "${SHOW_CURSOR}"
                printf "\n${YELLOW}已取消${RESET}\n"
                exit 0
                ;;
        esac
    done
}

# 主函数
main() {
    collect_scripts

    if [[ ${#SCRIPT_NAMES[@]} -eq 0 ]]; then
        draw_menu 0
        exit 1
    fi

    interactive_select
    local selected=$?

    if [[ $selected -eq 255 ]]; then
        exit 1
    fi

    local script="${SCRIPT_DIR}/${SCRIPT_NAMES[$selected]}"

    printf "\n${BOLD}执行: ${SCRIPT_NAMES[$selected]}${RESET}\n"
    printf "${DIM}─────────────────────────────────${RESET}\n\n"

    exec "$script"
}

main "$@"
