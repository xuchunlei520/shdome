#!/usr/bin/env bash

app_require_id() {
    local app_id="${1:-}"
    [[ -n "$app_id" ]] || { fail "缺少应用 ID" 64; return; }
    catalog_manifest_path "$app_id" >/dev/null || { fail "应用目录中不存在：$app_id" 66; return; }
}

app_require_installed() {
    local app_id="$1"
    [[ "$app_id" =~ ^[a-z0-9][a-z0-9-]{1,62}$ ]] || { fail "应用 ID 格式错误：$app_id" 64; return; }
    state_storage_require_readable || return
    state_exists "$app_id" || { fail "应用尚未安装：$app_id" 66; return; }
}

app_healthcheck() {
    local manifest_file="$1" host_port="$2"
    local type timeout path deadline now
    type="$(manifest_get "$manifest_file" healthcheck.type)"
    timeout="$(manifest_get "$manifest_file" healthcheck.timeoutSeconds)"
    path="$(manifest_get "$manifest_file" healthcheck.path 2>/dev/null || printf '/')"
    deadline=$(($(date +%s) + timeout))
    info "等待应用健康检查（最长 ${timeout} 秒）"
    while true; do
        case "$type" in
            http)
                if command -v curl >/dev/null 2>&1 && curl -fsS --max-time 3 "http://127.0.0.1:${host_port}${path}" >/dev/null 2>&1; then
                    return 0
                fi
                ;;
            tcp)
                if timeout 3 bash -c "</dev/tcp/127.0.0.1/$host_port" >/dev/null 2>&1; then
                    return 0
                fi
                ;;
            container)
                local container_name health
                container_name="$(manifest_get "$manifest_file" services.app.containerName)"
                health="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$container_name" 2>/dev/null || true)"
                [[ "$health" == "healthy" || "$health" == "running" ]] && return 0
                ;;
        esac
        now="$(date +%s)"
        ((now < deadline)) || break
        sleep 2
    done
    fail "应用未在 ${timeout} 秒内通过健康检查" 70
}

app_show_addresses() {
    local host_port="$1" address found=0
    if command -v hostname >/dev/null 2>&1; then
        for address in $(hostname -I 2>/dev/null || true); do
            case "$address" in
                *:*) printf '  http://[%s]:%s\n' "$address" "$host_port" ;;
                *) printf '  http://%s:%s\n' "$address" "$host_port" ;;
            esac
            found=1
        done
    fi
    [[ "$found" == "1" ]] || printf '  http://服务器IP:%s\n' "$host_port"
}

app_resource_preflight() {
    local manifest_file="$1" required_disk_gb required_memory_mb available_disk_mb available_memory_mb
    required_disk_gb="$(manifest_get "$manifest_file" resources.diskGB)"
    required_memory_mb="$(manifest_get "$manifest_file" resources.memoryMB)"
    available_disk_mb="$(df -Pk "$SHDOME_ROOT" | awk 'NR == 2 {print int($4 / 1024)}')"
    available_memory_mb="$(awk '/^MemAvailable:/ {print int($2 / 1024)}' /proc/meminfo)"
    [[ "$required_disk_gb" =~ ^[0-9]+$ && "$required_memory_mb" =~ ^[0-9]+$ ]] || { fail "Manifest 资源需求格式错误" 65; return; }
    ((available_disk_mb >= required_disk_gb * 1024)) || { fail "磁盘空间不足：至少需要 ${required_disk_gb} GB" 69; return; }
    if ((available_memory_mb < required_memory_mb)); then
        warn "可用内存约 ${available_memory_mb} MB，低于应用建议的 ${required_memory_mb} MB"
        terminal_confirm "内存不足可能导致安装失败，仍要继续吗？" || { fail "已取消安装" 69; return; }
    fi
}

app_install() {
    local app_id="${1:-}"
    shift || true
    app_require_id "$app_id" || return
    require_root || return
    local assume_yes=0 access="direct"
    local -a port_overrides=()
    while (($#)); do
        case "$1" in
            --port) [[ $# -ge 2 ]] || { fail "--port 缺少值" 64; return; }; port_overrides+=("$2"); shift 2 ;;
            --access) [[ $# -ge 2 ]] || { fail "--access 缺少值" 64; return; }; access="$2"; shift 2 ;;
            --yes|-y) assume_yes=1; shift ;;
            *) fail "未知安装参数：$1" 64; return ;;
        esac
    done
    [[ "$access" == "direct" ]] || { fail "应用安装阶段只支持 direct；请在安装后使用 k app domain $app_id 配置域名" 64; return; }
    SHDOME_ASSUME_YES="$assume_yes" lock_run "app-$app_id" app_install_locked "$app_id" "$assume_yes" "${port_overrides[@]}"
}

app_install_locked() {
    local app_id="$1" assume_yes="$2" manifest_file name ports_json primary_name primary_default selected_port
    local port_name host_port container_port protocol primary suffix
    shift 2
    local -a port_overrides=("$@")
    if state_exists "$app_id"; then
        fail "应用已安装：$app_id；更新请使用 k app update $app_id" 73
        return
    fi
    require_root || return
    require_linux || return
    require_supported_distribution || return
    require_command python3 || return
    manifest_file="$(catalog_manifest_path "$app_id")"
    manifest_validate "$manifest_file" || return
    [[ "$(manifest_get "$manifest_file" id)" == "$app_id" ]] || { fail "Manifest ID 与文件名不一致" 65; return; }
    manifest_supports_current_arch "$manifest_file" || { fail "应用不支持当前 CPU 架构" 69; return; }
    app_resource_preflight "$manifest_file" || return
    docker_runtime_ensure "$assume_yes" || return

    name="$(manifest_get "$manifest_file" name)"
    ports_json="$(manifest_ports_json "$manifest_file")"
    if ((${#port_overrides[@]} == 0)) && [[ "$assume_yes" != "1" ]]; then
        while IFS=$'\t' read -r port_name host_port container_port protocol primary; do
            if [[ "$primary" == "true" ]]; then
                primary_name="$port_name"
                primary_default="$host_port"
                break
            fi
        done < <(ports_json_each "$ports_json")
        terminal_read selected_port "输入应用主服务对外端口，回车默认使用 ${primary_default}: " "$primary_default" || return
        port_overrides+=("$primary_name=$selected_port")
    fi
    ports_json="$(manifest_ports_json "$manifest_file" "${port_overrides[@]}")"

    printf '\n安装计划\n%s\n' '--------------------------------'
    printf '应用：       %s (%s)\n' "$name" "$app_id"
    printf '访问模式：   IP+端口\n'
    while IFS=$'\t' read -r port_name host_port container_port protocol primary; do
        suffix=""
        [[ "$primary" != "true" ]] || suffix="（主服务）"
        printf '端口映射：   %-12s %s/%s → %s/%s%s\n' "$port_name" "$host_port" "$protocol" "$container_port" "$protocol" "$suffix"
    done < <(ports_json_each "$ports_json")
    printf '数据目录：   %s/%s\n' "$SHDOME_APPS_DIR" "$app_id"
    printf '%s\n' '--------------------------------'
    if [[ "$assume_yes" != "1" ]] && ! terminal_confirm "确认开始安装吗？"; then
        info "已取消安装"
        return 0
    fi
    lock_run ports app_install_with_port_lock "$app_id" "$manifest_file" "$ports_json"
}

app_install_with_port_lock() {
    local app_id="$1" manifest_file="$2" ports_json="$3"
    local app_dir="$SHDOME_APPS_DIR/$app_id" compose_file="$SHDOME_APPS_DIR/$app_id/compose.yml"
    local container_name container_id image image_digest primary_host
    local port_name host_port container_port protocol primary
    while IFS=$'\t' read -r port_name host_port container_port protocol primary; do
        port_assert_available "$host_port" "$app_id" || return
    done < <(ports_json_each "$ports_json")
    SHDOME_INSTALL_ACTIVE=1
    SHDOME_INSTALL_APP_ID="$app_id"
    SHDOME_INSTALL_COMPOSE_FILE="$compose_file"
    trap app_install_abort_cleanup EXIT
    mkdir -p "$app_dir/data" "$app_dir/logs"
    manifest_prepare_volumes "$manifest_file" "$app_dir" || return
    manifest_generate_env "$manifest_file" "$app_dir/.env" || return
    install -m 600 "$manifest_file" "$app_dir/manifest.json" || return
    compose_generate "$manifest_file" "$ports_json" "$compose_file" || return
    container_name="$(manifest_get "$manifest_file" services.app.containerName)"
    image="$(manifest_get "$manifest_file" services.app.image)"
    log_event INFO app-install "开始安装 $app_id，端口映射 $ports_json"
    if ! docker_compose -f "$compose_file" -p "shdome-$app_id" pull || \
       ! docker_compose -f "$compose_file" -p "shdome-$app_id" up -d; then
        docker_compose -f "$compose_file" -p "shdome-$app_id" down >/dev/null 2>&1 || true
        log_event ERROR app-install "容器启动失败 $app_id"
        fail "容器拉取或启动失败；数据目录已保留以便排查" 70
        return
    fi
    primary_host="$(ports_json_primary_host "$ports_json")"
    if ! app_healthcheck "$manifest_file" "$primary_host"; then
        docker_compose -f "$compose_file" -p "shdome-$app_id" down >/dev/null 2>&1 || true
        log_event ERROR app-install "健康检查失败并已停止 $app_id"
        fail "安装已回滚：容器未通过健康检查，应用数据目录已保留" 70
        return
    fi
    container_id="$(docker inspect -f '{{.Id}}' "$container_name")"
    image_digest="$(docker image inspect -f '{{index .RepoDigests 0}}' "$image" 2>/dev/null || true)"
    state_write "$app_id" "$manifest_file" "$ports_json" "$container_id" "$image_digest" || return
    SHDOME_INSTALL_ACTIVE=0
    trap - EXIT
    log_event INFO app-install "安装成功 $app_id"
    success "应用 $app_id 安装完成"
    app_show_addresses "$primary_host"
    info "后续可使用 k app domain $app_id 添加域名访问"
}

app_install_abort_cleanup() {
    [[ "${SHDOME_INSTALL_ACTIVE:-0}" == "1" ]] || return 0
    SHDOME_INSTALL_ACTIVE=0
    if [[ -f "${SHDOME_INSTALL_COMPOSE_FILE:-}" ]]; then
        docker_compose -f "$SHDOME_INSTALL_COMPOSE_FILE" -p "shdome-$SHDOME_INSTALL_APP_ID" down >/dev/null 2>&1 || true
    fi
    state_remove "$SHDOME_INSTALL_APP_ID" || true
    log_event WARN app-install "安装中断并清理未提交容器 $SHDOME_INSTALL_APP_ID"
}

app_status() {
    local app_id="${1:-}" container_name status health ports_json port_name host_port container_port protocol primary suffix json_output=0
    shift || true
    [[ "${1:-}" == "--json" ]] && json_output=1
    app_require_installed "$app_id" || return
    container_name="$(state_get "$app_id" containerName)"
    status="$(docker inspect -f '{{.State.Status}}' "$container_name" 2>/dev/null || printf 'missing')"
    health="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}未配置{{end}}' "$container_name" 2>/dev/null || printf '未知')"
    if [[ "$json_output" == "1" ]]; then
        python3 - "$(state_file_for "$app_id")" "$status" "$health" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as handle:
    state = json.load(handle)
state["runtimeStatus"] = sys.argv[2]
state["healthStatus"] = sys.argv[3]
print(json.dumps(state, ensure_ascii=False, separators=(",", ":")))
PY
        return
    fi
    printf '应用：%s (%s)\n' "$(state_get "$app_id" name)" "$app_id"
    printf '版本：%s\n' "$(state_get "$app_id" version)"
    printf '容器：%s (%s)\n' "$container_name" "$status"
    printf '健康：%s\n' "$health"
    printf '镜像：%s\n' "$(state_get "$app_id" image)"
    ports_json="$(state_ports_json "$app_id")"
    while IFS=$'\t' read -r port_name host_port container_port protocol primary; do
        suffix=""
        [[ "$primary" != "true" ]] || suffix="（主服务）"
        printf '端口：%-12s %s/%s → %s/%s%s\n' "$port_name" "$host_port" "$protocol" "$container_port" "$protocol" "$suffix"
    done < <(ports_json_each "$ports_json")
    printf '访问模式：%s\n' "$(state_get "$app_id" accessMode)"
    printf '域名：%s\n' "$(state_get "$app_id" domain 2>/dev/null || printf '未配置')"
    printf '数据目录：%s\n' "$(state_get "$app_id" dataDirectory)"
    printf '更新时间：%s\n' "$(state_get "$app_id" updatedAt)"
}

app_compose_action() {
    local app_id="$1" action="$2" app_dir
    app_dir="$SHDOME_APPS_DIR/$app_id"
    app_require_installed "$app_id" || return
    require_root || return
    docker_runtime_ready || { fail "Docker 服务不可用" 69; return; }
    case "$action" in
        start) docker_compose -f "$app_dir/compose.yml" -p "shdome-$app_id" start ;;
        stop) docker_compose -f "$app_dir/compose.yml" -p "shdome-$app_id" stop ;;
        restart) docker_compose -f "$app_dir/compose.yml" -p "shdome-$app_id" restart ;;
        *) fail "不支持的容器动作：$action" 70 ;;
    esac
    log_event INFO "app-$action" "$app_id"
}

app_start() { app_compose_action "${1:-}" start; }
app_stop() { app_compose_action "${1:-}" stop; }
app_restart() { app_compose_action "${1:-}" restart; }

app_logs() {
    local app_id="${1:-}" follow=0
    shift || true
    [[ "${1:-}" == "--follow" || "${1:-}" == "-f" ]] && follow=1
    app_require_installed "$app_id" || return
    if [[ "$follow" == "1" ]]; then
        docker_compose -f "$SHDOME_APPS_DIR/$app_id/compose.yml" -p "shdome-$app_id" logs -f --tail 200
    else
        docker_compose -f "$SHDOME_APPS_DIR/$app_id/compose.yml" -p "shdome-$app_id" logs --tail 200
    fi
}

app_credentials() {
    local app_id="${1:-}" env_file
    app_require_installed "$app_id" || return
    require_root || return
    env_file="$SHDOME_APPS_DIR/$app_id/.env"
    if [[ ! -s "$env_file" ]]; then
        info "该应用没有由 SHDome 生成的凭据"
        return 0
    fi
    warn "以下内容属于敏感凭据，请勿复制到公开日志"
    sed 's/^/  /' "$env_file"
}

app_reconcile() {
    local target="${1:-all}" repair=0 state_file app_id failures=0 found=0
    shift || true
    [[ "${1:-}" == "--repair" ]] && repair=1
    docker_runtime_ready || { fail "Docker 服务不可用" 69; return; }
    if [[ "$target" != "all" ]]; then
        app_require_installed "$target" || return
        app_reconcile_one "$target" "$repair"
        return
    fi
    while IFS= read -r state_file; do
        app_id="$(basename "$(dirname "$state_file")")"
        found=1
        if ! app_reconcile_one "$app_id" "$repair"; then
            failures=$((failures + 1))
        fi
    done < <(find "$SHDOME_APPS_DIR" -mindepth 2 -maxdepth 2 -type f -name state.json -print | LC_ALL=C sort)
    [[ "$found" == "1" ]] || { info "当前没有已安装应用"; return 0; }
    ((failures == 0)) || { fail "状态对账发现 $failures 个异常应用" 70; return; }
    success "全部应用状态一致"
}

app_reconcile_one() {
    local app_id="$1" repair="$2" state_file container_name app_dir host_port inspect_file
    state_file="$(state_file_for "$app_id")"
    container_name="$(state_get "$app_id" containerName)"
    app_dir="$SHDOME_APPS_DIR/$app_id"
    inspect_file="$(mktemp "$app_dir/.inspect.XXXXXX")"
    if docker inspect "$container_name" >"$inspect_file" 2>/dev/null && python3 - "$state_file" "$inspect_file" <<'PY'
import json, sys
state_path, inspect_path = sys.argv[1:]
with open(state_path, encoding="utf-8") as handle:
    state = json.load(handle)
try:
    with open(inspect_path, encoding="utf-8") as handle:
        inspected = json.load(handle)[0]
except (json.JSONDecodeError, IndexError):
    raise SystemExit(1)
labels = inspected.get("Config", {}).get("Labels") or {}
if labels.get("io.shdome.managed") != "true" or labels.get("io.shdome.app-id") != state["id"]:
    raise SystemExit(1)
bindings = inspected.get("NetworkSettings", {}).get("Ports") or {}
ports = state.get("ports") or [{
    "hostPort": state["hostPort"], "containerPort": state["containerPort"], "protocol": "tcp"
}]
for port in ports:
    key = f"{port['containerPort']}/{port.get('protocol', 'tcp')}"
    actual = {int(value["HostPort"]) for value in (bindings.get(key) or [])}
    if int(port["hostPort"]) not in actual:
        raise SystemExit(1)
if inspected.get("State", {}).get("Status") not in ("running", "exited"):
    raise SystemExit(1)
PY
    then
        rm -f "$inspect_file"
        printf '%-18s %s\n' "$app_id" '一致'
        return 0
    fi
    rm -f "$inspect_file"
    warn "$app_id 的容器、标签或端口与状态记录不一致"
    [[ "$repair" == "1" ]] || return 1
    require_root || return
    [[ -f "$app_dir/compose.yml" && -f "$app_dir/manifest.json" ]] || { fail "缺少重建文件：$app_id" 70; return; }
    docker_compose -f "$app_dir/compose.yml" -p "shdome-$app_id" up -d
    host_port="$(state_get "$app_id" hostPort)"
    app_healthcheck "$app_dir/manifest.json" "$host_port" || return
    success "$app_id 已按保存的 Compose 修复"
}

app_update() {
    local app_id="${1:-}" assume_yes=0 force=0
    shift || true
    while (($#)); do
        case "$1" in
            --yes|-y) assume_yes=1 ;;
            --force) force=1 ;;
            *) fail "未知更新参数：$1" 64; return ;;
        esac
        shift
    done
    app_require_id "$app_id" || return
    app_require_installed "$app_id" || return
    require_root || return
    SHDOME_ASSUME_YES="$assume_yes" lock_run "app-$app_id" app_update_locked "$app_id" "$assume_yes" "$force"
}

app_update_safe_remove_dir() {
    local path="$1" app_id="$2"
    case "$path" in
        "$SHDOME_APPS_DIR/$app_id"|"$SHDOME_APPS_DIR/.failed-update-$app_id-"*) rm -rf -- "$path" ;;
        *) warn "拒绝删除异常更新临时目录：$path"; return 70 ;;
    esac
}

app_update_restore_snapshot() {
    local app_id="$1" archive="$2" verify_health="${3:-0}"
    local app_dir="$SHDOME_APPS_DIR/$app_id" failed_dir="$SHDOME_APPS_DIR/.failed-update-$app_id-$$"
    local manifest_file host_port
    [[ -f "$archive" && -f "$archive.sha256" ]] || { warn "更新前一致性备份不完整：$archive"; return 1; }
    if ! (cd "$(dirname "$archive")" && sha256sum -c "$(basename "$archive").sha256" >/dev/null) || \
       ! backup_archive_validate "$archive" "$app_id"; then
        warn "更新前一致性备份校验失败：$archive"
        return 1
    fi
    [[ ! -e "$failed_dir" ]] || { warn "更新失败数据暂存目录已存在：$failed_dir"; return 1; }
    if [[ -f "$app_dir/compose.yml" ]]; then
        docker_compose -f "$app_dir/compose.yml" -p "shdome-$app_id" down >/dev/null 2>&1 || true
    fi
    if ! mv "$app_dir" "$failed_dir"; then
        warn "无法暂存更新失败后的应用目录"
        return 1
    fi
    if ! tar -xzf "$archive" -C "$SHDOME_APPS_DIR" --no-same-owner || \
       [[ ! -f "$app_dir/compose.yml" || ! -f "$app_dir/state.json" || ! -f "$app_dir/manifest.json" ]]; then
        [[ ! -e "$app_dir" ]] || app_update_safe_remove_dir "$app_dir" "$app_id" || true
        mv "$failed_dir" "$app_dir" || true
        warn "无法从一致性备份解压旧应用目录"
        return 1
    fi
    manifest_file="$app_dir/manifest.json"
    if ! manifest_validate "$manifest_file"; then
        app_update_safe_remove_dir "$app_dir" "$app_id" || true
        mv "$failed_dir" "$app_dir" || true
        warn "一致性备份中的 Manifest 无效"
        return 1
    fi
    if [[ -n "${SHDOME_UPDATE_OLD_IMAGE_ID:-}" ]]; then
        docker tag "$SHDOME_UPDATE_OLD_IMAGE_ID" "$SHDOME_UPDATE_OLD_IMAGE" >/dev/null 2>&1 || true
    fi
    if ! docker_compose -f "$app_dir/compose.yml" -p "shdome-$app_id" up -d; then
        warn "旧数据已经恢复，但旧容器启动失败；更新失败数据保留在 $failed_dir"
        return 1
    fi
    if [[ "$verify_health" == "1" ]]; then
        host_port="$(state_get "$app_id" hostPort)"
        if ! app_healthcheck "$manifest_file" "$host_port"; then
            warn "旧数据已经恢复，但应用尚未通过健康检查；更新失败数据保留在 $failed_dir"
            return 1
        fi
    fi
    app_update_safe_remove_dir "$failed_dir" "$app_id" || return 1
    return 0
}

app_update_locked() {
    local app_id="$1" assume_yes="$2" force="$3" manifest_file app_dir host_port ports_json image old_image_id container_name container_id digest
    local current_version target_version rollback_archive rollback_ok=0
    require_root || return
    docker_runtime_ready || { fail "Docker 服务不可用" 69; return; }
    manifest_file="$(catalog_manifest_path "$app_id")"
    manifest_validate "$manifest_file" || return
    [[ "$(manifest_get "$manifest_file" id)" == "$app_id" ]] || { fail "Manifest ID 与文件名不一致" 65; return; }
    app_dir="$SHDOME_APPS_DIR/$app_id"
    ports_json="$(state_ports_json "$app_id")"
    host_port="$(ports_json_primary_host "$ports_json")"
    image="$(state_get "$app_id" image)"
    current_version="$(state_get "$app_id" version)"
    target_version="$(manifest_get "$manifest_file" version)"
    old_image_id="$(docker image inspect -f '{{.Id}}' "$image" 2>/dev/null || true)"
    printf '当前版本：%s\n目标版本：%s\n' "$current_version" "$target_version"
    if [[ "$current_version" == "$target_version" && "$force" != "1" ]]; then
        success "应用已经是目录中的最新版本；重新部署请添加 --force"
        return 0
    fi
    if [[ "$assume_yes" != "1" ]] && ! terminal_confirm "将拉取目录中的固定版本并重建 $app_id，是否继续？"; then
        info "已取消更新"
        return
    fi
    info "更新前创建一致性备份"
    SHDOME_LAST_BACKUP_ARCHIVE=""
    app_backup_locked "$app_id" || return
    rollback_archive="${SHDOME_LAST_BACKUP_ARCHIVE:-}"
    if [[ ! -f "$rollback_archive" ]]; then
        fail "更新前一致性备份未生成，拒绝继续更新" 74
        return
    fi
    SHDOME_UPDATE_ACTIVE=1
    SHDOME_UPDATE_APP_ID="$app_id"
    SHDOME_UPDATE_ROLLBACK_ARCHIVE="$rollback_archive"
    SHDOME_UPDATE_OLD_IMAGE_ID="$old_image_id"
    SHDOME_UPDATE_OLD_IMAGE="$image"
    trap app_update_abort_cleanup EXIT
    manifest_generate_env "$manifest_file" "$app_dir/.env" || return
    local bind_address="0.0.0.0"
    [[ "$(state_get "$app_id" accessMode)" == "domain_only" ]] && bind_address="127.0.0.1"
    compose_generate "$manifest_file" "$ports_json" "$app_dir/compose.yml.new" "$bind_address" || return
    mv -f "$app_dir/compose.yml.new" "$app_dir/compose.yml" || return
    if docker_compose -f "$app_dir/compose.yml" -p "shdome-$app_id" pull && \
       docker_compose -f "$app_dir/compose.yml" -p "shdome-$app_id" up -d && \
       app_healthcheck "$manifest_file" "$host_port"; then
        install -m 600 "$manifest_file" "$app_dir/manifest.json" || return
        container_name="$(manifest_get "$manifest_file" services.app.containerName)"
        container_id="$(docker inspect -f '{{.Id}}' "$container_name")"
        digest="$(docker image inspect -f '{{index .RepoDigests 0}}' "$(manifest_get "$manifest_file" services.app.image)" 2>/dev/null || true)"
        state_write "$app_id" "$manifest_file" "$ports_json" "$container_id" "$digest" || return
        SHDOME_UPDATE_ACTIVE=0
        trap - EXIT
        log_event INFO app-update "更新成功 $app_id"
        success "应用 $app_id 更新完成"
        return
    fi
    warn "更新失败，正在从一致性备份恢复旧镜像、配置和应用数据"
    if app_update_restore_snapshot "$app_id" "$rollback_archive" 1; then
        rollback_ok=1
    fi
    SHDOME_UPDATE_ACTIVE=0
    trap - EXIT
    if [[ "$rollback_ok" == "1" ]]; then
        log_event ERROR app-update "更新失败并从一致性备份完成回滚 $app_id"
        fail "应用更新失败，已恢复更新前的镜像、配置和数据" 70
    else
        log_event ERROR app-update "更新失败且自动回滚未完全恢复 $app_id backup=$rollback_archive"
        fail "应用更新失败，自动恢复未完成；请保留现场并使用备份：$rollback_archive" 70
    fi
}

app_update_abort_cleanup() {
    [[ "${SHDOME_UPDATE_ACTIVE:-0}" == "1" ]] || return 0
    SHDOME_UPDATE_ACTIVE=0
    local app_id="$SHDOME_UPDATE_APP_ID" archive="$SHDOME_UPDATE_ROLLBACK_ARCHIVE"
    if app_update_restore_snapshot "$app_id" "$archive" 0; then
        log_event WARN app-update "更新中断并从一致性备份恢复旧配置和数据 $app_id"
    else
        log_event ERROR app-update "更新中断且自动恢复未完成 $app_id backup=$archive"
    fi
}

app_remove() {
    local app_id="${1:-}" purge=0 assume_yes=0
    shift || true
    while (($#)); do
        case "$1" in
            --purge) purge=1 ;;
            --yes|-y) assume_yes=1 ;;
            *) fail "未知卸载参数：$1" 64; return ;;
        esac
        shift
    done
    app_require_installed "$app_id" || return
    require_root || return
    SHDOME_ASSUME_YES="$assume_yes" lock_run "app-$app_id" app_remove_locked "$app_id" "$purge" "$assume_yes"
}

app_remove_locked() {
    local app_id="$1" purge="$2" assume_yes="$3" app_dir
    local domain
    app_dir="$SHDOME_APPS_DIR/$app_id"
    require_root || return
    if [[ "$assume_yes" != "1" ]] && ! terminal_confirm "确认卸载应用 $app_id 吗？默认保留数据"; then
        info "已取消卸载"
        return
    fi
    docker_compose -f "$app_dir/compose.yml" -p "shdome-$app_id" down
    domain="$(state_get "$app_id" domain 2>/dev/null || true)"
    if [[ -n "$domain" ]]; then
        gateway_paths_init
        rm -f "$SHDOME_GATEWAY_CONF_DIR/$domain.conf"
        if gateway_container_running; then
            gateway_reload || true
        fi
    fi
    state_remove "$app_id"
    if [[ "$purge" == "1" ]]; then
        if [[ "$assume_yes" != "1" ]] && ! terminal_confirm "这会永久删除 $app_dir 中的全部数据，再次确认？"; then
            warn "运行资源已卸载，数据仍保留"
            return
        fi
        [[ "$app_dir" == "$SHDOME_APPS_DIR/"* && "$app_dir" != "$SHDOME_APPS_DIR" ]] || { fail "拒绝删除异常路径：$app_dir" 70; return; }
        rm -rf -- "$app_dir"
        success "应用与数据已删除：$app_id"
    else
        success "应用运行资源已卸载，数据保留在 $app_dir"
    fi
    log_event INFO app-remove "$app_id purge=$purge"
}
