#!/usr/bin/env bash

SHDOME_NAME="SHDome"
SHDOME_VERSION="0.1.0-dev"

shdome_config_init() {
    : "${SHDOME_ROOT:=/opt/shdome}"
    : "${SHDOME_CONFIG_DIR:=$SHDOME_ROOT/config}"
    : "${SHDOME_APPS_DIR:=$SHDOME_ROOT/apps}"
    : "${SHDOME_STATE_DIR:=$SHDOME_ROOT/state}"
    : "${SHDOME_LOCK_DIR:=$SHDOME_ROOT/locks}"
    : "${SHDOME_LOG_DIR:=$SHDOME_ROOT/logs}"
    : "${SHDOME_BACKUP_DIR:=$SHDOME_ROOT/backups}"
    : "${SHDOME_RUNTIME_DIR:=$SHDOME_ROOT/runtime}"
    if [[ -z "${SHDOME_CATALOG_DIR:-}" ]]; then
        SHDOME_CATALOG_DIR="$(cd "$SHDOME_SOURCE_DIR/../catalog" && pwd)"
    fi
    : "${SHDOME_GITHUB_REPO:=OWNER/shdome}"
    : "${SHDOME_RELEASE_VERSION:=v0.1.0}"

    export SHDOME_ROOT SHDOME_CONFIG_DIR SHDOME_APPS_DIR SHDOME_STATE_DIR
    export SHDOME_LOCK_DIR SHDOME_LOG_DIR SHDOME_BACKUP_DIR SHDOME_RUNTIME_DIR
    export SHDOME_CATALOG_DIR SHDOME_GITHUB_REPO SHDOME_RELEASE_VERSION

    umask 027
    if [[ ${EUID:-$(id -u)} -eq 0 || -w "$SHDOME_ROOT" || "${SHDOME_ALLOW_NON_ROOT:-0}" == "1" ]]; then
        mkdir -p "$SHDOME_CONFIG_DIR" "$SHDOME_APPS_DIR" "$SHDOME_STATE_DIR" \
            "$SHDOME_LOCK_DIR" "$SHDOME_LOG_DIR" "$SHDOME_BACKUP_DIR"
    fi
}

require_root() {
    if [[ "${SHDOME_ALLOW_NON_ROOT:-0}" == "1" ]]; then
        return 0
    fi
    if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
        fail "此操作需要 root 权限，请使用 sudo -i 后重试" 77
    fi
}

require_linux() {
    [[ "$(uname -s)" == "Linux" ]] || fail "SHDome 目前只支持 Linux" 69
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || fail "缺少必需命令：$1" 69
}

show_version() {
    printf '%s %s\n' "$SHDOME_NAME" "$SHDOME_VERSION"
}

settings_menu() {
    printf 'SHDome 版本：%s\n' "$SHDOME_VERSION"
    printf '数据目录：%s\n' "$SHDOME_ROOT"
    printf '应用目录：%s\n' "$SHDOME_CATALOG_DIR"
    printf '日志文件：%s/shdome.log\n' "$SHDOME_LOG_DIR"
    terminal_pause
}

config_command() {
    case "${1:-}" in
        ''|show) settings_menu ;;
        *) fail "用法：k config [show]" 64 ;;
    esac
}
