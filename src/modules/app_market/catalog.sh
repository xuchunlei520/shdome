#!/usr/bin/env bash

catalog_manifest_path() {
    local app_id="$1"
    [[ "$app_id" =~ ^[a-z0-9][a-z0-9-]{1,62}$ ]] || return 1
    local manifest_file="$SHDOME_CATALOG_DIR/$app_id.json"
    [[ -f "$manifest_file" ]] || return 1
    printf '%s\n' "$manifest_file"
}

catalog_each_manifest() {
    find "$SHDOME_CATALOG_DIR" -maxdepth 1 -type f -name '*.json' -print | LC_ALL=C sort
}

catalog_resolve_selector() {
    local selector="${1:-}" manifest_file app_id app_name index=0 match=""
    [[ -n "$selector" ]] || return 1
    while IFS= read -r manifest_file; do
        [[ -n "$manifest_file" ]] || continue
        manifest_validate "$manifest_file" >/dev/null 2>&1 || continue
        index=$((index + 1))
        app_id="$(manifest_get "$manifest_file" id)"
        app_name="$(manifest_get "$manifest_file" name)"
        if [[ "$selector" == "$index" || "${selector,,}" == "${app_name,,}" || "${selector,,}" == "${app_id,,}" ]]; then
            [[ -z "$match" || "$match" == "$app_id" ]] || return 2
            match="$app_id"
        fi
    done < <(catalog_each_manifest)
    [[ -n "$match" ]] || return 1
    printf '%s\n' "$match"
}

app_runtime_status() {
    local app_id="$1" container_name manifest_file installed_version catalog_version
    if ! state_exists "$app_id"; then
        printf '未安装'
        return
    fi
    manifest_file="$(catalog_manifest_path "$app_id" 2>/dev/null || true)"
    if [[ -n "$manifest_file" ]]; then
        installed_version="$(state_get "$app_id" version 2>/dev/null || true)"
        catalog_version="$(manifest_get "$manifest_file" version 2>/dev/null || true)"
        if [[ -n "$installed_version" && -n "$catalog_version" && "$installed_version" != "$catalog_version" ]]; then
            printf '可更新'
            return
        fi
    fi
    container_name="$(state_get "$app_id" containerName 2>/dev/null || true)"
    if command -v docker >/dev/null 2>&1 && [[ -n "$container_name" ]]; then
        case "$(docker inspect -f '{{.State.Status}}' "$container_name" 2>/dev/null || true)" in
            running) printf '运行中' ;;
            exited|dead) printf '已停止' ;;
            '') printf '状态缺失' ;;
            *) printf '异常' ;;
        esac
    else
        printf '已登记'
    fi
}

app_list() {
    state_storage_require_readable || return
    if [[ "${1:-}" == "--json" ]]; then
        app_list_json
        return
    fi
    local manifest_file app_id name version status description found=0 index=0
    printf '%-6s %-20s %-14s %-10s %s\n' '序号' '名称' '版本' '状态' '说明'
    printf '%s\n' '------------------------------------------------------------------------------------------------'
    while IFS= read -r manifest_file; do
        [[ -n "$manifest_file" ]] || continue
        manifest_validate "$manifest_file" || continue
        app_id="$(manifest_get "$manifest_file" id)"
        name="$(manifest_get "$manifest_file" name)"
        version="$(manifest_get "$manifest_file" version)"
        status="$(app_runtime_status "$app_id")"
        description="$(manifest_get "$manifest_file" description)"
        index=$((index + 1))
        printf '%-6s %-20s %-14s %-10s %s\n' "$index" "$name" "$version" "$status" "$description"
        found=1
    done < <(catalog_each_manifest)
    [[ "$found" == "1" ]] || warn "应用目录为空：$SHDOME_CATALOG_DIR"
}

app_list_json() {
    python3 - "$SHDOME_CATALOG_DIR" "$SHDOME_APPS_DIR" <<'PY'
import glob, json, os, shutil, subprocess, sys
catalog_dir, apps_dir = sys.argv[1:]
result = []
for path in sorted(glob.glob(os.path.join(catalog_dir, "*.json"))):
    with open(path, encoding="utf-8") as handle:
        manifest = json.load(handle)
    state_path = os.path.join(apps_dir, manifest["id"], "state.json")
    state = None
    if os.path.isfile(state_path):
        try:
            with open(state_path, encoding="utf-8") as handle:
                state = json.load(handle)
        except (OSError, json.JSONDecodeError):
            state = None
    runtime_status = "not_installed"
    if state:
        runtime_status = "registered"
        if state.get("version") != manifest.get("version"):
            runtime_status = "update_available"
        elif shutil.which("docker"):
            completed = subprocess.run(
                ["docker", "inspect", "-f", "{{.State.Status}}", state.get("containerName", "")],
                text=True, capture_output=True,
            )
            runtime_status = completed.stdout.strip() if completed.returncode == 0 else "missing"
    ports = manifest.get("ports")
    if ports is None:
        ports = [{
            "name": "http",
            "containerPort": manifest["services"]["app"]["containerPort"],
            "defaultHostPort": manifest["routing"]["defaultHostPort"],
            "protocol": "tcp",
            "primary": True,
        }]
    result.append({
        "id": manifest["id"], "name": manifest["name"], "version": manifest["version"],
        "category": manifest["category"], "description": manifest["description"],
        "architectures": manifest["architectures"], "ports": ports, "status": runtime_status,
    })
print(json.dumps(result, ensure_ascii=False, separators=(",", ":")))
PY
}

app_search() {
    local query="${1:-}" manifest_file searchable
    [[ -n "$query" ]] || { fail "用法：k app search <关键词>" 64; return; }
    while IFS= read -r manifest_file; do
        searchable="$(manifest_get "$manifest_file" id) $(manifest_get "$manifest_file" name) $(manifest_get "$manifest_file" description)"
        if [[ "${searchable,,}" == *"${query,,}"* ]]; then
            printf '%s\t%s\t%s\n' "$(manifest_get "$manifest_file" id)" "$(manifest_get "$manifest_file" name)" "$(manifest_get "$manifest_file" description)"
        fi
    done < <(catalog_each_manifest)
}

app_installed() {
    local state_file app_id found=0
    state_storage_require_readable || return
    while IFS= read -r state_file; do
        [[ -n "$state_file" ]] || continue
        app_id="$(basename "$(dirname "$state_file")")"
        printf '%-18s %s\n' "$app_id" "$(app_runtime_status "$app_id")"
        found=1
    done < <(find "$SHDOME_APPS_DIR" -mindepth 2 -maxdepth 2 -type f -name state.json -print 2>/dev/null | LC_ALL=C sort)
    [[ "$found" == "1" ]] || info "当前没有已安装应用"
}

app_details() {
    local app_id="$1" manifest_file ports_json port_name host_port container_port protocol primary suffix
    state_storage_require_readable || return
    manifest_file="$(catalog_manifest_path "$app_id")" || { fail "应用目录中不存在：$app_id" 66; return; }
    manifest_validate "$manifest_file" || return
    printf '应用：%s\n' "$(manifest_get "$manifest_file" name)"
    printf '版本：%s\n' "$(manifest_get "$manifest_file" version)"
    printf '分类：%s\n' "$(manifest_get "$manifest_file" category)"
    printf '说明：%s\n' "$(manifest_get "$manifest_file" description)"
    printf '镜像：%s\n' "$(manifest_get "$manifest_file" services.app.image)"
    printf '架构：%s\n' "$(manifest_get "$manifest_file" architectures)"
    printf '资源：磁盘 %s GB，内存 %s MB\n' "$(manifest_get "$manifest_file" resources.diskGB)" "$(manifest_get "$manifest_file" resources.memoryMB)"
    ports_json="$(manifest_ports_json "$manifest_file")"
    while IFS=$'\t' read -r port_name host_port container_port protocol primary; do
        suffix=""
        [[ "$primary" != "true" ]] || suffix="（主服务）"
        printf '建议端口：%-12s %s/%s → %s/%s%s\n' "$port_name" "$host_port" "$protocol" "$container_port" "$protocol" "$suffix"
    done < <(ports_json_each "$ports_json")
    printf '状态：%s\n' "$(app_runtime_status "$app_id")"
}

app_categories() {
    python3 - "$SHDOME_CATALOG_DIR" <<'PY'
import collections, glob, json, os, sys
counts = collections.Counter()
for path in glob.glob(os.path.join(sys.argv[1], "*.json")):
    with open(path, encoding="utf-8") as handle:
        counts[json.load(handle)["category"]] += 1
for category in sorted(counts):
    print(f"{category}\t{counts[category]}")
PY
}

app_category() {
    local category="${1:-}" manifest_file found=0
    state_storage_require_readable || return
    [[ -n "$category" ]] || { fail "用法：k app category <分类>" 64; return; }
    while IFS= read -r manifest_file; do
        if [[ "$(manifest_get "$manifest_file" category)" == "$category" ]]; then
            printf '%s\t%s\t%s\n' "$(manifest_get "$manifest_file" id)" "$(manifest_get "$manifest_file" name)" "$(app_runtime_status "$(manifest_get "$manifest_file" id)")"
            found=1
        fi
    done < <(catalog_each_manifest)
    [[ "$found" == "1" ]] || fail "分类不存在或暂无应用：$category" 66
}
