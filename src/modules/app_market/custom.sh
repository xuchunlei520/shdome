#!/usr/bin/env bash

custom_manifest_path() {
    local app_id="$1"
    [[ "$app_id" =~ ^[a-z0-9][a-z0-9-]{1,62}$ ]] || return 1
    [[ -f "$SHDOME_CUSTOM_CATALOG_DIR/$app_id.json" ]] || return 1
    printf '%s\n' "$SHDOME_CUSTOM_CATALOG_DIR/$app_id.json"
}

custom_image_validate() {
    local image="$1"
    python3 - "$image" <<'PY'
import re, sys
image = sys.argv[1]
pattern = r"(?:[a-zA-Z0-9.-]+(?::[0-9]+)?/)*[a-zA-Z0-9][a-zA-Z0-9._-]*:[a-zA-Z0-9][a-zA-Z0-9._-]*"
if not re.fullmatch(pattern, image):
    raise SystemExit("镜像必须包含固定版本 tag，例如 vaultwarden/server:1.32.7")
if image.rsplit(":", 1)[1].lower() == "latest":
    raise SystemExit("自定义应用不能使用 latest，请指定固定版本")
PY
}

custom_id_from_image() {
    python3 - "$1" <<'PY'
import re, sys
repository = sys.argv[1].rsplit(":", 1)[0].rstrip("/").rsplit("/", 1)[-1]
value = re.sub(r"[^a-z0-9]+", "-", repository.lower()).strip("-")
if len(value) < 2:
    value = "app-" + value
print(value[:63].rstrip("-"))
PY
}

custom_name_from_image() {
    python3 - "$1" <<'PY'
import sys
repository = sys.argv[1].rsplit(":", 1)[0].rstrip("/").rsplit("/", 1)[-1]
print(repository.replace("-", " ").replace("_", " ").strip().title())
PY
}

custom_image_tcp_ports() {
    python3 - "$1" <<'PY'
import json, re, sys
with open(sys.argv[1], encoding="utf-8") as handle:
    values = json.load(handle)
item = values[0] if isinstance(values, list) else values
exposed = (item.get("Config") or {}).get("ExposedPorts") or {}
ports = sorted({int(match.group(1)) for value in exposed for match in [re.fullmatch(r"([0-9]+)/tcp", value)] if match})
for port in ports:
    if 1 <= port <= 65535:
        print(port)
PY
}

custom_generate_manifest() {
    local inspect_file="$1" output_file="$2" image="$3" app_id="$4" name="$5" arch="$6"
    local primary_port="$7" preferred_host_port="$8"
    python3 - "$inspect_file" "$output_file" "$image" "$app_id" "$name" "$arch" "$primary_port" "$preferred_host_port" <<'PY'
import json, re, sys
inspect_path, output, image, app_id, name, arch, primary_raw, host_raw = sys.argv[1:]
with open(inspect_path, encoding="utf-8") as handle:
    values = json.load(handle)
metadata = values[0] if isinstance(values, list) else values
config = metadata.get("Config") or {}
exposed = config.get("ExposedPorts") or {}
detected = sorted({
    int(match.group(1)) for value in exposed
    for match in [re.fullmatch(r"([0-9]+)/tcp", value)] if match
    if 1 <= int(match.group(1)) <= 65535
})
primary = int(primary_raw)
ports = [primary] + [port for port in detected if port != primary]

def preferred(port):
    if port == primary and host_raw:
        return int(host_raw)
    if port == 80:
        return 8080
    if port == 443:
        return 8443
    return port

port_items = []
for index, port in enumerate(ports):
    port_items.append({
        "name": "main" if index == 0 else f"port-{port}",
        "service": "app",
        "containerPort": port,
        "defaultHostPort": preferred(port),
        "protocol": "tcp",
        "primary": index == 0,
    })

volume_items = []
targets = sorted((config.get("Volumes") or {}).keys())
for index, target in enumerate(targets, 1):
    if not re.fullmatch(r"/[a-zA-Z0-9_./-]+", target) or ".." in target.split("/"):
        continue
    leaf = re.sub(r"[^a-zA-Z0-9._-]+", "-", target.rstrip("/").rsplit("/", 1)[-1]).strip("-") or "data"
    source = leaf if index == 1 else f"{leaf}-{index}"
    volume_items.append({"source": source, "target": target, "type": "directory"})

version = image.rsplit(":", 1)[1]
manifest = {
    "schema": 2,
    "id": app_id,
    "name": name,
    "version": version,
    "description": f"用户从镜像 {image} 创建的自定义应用",
    "category": "自定义",
    "architectures": [arch],
    "services": {"app": {
        "image": image,
        "containerName": f"shdome-{app_id}",
        "volumes": volume_items,
    }},
    "resources": {"diskGB": 1, "memoryMB": 256},
    "ports": port_items,
    "backup": {"strategy": "cold-filesystem"},
    "healthcheck": {"type": "tcp", "service": "app", "port": "main", "timeoutSeconds": 120},
    "routing": {"enabled": True, "service": "app", "port": "main", "scheme": "tcp", "defaultAccessMode": "direct"},
}
with open(output, "w", encoding="utf-8") as handle:
    json.dump(manifest, handle, ensure_ascii=False, indent=2)
    handle.write("\n")
PY
}

custom_manifest_install() {
    local source_file="$1" assume_yes="${2:-0}" replace="${3:-0}" app_id destination temp_file
    [[ -f "$source_file" && ! -L "$source_file" ]] || { fail "只能导入本地普通 JSON 文件" 65; return; }
    [[ "$(stat -c %s "$source_file" 2>/dev/null || printf '1048577')" -le 1048576 ]] || { fail "Manifest 不能超过 1 MB" 65; return; }
    manifest_validate "$source_file" || return
    app_id="$(manifest_get "$source_file" id)"
    if catalog_official_manifest_path "$app_id" >/dev/null 2>&1; then
        fail "自定义应用不能覆盖官方应用：$app_id" 73
        return
    fi
    destination="$SHDOME_CUSTOM_CATALOG_DIR/$app_id.json"
    if [[ -e "$destination" && "$replace" != "1" ]]; then
        fail "自定义应用已存在：$app_id；更新定义请添加 --replace"
        return 73
    fi
    if state_exists "$app_id" && [[ ! -e "$destination" ]]; then
        fail "已存在同 ID 的非自定义应用状态：$app_id"
        return 73
    fi
    if [[ "$assume_yes" != "1" ]] && ! terminal_confirm "确认保存自定义应用 $app_id 吗？"; then
        info "已取消导入"
        return 0
    fi
    mkdir -p "$SHDOME_CUSTOM_CATALOG_DIR"
    temp_file="$(mktemp "$SHDOME_CUSTOM_CATALOG_DIR/.manifest.XXXXXX")" || return
    if ! install -m 640 "$source_file" "$temp_file"; then
        rm -f -- "$temp_file"
        return 1
    fi
    mv -f "$temp_file" "$destination"
    success "已保存自定义应用：$app_id"
}

custom_add() {
    local image="${1:-}" name="" app_id="" container_port="" host_port="" assume_yes=0 install_app=1
    local inspect_file manifest_file arch detected_port replace=0 plan_action confirm_prompt
    if [[ "$image" == --* ]]; then
        image=""
    elif [[ -n "$image" ]]; then
        shift
    fi
    while (($#)); do
        case "$1" in
            --name) [[ $# -ge 2 ]] || { fail "--name 缺少值" 64; return; }; name="$2"; shift 2 ;;
            --id) [[ $# -ge 2 ]] || { fail "--id 缺少值" 64; return; }; app_id="$2"; shift 2 ;;
            --container-port) [[ $# -ge 2 ]] || { fail "--container-port 缺少值" 64; return; }; container_port="$2"; shift 2 ;;
            --host-port) [[ $# -ge 2 ]] || { fail "--host-port 缺少值" 64; return; }; host_port="$2"; shift 2 ;;
            --no-install) install_app=0; shift ;;
            --yes|-y) assume_yes=1; shift ;;
            *) fail "未知自定义应用参数：$1" 64; return ;;
        esac
    done
    require_root || return
    require_linux || return
    require_command python3 || return
    if [[ -z "$image" ]]; then
        terminal_read image "请输入固定版本 Docker 镜像: " "" || return
    fi
    custom_image_validate "$image" || return
    app_id="${app_id:-$(custom_id_from_image "$image")}"
    name="${name:-$(custom_name_from_image "$image")}"
    [[ "$app_id" =~ ^[a-z0-9][a-z0-9-]{1,62}$ ]] || { fail "自定义应用 ID 格式错误：$app_id" 64; return; }
    [[ -n "$name" ]] || { fail "应用名称不能为空" 64; return; }
    if custom_manifest_path "$app_id" >/dev/null 2>&1; then
        replace=1
    elif catalog_manifest_path "$app_id" >/dev/null 2>&1; then
        fail "应用 ID 已存在：$app_id；可使用 --id 指定其他 ID" 73
        return
    elif state_exists "$app_id"; then
        fail "已存在同 ID 的应用状态：$app_id" 73
        return
    fi
    if [[ -n "$container_port" ]] && ! port_validate "$container_port"; then
        fail "容器端口必须是 1-65535 的整数" 64
        return
    fi
    if [[ -n "$host_port" ]] && ! port_validate "$host_port"; then
        fail "宿主机端口必须是 1-65535 的整数" 64
        return
    fi
    if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
        fail "读取镜像需要可用的 Docker 服务，请先执行 k env install" 69
        return
    fi
    inspect_file="$(mktemp "$SHDOME_CATALOG_ROOT/.image-inspect.XXXXXX")" || return
    manifest_file="$(mktemp "$SHDOME_CATALOG_ROOT/.custom-manifest.XXXXXX")" || { rm -f -- "$inspect_file"; return; }
    if ! image_source_pull "$image"; then
        rm -f -- "$inspect_file" "$manifest_file"
        return
    fi
    if ! docker image inspect "$image" >"$inspect_file"; then
        rm -f -- "$inspect_file" "$manifest_file"
        fail "无法拉取或读取镜像：$image" 69
        return
    fi
    if [[ -z "$container_port" ]]; then
        detected_port="$(custom_image_tcp_ports "$inspect_file" | head -n 1)"
        if [[ -n "$detected_port" ]]; then
            container_port="$detected_port"
        elif [[ "$assume_yes" == "1" ]] || ! terminal_is_interactive; then
            rm -f -- "$inspect_file" "$manifest_file"
            fail "镜像没有声明 TCP 端口，请添加 --container-port" 64
            return
        else
            terminal_read container_port "镜像没有声明服务端口，请输入容器端口: " "" || { rm -f -- "$inspect_file" "$manifest_file"; return; }
            port_validate "$container_port" || { rm -f -- "$inspect_file" "$manifest_file"; fail "容器端口必须是 1-65535 的整数" 64; return; }
        fi
    fi
    arch="$(normalized_architecture)"
    [[ "$arch" != "unsupported" ]] || { rm -f -- "$inspect_file" "$manifest_file"; fail "不支持的 CPU 架构" 69; return; }
    custom_generate_manifest "$inspect_file" "$manifest_file" "$image" "$app_id" "$name" "$arch" "$container_port" "$host_port" || { rm -f -- "$inspect_file" "$manifest_file"; return; }
    rm -f -- "$inspect_file"
    manifest_validate "$manifest_file" || { rm -f -- "$manifest_file"; return; }
    plan_action="创建"
    [[ "$replace" != "1" ]] || plan_action="更新"
    printf '\n自定义应用%s计划\n%s\n' "$plan_action" '--------------------------------'
    printf '应用：       %s (%s)\n镜像：       %s\n容器端口：   %s\n' "$name" "$app_id" "$image" "$container_port"
    printf '保存位置：   %s/%s.json\n%s\n' "$SHDOME_CUSTOM_CATALOG_DIR" "$app_id" '--------------------------------'
    confirm_prompt="确认${plan_action}吗？"
    [[ "$install_app" != "1" ]] || confirm_prompt="确认${plan_action}并$([[ "$replace" == "1" ]] && printf '更新' || printf '安装')吗？"
    if [[ "$assume_yes" != "1" ]] && ! terminal_confirm "$confirm_prompt"; then
        rm -f -- "$manifest_file"
        info "已取消创建"
        return 0
    fi
    custom_manifest_install "$manifest_file" 1 "$replace" || { rm -f -- "$manifest_file"; return; }
    rm -f -- "$manifest_file"
    if [[ "$install_app" == "1" ]]; then
        if state_exists "$app_id"; then
            app_update "$app_id" --yes
        else
            app_install "$app_id" --yes
        fi
    fi
}

custom_import() {
    local source_file="${1:-}" assume_yes=0 replace=0
    shift || true
    while (($#)); do
        case "$1" in
            --yes|-y) assume_yes=1; shift ;;
            --replace) replace=1; shift ;;
            *) fail "未知导入参数：$1" 64; return ;;
        esac
    done
    [[ -n "$source_file" ]] || { fail "用法：k app custom import <manifest.json>" 64; return; }
    require_root || return
    custom_manifest_install "$source_file" "$assume_yes" "$replace"
}

custom_validate() {
    local target="${1:-}" manifest_file
    [[ -n "$target" ]] || { fail "用法：k app custom validate <id|manifest.json>" 64; return; }
    if [[ -f "$target" ]]; then
        manifest_file="$target"
    else
        manifest_file="$(custom_manifest_path "$target")" || { fail "找不到自定义应用：$target" 66; return; }
    fi
    manifest_validate "$manifest_file" || return
    success "Manifest 校验通过：$(manifest_get "$manifest_file" id)"
}

custom_list() {
    local manifest_file found=0 routing_service
    printf '%-20s %-24s %s\n' '应用 ID' '名称' '镜像'
    while IFS= read -r manifest_file; do
        [[ -n "$manifest_file" ]] || continue
        manifest_validate "$manifest_file" >/dev/null 2>&1 || continue
        routing_service="$(manifest_get "$manifest_file" routing.service)"
        printf '%-20s %-24s %s\n' "$(manifest_get "$manifest_file" id)" "$(manifest_get "$manifest_file" name)" "$(manifest_get "$manifest_file" "services.$routing_service.image")"
        found=1
    done < <(find "$SHDOME_CUSTOM_CATALOG_DIR" -maxdepth 1 -type f -name '*.json' -print 2>/dev/null | LC_ALL=C sort)
    [[ "$found" == "1" ]] || info "当前没有自定义应用"
}

custom_export() {
    local app_id="${1:-}" output="${2:-}" manifest_file
    manifest_file="$(custom_manifest_path "$app_id")" || { fail "找不到自定义应用：$app_id" 66; return; }
    if [[ -z "$output" ]]; then
        cat "$manifest_file"
        return
    fi
    [[ ! -e "$output" ]] || { fail "导出目标已存在：$output" 73; return; }
    install -m 640 "$manifest_file" "$output" || return
    success "已导出到：$output"
}

custom_delete() {
    local app_id="${1:-}" assume_yes=0 manifest_file
    shift || true
    while (($#)); do
        case "$1" in
            --yes|-y) assume_yes=1; shift ;;
            *) fail "未知删除参数：$1" 64; return ;;
        esac
    done
    require_root || return
    manifest_file="$(custom_manifest_path "$app_id")" || { fail "找不到自定义应用：$app_id" 66; return; }
    state_exists "$app_id" && { fail "应用仍已安装，请先执行 k app remove $app_id" 73; return; }
    if [[ "$assume_yes" != "1" ]] && ! terminal_confirm "确认删除自定义应用定义 $app_id 吗？"; then
        info "已取消删除"
        return 0
    fi
    rm -f -- "$manifest_file"
    success "已删除自定义应用定义：$app_id"
}

custom_command() {
    local action="${1:-}"
    shift || true
    case "$action" in
        add|create) custom_add "$@" ;;
        import) custom_import "$@" ;;
        validate) custom_validate "$@" ;;
        list) custom_list ;;
        export) custom_export "$@" ;;
        delete|remove) custom_delete "$@" ;;
        *) fail "用法：k app custom [add|import|validate|list|export|delete]" 64 ;;
    esac
}
