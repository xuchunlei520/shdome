#!/usr/bin/env bash

catalog_signature_verify() {
    local archive="$1" signature="$2" public_key="$3"
    openssl pkeyutl -verify -pubin -inkey "$public_key" -rawin -in "$archive" -sigfile "$signature" >/dev/null 2>&1 && return 0
    openssl dgst -sha256 -verify "$public_key" -signature "$signature" "$archive" >/dev/null 2>&1
}

catalog_archive_extract() {
    local archive="$1" output_dir="$2"
    python3 - "$archive" "$output_dir" <<'PY'
import os, pathlib, tarfile, sys
archive, output = sys.argv[1:]
os.makedirs(output, mode=0o750, exist_ok=True)
with tarfile.open(archive, "r:gz") as handle:
    members = handle.getmembers()
    files = [member for member in members if member.isfile()]
    if not files or len(files) > 512:
        raise SystemExit("目录压缩包必须包含 1-512 个 Manifest")
    if any(not member.isfile() and not member.isdir() for member in members):
        raise SystemExit("目录压缩包不能包含链接或特殊文件")
    if sum(member.size for member in files) > 5 * 1024 * 1024:
        raise SystemExit("目录解压后不能超过 5 MB")
    seen = set()
    for member in files:
        path = pathlib.PurePosixPath(member.name)
        if path.is_absolute() or ".." in path.parts or path.suffix != ".json":
            raise SystemExit(f"目录压缩包包含非法路径：{member.name}")
        name = path.name
        if name in seen:
            raise SystemExit(f"目录压缩包包含重复文件：{name}")
        seen.add(name)
        source = handle.extractfile(member)
        if source is None:
            raise SystemExit(f"无法读取：{member.name}")
        target = os.path.join(output, name)
        with open(target, "wb") as destination:
            destination.write(source.read())
        os.chmod(target, 0o640)
PY
}

catalog_release_validate() {
    local directory="$1" manifest_file app_id count=0
    declare -A seen=()
    while IFS= read -r manifest_file; do
        [[ -n "$manifest_file" ]] || continue
        manifest_validate "$manifest_file" || return
        app_id="$(manifest_get "$manifest_file" id)"
        [[ "$(basename "$manifest_file")" == "$app_id.json" ]] || { fail "官方 Manifest 文件名必须与 ID 一致：$manifest_file" 65; return; }
        [[ -z "${seen[$app_id]:-}" ]] || { fail "官方目录包含重复 ID：$app_id" 65; return; }
        seen["$app_id"]=1
        if [[ -f "$SHDOME_CUSTOM_CATALOG_DIR/$app_id.json" ]]; then
            fail "官方目录与自定义应用 ID 冲突：$app_id" 73
            return
        fi
        count=$((count + 1))
    done < <(find "$directory" -maxdepth 1 -type f -name '*.json' -print | LC_ALL=C sort)
    ((count > 0)) || { fail "官方目录中没有 Manifest" 65; return; }
}

catalog_symlink_replace() {
    local link_path="$1" target="$2"
    python3 - "$link_path" "$target" <<'PY'
import os, sys, uuid
path, target = sys.argv[1:]
temporary = path + ".new-" + uuid.uuid4().hex
os.symlink(target, temporary)
os.replace(temporary, path)
PY
}

catalog_refresh_metadata_write() {
    local version="$1" archive_url="$2" digest="$3" metadata="$SHDOME_CATALOG_ROOT/refresh.json" temp_file
    temp_file="$(mktemp "$SHDOME_CATALOG_ROOT/.refresh.XXXXXX")" || return
    python3 - "$temp_file" "$version" "$archive_url" "$digest" <<'PY'
import datetime, json, sys
output, version, url, digest = sys.argv[1:]
value = {
    "schema": 1,
    "version": version,
    "archiveUrl": url,
    "sha256": digest,
    "refreshedAt": datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0).isoformat(),
}
with open(output, "w", encoding="utf-8") as handle:
    json.dump(value, handle, ensure_ascii=False, indent=2)
    handle.write("\n")
PY
    chmod 640 "$temp_file"
    mv -f "$temp_file" "$metadata"
}

catalog_release_link_validate() {
    local target="$1"
    [[ "$target" =~ ^releases/[A-Za-z0-9][A-Za-z0-9._-]{0,80}$ ]] || return 1
    [[ -d "$SHDOME_OFFICIAL_CATALOG_ROOT/$target" ]]
}

catalog_release_activate() {
    local extracted="$1" version="$2" archive_url="$3" digest="$4" release_dir
    local current="$SHDOME_OFFICIAL_CATALOG_ROOT/current" previous="$SHDOME_OFFICIAL_CATALOG_ROOT/previous"
    local current_target="" previous_target=""
    [[ "$version" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,80}$ ]] || { fail "目录版本格式错误" 64; return; }
    release_dir="$SHDOME_OFFICIAL_RELEASES_DIR/$version"
    [[ ! -e "$release_dir" ]] || { fail "目录版本已经存在：$version" 73; return; }
    if [[ -L "$current" ]]; then
        current_target="$(readlink "$current")"
        catalog_release_link_validate "$current_target" || { fail "官方目录 current 指向无效位置" 73; return; }
    elif [[ -e "$current" ]]; then
        fail "官方目录 current 不是平台管理的符号链接" 73
        return
    fi
    if [[ -L "$previous" ]]; then
        previous_target="$(readlink "$previous")"
        catalog_release_link_validate "$previous_target" || { fail "官方目录 previous 指向无效位置" 73; return; }
    elif [[ -e "$previous" ]]; then
        fail "官方目录 previous 不是平台管理的符号链接" 73
        return
    fi
    mv "$extracted" "$release_dir" || return
    if [[ -n "$current_target" ]] && ! catalog_symlink_replace "$previous" "$current_target"; then
        rm -rf -- "$release_dir"
        return 1
    fi
    if ! catalog_symlink_replace "$current" "releases/$version"; then
        if [[ -n "$previous_target" ]]; then
            catalog_symlink_replace "$previous" "$previous_target" || true
        elif [[ -n "$current_target" ]]; then
            rm -f -- "$previous"
        fi
        rm -rf -- "$release_dir"
        return 1
    fi
    if ! catalog_refresh_metadata_write "$version" "$archive_url" "$digest"; then
        if [[ -n "$current_target" ]]; then
            catalog_symlink_replace "$current" "$current_target" || true
        else
            rm -f -- "$current"
        fi
        if [[ -n "$previous_target" ]]; then
            catalog_symlink_replace "$previous" "$previous_target" || true
        else
            rm -f -- "$previous"
        fi
        return 1
    fi
}

catalog_refresh() {
    local archive_url="${SHDOME_CATALOG_URL:-}" signature_url="${SHDOME_CATALOG_SIGNATURE_URL:-}"
    local public_key="${SHDOME_CATALOG_PUBLIC_KEY:-}" version="" quiet=0 temp_dir archive signature extracted
    local digest
    while (($#)); do
        case "$1" in
            --url) [[ $# -ge 2 ]] || { fail "--url 缺少值" 64; return; }; archive_url="$2"; shift 2 ;;
            --signature-url) [[ $# -ge 2 ]] || { fail "--signature-url 缺少值" 64; return; }; signature_url="$2"; shift 2 ;;
            --public-key) [[ $# -ge 2 ]] || { fail "--public-key 缺少值" 64; return; }; public_key="$2"; shift 2 ;;
            --version) [[ $# -ge 2 ]] || { fail "--version 缺少值" 64; return; }; version="$2"; shift 2 ;;
            --quiet) quiet=1; shift ;;
            *) fail "未知目录刷新参数：$1" 64; return ;;
        esac
    done
    require_root || return
    require_command curl || return
    require_command openssl || return
    require_command python3 || return
    [[ "$archive_url" == https://* && "$signature_url" == https://* ]] || { fail "官方目录地址必须使用 HTTPS" 64; return; }
    [[ -f "$public_key" && ! -L "$public_key" ]] || { fail "缺少可信官方目录公钥" 65; return; }
    [[ "$(stat -c %s "$public_key" 2>/dev/null || printf '65537')" -le 65536 ]] || { fail "官方目录公钥文件过大" 65; return; }
    temp_dir="$(mktemp -d "$SHDOME_CATALOG_ROOT/.catalog-refresh.XXXXXX")" || return
    archive="$temp_dir/catalog.tar.gz"
    signature="$temp_dir/catalog.tar.gz.sig"
    extracted="$temp_dir/manifests"
    if ! curl --proto '=https' --tlsv1.2 -fsSL --connect-timeout 8 --max-time 60 "$archive_url" -o "$archive" || \
       ! curl --proto '=https' --tlsv1.2 -fsSL --connect-timeout 8 --max-time 30 "$signature_url" -o "$signature"; then
        rm -rf -- "$temp_dir"
        [[ "$quiet" == "1" ]] || fail "下载官方应用目录失败" 69
        return 69
    fi
    if ! catalog_signature_verify "$archive" "$signature" "$public_key"; then
        rm -rf -- "$temp_dir"
        [[ "$quiet" == "1" ]] || fail "官方应用目录签名验证失败" 65
        return 65
    fi
    if ! catalog_archive_extract "$archive" "$extracted" || ! catalog_release_validate "$extracted"; then
        rm -rf -- "$temp_dir"
        [[ "$quiet" == "1" ]] || fail "官方应用目录内容无效" 65
        return 65
    fi
    digest="$(sha256sum "$archive" | awk '{print $1}')"
    version="${version:-$(date -u +%Y%m%d%H%M%S)-${digest:0:12}}"
    catalog_release_activate "$extracted" "$version" "$archive_url" "$digest" || { rm -rf -- "$temp_dir"; return; }
    rm -rf -- "$temp_dir"
    [[ "$quiet" == "1" ]] || success "官方应用目录已更新：$version"
}

catalog_rollback() {
    local current="$SHDOME_OFFICIAL_CATALOG_ROOT/current" previous="$SHDOME_OFFICIAL_CATALOG_ROOT/previous"
    local current_target previous_target
    require_root || return
    [[ -L "$current" && -L "$previous" ]] || { fail "没有可回滚的官方目录版本" 66; return; }
    current_target="$(readlink "$current")"
    previous_target="$(readlink "$previous")"
    catalog_release_link_validate "$current_target" || { fail "当前目录版本无效" 66; return; }
    catalog_release_link_validate "$previous_target" || { fail "上一目录版本不存在" 66; return; }
    catalog_symlink_replace "$current" "$previous_target" || return
    if ! catalog_symlink_replace "$previous" "$current_target"; then
        catalog_symlink_replace "$current" "$current_target" || true
        return 1
    fi
    success "已回滚官方应用目录：$(basename "$previous_target")"
}

catalog_status() {
    local official_dir current_version="内置目录" previous_version="无" metadata="$SHDOME_CATALOG_ROOT/refresh.json"
    official_dir="$(catalog_official_dir)"
    if [[ -L "$SHDOME_OFFICIAL_CATALOG_ROOT/current" ]]; then
        current_version="$(basename "$(readlink "$SHDOME_OFFICIAL_CATALOG_ROOT/current")")"
    fi
    if [[ -L "$SHDOME_OFFICIAL_CATALOG_ROOT/previous" ]]; then
        previous_version="$(basename "$(readlink "$SHDOME_OFFICIAL_CATALOG_ROOT/previous")")"
    fi
    printf '当前官方目录：%s\n目录位置：%s\n上一版本：%s\n自定义目录：%s\n' \
        "$current_version" "$official_dir" "$previous_version" "$SHDOME_CUSTOM_CATALOG_DIR"
    [[ ! -f "$metadata" ]] || printf '最近刷新：%s\n' "$(python3 - "$metadata" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as handle:
    value = json.load(handle)
print(value.get("refreshedAt", "未知"))
PY
)"
}

catalog_auto_refresh() {
    local marker="$SHDOME_CATALOG_ROOT/.last-refresh-attempt" now previous=0
    [[ -n "${SHDOME_CATALOG_URL:-}" && -n "${SHDOME_CATALOG_SIGNATURE_URL:-}" && -n "${SHDOME_CATALOG_PUBLIC_KEY:-}" ]] || return 0
    now="$(date +%s)"
    [[ ! -f "$marker" ]] || previous="$(stat -c %Y "$marker" 2>/dev/null || printf '0')"
    ((now - previous >= SHDOME_CATALOG_REFRESH_INTERVAL)) || return 0
    touch "$marker"
    catalog_refresh --quiet >/dev/null 2>&1 || true
}

catalog_command() {
    local action="${1:-status}"
    shift || true
    case "$action" in
        status) catalog_status ;;
        refresh) catalog_refresh "$@" ;;
        rollback) catalog_rollback ;;
        *) fail "用法：k app catalog [status|refresh|rollback]" 64 ;;
    esac
}
