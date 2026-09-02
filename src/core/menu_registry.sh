#!/usr/bin/env bash

declare -ag SHDOME_MENU_NUMBERS=()
declare -ag SHDOME_MENU_TITLES=()
declare -ag SHDOME_MENU_HANDLERS=()

menu_register() {
    local number="$1" title="$2" handler="$3" existing index previous
    [[ "$number" =~ ^[1-9][0-9]*$ ]] || { fail "无效主菜单编号：$number" 70; return; }
    [[ -n "$title" ]] || { fail "主菜单标题不能为空" 70; return; }
    declare -F "$handler" >/dev/null || { fail "主菜单处理函数不存在：$handler" 70; return; }
    for existing in "${SHDOME_MENU_NUMBERS[@]:-}"; do
        [[ "$existing" != "$number" ]] || { fail "主菜单编号重复：$number" 70; return; }
    done
    SHDOME_MENU_NUMBERS+=("$number")
    SHDOME_MENU_TITLES+=("$title")
    SHDOME_MENU_HANDLERS+=("$handler")

    # 注册顺序不影响展示顺序，后续模块可独立接入自己的稳定编号段。
    index=$((${#SHDOME_MENU_NUMBERS[@]} - 1))
    while ((index > 0)); do
        previous=$((index - 1))
        ((10#${SHDOME_MENU_NUMBERS[$previous]} > 10#${SHDOME_MENU_NUMBERS[$index]})) || break
        existing="${SHDOME_MENU_NUMBERS[previous]}"
        SHDOME_MENU_NUMBERS[previous]="${SHDOME_MENU_NUMBERS[index]}"
        SHDOME_MENU_NUMBERS[index]="$existing"
        existing="${SHDOME_MENU_TITLES[previous]}"
        SHDOME_MENU_TITLES[previous]="${SHDOME_MENU_TITLES[index]}"
        SHDOME_MENU_TITLES[index]="$existing"
        existing="${SHDOME_MENU_HANDLERS[previous]}"
        SHDOME_MENU_HANDLERS[previous]="${SHDOME_MENU_HANDLERS[index]}"
        SHDOME_MENU_HANDLERS[index]="$existing"
        index=$previous
    done
}

main_menu() {
    local choice index handled
    terminal_is_interactive || { fail "无参数启动需要交互终端；请使用 k help 查看命令" 64; return; }
    while true; do
        printf '\n%s 服务器管理工具\n' "$SHDOME_NAME"
        printf '%s\n' '--------------------------------'
        for index in "${!SHDOME_MENU_NUMBERS[@]}"; do
            printf '%s. %s\n' "${SHDOME_MENU_NUMBERS[$index]}" "${SHDOME_MENU_TITLES[$index]}"
        done
        printf '%s\n' '00. 更新 SHDome' '0. 退出' '--------------------------------'
        terminal_read choice "请输入选择: " ""
        case "$choice" in
            0) return 0 ;;
            00) self_update_interactive; terminal_pause ;;
            *)
                handled=0
                for index in "${!SHDOME_MENU_NUMBERS[@]}"; do
                    if [[ "$choice" == "${SHDOME_MENU_NUMBERS[$index]}" ]]; then
                        if ! "${SHDOME_MENU_HANDLERS[$index]}"; then
                            warn "操作未完成，请根据上方错误信息处理"
                        fi
                        handled=1
                        break
                    fi
                done
                [[ "$handled" == "1" ]] || warn "无效选择：$choice"
                ;;
        esac
    done
}
