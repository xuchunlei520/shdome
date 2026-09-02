#!/usr/bin/env bash

app_market_menu() {
    local choice app_id
    while true; do
        printf '\n应用市场\n%s\n' '--------------------------------'
        app_list
        printf '%s\n' '--------------------------------'
        printf '%s\n' 'i. 安装应用' 's. 搜索应用' 'c. 按分类浏览' '0. 返回'
        terminal_read choice "请输入选择: " ""
        case "$choice" in
            0) return 0 ;;
            i)
                terminal_read app_id "请输入应用 ID: " ""
                app_install "$app_id" || true
                terminal_pause
                ;;
            s)
                terminal_read app_id "请输入关键词: " ""
                app_search "$app_id" || true
                terminal_pause
                ;;
            c)
                app_categories
                terminal_read app_id "请输入分类名称: " ""
                app_category "$app_id" || true
                terminal_pause
                ;;
            *)
                if catalog_manifest_path "$choice" >/dev/null 2>&1; then
                    app_details "$choice"
                    terminal_pause
                else
                    warn "请输入应用 ID、i、s 或 0"
                fi
                ;;
        esac
    done
}

installed_apps_menu() {
    local app_id
    while true; do
        printf '\n已安装应用\n%s\n' '--------------------------------'
        app_installed
        printf '%s\n' '--------------------------------'
        terminal_read app_id "输入应用 ID 进行管理，输入 0 返回: " ""
        [[ "$app_id" != "0" ]] || return 0
        if state_exists "$app_id"; then
            app_manage_menu "$app_id"
        else
            warn "应用未安装：$app_id"
        fi
    done
}

app_manage_menu() {
    local app_id="$1" choice
    while true; do
        printf '\n应用：%s\n%s\n' "$app_id" '--------------------------------'
        printf '%s\n' '1. 查看状态' '2. 启动' '3. 停止' '4. 重启' '5. 查看日志' '6. 更新' '7. 查看生成凭据' '8. 配置域名/HTTPS' '9. 备份' '10. 恢复' '20. 卸载' '0. 返回'
        terminal_read choice "请输入选择: " ""
        case "$choice" in
            0) return 0 ;;
            1) app_status "$app_id" || true ;;
            2) app_start "$app_id" || true ;;
            3) app_stop "$app_id" || true ;;
            4) app_restart "$app_id" || true ;;
            5) app_logs "$app_id" || true ;;
            6) app_update "$app_id" || true ;;
            7) app_credentials "$app_id" || true ;;
            8) app_domain_menu "$app_id" || true ;;
            9) app_backup "$app_id" || true ;;
            10)
                local backup_id
                app_backups "$app_id"
                terminal_read backup_id "请输入备份 ID（不含 .tar.gz）: " ""
                app_restore "$app_id" "$backup_id" || true
                ;;
            20) app_remove "$app_id" || true; state_exists "$app_id" || return 0 ;;
            *) warn "无效选择：$choice"; continue ;;
        esac
        terminal_pause
    done
}

app_environment_menu() {
    local choice
    while true; do
        printf '\n应用运行环境\n%s\n' '--------------------------------'
        docker_runtime_status
        if command -v docker >/dev/null 2>&1; then
            printf '共享 Nginx：%s\n' "$(gateway_container_running && printf '运行中' || printf '未运行')"
        fi
        printf '%s\n' '--------------------------------' '1. 完整环境检查' '2. 安装/修复 Docker' '3. 查看容器' '4. 查看镜像' '5. 查看网络' '6. 查看资源占用' '7. 查看端口监听' '8. 清理悬空镜像' '0. 返回'
        terminal_read choice "请输入选择: " ""
        case "$choice" in
            0) return 0 ;;
            1) environment_check || true; terminal_pause ;;
            2) lock_run docker-install docker_runtime_install || true; terminal_pause ;;
            3) docker_managed_containers || true; terminal_pause ;;
            4) docker_images || true; terminal_pause ;;
            5) docker_networks || true; terminal_pause ;;
            6) docker_resource_usage || true; terminal_pause ;;
            7) if command -v ss >/dev/null 2>&1; then ss -lntu; else warn "系统缺少 ss"; fi; terminal_pause ;;
            8) docker_prune_images || true; terminal_pause ;;
            *) warn "无效选择：$choice" ;;
        esac
    done
}
