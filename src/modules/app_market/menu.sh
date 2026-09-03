#!/usr/bin/env bash

app_market_menu() {
    local choice app_id
    catalog_auto_refresh
    while true; do
        printf '\n应用市场\n%s\n' '--------------------------------'
        app_list
        printf '%s\n' '--------------------------------'
        printf '%s\n' 'A. 添加自定义应用' '0. 返回上一级选单' '--------------------------------'
        terminal_read choice "输入序号、应用名称或 A: " ""
        case "$choice" in
            0) return 0 ;;
            A|a) custom_add || true; terminal_pause ;;
            *)
                if app_id="$(catalog_resolve_selector "$choice")"; then
                    if state_exists "$app_id"; then
                        app_manage_menu "$app_id"
                    else
                        app_install "$app_id" || true
                        terminal_pause
                    fi
                else
                    warn "找不到应用：$choice；请输入序号或应用名称"
                fi
                ;;
        esac
    done
}

app_manage_menu() {
    local app_id="$1" choice manifest_file app_name status current_domain access_mode direct_status direct_address direct_addresses
    app_name="$app_id"
    manifest_file="$(catalog_manifest_path "$app_id" 2>/dev/null || true)"
    if [[ -n "$manifest_file" ]]; then
        app_name="$(manifest_get "$manifest_file" name 2>/dev/null || printf '%s' "$app_id")"
    fi
    while true; do
        status="$(app_runtime_status "$app_id")"
        current_domain=""
        access_mode=""
        direct_status="不可用"
        if state_exists "$app_id"; then
            current_domain="$(state_get "$app_id" domain 2>/dev/null || true)"
            access_mode="$(state_get "$app_id" accessMode 2>/dev/null || printf 'direct')"
            direct_status="允许"
            if [[ "$access_mode" == "domain_only" ]]; then
                direct_status="已阻止"
            else
                direct_addresses="$(app_show_direct_addresses "$app_id")"
                direct_address="${direct_addresses%%$'\n'*}"
                direct_status="允许  $direct_address"
            fi
        fi
        printf '\n应用：%s\n状态：%s\n' "$app_name" "$status"
        printf '域名访问：%s\nIP+端口访问：%s\n' "${current_domain:-未配置}" "$direct_status"
        printf '%s\n' '--------------------------------'
        printf '%s\n' \
            '1. 安装              2. 更新            3. 卸载' \
            '--------------------------------' \
            '5. 添加域名访问      6. 删除域名访问' \
            '7. 允许IP+端口访问   8. 阻止IP+端口访问' \
            '--------------------------------' \
            '0. 返回上一级选单' \
            '--------------------------------'
        terminal_read choice "请输入选择: " ""
        case "$choice" in
            0) return 0 ;;
            1) app_install "$app_id" || true ;;
            2) app_update "$app_id" || true ;;
            3) app_remove "$app_id" || true ;;
            5) app_domain "$app_id" --configure --access domain-only || true ;;
            6) app_domain "$app_id" --remove || true ;;
            7) app_access_mode "$app_id" direct || true ;;
            8) app_access_mode "$app_id" domain-only || true ;;
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
        printf '%s\n' '--------------------------------' '1. 完整环境检查' '2. 安装/修复 Docker' '3. 查看容器' '4. 查看镜像' '5. 查看网络' '6. 查看资源占用' '7. 查看端口监听' '8. 清理悬空镜像' '9. 自动镜像源状态' '0. 返回'
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
            9) image_source_status; image_source_test || true; terminal_pause ;;
            *) warn "无效选择：$choice" ;;
        esac
    done
}
