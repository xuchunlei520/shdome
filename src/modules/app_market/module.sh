#!/usr/bin/env bash

app_market_load() {
    local file
    for file in \
        manifest.sh \
        catalog.sh \
        port.sh \
        docker_runtime.sh \
        image_source.sh \
        preflight.sh \
        lifecycle.sh \
        gateway.sh \
        certificate.sh \
        backup.sh \
        custom.sh \
        catalog_update.sh \
        menu.sh; do
        # shellcheck source=/dev/null
        source "$SHDOME_SOURCE_DIR/modules/app_market/$file"
    done
}

app_market_load

app_market_register() {
    menu_register 1 "应用市场" app_market_menu
    menu_register 2 "应用运行环境" app_environment_menu
    command_register app app_command
    command_register env app_environment_command
    command_register backup backup_command
    command_register restore restore_command
    help_register app_market_help
}

app_market_help() {
    cat <<'EOF'
  k app                     打开应用市场
  k app list [--json]       查看应用目录
  k app categories          查看应用分类
  k app installed           查看已安装应用
  k app install <id>        安装应用
  k app custom add <镜像>    创建并安装自定义应用
  k app custom list         查看自定义应用
  k app catalog status      查看官方目录状态
  k app catalog refresh ... 验签并刷新官方目录
  k app status <id> [--json] 查看应用状态
  k app start|stop|restart <id>
  k app logs <id> [--follow]
  k app credentials <id>    查看生成的敏感凭据
  k app reconcile [id|all] [--repair]
  k app update <id>         更新应用
  k app domain <id>         配置应用域名和 HTTPS
  k app access <id> <direct|domain-only>
  k app backup <id>         备份应用
  k app restore <id> <备份ID> 恢复应用
  k app remove <id> [--purge]
  k env                     查看应用运行环境
  k env check               执行完整环境诊断
  k env mirror status|test  查看或测试自动镜像源
  k backup all              备份全部已安装应用
  k restore <备份ID>        按唯一备份 ID 恢复
EOF
}

app_command() {
    local action="${1:-}"
    if [[ -z "$action" ]]; then
        app_market_menu
        return
    fi
    shift
    case "$action" in
        list) app_list "$@" ;;
        search) app_search "$@" ;;
        categories) app_categories ;;
        category) app_category "$@" ;;
        details|info) app_details "${1:-}" ;;
        installed) app_installed ;;
        custom) custom_command "$@" ;;
        catalog) catalog_command "$@" ;;
        install) app_install "$@" ;;
        status) app_status "$@" ;;
        start) app_start "$@" ;;
        stop) app_stop "$@" ;;
        restart) app_restart "$@" ;;
        logs) app_logs "$@" ;;
        credentials) app_credentials "$@" ;;
        reconcile) app_reconcile "$@" ;;
        update) app_update "$@" ;;
        domain) app_domain "$@" ;;
        access) app_access_mode "$@" ;;
        certs) app_certs "$@" ;;
        cert) app_cert_command "$@" ;;
        backup) app_backup "$@" ;;
        backups) app_backups "$@" ;;
        restore) app_restore "$@" ;;
        remove|uninstall) app_remove "$@" ;;
        help|--help|-h) show_help ;;
        *) fail "未知应用命令：app $action" 64 ;;
    esac
}

app_environment_command() {
    case "${1:-}" in
        '') app_environment_menu ;;
        status) docker_runtime_status ;;
        check) environment_check ;;
        install) shift; lock_run docker-install docker_runtime_install "$@" ;;
        mirror) shift; image_source_command "$@" ;;
        containers) docker_managed_containers ;;
        images) docker_images ;;
        networks) docker_networks ;;
        resources) docker_resource_usage ;;
        ports) if command -v ss >/dev/null 2>&1; then ss -lntu; else fail "系统缺少 ss" 69; fi ;;
        prune-images) shift; docker_prune_images "$@" ;;
        *) fail "用法：k env [check|status|install|containers|images|networks|resources|ports|prune-images]" 64 ;;
    esac
}

backup_command() {
    local action="${1:-}"
    shift || true
    case "$action" in
        all) app_backup_all "$@" ;;
        *) fail "用法：k backup all [--yes]" 64 ;;
    esac
}

restore_command() {
    local backup_id="${1:-}"
    shift || true
    app_restore_by_id "$backup_id" "$@"
}

module_register app_market app_market_register
