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

app_compose_pull_or_cached() {
    local compose_file="$1" project="$2" manifest_file="$3" service_name image container_name
    : "$compose_file" "$project"
    while IFS=$'\t' read -r service_name image container_name; do
        image_source_pull "$image" || return
    done < <(manifest_services_each "$manifest_file")
}

app_services_running() {
    local manifest_file="$1" service_name image container_name status
    while IFS=$'\t' read -r service_name image container_name; do
        status="$(docker inspect -f '{{.State.Status}}' "$container_name" 2>/dev/null || true)"
        [[ "$status" == "running" ]] || return 1
    done < <(manifest_services_each "$manifest_file")
}

app_healthcheck() {
    local manifest_file="$1" ports_json="$2"
    local type timeout path deadline now host_port service_name container_name health ready
    type="$(manifest_get "$manifest_file" healthcheck.type)"
    timeout="$(manifest_get "$manifest_file" healthcheck.timeoutSeconds)"
    path="$(manifest_get "$manifest_file" healthcheck.path 2>/dev/null || printf '/')"
    service_name="$(manifest_get "$manifest_file" healthcheck.service)"
    host_port="$(ports_json_primary_host "$ports_json")"
    container_name="$(manifest_get "$manifest_file" "services.$service_name.containerName")"
    deadline=$(($(date +%s) + timeout))
    info "等待应用健康检查（最长 ${timeout} 秒）"
    while true; do
        ready=0
        case "$type" in
            http)
                if command -v curl >/dev/null 2>&1 && curl -fsS --max-time 3 "http://127.0.0.1:${host_port}${path}" >/dev/null 2>&1; then
                    ready=1
                fi
                ;;
            tcp)
                if timeout 3 bash -c "</dev/tcp/127.0.0.1/$host_port" >/dev/null 2>&1; then
                    ready=1
                fi
                ;;
            container)
                health="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$container_name" 2>/dev/null || true)"
                [[ "$health" == "healthy" || "$health" == "running" ]] && ready=1
                ;;
        esac
        if [[ "$ready" == "1" ]] && app_services_running "$manifest_file"; then
            return 0
        fi
        now="$(date +%s)"
        ((now < deadline)) || break
        sleep 2
    done
    fail "应用未在 ${timeout} 秒内通过健康检查" 70
}

app_show_addresses() {
    local host_port="$1" scheme="${2:-http}" address found=0
    local public_v4 public_v6 addresses
    public_v4="$(curl -4 -fsS --max-time 2 https://api.ipify.org 2>/dev/null || true)"
    public_v6="$(curl -6 -fsS --max-time 2 https://api64.ipify.org 2>/dev/null || true)"
    addresses="$public_v4"$'\n'"$public_v6"
    if [[ -z "$public_v4" && -z "$public_v6" ]] && command -v hostname >/dev/null 2>&1; then
        addresses+=$'\n'"$(hostname -I 2>/dev/null | tr ' ' '\n' || true)"
    fi
    while IFS= read -r address; do
        [[ -n "$address" ]] || continue
        [[ "$address" != "127.0.0.1" && "$address" != "::1" ]] || continue
        [[ "$found" != *"|$address|"* ]] || continue
        found+="|$address|"
        case "$address" in
            *:*) printf '%s://[%s]:%s\n' "$scheme" "$address" "$host_port" ;;
            *) printf '%s://%s:%s\n' "$scheme" "$address" "$host_port" ;;
        esac
    done <<<"$addresses"
    [[ "$found" != "0" ]] || printf '%s://服务器IP:%s\n' "$scheme" "$host_port"
}

app_show_direct_addresses() {
    local app_id="$1" app_dir ports_json host_port scheme
    app_dir="$SHDOME_APPS_DIR/$app_id"
    ports_json="$(state_ports_json "$app_id")"
    host_port="$(ports_json_primary_host "$ports_json")"
    scheme="$(manifest_get "$app_dir/manifest.json" routing.scheme)"
    app_show_addresses "$host_port" "$scheme"
}

app_runtime_services_json() {
    local manifest_file="$1" service_name image container_name container_id image_digest
    local -a values=()
    while IFS=$'\t' read -r service_name image container_name; do
        container_id="$(docker inspect -f '{{.Id}}' "$container_name")" || return
        image_digest="$(docker image inspect -f '{{index .RepoDigests 0}}' "$image" 2>/dev/null || true)"
        values+=("$service_name" "$image" "$container_name" "$container_id" "$image_digest")
    done < <(manifest_services_each "$manifest_file")
    python3 - "${values[@]}" <<'PY'
import json, sys
values = sys.argv[1:]
services = {}
for index in range(0, len(values), 5):
    name, image, container_name, container_id, digest = values[index:index + 5]
    services[name] = {
        "image": image, "imageDigest": digest,
        "containerName": container_name, "containerId": container_id,
    }
print(json.dumps(services, ensure_ascii=False, separators=(",", ":")))
PY
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
    local app_id="$1" assume_yes="$2" manifest_file name
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
    lock_run ports app_install_plan_locked "$app_id" "$assume_yes" "$manifest_file" "$name" "${port_overrides[@]}"
}

app_install_plan_locked() {
    local app_id="$1" assume_yes="$2" manifest_file="$3" name="$4"
    local ports_json base_ports_json primary_name port_name host_port container_port protocol primary service_name suffix
    local override override_name selected_port reserved=""
    shift 4
    local -a port_overrides=("$@")
    local -a auto_overrides=()
    declare -A explicit_ports=()
    base_ports_json="$(manifest_ports_json "$manifest_file")"
    while IFS=$'\t' read -r port_name host_port container_port protocol primary service_name; do
        [[ "$primary" != "true" ]] || primary_name="$port_name"
    done < <(ports_json_each "$base_ports_json")
    for override in "${port_overrides[@]}"; do
        if [[ "$override" == *=* ]]; then
            override_name="${override%%=*}"
        else
            override_name="$primary_name"
        fi
        explicit_ports["$override_name"]=1
    done
    ports_json="$(manifest_ports_json "$manifest_file" "${port_overrides[@]}")"
    while IFS=$'\t' read -r port_name host_port container_port protocol primary service_name; do
        if [[ -n "${explicit_ports[$port_name]:-}" ]]; then
            selected_port="$host_port"
        else
            selected_port="$(port_find_available "$host_port" "$app_id" "$reserved" "$protocol")" || return
            auto_overrides+=("$port_name=$selected_port")
            if [[ "$selected_port" != "$host_port" ]]; then
                info "建议端口 $host_port 已占用，已为 $port_name 自动选择 $selected_port"
            fi
        fi
        reserved="${reserved:+$reserved,}$selected_port/$protocol"
    done < <(ports_json_each "$ports_json")
    ports_json="$(manifest_ports_json "$manifest_file" "${port_overrides[@]}" "${auto_overrides[@]}")" || return

    printf '\n安装计划\n%s\n' '--------------------------------'
    printf '应用：       %s (%s)\n' "$name" "$app_id"
    printf '访问模式：   IP+端口\n'
    while IFS=$'\t' read -r port_name host_port container_port protocol primary service_name; do
        suffix=""
        [[ "$primary" != "true" ]] || suffix="（主服务）"
        printf '端口映射：   %-12s %s/%s → %s:%s/%s%s\n' "$port_name" "$host_port" "$protocol" "$service_name" "$container_port" "$protocol" "$suffix"
    done < <(ports_json_each "$ports_json")
    printf '数据目录：   %s/%s\n' "$SHDOME_APPS_DIR" "$app_id"
    printf '%s\n' '--------------------------------'
    if [[ "$assume_yes" != "1" ]] && ! terminal_confirm "确认开始安装吗？"; then
        info "已取消安装"
        return 0
    fi
    app_install_with_port_lock "$app_id" "$manifest_file" "$ports_json"
}

app_install_with_port_lock() {
    local app_id="$1" manifest_file="$2" ports_json="$3"
    local app_dir="$SHDOME_APPS_DIR/$app_id" compose_file="$SHDOME_APPS_DIR/$app_id/compose.yml"
    local services_json primary_host address_scheme
    local port_name host_port container_port protocol primary service_name
    while IFS=$'\t' read -r port_name host_port container_port protocol primary service_name; do
        port_assert_available "$host_port" "$app_id" "$protocol" || return
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
    log_event INFO app-install "开始安装 $app_id，端口映射 $ports_json"
    if ! app_compose_pull_or_cached "$compose_file" "shdome-$app_id" "$manifest_file" || \
       ! docker_compose -f "$compose_file" -p "shdome-$app_id" up -d; then
        docker_compose -f "$compose_file" -p "shdome-$app_id" down >/dev/null 2>&1 || true
        log_event ERROR app-install "容器启动失败 $app_id"
        fail "容器拉取或启动失败；数据目录已保留以便排查" 70
        return
    fi
    primary_host="$(ports_json_primary_host "$ports_json")"
    if ! app_healthcheck "$manifest_file" "$ports_json"; then
        docker_compose -f "$compose_file" -p "shdome-$app_id" down >/dev/null 2>&1 || true
        log_event ERROR app-install "健康检查失败并已停止 $app_id"
        fail "安装已回滚：容器未通过健康检查，应用数据目录已保留" 70
        return
    fi
    services_json="$(app_runtime_services_json "$manifest_file")" || return
    state_write "$app_id" "$manifest_file" "$ports_json" "$services_json" || return
    SHDOME_INSTALL_ACTIVE=0
    trap - EXIT
    log_event INFO app-install "安装成功 $app_id"
    success "应用 $app_id 安装完成"
    address_scheme="$(manifest_get "$manifest_file" routing.scheme)"
    app_show_addresses "$primary_host" "$address_scheme"
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
    local app_id="${1:-}" service_name image container_name container_id image_digest status health
    local ports_json port_name host_port container_port protocol primary port_service suffix json_output=0
    local -a runtime_values=()
    shift || true
    [[ "${1:-}" == "--json" ]] && json_output=1
    app_require_installed "$app_id" || return
    if [[ "$json_output" == "1" ]]; then
        while IFS=$'\t' read -r service_name image container_name container_id image_digest; do
            status="$(docker inspect -f '{{.State.Status}}' "$container_name" 2>/dev/null || printf 'missing')"
            health="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}未配置{{end}}' "$container_name" 2>/dev/null || printf '未知')"
            runtime_values+=("$service_name" "$status" "$health")
        done < <(state_services_each "$app_id")
        python3 - "$(state_file_for "$app_id")" "${runtime_values[@]}" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as handle:
    state = json.load(handle)
for index in range(2, len(sys.argv), 3):
    name, status, health = sys.argv[index:index + 3]
    state["services"][name]["runtimeStatus"] = status
    state["services"][name]["healthStatus"] = health
print(json.dumps(state, ensure_ascii=False, separators=(",", ":")))
PY
        return
    fi
    printf '应用：%s (%s)\n' "$(state_get "$app_id" name)" "$app_id"
    printf '版本：%s\n' "$(state_get "$app_id" version)"
    while IFS=$'\t' read -r service_name image container_name container_id image_digest; do
        status="$(docker inspect -f '{{.State.Status}}' "$container_name" 2>/dev/null || printf 'missing')"
        health="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}未配置{{end}}' "$container_name" 2>/dev/null || printf '未知')"
        printf '服务：%-12s %s (%s，健康：%s)\n' "$service_name" "$container_name" "$status" "$health"
        printf '镜像：%-12s %s\n' "" "$image"
    done < <(state_services_each "$app_id")
    ports_json="$(state_ports_json "$app_id")"
    while IFS=$'\t' read -r port_name host_port container_port protocol primary port_service; do
        suffix=""
        [[ "$primary" != "true" ]] || suffix="（主服务）"
        printf '端口：%-12s %s/%s → %s:%s/%s%s\n' "$port_name" "$host_port" "$protocol" "$port_service" "$container_port" "$protocol" "$suffix"
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
    local app_id="$1" repair="$2" state_file app_dir inspect_file
    local service_name image container_name container_id image_digest
    local -a container_names=()
    state_file="$(state_file_for "$app_id")"
    app_dir="$SHDOME_APPS_DIR/$app_id"
    inspect_file="$(mktemp "$app_dir/.inspect.XXXXXX")"
    while IFS=$'\t' read -r service_name image container_name container_id image_digest; do
        container_names+=("$container_name")
    done < <(state_services_each "$app_id")
    if docker inspect "${container_names[@]}" >"$inspect_file" 2>/dev/null && python3 - "$state_file" "$inspect_file" <<'PY'
import json, sys
state_path, inspect_path = sys.argv[1:]
with open(state_path, encoding="utf-8") as handle:
    state = json.load(handle)
try:
    with open(inspect_path, encoding="utf-8") as handle:
        inspected_items = json.load(handle)
except json.JSONDecodeError:
    raise SystemExit(1)
inspected_by_name = {item.get("Name", "").lstrip("/"): item for item in inspected_items}
if len(inspected_by_name) != len(state["services"]):
    raise SystemExit(1)
for service_name, service in state["services"].items():
    inspected = inspected_by_name.get(service["containerName"])
    if not inspected:
        raise SystemExit(1)
    labels = inspected.get("Config", {}).get("Labels") or {}
    if labels.get("io.shdome.managed") != "true" or labels.get("io.shdome.app-id") != state["id"] or labels.get("io.shdome.service") != service_name:
        raise SystemExit(1)
    if inspected.get("State", {}).get("Status") not in ("running", "exited"):
        raise SystemExit(1)
    bindings = inspected.get("NetworkSettings", {}).get("Ports") or {}
    for port in (value for value in state["ports"] if value["service"] == service_name):
        key = f"{port['containerPort']}/{port.get('protocol', 'tcp')}"
        actual = {int(value["HostPort"]) for value in (bindings.get(key) or [])}
        if int(port["hostPort"]) not in actual:
            raise SystemExit(1)
PY
    then
        rm -f "$inspect_file"
        printf '%-18s %s\n' "$app_id" '一致'
        return 0
    fi
    rm -f "$inspect_file"
    warn "$app_id 的服务容器、标签或端口与状态记录不一致"
    [[ "$repair" == "1" ]] || return 1
    require_root || return
    [[ -f "$app_dir/compose.yml" && -f "$app_dir/manifest.json" ]] || { fail "缺少重建文件：$app_id" 70; return; }
    docker_compose -f "$app_dir/compose.yml" -p "shdome-$app_id" up -d
    app_healthcheck "$app_dir/manifest.json" "$(state_ports_json "$app_id")" || return
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
    local manifest_file
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
    if [[ -n "${SHDOME_UPDATE_OLD_IMAGES_JSON:-}" ]]; then
        while IFS=$'\t' read -r image image_id; do
            if [[ -n "$image_id" ]]; then
                docker tag "$image_id" "$image" >/dev/null 2>&1 || true
            fi
        done < <(python3 - "$SHDOME_UPDATE_OLD_IMAGES_JSON" <<'PY'
import json, sys
for image, image_id in json.loads(sys.argv[1]).items():
    print(image, image_id, sep="\t")
PY
)
    fi
    if ! docker_compose -f "$app_dir/compose.yml" -p "shdome-$app_id" up -d; then
        warn "旧数据已经恢复，但旧容器启动失败；更新失败数据保留在 $failed_dir"
        return 1
    fi
    if [[ "$verify_health" == "1" ]]; then
        if ! app_healthcheck "$manifest_file" "$(state_ports_json "$app_id")"; then
            warn "旧数据已经恢复，但应用尚未通过健康检查；更新失败数据保留在 $failed_dir"
            return 1
        fi
    fi
    app_update_safe_remove_dir "$failed_dir" "$app_id" || return 1
    return 0
}

app_update_locked() {
    local app_id="$1" assume_yes="$2" force="$3" manifest_file app_dir ports_json services_json
    local service_name image container_name container_id image_digest old_image_id
    local -a old_image_values=()
    local current_version target_version rollback_archive rollback_ok=0
    require_root || return
    docker_runtime_ready || { fail "Docker 服务不可用" 69; return; }
    manifest_file="$(catalog_manifest_path "$app_id")"
    manifest_validate "$manifest_file" || return
    [[ "$(manifest_get "$manifest_file" id)" == "$app_id" ]] || { fail "Manifest ID 与文件名不一致" 65; return; }
    app_dir="$SHDOME_APPS_DIR/$app_id"
    ports_json="$(state_ports_json "$app_id")"
    current_version="$(state_get "$app_id" version)"
    target_version="$(manifest_get "$manifest_file" version)"
    while IFS=$'\t' read -r service_name image container_name container_id image_digest; do
        old_image_id="$(docker image inspect -f '{{.Id}}' "$image" 2>/dev/null || true)"
        old_image_values+=("$image" "$old_image_id")
    done < <(state_services_each "$app_id")
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
    SHDOME_UPDATE_OLD_IMAGES_JSON="$(python3 - "${old_image_values[@]}" <<'PY'
import json, sys
print(json.dumps(dict(zip(sys.argv[1::2], sys.argv[2::2])), separators=(",", ":")))
PY
)"
    trap app_update_abort_cleanup EXIT
    manifest_prepare_volumes "$manifest_file" "$app_dir" || return
    manifest_generate_env "$manifest_file" "$app_dir/.env" || return
    local bind_address="0.0.0.0"
    [[ "$(state_get "$app_id" accessMode)" == "domain_only" ]] && bind_address="127.0.0.1"
    compose_generate "$manifest_file" "$ports_json" "$app_dir/compose.yml.new" "$bind_address" || return
    mv -f "$app_dir/compose.yml.new" "$app_dir/compose.yml" || return
    if app_compose_pull_or_cached "$app_dir/compose.yml" "shdome-$app_id" "$manifest_file" && \
       docker_compose -f "$app_dir/compose.yml" -p "shdome-$app_id" up -d && \
       app_healthcheck "$manifest_file" "$ports_json"; then
        install -m 600 "$manifest_file" "$app_dir/manifest.json" || return
        services_json="$(app_runtime_services_json "$manifest_file")" || return
        state_write "$app_id" "$manifest_file" "$ports_json" "$services_json" || return
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
