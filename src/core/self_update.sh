#!/usr/bin/env bash

self_update_repository_from_metadata() {
    local metadata_file="$1"
    python3 - "$metadata_file" <<'PY'
import json, re, sys
with open(sys.argv[1], encoding="utf-8") as handle:
    value = json.load(handle).get("repository", "")
if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", value):
    raise SystemExit("invalid repository")
print(value)
PY
}

self_update_parse_release_api() {
    local api_file="$1" repository="$2"
    python3 - "$api_file" "$repository" <<'PY'
import json, re, sys
with open(sys.argv[1], encoding="utf-8") as handle:
    release = json.load(handle)
repository = sys.argv[2]
tag = release.get("tag_name", "")
if release.get("draft") or release.get("prerelease") or not re.fullmatch(r"v\d+\.\d+\.\d+", tag):
    raise SystemExit("latest release is not a stable semantic version")
archive_name = f"shdome-{tag}.tar.gz"
assets = {asset.get("name"): asset.get("browser_download_url") for asset in release.get("assets", [])}
archive = assets.get(archive_name, "")
checksum = assets.get(archive_name + ".sha256", "")
prefix = f"https://github.com/{repository}/releases/download/{tag}/"
if archive != prefix + archive_name or checksum != prefix + archive_name + ".sha256":
    raise SystemExit("release assets are incomplete or untrusted")
print("\t".join((tag, archive, checksum)))
PY
}

self_update_parse_checksum() {
    local checksum_file="$1" archive_name="$2"
    python3 - "$checksum_file" "$archive_name" <<'PY'
import re, sys
with open(sys.argv[1], encoding="utf-8") as handle:
    lines = handle.read().strip().splitlines()
matches = []
for line in lines:
    match = re.fullmatch(r"([a-fA-F0-9]{64})\s+\*?([^\s]+)", line.strip())
    if match and match.group(2) == sys.argv[2]:
        matches.append(match.group(1).lower())
if len(matches) != 1:
    raise SystemExit("matching checksum must occur exactly once")
print(matches[0])
PY
}

self_update_release_url_validate() {
    local url="$1" version="$2"
    if [[ "$url" =~ ^https://github\.com/([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)/releases/download/([^/]+)/([^/]+)$ ]]; then
        [[ "${BASH_REMATCH[2]}" == "$version" && "${BASH_REMATCH[3]}" == "shdome-$version.tar.gz" ]]
        return
    fi
    return 1
}

self_update_discover() {
    local metadata_file="$SHDOME_ROOT/install-meta.json" repository api_file checksum_file
    [[ -f "$metadata_file" ]] || { fail "缺少安装元数据，无法确定官方更新仓库" 66; return; }
    if ! repository="$(self_update_repository_from_metadata "$metadata_file")"; then
        fail "安装元数据中的 GitHub 仓库无效" 65
        return
    fi
    api_file="$(mktemp /tmp/shdome-release-api.XXXXXX)"
    checksum_file="$(mktemp /tmp/shdome-release-sha.XXXXXX)"
    if ! curl --proto '=https' --tlsv1.2 -fsSL --retry 3 \
        -H 'Accept: application/vnd.github+json' \
        -o "$api_file" "https://api.github.com/repos/$repository/releases/latest"; then
        rm -f "$api_file" "$checksum_file"
        fail "无法查询 GitHub 最新稳定版本" 69
        return
    fi
    local release_version release_url checksum_url release_row
    if ! release_row="$(self_update_parse_release_api "$api_file" "$repository")"; then
        rm -f "$api_file" "$checksum_file"
        fail "最新 Release 元数据无效或发布资产不完整" 65
        return
    fi
    IFS=$'\t' read -r release_version release_url checksum_url <<<"$release_row"
    rm -f "$api_file"
    [[ -n "$release_version" && -n "$release_url" && -n "$checksum_url" ]] || {
        rm -f "$checksum_file"
        fail "最新 Release 缺少发布包或校验文件" 65
        return
    }
    if ! curl --proto '=https' --tlsv1.2 -fsSL --retry 3 -o "$checksum_file" "$checksum_url"; then
        rm -f "$checksum_file"
        fail "无法下载发布包校验文件" 69
        return
    fi
    local release_sha
    if ! release_sha="$(self_update_parse_checksum "$checksum_file" "shdome-$release_version.tar.gz")"; then
        rm -f "$checksum_file"
        fail "发布包校验文件内容无效" 65
        return
    fi
    rm -f "$checksum_file"
    printf '%s\t%s\t%s\n' "$release_version" "$release_url" "$release_sha"
}

self_update_current_version() {
    local metadata_file="$SHDOME_ROOT/install-meta.json"
    if [[ -f "$metadata_file" ]]; then
        python3 - "$metadata_file" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as handle:
    print(json.load(handle).get("releaseVersion", ""))
PY
    else
        printf '%s\n' "$SHDOME_RELEASE_VERSION"
    fi
}

# 命令路由会动态传入更新参数。
# shellcheck disable=SC2120
self_update_command() {
    require_root || return
    local release_url="${SHDOME_UPDATE_URL:-}" release_sha="${SHDOME_UPDATE_SHA256:-}" release_version="${SHDOME_UPDATE_VERSION:-}"
    local assume_yes=0 check_only=0 force=0 current_version installer
    while (($#)); do
        case "$1" in
            --url) [[ $# -ge 2 ]] || { fail "--url 缺少值" 64; return; }; release_url="$2"; shift 2 ;;
            --sha256) [[ $# -ge 2 ]] || { fail "--sha256 缺少值" 64; return; }; release_sha="$2"; shift 2 ;;
            --version) [[ $# -ge 2 ]] || { fail "--version 缺少值" 64; return; }; release_version="$2"; shift 2 ;;
            --check) check_only=1; shift ;;
            --force) force=1; shift ;;
            --yes|-y) assume_yes=1; shift ;;
            *) fail "未知更新参数：$1" 64; return ;;
        esac
    done
    if [[ -z "$release_url" && -z "$release_sha" && -z "$release_version" ]]; then
        IFS=$'\t' read -r release_version release_url release_sha < <(self_update_discover)
    elif [[ -z "$release_url" || -z "$release_sha" || -z "$release_version" ]]; then
        fail "手动更新必须同时提供 --version、--url 和 --sha256" 64
        return
    fi
    [[ "$release_version" =~ ^v[0-9]+\.[0-9]+\.[0-9]+([.-][A-Za-z0-9._-]+)?$ ]] || { fail "目标版本格式错误" 65; return; }
    self_update_release_url_validate "$release_url" "$release_version" || { fail "目标发布地址与版本或文件名不匹配" 65; return; }
    [[ "$release_sha" =~ ^[a-fA-F0-9]{64}$ ]] || { fail "目标 SHA-256 格式错误" 65; return; }
    current_version="$(self_update_current_version)"
    printf '当前版本：%s\n最新版本：%s\n' "$current_version" "$release_version"
    if [[ "$current_version" == "$release_version" && "$force" != "1" ]]; then
        success "当前已经是最新稳定版本"
        return 0
    fi
    [[ "$check_only" != "1" ]] || return 0
    if [[ "$assume_yes" != "1" ]] && ! terminal_confirm "确认更新 SHDome 吗？"; then
        info "已取消更新"
        return 0
    fi
    installer="$SHDOME_SOURCE_DIR/../bootstrap/install.sh"
    [[ -f "$installer" ]] || { fail "当前安装缺少 bootstrap/install.sh" 70; return; }
    SHDOME_RELEASE_VERSION="$release_version" \
    SHDOME_RELEASE_URL="$release_url" \
    SHDOME_RELEASE_SHA256="$release_sha" \
    SHDOME_NO_LAUNCH=1 \
        bash "$installer"
    success "SHDome 已更新到 $release_version"
}

self_update_interactive() {
    self_update_command || true
}
