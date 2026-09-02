#!/usr/bin/env bash

declare -Ag SHDOME_COMMAND_HANDLERS=()
declare -ag SHDOME_HELP_HANDLERS=()

command_register() {
    local command_name="$1" handler="$2"
    [[ "$command_name" =~ ^[a-z][a-z0-9-]*$ ]] || { fail "无效命令名：$command_name" 70; return; }
    [[ -z "${SHDOME_COMMAND_HANDLERS[$command_name]:-}" ]] || { fail "命令重复注册：$command_name" 70; return; }
    SHDOME_COMMAND_HANDLERS["$command_name"]="$handler"
}

help_register() {
    local handler="$1" existing
    declare -F "$handler" >/dev/null || { fail "帮助处理函数不存在：$handler" 70; return; }
    for existing in "${SHDOME_HELP_HANDLERS[@]:-}"; do
        [[ "$existing" != "$handler" ]] || { fail "帮助处理函数重复注册：$handler" 70; return; }
    done
    SHDOME_HELP_HANDLERS+=("$handler")
}

shdome_register_builtin_commands() {
    command_register help show_help
    command_register version show_version
    command_register self-update self_update_command
    command_register config config_command
    menu_register 3 "SHDome 设置" settings_menu
}

route_command() {
    local command_name="${1:-}" handler
    if [[ -z "$command_name" ]]; then
        main_menu
        return
    fi
    case "$command_name" in
        --help|-h) show_help; return ;;
        --version|-v) show_version; return ;;
    esac
    shift
    handler="${SHDOME_COMMAND_HANDLERS[$command_name]:-}"
    if [[ -z "$handler" ]]; then
        show_help >&2
        fail "未知命令：$command_name" 64
        return
    fi
    "$handler" "$@"
}

show_help() {
    local handler
    cat <<'EOF'
用法：k [命令]

  k                         打开交互式主菜单
EOF
    for handler in "${SHDOME_HELP_HANDLERS[@]:-}"; do
        "$handler"
    done
    cat <<'EOF'
  k config                  查看 SHDome 设置
  k self-update             更新 SHDome
  k version                 查看版本
EOF
}
