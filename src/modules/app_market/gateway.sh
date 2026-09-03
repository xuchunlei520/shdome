#!/usr/bin/env bash

SHDOME_NGINX_IMAGE="nginx:1.28.0-alpine"
SHDOME_GATEWAY_CONTAINER="shdome-gateway"

domain_validate() {
    local domain="${1,,}"
    [[ ${#domain} -le 253 ]] || return 1
    [[ "$domain" =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$ ]]
}

domain_registered_to_other_app() {
    local domain="$1" current_app_id="$2"
    python3 - "$SHDOME_APPS_DIR" "$domain" "$current_app_id" <<'PY'
import glob, json, os, sys
root, domain, current = sys.argv[1:]
for path in glob.glob(os.path.join(root, "*", "state.json")):
    try:
        with open(path, encoding="utf-8") as handle:
            state = json.load(handle)
    except (OSError, json.JSONDecodeError):
        continue
    if state.get("id") != current and state.get("domain", "").lower() == domain.lower():
        print(state.get("id", "unknown"))
        raise SystemExit(0)
raise SystemExit(1)
PY
}

gateway_paths_init() {
    local nginx_temp=""
    SHDOME_GATEWAY_DIR="$SHDOME_ROOT/gateway"
    SHDOME_GATEWAY_CONF_DIR="$SHDOME_GATEWAY_DIR/conf.d"
    SHDOME_GATEWAY_WEBROOT="$SHDOME_GATEWAY_DIR/webroot"
    SHDOME_GATEWAY_CERTS="$SHDOME_GATEWAY_DIR/letsencrypt"
    export SHDOME_GATEWAY_DIR SHDOME_GATEWAY_CONF_DIR SHDOME_GATEWAY_WEBROOT SHDOME_GATEWAY_CERTS
    mkdir -p "$SHDOME_GATEWAY_CONF_DIR" "$SHDOME_GATEWAY_WEBROOT/.well-known/acme-challenge" "$SHDOME_GATEWAY_CERTS" || {
        fail "无法创建共享 Nginx 数据目录" 70
        return
    }
    chmod 755 "$SHDOME_GATEWAY_WEBROOT" "$SHDOME_GATEWAY_WEBROOT/.well-known" \
        "$SHDOME_GATEWAY_WEBROOT/.well-known/acme-challenge" || {
        fail "无法设置 ACME 验证目录权限" 70
        return
    }
    if [[ ! -f "$SHDOME_GATEWAY_DIR/nginx.conf" ]]; then
        nginx_temp="$(mktemp "$SHDOME_GATEWAY_DIR/.nginx.conf.XXXXXX")" || { fail "无法创建 Nginx 主配置临时文件" 70; return; }
        if ! printf '%s\n' \
            'user nginx;' \
            'worker_processes auto;' \
            'error_log /var/log/nginx/error.log notice;' \
            'pid /var/run/nginx.pid;' \
            'events { worker_connections 1024; }' \
            'http {' \
            '    include /etc/nginx/mime.types;' \
            '    default_type application/octet-stream;' \
            '    sendfile on;' \
            "    map \$http_upgrade \$connection_upgrade {" \
            '        default upgrade;' \
            "        '' close;" \
            '    }' \
            '    include /etc/nginx/conf.d/*.conf;' \
            '}' >"$nginx_temp"; then
            rm -f -- "$nginx_temp"
            fail "无法写入 Nginx 主配置" 70
            return
        fi
        chmod 644 "$nginx_temp" || { rm -f -- "$nginx_temp"; fail "无法设置 Nginx 主配置权限" 70; return; }
        if ! mv -f "$nginx_temp" "$SHDOME_GATEWAY_DIR/nginx.conf"; then
            rm -f -- "$nginx_temp"
            fail "无法提交 Nginx 主配置" 70
            return
        fi
    fi
}

gateway_container_running() {
    [[ "$(docker inspect -f '{{.State.Running}}' "$SHDOME_GATEWAY_CONTAINER" 2>/dev/null || true)" == "true" ]]
}

gateway_container_managed() {
    [[ "$(docker inspect -f '{{index .Config.Labels "io.shdome.managed"}}' "$SHDOME_GATEWAY_CONTAINER" 2>/dev/null || true)" == "true" ]]
}

gateway_ensure() {
    require_root || return
    docker_runtime_ready || { fail "配置域名需要 Docker 服务" 69; return; }
    gateway_paths_init
    if docker inspect "$SHDOME_GATEWAY_CONTAINER" >/dev/null 2>&1; then
        gateway_container_managed || { fail "存在同名但不属于 SHDome 的容器：$SHDOME_GATEWAY_CONTAINER" 73; return; }
        gateway_container_running && return 0
        docker start "$SHDOME_GATEWAY_CONTAINER" >/dev/null || { fail "共享 Nginx 容器启动失败" 70; return; }
        gateway_container_running || { fail "共享 Nginx 容器启动后未进入运行状态" 70; return; }
        return
    fi
    port_assert_available 80 gateway || return
    port_assert_available 443 gateway || return
    image_source_pull "$SHDOME_NGINX_IMAGE" || { fail "共享 Nginx 镜像拉取失败" 69; return; }
    docker run -d \
        --name "$SHDOME_GATEWAY_CONTAINER" \
        --label io.shdome.managed=true \
        --restart unless-stopped \
        --network host \
        -v "$SHDOME_GATEWAY_DIR/nginx.conf:/etc/nginx/nginx.conf:ro" \
        -v "$SHDOME_GATEWAY_CONF_DIR:/etc/nginx/conf.d:ro" \
        -v "$SHDOME_GATEWAY_WEBROOT:/var/www/certbot:ro" \
        -v "$SHDOME_GATEWAY_CERTS:/etc/letsencrypt:ro" \
        "$SHDOME_NGINX_IMAGE" || { fail "共享 Nginx 容器启动失败" 70; return; }
    gateway_container_running || { fail "共享 Nginx 启动失败" 70; return; }
}

gateway_config_test() {
    local candidate_file="${1:-}" target_name="${2:-}" test_dir
    gateway_paths_init || return
    test_dir="$(mktemp -d "$SHDOME_GATEWAY_DIR/.nginx-test.XXXXXX")" || { fail "无法创建 Nginx 配置校验目录" 70; return; }
    if ! find "$SHDOME_GATEWAY_CONF_DIR" -maxdepth 1 -type f -name '*.conf' -exec cp {} "$test_dir/" \;; then
        rm -rf -- "$test_dir"
        fail "无法准备 Nginx 配置校验目录" 70
        return
    fi
    if [[ -n "$candidate_file" ]]; then
        if ! cp "$candidate_file" "$test_dir/$target_name"; then
            rm -rf -- "$test_dir"
            fail "无法复制待校验的 Nginx 配置" 70
            return
        fi
    fi
    if ! docker run --rm \
        -v "$SHDOME_GATEWAY_DIR/nginx.conf:/etc/nginx/nginx.conf:ro" \
        -v "$test_dir:/etc/nginx/conf.d:ro" \
        -v "$SHDOME_GATEWAY_WEBROOT:/var/www/certbot:ro" \
        -v "$SHDOME_GATEWAY_CERTS:/etc/letsencrypt:ro" \
        "$SHDOME_NGINX_IMAGE" nginx -t; then
        rm -rf -- "$test_dir"
        fail "Nginx 配置校验失败" 70
        return
    fi
    rm -rf -- "$test_dir"
}

gateway_reload() {
    gateway_config_test || return
    docker exec "$SHDOME_GATEWAY_CONTAINER" nginx -s reload || { fail "Nginx 重载失败" 70; return; }
}

gateway_ipv6_listen() {
    local port="$1" options="${2:-}"
    host_ipv6_available || return 0
    printf '    listen [::]:%s%s;\n' "$port" "$options"
}

gateway_write_http_candidate() {
    local domain="$1" host_port="$2" output="$3" ipv6_listen
    ipv6_listen="$(gateway_ipv6_listen 80)"
    cat >"$output" <<EOF
server {
    listen 80;
$ipv6_listen
    server_name $domain;

    location ^~ /.well-known/acme-challenge/ {
        root /var/www/certbot;
    }

    location / {
        proxy_pass http://127.0.0.1:$host_port;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;
    }
}
EOF
}

gateway_write_https_candidate() {
    local domain="$1" host_port="$2" output="$3" ipv6_http ipv6_https
    ipv6_http="$(gateway_ipv6_listen 80)"
    ipv6_https="$(gateway_ipv6_listen 443 ' ssl')"
    cat >"$output" <<EOF
server {
    listen 80;
$ipv6_http
    server_name $domain;
    location ^~ /.well-known/acme-challenge/ { root /var/www/certbot; }
    location / { return 301 https://\$host\$request_uri; }
}

server {
    listen 443 ssl;
$ipv6_https
    http2 on;
    server_name $domain;
    ssl_certificate /etc/letsencrypt/live/$domain/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$domain/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;

    client_max_body_size 2g;
    proxy_connect_timeout 60s;
    proxy_read_timeout 3600s;
    proxy_send_timeout 3600s;
    location / {
        proxy_pass http://127.0.0.1:$host_port;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;
    }
}
EOF
}

gateway_commit_candidate() {
    local candidate="$1" domain="$2" target backup="" existed=0
    target="$SHDOME_GATEWAY_CONF_DIR/$domain.conf"
    if ! gateway_config_test "$candidate" "$domain.conf"; then
        rm -f -- "$candidate"
        return 70
    fi
    if [[ -f "$target" ]]; then
        backup="$(mktemp "$SHDOME_GATEWAY_DIR/.${domain}.rollback.XXXXXX")" || {
            rm -f -- "$candidate"
            fail "无法创建 Nginx 配置回滚文件" 70
            return
        }
        if ! cp "$target" "$backup"; then
            rm -f -- "$candidate" "$backup"
            fail "无法备份当前 Nginx 配置" 70
            return
        fi
        existed=1
    fi
    if ! mv -f "$candidate" "$target"; then
        [[ -z "$backup" ]] || rm -f -- "$backup"
        fail "无法提交 Nginx 配置文件" 70
        return
    fi
    if gateway_config_test && docker exec "$SHDOME_GATEWAY_CONTAINER" nginx -s reload; then
        [[ -z "$backup" ]] || rm -f "$backup"
        return 0
    fi
    warn "Nginx reload 失败，正在恢复旧配置"
    if [[ "$existed" == "1" ]]; then
        if ! mv -f "$backup" "$target"; then
            fail "Nginx 配置提交失败，且旧配置恢复失败：$target" 70
            return
        fi
    else
        rm -f -- "$target" || {
            fail "Nginx 配置提交失败，且新配置清理失败：$target" 70
            return
        }
    fi
    gateway_config_test || true
    docker exec "$SHDOME_GATEWAY_CONTAINER" nginx -s reload >/dev/null 2>&1 || true
    fail "Nginx 配置提交失败，已恢复旧配置" 70
    return
}

gateway_restore_domain_config() {
    local domain="$1" backup="$2" existed="$3" target restore_status=0
    target="$SHDOME_GATEWAY_CONF_DIR/$domain.conf"
    if [[ "$existed" == "1" && -f "$backup" ]]; then
        mv -f "$backup" "$target" || restore_status=1
    else
        rm -f -- "$target" || restore_status=1
        [[ -z "$backup" ]] || rm -f "$backup"
    fi
    if gateway_container_running; then
        gateway_config_test >/dev/null 2>&1 || restore_status=1
        docker exec "$SHDOME_GATEWAY_CONTAINER" nginx -s reload >/dev/null 2>&1 || restore_status=1
    fi
    [[ "$restore_status" == "0" ]] || { fail "Nginx 旧配置恢复不完整：$domain" 70; return; }
}

app_switch_access_mode() {
    local app_id="$1" access_mode="$2" domain="$3" app_dir manifest_file host_port ports_json bind_address backup
    app_dir="$SHDOME_APPS_DIR/$app_id"
    manifest_file="$app_dir/manifest.json"
    ports_json="$(state_ports_json "$app_id")"
    host_port="$(ports_json_primary_host "$ports_json")"
    bind_address="0.0.0.0"
    [[ "$access_mode" == "domain_only" ]] && bind_address="127.0.0.1"
    backup="$(mktemp "$app_dir/.compose.yml.routing-backup.XXXXXX")" || { fail "无法创建应用 Compose 回滚文件：$app_id" 70; return; }
    cp "$app_dir/compose.yml" "$backup" || { rm -f -- "$backup"; fail "无法备份应用 Compose 配置：$app_id" 70; return; }
    if ! compose_generate "$manifest_file" "$ports_json" "$app_dir/compose.yml.new" "$bind_address"; then
        rm -f -- "$backup" "$app_dir/compose.yml.new"
        return 70
    fi
    if ! mv -f "$app_dir/compose.yml.new" "$app_dir/compose.yml"; then
        rm -f -- "$app_dir/compose.yml.new"
        mv -f "$backup" "$app_dir/compose.yml" >/dev/null 2>&1 || true
        fail "无法提交应用 Compose 配置：$app_id" 70
        return
    fi
    if docker_compose -f "$app_dir/compose.yml" -p "shdome-$app_id" up -d && \
       app_healthcheck "$manifest_file" "$host_port"; then
        if state_set_routing "$app_id" "$access_mode" "$domain"; then
            rm -f -- "$backup"
            return 0
        fi
        warn "应用已按新模式启动，但访问状态保存失败，正在回滚"
    else
        warn "访问模式切换失败，正在恢复原端口绑定"
    fi
    mv -f "$backup" "$app_dir/compose.yml" || { fail "访问模式切换失败，且 Compose 配置恢复失败：$app_id" 70; return; }
    docker_compose -f "$app_dir/compose.yml" -p "shdome-$app_id" up -d || true
    fail "访问模式切换失败" 70
    return
}
