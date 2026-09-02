#!/usr/bin/env bash

terminal_is_interactive() {
    [[ -r /dev/tty && -w /dev/tty ]]
}

terminal_read() {
    local __var_name="$1" prompt="$2" default_value="${3:-}" value
    terminal_is_interactive || { fail "当前操作需要交互终端；SSH 请使用 ssh -t，自动化请补全参数并使用 --yes" 64; return; }
    printf '%s' "$prompt" >/dev/tty
    IFS= read -r value </dev/tty || return 130
    [[ -n "$value" ]] || value="$default_value"
    printf -v "$__var_name" '%s' "$value"
}

terminal_confirm() {
    local prompt="$1" answer
    if [[ "${SHDOME_ASSUME_YES:-0}" == "1" ]]; then
        return 0
    fi
    terminal_read answer "$prompt [y/N]: " ""
    [[ "$answer" =~ ^[Yy]([Ee][Ss])?$ ]]
}

terminal_pause() {
    local ignored=""
    terminal_is_interactive || return 0
    terminal_read ignored "按回车键继续..." ""
    : "$ignored"
}

info() { printf '[信息] %s\n' "$*"; }
success() { printf '[完成] %s\n' "$*"; }
warn() { printf '[警告] %s\n' "$*" >&2; }
error() { printf '[错误] %s\n' "$*" >&2; }

fail() {
    local message="$1" code="${2:-1}"
    error "$message"
    return "$code"
}
