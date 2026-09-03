#!/usr/bin/env bash

catalog_official_dir() {
    local current="$SHDOME_OFFICIAL_CATALOG_ROOT/current" resolved=""
    if [[ -L "$current" ]]; then
        resolved="$(readlink -f "$current" 2>/dev/null || true)"
    fi
    if [[ -n "$resolved" && "$resolved" == "$SHDOME_OFFICIAL_RELEASES_DIR"/* ]] && \
       find "$resolved" -maxdepth 1 -type f -name '*.json' -print -quit 2>/dev/null | grep -q .; then
        printf '%s\n' "$resolved"
    else
        printf '%s\n' "$SHDOME_CATALOG_DIR"
    fi
}

catalog_manifest_path() {
    local app_id="$1" official_dir manifest_file
    [[ "$app_id" =~ ^[a-z0-9][a-z0-9-]{1,62}$ ]] || return 1
    official_dir="$(catalog_official_dir)"
    manifest_file="$official_dir/$app_id.json"
    if [[ -f "$manifest_file" ]]; then
        printf '%s\n' "$manifest_file"
        return
    fi
    manifest_file="$SHDOME_CUSTOM_CATALOG_DIR/$app_id.json"
    [[ -f "$manifest_file" ]] || return 1
    printf '%s\n' "$manifest_file"
}

catalog_manifest_source() {
    local manifest_file="$1"
    case "$manifest_file" in
        "$SHDOME_CUSTOM_CATALOG_DIR"/*) printf '我的\n' ;;
        *) printf '官方\n' ;;
    esac
}

catalog_official_manifest_path() {
    local app_id="$1" manifest_file
    manifest_file="$(catalog_official_dir)/$app_id.json"
    [[ -f "$manifest_file" ]] || return 1
    printf '%s\n' "$manifest_file"
}

catalog_each_manifest() {
    local official_dir manifest_file app_id
    declare -A seen=()
    official_dir="$(catalog_official_dir)"
    while IFS= read -r manifest_file; do
        [[ -n "$manifest_file" ]] || continue
        app_id="$(basename "$manifest_file" .json)"
        seen["$app_id"]=1
        printf '%s\n' "$manifest_file"
    done < <(find "$official_dir" -maxdepth 1 -type f -name '*.json' -print 2>/dev/null | LC_ALL=C sort)
    while IFS= read -r manifest_file; do
        [[ -n "$manifest_file" ]] || continue
        app_id="$(basename "$manifest_file" .json)"
        if [[ -n "${seen[$app_id]:-}" ]]; then
            warn "自定义应用 ID 与官方应用冲突，已忽略：$app_id"
            continue
        fi
        printf '%s\n' "$manifest_file"
    done < <(find "$SHDOME_CUSTOM_CATALOG_DIR" -maxdepth 1 -type f -name '*.json' -print 2>/dev/null | LC_ALL=C sort)
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
        if [[ "$selector" == "$index" || "${selector,,}" == "${app_name,,}" ]]; then
            [[ -z "$match" || "$match" == "$app_id" ]] || return 2
            match="$app_id"
        fi
    done < <(catalog_each_manifest)
    [[ -n "$match" ]] || return 1
    printf '%s\n' "$match"
}

app_runtime_status() {
    local app_id="$1" service_name image container_name container_id image_digest status
    local manifest_file installed_version catalog_version running=0 stopped=0 missing=0
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
    if ! command -v docker >/dev/null 2>&1; then
        printf '已登记'
        return
    fi
    while IFS=$'\t' read -r service_name image container_name container_id image_digest; do
        status="$(docker inspect -f '{{.State.Status}}' "$container_name" 2>/dev/null || true)"
        case "$status" in
            running) running=$((running + 1)) ;;
            exited|dead) stopped=$((stopped + 1)) ;;
            '') missing=$((missing + 1)) ;;
            *) printf '异常'; return ;;
        esac
    done < <(state_services_each "$app_id")
    if ((missing > 0)); then printf '状态缺失'
    elif ((stopped > 0 && running == 0)); then printf '已停止'
    elif ((stopped > 0)); then printf '部分运行'
    else printf '运行中'
    fi
}

app_list() {
    state_storage_require_readable || return
    if [[ "${1:-}" == "--json" ]]; then
        app_list_json
        return
    fi
    local manifest_file app_id name version status source description found=0 index=0 row_index
    local -a indexes=() names=() versions=() statuses=() sources=() descriptions=()
    while IFS= read -r manifest_file; do
        [[ -n "$manifest_file" ]] || continue
        manifest_validate "$manifest_file" || continue
        app_id="$(manifest_get "$manifest_file" id)"
        name="$(manifest_get "$manifest_file" name)"
        version="$(manifest_get "$manifest_file" version)"
        status="$(app_runtime_status "$app_id")"
        source="$(catalog_manifest_source "$manifest_file")"
        description="$(manifest_get "$manifest_file" description)"
        index=$((index + 1))
        indexes+=("$index")
        names+=("$name")
        versions+=("$version")
        statuses+=("$status")
        sources+=("$source")
        descriptions+=("$description")
        found=1
    done < <(catalog_each_manifest)
    {
        printf '%s\0' '序号' '名称' '版本' '状态' '来源' '说明'
        for ((row_index = 0; row_index < ${#indexes[@]}; row_index++)); do
            printf '%s\0' \
                "${indexes[$row_index]}" "${names[$row_index]}" "${versions[$row_index]}" \
                "${statuses[$row_index]}" "${sources[$row_index]}" "${descriptions[$row_index]}"
        done
    } | terminal_render_table 6
    [[ "$found" == "1" ]] || warn "应用目录为空"
}

app_list_json() {
    local official_dir
    official_dir="$(catalog_official_dir)"
    python3 - "$official_dir" "$SHDOME_CUSTOM_CATALOG_DIR" "$SHDOME_APPS_DIR" <<'PY'
import glob, json, os, shutil, subprocess, sys
official_dir, custom_dir, apps_dir = sys.argv[1:]
result = []
paths = [(path, "official") for path in sorted(glob.glob(os.path.join(official_dir, "*.json")))]
official_ids = {os.path.basename(path) for path, _ in paths}
paths.extend(
    (path, "custom") for path in sorted(glob.glob(os.path.join(custom_dir, "*.json")))
    if os.path.basename(path) not in official_ids
)
for path, source in paths:
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
            containers = [service["containerName"] for service in state.get("services", {}).values()]
            completed = subprocess.run(
                ["docker", "inspect", "-f", "{{.State.Status}}", *containers],
                text=True, capture_output=True,
            )
            statuses = completed.stdout.splitlines()
            if completed.returncode != 0 or len(statuses) != len(containers):
                runtime_status = "missing"
            elif all(status == "running" for status in statuses):
                runtime_status = "running"
            elif all(status in {"exited", "dead"} for status in statuses):
                runtime_status = "exited"
            else:
                runtime_status = "partial"
    ports = manifest["ports"]
    result.append({
        "id": manifest["id"], "name": manifest["name"], "version": manifest["version"],
        "category": manifest["category"], "description": manifest["description"],
        "architectures": manifest["architectures"], "ports": ports, "status": runtime_status,
        "source": source,
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
    local app_id="$1" manifest_file ports_json port_name host_port container_port protocol primary service_name suffix image container_name
    state_storage_require_readable || return
    manifest_file="$(catalog_manifest_path "$app_id")" || { fail "应用目录中不存在：$app_id" 66; return; }
    manifest_validate "$manifest_file" || return
    printf '应用：%s\n' "$(manifest_get "$manifest_file" name)"
    printf '版本：%s\n' "$(manifest_get "$manifest_file" version)"
    printf '分类：%s\n' "$(manifest_get "$manifest_file" category)"
    printf '说明：%s\n' "$(manifest_get "$manifest_file" description)"
    printf '来源：%s\n' "$(catalog_manifest_source "$manifest_file")"
    while IFS=$'\t' read -r service_name image container_name; do
        printf '服务：%-12s %s（%s）\n' "$service_name" "$image" "$container_name"
    done < <(manifest_services_each "$manifest_file")
    printf '架构：%s\n' "$(manifest_get "$manifest_file" architectures)"
    printf '资源：磁盘 %s GB，内存 %s MB\n' "$(manifest_get "$manifest_file" resources.diskGB)" "$(manifest_get "$manifest_file" resources.memoryMB)"
    ports_json="$(manifest_ports_json "$manifest_file")"
    while IFS=$'\t' read -r port_name host_port container_port protocol primary service_name; do
        suffix=""
        [[ "$primary" != "true" ]] || suffix="（主服务）"
        printf '建议端口：%-12s %s/%s → %s:%s/%s%s\n' "$port_name" "$host_port" "$protocol" "$service_name" "$container_port" "$protocol" "$suffix"
    done < <(ports_json_each "$ports_json")
    printf '状态：%s\n' "$(app_runtime_status "$app_id")"
}

app_categories() {
    local manifest_file category
    declare -A counts=()
    while IFS= read -r manifest_file; do
        [[ -n "$manifest_file" ]] || continue
        manifest_validate "$manifest_file" >/dev/null 2>&1 || continue
        category="$(manifest_get "$manifest_file" category)"
        counts["$category"]=$(( ${counts["$category"]:-0} + 1 ))
    done < <(catalog_each_manifest)
    for category in "${!counts[@]}"; do
        printf '%s\t%s\n' "$category" "${counts[$category]}"
    done | LC_ALL=C sort
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
