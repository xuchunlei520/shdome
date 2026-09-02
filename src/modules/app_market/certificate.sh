#!/usr/bin/env bash

SHDOME_CERTBOT_IMAGE="certbot/certbot:v4.0.0"

domain_dns_matches_server() {
    local domain="$1" resolved public_v4 public_v6 local_ips
    resolved="$(getent ahosts "$domain" 2>/dev/null | awk '{print $1}' | sort -u || true)"
    [[ -n "$resolved" ]] || return 1
    local_ips="$(hostname -I 2>/dev/null | tr ' ' '\n' || true)"
    public_v4="$(curl -4 -fsS --max-time 5 https://api.ipify.org 2>/dev/null || true)"
    public_v6="$(curl -6 -fsS --max-time 5 https://api64.ipify.org 2>/dev/null || true)"
    while IFS= read -r address; do
        [[ -n "$address" ]] || continue
        grep -Fxq "$address" <<<"$resolved" && return 0
    done <<<"$local_ips"$'\n'"$public_v4"$'\n'"$public_v6"
    return 1
}

certificate_issue() {
    local domain="$1" email="$2"
    local -a account_args
    if [[ -n "$email" ]]; then
        account_args=(--email "$email")
    else
        account_args=(--register-unsafely-without-email)
    fi
    gateway_paths_init || return
    docker pull "$SHDOME_CERTBOT_IMAGE" || { fail "Certbot 镜像拉取失败" 69; return; }
    docker run --rm \
        -v "$SHDOME_GATEWAY_WEBROOT:/var/www/certbot" \
        -v "$SHDOME_GATEWAY_CERTS:/etc/letsencrypt" \
        "$SHDOME_CERTBOT_IMAGE" certonly \
        --webroot --webroot-path /var/www/certbot \
        --non-interactive --agree-tos --keep-until-expiring \
        "${account_args[@]}" -d "$domain" || { fail "证书签发失败：$domain" 70; return; }
    certificate_validate "$domain" || return
}

certificate_validate() {
    local domain="$1" cert key cert_pubkey key_pubkey
    cert="$SHDOME_GATEWAY_CERTS/live/$domain/fullchain.pem"
    key="$SHDOME_GATEWAY_CERTS/live/$domain/privkey.pem"
    [[ -s "$cert" && -s "$key" ]] || { fail "证书文件不完整：$domain" 70; return; }
    openssl x509 -in "$cert" -noout -checkend 86400 >/dev/null || { fail "证书有效期异常：$domain" 70; return; }
    openssl x509 -in "$cert" -noout -checkhost "$domain" >/dev/null || { fail "证书不包含域名：$domain" 70; return; }
    cert_pubkey="$(openssl x509 -in "$cert" -pubkey -noout | openssl sha256)"
    key_pubkey="$(openssl pkey -in "$key" -pubout 2>/dev/null | openssl sha256)"
    [[ -n "$cert_pubkey" && "$cert_pubkey" == "$key_pubkey" ]] || { fail "证书和私钥不匹配：$domain" 70; return; }
}

app_domain() {
    local app_id="${1:-}" domain="" email="" access_mode="direct" assume_yes=0 skip_dns=0 remove=0 configure=0
    shift || true
    app_require_installed "$app_id" || return
    require_root || return
    while (($#)); do
        case "$1" in
            --domain) [[ $# -ge 2 ]] || { fail "--domain 缺少值" 64; return; }; domain="${2,,}"; shift 2 ;;
            --email) [[ $# -ge 2 ]] || { fail "--email 缺少值" 64; return; }; email="$2"; shift 2 ;;
            --access) [[ $# -ge 2 ]] || { fail "--access 缺少值" 64; return; }; access_mode="${2//-/_}"; shift 2 ;;
            --skip-dns-check) skip_dns=1; shift ;;
            --remove) remove=1; shift ;;
            --configure) configure=1; shift ;;
            --yes|-y) assume_yes=1; shift ;;
            *) fail "未知域名参数：$1" 64; return ;;
        esac
    done
    if [[ "$remove" == "1" ]]; then
        if [[ "$assume_yes" != "1" ]] && ! terminal_confirm "确认移除 $app_id 的域名和反向代理配置吗？"; then
            info "已取消移除域名"
            return 0
        fi
        lock_run "app-$app_id" lock_run nginx app_domain_remove_locked "$app_id"
        return
    fi
    if [[ "$configure" != "1" && -z "$domain" && "$assume_yes" != "1" && -n "$(state_get "$app_id" domain 2>/dev/null || true)" ]]; then
        app_domain_menu "$app_id"
        return
    fi
    if [[ -z "$domain" ]]; then
        [[ "$assume_yes" != "1" ]] || { fail "自动化模式必须提供 --domain" 64; return; }
        terminal_read domain "请输入已解析到本机的域名: " "" || return
        domain="${domain,,}"
    fi
    if [[ -z "$email" && "$assume_yes" != "1" ]]; then
        terminal_read email "请输入 Let's Encrypt 通知邮箱（可留空）: " "" || return
    fi
    domain_validate "$domain" || { fail "域名格式错误：$domain" 64; return; }
    if [[ -n "$email" ]]; then
        [[ "$email" =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]] || { fail "邮箱格式错误" 64; return; }
    else
        warn "未提供 Let's Encrypt 通知邮箱，证书到期或续期失败时不会收到邮件提醒"
    fi
    [[ "$access_mode" == "direct" || "$access_mode" == "domain_only" ]] || { fail "--access 只支持 direct 或 domain-only" 64; return; }
    local owner
    owner="$(domain_registered_to_other_app "$domain" "$app_id" 2>/dev/null || true)"
    [[ -z "$owner" ]] || { fail "域名已绑定到应用：$owner" 73; return; }
    if [[ "$(system_time_status)" == "未确认同步" ]]; then
        if [[ "$assume_yes" == "1" ]]; then
            fail "系统时间未确认同步，自动化模式拒绝申请证书" 69
            return
        fi
        warn "系统时间未确认同步，可能导致 ACME 验证或证书校验失败"
        terminal_confirm "仍要继续吗？" || return 0
    fi
    if [[ "$skip_dns" != "1" ]] && ! domain_dns_matches_server "$domain"; then
        if [[ "$assume_yes" == "1" ]]; then
            fail "域名解析结果与本机地址不一致；确认使用 CDN 代理时可显式添加 --skip-dns-check" 69
            return
        fi
        warn "域名解析结果未匹配本机公网地址，HTTP-01 可能失败"
        terminal_confirm "仍要继续申请证书吗？" || return 0
    fi
    SHDOME_ASSUME_YES="$assume_yes" lock_run "app-$app_id" lock_run nginx app_domain_locked "$app_id" "$domain" "$email" "$access_mode"
}

app_access_mode() {
    local app_id="${1:-}" access_mode="${2:-}" assume_yes=0 domain
    shift 2 2>/dev/null || true
    [[ "${1:-}" == "--yes" || "${1:-}" == "-y" ]] && assume_yes=1
    app_require_installed "$app_id" || return
    require_root || return
    access_mode="${access_mode//-/_}"
    [[ "$access_mode" == "direct" || "$access_mode" == "domain_only" ]] || { fail "访问模式只支持 direct 或 domain-only" 64; return; }
    domain="$(state_get "$app_id" domain 2>/dev/null || true)"
    [[ "$access_mode" != "domain_only" || -n "$domain" ]] || { fail "应用尚未配置域名，不能切换为 domain-only" 69; return; }
    if [[ "$assume_yes" != "1" ]] && ! terminal_confirm "确认将 $app_id 切换为 $access_mode 吗？"; then
        info "已取消切换"
        return 0
    fi
    SHDOME_ASSUME_YES="$assume_yes" lock_run "app-$app_id" app_switch_access_mode "$app_id" "$access_mode" "$domain" || return
    success "访问模式已切换为 $access_mode"
}

app_domain_menu() {
    local app_id="$1" choice current_domain access_mode
    while true; do
        current_domain="$(state_get "$app_id" domain 2>/dev/null || true)"
        access_mode="$(state_get "$app_id" accessMode)"
        printf '\n应用域名：%s\n访问模式：%s\n%s\n' "${current_domain:-未配置}" "$access_mode" '--------------------------------'
        printf '%s\n' '1. 添加/更换域名并申请证书' '2. 移除域名' '3. 允许 IP+端口访问' '4. 仅允许域名访问' '5. 查看证书' '6. 手动续期证书' '0. 返回'
        terminal_read choice "请输入选择: " ""
        case "$choice" in
            0) return ;;
            1) app_domain "$app_id" --configure || true ;;
            2) app_domain "$app_id" --remove || true ;;
            3) app_access_mode "$app_id" direct || true ;;
            4) app_access_mode "$app_id" domain-only || true ;;
            5) app_certs; terminal_pause ;;
            6)
                if [[ -n "$current_domain" ]]; then certificate_renew_one "$app_id" || true; else warn "尚未配置域名"; fi
                terminal_pause
                ;;
            *) warn "无效选择：$choice" ;;
        esac
    done
}

app_domain_locked() {
    local app_id="$1" domain="$2" email="$3" access_mode="$4" host_port candidate old_domain target transaction_backup="" config_existed=0
    if ! host_port="$(state_get "$app_id" hostPort)"; then
        fail "无法读取应用端口状态：$app_id" 65
        return
    fi
    old_domain="$(state_get "$app_id" domain 2>/dev/null || true)"
    gateway_ensure || return
    target="$SHDOME_GATEWAY_CONF_DIR/$domain.conf"
    if [[ -f "$target" ]]; then
        transaction_backup="$(mktemp "$SHDOME_GATEWAY_DIR/.${domain}.transaction.XXXXXX")" || { fail "无法创建域名配置回滚文件" 70; return; }
        if ! cp "$target" "$transaction_backup"; then
            rm -f -- "$transaction_backup"
            fail "无法备份域名原配置：$domain" 70
            return
        fi
        config_existed=1
    fi
    candidate="$(mktemp "$SHDOME_GATEWAY_CONF_DIR/.${domain}.XXXXXX")" || {
        [[ -z "$transaction_backup" ]] || rm -f -- "$transaction_backup"
        fail "无法创建域名配置候选文件" 70
        return
    }
    if ! gateway_write_http_candidate "$domain" "$host_port" "$candidate"; then
        rm -f -- "$candidate"
        [[ -z "$transaction_backup" ]] || rm -f -- "$transaction_backup"
        fail "无法生成 HTTP 反向代理配置" 70
        return
    fi
    if ! gateway_commit_candidate "$candidate" "$domain"; then
        [[ -z "$transaction_backup" ]] || rm -f "$transaction_backup"
        return 70
    fi
    if ! lock_run certificates lock_run "cert-$domain" certificate_issue "$domain" "$email"; then
        gateway_restore_domain_config "$domain" "$transaction_backup" "$config_existed" || warn "域名原配置未能完整恢复，请检查 Nginx"
        warn "证书签发失败，已恢复域名原配置"
        return 70
    fi
    candidate="$(mktemp "$SHDOME_GATEWAY_CONF_DIR/.${domain}.XXXXXX")" || {
        gateway_restore_domain_config "$domain" "$transaction_backup" "$config_existed" || true
        fail "无法创建 HTTPS 配置候选文件" 70
        return
    }
    if ! gateway_write_https_candidate "$domain" "$host_port" "$candidate"; then
        rm -f -- "$candidate"
        gateway_restore_domain_config "$domain" "$transaction_backup" "$config_existed" || true
        fail "无法生成 HTTPS 反向代理配置" 70
        return
    fi
    if ! gateway_commit_candidate "$candidate" "$domain"; then
        gateway_restore_domain_config "$domain" "$transaction_backup" "$config_existed" || warn "域名原配置未能完整恢复，请检查 Nginx"
        return 70
    fi
    if ! app_switch_access_mode "$app_id" "$access_mode" "$domain"; then
        gateway_restore_domain_config "$domain" "$transaction_backup" "$config_existed" || warn "域名原配置未能完整恢复，请检查 Nginx"
        return 70
    fi
    [[ -z "$transaction_backup" ]] || rm -f -- "$transaction_backup"
    if [[ -n "$old_domain" && "$old_domain" != "$domain" ]]; then
        app_domain_old_config_remove "$old_domain" || warn "新域名已生效，但旧域名配置未能移除：$old_domain"
    fi
    certificate_timer_install || warn "证书已签发，但自动续期定时器安装失败；请修复后执行 k app cert renew-all"
    log_event INFO app-domain "$app_id domain=$domain access=$access_mode"
    success "域名已配置：https://$domain"
}

app_domain_old_config_remove() {
    local domain="$1" target backup
    gateway_paths_init || return
    target="$SHDOME_GATEWAY_CONF_DIR/$domain.conf"
    [[ -f "$target" ]] || return 0
    backup="$(mktemp "$SHDOME_GATEWAY_DIR/.${domain}.old-domain.XXXXXX")" || { fail "无法创建旧域名配置回滚文件" 70; return; }
    cp "$target" "$backup" || { rm -f -- "$backup"; fail "无法备份旧域名配置：$domain" 70; return; }
    rm -f -- "$target" || { rm -f -- "$backup"; fail "无法移除旧域名配置：$domain" 70; return; }
    if gateway_container_running && ! gateway_reload; then
        gateway_restore_domain_config "$domain" "$backup" 1 || true
        fail "旧域名配置移除失败，已尝试恢复：$domain" 70
        return
    fi
    rm -f -- "$backup"
}

app_domain_remove_locked() {
    local app_id="$1" domain target backup="" config_existed=0
    domain="$(state_get "$app_id" domain 2>/dev/null || true)"
    [[ -n "$domain" ]] || { info "应用未配置域名"; return 0; }
    gateway_paths_init || return
    target="$SHDOME_GATEWAY_CONF_DIR/$domain.conf"
    if [[ -f "$target" ]]; then
        backup="$(mktemp "$SHDOME_GATEWAY_DIR/.${domain}.remove.XXXXXX")" || { fail "无法创建域名移除回滚文件" 70; return; }
        cp "$target" "$backup" || { rm -f -- "$backup"; fail "无法备份域名配置：$domain" 70; return; }
        config_existed=1
        rm -f -- "$target" || { rm -f -- "$backup"; fail "无法移除域名配置：$domain" 70; return; }
        if gateway_container_running && ! gateway_reload; then
            gateway_restore_domain_config "$domain" "$backup" "$config_existed" || true
            return 70
        fi
    fi
    if ! app_switch_access_mode "$app_id" direct ""; then
        gateway_restore_domain_config "$domain" "$backup" "$config_existed" || true
        return 70
    fi
    [[ -z "$backup" ]] || rm -f -- "$backup"
    log_event INFO app-domain-remove "$app_id domain=$domain"
    success "已移除域名绑定，应用恢复 IP+端口访问"
}

certificate_renew_all() {
    require_root || return
    lock_run nginx lock_run certificates certificate_renew_all_locked
}

certificate_renew_all_locked() {
    gateway_paths_init || return
    gateway_container_running || { fail "共享 Nginx 未运行" 69; return; }
    docker run --rm \
        -v "$SHDOME_GATEWAY_WEBROOT:/var/www/certbot" \
        -v "$SHDOME_GATEWAY_CERTS:/etc/letsencrypt" \
        "$SHDOME_CERTBOT_IMAGE" renew --webroot -w /var/www/certbot --non-interactive || { fail "Certbot 续期检查失败" 70; return; }
    local state_file domain
    while IFS= read -r state_file; do
        if ! domain="$(python3 - "$state_file" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as handle:
    print(json.load(handle).get("domain", ""))
PY
)"; then
            fail "无法读取应用证书状态：$state_file" 65
            return
        fi
        [[ -z "$domain" ]] || certificate_validate "$domain" || return
    done < <(find "$SHDOME_APPS_DIR" -mindepth 2 -maxdepth 2 -type f -name state.json -print)
    gateway_reload || return
    log_event INFO cert-renew "证书续期检查完成"
}

certificate_renew_one() {
    local target="${1:-}" domain
    require_root || return
    [[ -n "$target" ]] || { fail "用法：k app cert renew <应用ID或域名>" 64; return; }
    if state_exists "$target"; then
        domain="$(state_get "$target" domain 2>/dev/null || true)"
    else
        domain="${target,,}"
    fi
    domain_validate "$domain" || { fail "找不到有效的应用域名：$target" 66; return; }
    lock_run nginx lock_run certificates lock_run "cert-$domain" certificate_renew_one_locked "$domain"
}

certificate_renew_one_locked() {
    local domain="$1"
    gateway_paths_init || return
    gateway_container_running || { fail "共享 Nginx 未运行" 69; return; }
    docker run --rm \
        -v "$SHDOME_GATEWAY_WEBROOT:/var/www/certbot" \
        -v "$SHDOME_GATEWAY_CERTS:/etc/letsencrypt" \
        "$SHDOME_CERTBOT_IMAGE" renew --cert-name "$domain" --webroot -w /var/www/certbot --non-interactive || { fail "Certbot 续期失败：$domain" 70; return; }
    certificate_validate "$domain" || return
    gateway_reload || return
    log_event INFO cert-renew "手动续期 $domain"
    success "证书续期检查完成：$domain"
}

certificate_import() {
    local app_id="${1:-}" domain="" cert_source="" key_source="" access_mode="direct" assume_yes=0 owner
    shift || true
    app_require_installed "$app_id" || return
    require_root || return
    while (($#)); do
        case "$1" in
            --domain) [[ $# -ge 2 ]] || { fail "--domain 缺少值" 64; return; }; domain="${2,,}"; shift 2 ;;
            --cert) [[ $# -ge 2 ]] || { fail "--cert 缺少值" 64; return; }; cert_source="$2"; shift 2 ;;
            --key) [[ $# -ge 2 ]] || { fail "--key 缺少值" 64; return; }; key_source="$2"; shift 2 ;;
            --access) [[ $# -ge 2 ]] || { fail "--access 缺少值" 64; return; }; access_mode="${2//-/_}"; shift 2 ;;
            --yes|-y) assume_yes=1; shift ;;
            *) fail "未知证书导入参数：$1" 64; return ;;
        esac
    done
    [[ -n "$domain" && -n "$cert_source" && -n "$key_source" ]] || { fail "必须提供 --domain、--cert 和 --key" 64; return; }
    domain_validate "$domain" || { fail "域名格式错误：$domain" 64; return; }
    [[ "$access_mode" == "direct" || "$access_mode" == "domain_only" ]] || { fail "--access 只支持 direct 或 domain-only" 64; return; }
    [[ -f "$cert_source" && -f "$key_source" ]] || { fail "证书或私钥文件不存在" 66; return; }
    owner="$(domain_registered_to_other_app "$domain" "$app_id" 2>/dev/null || true)"
    [[ -z "$owner" ]] || { fail "域名已绑定到应用：$owner" 73; return; }
    certificate_validate_files "$domain" "$cert_source" "$key_source" || return
    if [[ "$assume_yes" != "1" ]] && ! terminal_confirm "将为 $app_id 导入 $domain 的证书，是否继续？"; then
        info "已取消导入"
        return 0
    fi
    SHDOME_ASSUME_YES="$assume_yes" lock_run "app-$app_id" lock_run nginx lock_run certificates lock_run "cert-$domain" certificate_import_locked "$app_id" "$domain" "$cert_source" "$key_source" "$access_mode"
}

certificate_validate_files() {
    local domain="$1" cert="$2" key="$3" cert_pubkey key_pubkey
    openssl x509 -in "$cert" -noout -checkend 86400 >/dev/null || { fail "证书有效期不足或格式错误" 65; return; }
    openssl x509 -in "$cert" -noout -checkhost "$domain" >/dev/null || { fail "证书不包含域名：$domain" 65; return; }
    cert_pubkey="$(openssl x509 -in "$cert" -pubkey -noout | openssl sha256)"
    key_pubkey="$(openssl pkey -in "$key" -pubout 2>/dev/null | openssl sha256)"
    [[ -n "$cert_pubkey" && "$cert_pubkey" == "$key_pubkey" ]] || { fail "证书和私钥不匹配" 65; return; }
}

certificate_import_locked() {
    local app_id="$1" domain="$2" cert_source="$3" key_source="$4" access_mode="$5"
    local host_port live_dir cert_temp="" key_temp="" candidate="" old_domain target config_backup="" config_existed=0
    local cert_backup_dir cert_existed=0
    if ! host_port="$(state_get "$app_id" hostPort)"; then
        fail "无法读取应用端口状态：$app_id" 65
        return
    fi
    old_domain="$(state_get "$app_id" domain 2>/dev/null || true)"
    gateway_ensure || return
    [[ ! -f "$SHDOME_GATEWAY_CERTS/renewal/$domain.conf" ]] || { fail "该域名由 ACME 管理，请使用续期命令，不能覆盖导入" 73; return; }
    live_dir="$SHDOME_GATEWAY_CERTS/live/$domain"
    mkdir -p "$live_dir" || { fail "无法创建证书目录：$live_dir" 70; return; }
    cert_backup_dir="$(mktemp -d "$SHDOME_GATEWAY_DIR/.cert-${domain}.rollback.XXXXXX")" || { fail "无法创建证书回滚目录" 70; return; }
    if [[ -e "$live_dir/fullchain.pem" || -e "$live_dir/privkey.pem" ]]; then
        if [[ ! -f "$live_dir/fullchain.pem" || ! -f "$live_dir/privkey.pem" ]]; then
            rm -rf -- "$cert_backup_dir"
            fail "现有证书目录不完整，拒绝覆盖：$domain" 65
            return
        fi
        if ! cp "$live_dir/fullchain.pem" "$cert_backup_dir/fullchain.pem" || \
           ! cp "$live_dir/privkey.pem" "$cert_backup_dir/privkey.pem"; then
            rm -rf -- "$cert_backup_dir"
            fail "无法备份现有证书：$domain" 70
            return
        fi
        cert_existed=1
    fi
    target="$SHDOME_GATEWAY_CONF_DIR/$domain.conf"
    if [[ -f "$target" ]]; then
        config_backup="$(mktemp "$SHDOME_GATEWAY_DIR/.${domain}.import.XXXXXX")" || {
            rm -rf -- "$cert_backup_dir"
            fail "无法创建 Nginx 配置回滚文件" 70
            return
        }
        if ! cp "$target" "$config_backup"; then
            rm -f -- "$config_backup"
            rm -rf -- "$cert_backup_dir"
            fail "无法备份当前 Nginx 配置" 70
            return
        fi
        config_existed=1
    fi
    cert_temp="$(mktemp "$live_dir/.fullchain.XXXXXX")" || {
        certificate_import_rollback "$domain" "$live_dir" "$cert_backup_dir" "$cert_existed" "$config_backup" "$config_existed" "" "" "" || true
        fail "无法创建证书临时文件" 70
        return
    }
    key_temp="$(mktemp "$live_dir/.privkey.XXXXXX")" || {
        certificate_import_rollback "$domain" "$live_dir" "$cert_backup_dir" "$cert_existed" "$config_backup" "$config_existed" "$cert_temp" "" "" || true
        fail "无法创建私钥临时文件" 70
        return
    }
    if ! install -m 644 "$cert_source" "$cert_temp" || ! install -m 600 "$key_source" "$key_temp"; then
        certificate_import_rollback "$domain" "$live_dir" "$cert_backup_dir" "$cert_existed" "$config_backup" "$config_existed" "$cert_temp" "$key_temp" "" || true
        fail "无法暂存导入的证书文件" 70
        return
    fi
    if ! certificate_validate_files "$domain" "$cert_temp" "$key_temp"; then
        certificate_import_rollback "$domain" "$live_dir" "$cert_backup_dir" "$cert_existed" "$config_backup" "$config_existed" "$cert_temp" "$key_temp" "" || true
        return 65
    fi
    if ! mv -f "$cert_temp" "$live_dir/fullchain.pem" || ! mv -f "$key_temp" "$live_dir/privkey.pem"; then
        certificate_import_rollback "$domain" "$live_dir" "$cert_backup_dir" "$cert_existed" "$config_backup" "$config_existed" "$cert_temp" "$key_temp" "" || true
        fail "无法提交导入的证书文件" 70
        return
    fi
    cert_temp=""
    key_temp=""
    if ! certificate_validate "$domain"; then
        certificate_import_rollback "$domain" "$live_dir" "$cert_backup_dir" "$cert_existed" "$config_backup" "$config_existed" "" "" "" || true
        return 65
    fi
    candidate="$(mktemp "$SHDOME_GATEWAY_CONF_DIR/.${domain}.XXXXXX")" || {
        certificate_import_rollback "$domain" "$live_dir" "$cert_backup_dir" "$cert_existed" "$config_backup" "$config_existed" "" "" "" || true
        fail "无法创建 HTTPS 配置候选文件" 70
        return
    }
    if ! gateway_write_https_candidate "$domain" "$host_port" "$candidate"; then
        certificate_import_rollback "$domain" "$live_dir" "$cert_backup_dir" "$cert_existed" "$config_backup" "$config_existed" "" "" "$candidate" || true
        fail "无法生成 HTTPS 反向代理配置" 70
        return
    fi
    if ! gateway_commit_candidate "$candidate" "$domain" || \
       ! app_switch_access_mode "$app_id" "$access_mode" "$domain"; then
        certificate_import_rollback "$domain" "$live_dir" "$cert_backup_dir" "$cert_existed" "$config_backup" "$config_existed" "" "" "$candidate" || true
        return 70
    fi
    rm -rf -- "$cert_backup_dir"
    [[ -z "$config_backup" ]] || rm -f -- "$config_backup"
    if [[ -n "$old_domain" && "$old_domain" != "$domain" ]]; then
        app_domain_old_config_remove "$old_domain" || warn "新域名已生效，但旧域名配置未能移除：$old_domain"
    fi
    log_event INFO cert-import "$app_id domain=$domain"
    success "已导入证书并配置：https://$domain"
    warn "导入证书没有 ACME 续期配置，到期前请重新导入"
}

certificate_import_rollback() {
    local domain="$1" live_dir="$2" cert_backup_dir="$3" cert_existed="$4" config_backup="$5" config_existed="$6"
    local cert_temp="${7:-}" key_temp="${8:-}" candidate="${9:-}" rollback_status=0
    [[ -z "$cert_temp" ]] || rm -f -- "$cert_temp" || rollback_status=1
    [[ -z "$key_temp" ]] || rm -f -- "$key_temp" || rollback_status=1
    [[ -z "$candidate" ]] || rm -f -- "$candidate" || rollback_status=1
    if [[ "$cert_existed" == "1" ]]; then
        install -m 644 "$cert_backup_dir/fullchain.pem" "$live_dir/fullchain.pem" || rollback_status=1
        install -m 600 "$cert_backup_dir/privkey.pem" "$live_dir/privkey.pem" || rollback_status=1
    else
        rm -f -- "$live_dir/fullchain.pem" "$live_dir/privkey.pem" || rollback_status=1
        rmdir "$live_dir" >/dev/null 2>&1 || true
    fi
    rm -rf -- "$cert_backup_dir"
    gateway_restore_domain_config "$domain" "$config_backup" "$config_existed" || rollback_status=1
    if [[ "$rollback_status" == "0" ]]; then
        warn "证书导入未完成，已恢复原证书和 Nginx 配置"
        return 0
    fi
    fail "证书导入回滚不完整，请立即检查：$domain" 70
    return
}

app_certs() {
    local state_file app_id domain cert expires issuer found=0
    gateway_paths_init || return
    printf '%-18s %-35s %-30s %s\n' '应用 ID' '域名' '颁发者' '证书到期时间'
    while IFS= read -r state_file; do
        app_id="$(basename "$(dirname "$state_file")")"
        domain="$(state_get "$app_id" domain 2>/dev/null || true)"
        [[ -n "$domain" ]] || continue
        cert="$SHDOME_GATEWAY_CERTS/live/$domain/fullchain.pem"
        expires="$(openssl x509 -in "$cert" -noout -enddate 2>/dev/null | cut -d= -f2- || printf '证书缺失')"
        issuer="$(openssl x509 -in "$cert" -noout -issuer 2>/dev/null | sed 's/^issuer=//' || printf '未知')"
        printf '%-18s %-35s %-30s %s\n' "$app_id" "$domain" "$issuer" "$expires"
        found=1
    done < <(find "$SHDOME_APPS_DIR" -mindepth 2 -maxdepth 2 -type f -name state.json -print)
    [[ "$found" == "1" ]] || info "当前没有应用证书"
}

certificate_timer_install() {
    local service_file=/etc/systemd/system/shdome-cert-renew.service
    local timer_file=/etc/systemd/system/shdome-cert-renew.timer
    local service_temp timer_temp
    command -v systemctl >/dev/null 2>&1 || { warn "未使用 systemd，请自行定期执行 k app cert renew-all"; return 0; }
    service_temp="$(mktemp /etc/systemd/system/.shdome-cert-renew.service.XXXXXX)" || { fail "无法创建证书续期服务配置" 70; return; }
    timer_temp="$(mktemp /etc/systemd/system/.shdome-cert-renew.timer.XXXXXX)" || {
        rm -f -- "$service_temp"
        fail "无法创建证书续期定时器配置" 70
        return
    }
    if ! printf '%s\n' \
        '[Unit]' \
        'Description=Renew SHDome application certificates' \
        '[Service]' \
        'Type=oneshot' \
        'ExecStart=/usr/local/bin/k app cert renew-all --yes' \
        >"$service_temp"; then
        rm -f -- "$service_temp" "$timer_temp"
        fail "无法写入证书续期服务配置" 70
        return
    fi
    if ! printf '%s\n' \
        '[Unit]' \
        'Description=Daily SHDome certificate renewal check' \
        '[Timer]' \
        'OnCalendar=daily' \
        'RandomizedDelaySec=2h' \
        'Persistent=true' \
        '[Install]' \
        'WantedBy=timers.target' \
        >"$timer_temp"; then
        rm -f -- "$service_temp" "$timer_temp"
        fail "无法写入证书续期定时器配置" 70
        return
    fi
    chmod 644 "$service_temp" "$timer_temp" || { rm -f -- "$service_temp" "$timer_temp"; fail "无法设置证书续期配置权限" 70; return; }
    mv -f "$service_temp" "$service_file" || { rm -f -- "$service_temp" "$timer_temp"; fail "无法安装证书续期服务" 70; return; }
    mv -f "$timer_temp" "$timer_file" || { rm -f -- "$timer_temp"; fail "无法安装证书续期定时器" 70; return; }
    systemctl daemon-reload || { fail "systemd 重新加载失败" 70; return; }
    systemctl enable --now shdome-cert-renew.timer >/dev/null || { fail "证书自动续期定时器启用失败" 70; return; }
}

app_cert_command() {
    case "${1:-}" in
        renew-all) shift; certificate_renew_all "$@" ;;
        renew) shift; certificate_renew_one "$@" ;;
        import) shift; certificate_import "$@" ;;
        list|'') app_certs ;;
        *) fail "用法：k app cert [list|renew <应用ID或域名>|renew-all|import <应用ID> --domain ... --cert ... --key ...]" 64 ;;
    esac
}
