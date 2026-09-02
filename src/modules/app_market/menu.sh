#!/usr/bin/env bash

app_market_menu() {
    local choice selector app_id
    while true; do
        printf '\n应用市场\n%s\n' '--------------------------------'
        app_list
        printf '%s\n' '--------------------------------'
        printf '%s\n' 'i. 安装应用' 's. 搜索应用' 'c. 按分类浏览' '0. 返回'
        terminal_read choice "输入序号或名称查看/管理应用: " ""
        case "$choice" in
            0) return 0 ;;
            i)
                terminal_read selector "请输入应用序号或名称: " ""
                if ! app_id="$(catalog_resolve_selector "$selector")"; then
                    warn "找不到应用：$selector"
                    terminal_pause
                    continue
                fi
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
                if app_id="$(catalog_resolve_selector "$choice")"; then
                    if state_exists "$app_id"; then
                        app_manage_menu "$app_id"
                    else
                        app_details "$app_id"
                        terminal_pause
                    fi
                else
                    warn "请输入应用序号、名称、i、s、c 或 0"
                fi
                ;;
        esac
    done
}

app_manage_menu() {
    local app_id="$1" choice manifest_file app_name
    app_name="$app_id"
    manifest_file="$(catalog_manifest_path "$app_id" 2>/dev/null || true)"
    if [[ -n "$manifest_file" ]]; then
        app_name="$(manifest_get "$manifest_file" name 2>/dev/null || printf '%s' "$app_id")"
    fi
    while true; do
        printf '\n应用：%s\n%s\n' "$app_name" '--------------------------------'
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
