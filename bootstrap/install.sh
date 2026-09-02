#!/usr/bin/env bash
set -Eeuo pipefail

INSTALL_ROOT="${SHDOME_INSTALL_ROOT:-/opt/shdome}"
RELEASE_VERSION="${SHDOME_RELEASE_VERSION:-}"
RELEASE_URL="${SHDOME_RELEASE_URL:-}"
RELEASE_SHA256="${SHDOME_RELEASE_SHA256:-}"
NO_LAUNCH="${SHDOME_NO_LAUNCH:-0}"
INSTALL_OWNER_UID="${SHDOME_INSTALL_OWNER_UID:-0}"
TEMP_DIR=""

bootstrap_fail() {
    printf '[SHDome 安装失败] %s\n' "$1" >&2
    exit "${2:-1}"
}

bootstrap_cleanup() {
    [[ -z "$TEMP_DIR" || ! -d "$TEMP_DIR" ]] || rm -rf -- "$TEMP_DIR"
}

bootstrap_release_url_validate() {
    local url="$1" version="$2"
    if [[ "$url" =~ ^https://github\.com/([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)/releases/download/([^/]+)/([^/]+)$ ]]; then
        [[ "${BASH_REMATCH[2]}" == "$version" && "${BASH_REMATCH[3]}" == "shdome-$version.tar.gz" ]]
        return
    fi
    return 1
}

bootstrap_assert_secure_directory() {
    local directory="$1" owner permissions
    [[ -d "$directory" && ! -L "$directory" ]] || bootstrap_fail "安装目录不是可信的普通目录：$directory" 73
    owner="$(stat -c '%u' "$directory")"
    [[ "$owner" == "$INSTALL_OWNER_UID" ]] || bootstrap_fail "安装目录所有者异常：$directory" 73
    permissions="$(stat -c '%a' "$directory")"
    [[ "$permissions" =~ ^[0-7]{3,4}$ ]] || bootstrap_fail "无法识别安装目录权限：$directory" 73
    ((8#$permissions & 022)) && bootstrap_fail "安装目录不能允许组或其他用户写入：$directory" 73
    return 0
}

bootstrap_assert_current_link() {
    local link_path="$1" owner resolved
    [[ -e "$link_path" || -L "$link_path" ]] || return 0
    [[ -L "$link_path" ]] || bootstrap_fail "当前版本入口不是软链接：$link_path" 73
    owner="$(stat -c '%u' "$link_path")"
    [[ "$owner" == "$INSTALL_OWNER_UID" ]] || bootstrap_fail "当前版本入口所有者异常：$link_path" 73
    resolved="$(readlink -f -- "$link_path" 2>/dev/null || true)"
    case "$resolved" in
        "$INSTALL_ROOT"/runtime/*) ;;
        *) bootstrap_fail "当前版本入口指向 SHDome 目录之外：$link_path -> $resolved" 73 ;;
    esac
}

bootstrap_archive_validate() {
    local archive="$1" version="$2"
    python3 - "$archive" "shdome-$version" <<'PY'
import posixpath, sys, tarfile
archive, expected_root = sys.argv[1:]
with tarfile.open(archive, "r:gz") as handle:
    members = handle.getmembers()
    if not members:
        raise SystemExit("release archive is empty")
    for member in members:
        normalized = posixpath.normpath(member.name)
        if member.name.startswith("/") or normalized in {"", ".", ".."} or normalized.startswith("../"):
            raise SystemExit(f"unsafe release path: {member.name}")
        if normalized != expected_root and not normalized.startswith(expected_root + "/"):
            raise SystemExit(f"unexpected release root: {member.name}")
        if member.issym() or member.islnk() or member.isdev() or member.isfifo():
            raise SystemExit(f"unsupported release entry type: {member.name}")
PY
}

bootstrap_safe_link() {
    local target="$1" link_path="$2" target_resolved existing_target="" owner
    target_resolved="$(readlink -f -- "$target" 2>/dev/null || true)"
    case "$target_resolved" in
        "$INSTALL_ROOT"/runtime/*) ;;
        *) bootstrap_fail "快捷入口目标不属于 SHDome 运行目录：$target" 73 ;;
    esac
    [[ -f "$target_resolved" ]] || bootstrap_fail "快捷入口目标不存在：$target" 73
    if [[ -L "$link_path" ]]; then
        owner="$(stat -c '%u' "$link_path")"
        [[ "$owner" == "$INSTALL_OWNER_UID" ]] || bootstrap_fail "拒绝覆盖所有者异常的软链接：$link_path" 73
        existing_target="$(readlink -f -- "$link_path" 2>/dev/null || true)"
        case "$existing_target" in
            "$INSTALL_ROOT"/runtime/*) ;;
            *) bootstrap_fail "拒绝覆盖不属于 SHDome 的软链接：$link_path -> $existing_target" 73 ;;
        esac
    elif [[ -e "$link_path" ]]; then
        bootstrap_fail "拒绝覆盖已有文件：$link_path" 73
    fi
    ln -sfn "$target" "$link_path"
}

if [[ "${SHDOME_INSTALLER_LIBRARY_ONLY:-0}" == "1" ]]; then
    # shellcheck disable=SC2317
    return 0 2>/dev/null || exit 0
fi

trap bootstrap_cleanup EXIT INT TERM

[[ "$(uname -s)" == "Linux" ]] || bootstrap_fail "目前只支持 Linux" 69
[[ ${EUID:-$(id -u)} -eq 0 ]] || bootstrap_fail "请使用 root 用户执行安装" 77
[[ "$RELEASE_VERSION" =~ ^v[0-9]+\.[0-9]+\.[0-9]+([.-][a-zA-Z0-9._-]+)?$ ]] || bootstrap_fail "发布版本未配置或格式错误"
[[ "$RELEASE_SHA256" =~ ^[a-fA-F0-9]{64}$ ]] || bootstrap_fail "发布包 SHA-256 未配置或格式错误"
bootstrap_release_url_validate "$RELEASE_URL" "$RELEASE_VERSION" || \
    bootstrap_fail "发布地址必须与版本及发布包名称严格匹配"

for command_name in curl sha256sum tar mktemp install ln mv stat readlink; do
    command -v "$command_name" >/dev/null 2>&1 || bootstrap_fail "缺少基础命令：$command_name" 69
done

bootstrap_install_runtime_dependencies() {
    if command -v python3 >/dev/null 2>&1 && command -v flock >/dev/null 2>&1 && \
       command -v openssl >/dev/null 2>&1 && command -v ss >/dev/null 2>&1; then
        return 0
    fi
    printf '[SHDome] 安装运行依赖（python3、flock、openssl、ss）\n'
    if command -v apt-get >/dev/null 2>&1; then
        apt-get update
        DEBIAN_FRONTEND=noninteractive apt-get install -y python3 util-linux openssl iproute2 ca-certificates
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y python3 util-linux openssl iproute ca-certificates
    elif command -v yum >/dev/null 2>&1; then
        yum install -y python3 util-linux openssl iproute ca-certificates
    elif command -v apk >/dev/null 2>&1; then
        apk add --no-cache python3 util-linux openssl iproute2 ca-certificates
    else
        bootstrap_fail "无法自动安装运行依赖，请先安装 python3、flock、openssl 和 ss" 69
    fi
    for dependency in python3 flock openssl ss; do
        command -v "$dependency" >/dev/null 2>&1 || bootstrap_fail "运行依赖安装失败：$dependency" 69
    done
}

bootstrap_install_runtime_dependencies

mkdir -p "$INSTALL_ROOT"
bootstrap_assert_secure_directory "$INSTALL_ROOT"
exec 9>"$INSTALL_ROOT/install.lock"
flock -n 9 || bootstrap_fail "另一个 SHDome 安装或更新正在进行" 75

TEMP_DIR="$(mktemp -d /tmp/shdome-install.XXXXXX)"
archive="$TEMP_DIR/shdome.tar.gz"
unpack_dir="$TEMP_DIR/unpack"
mkdir -p "$unpack_dir"

printf '[SHDome] 下载 %s\n' "$RELEASE_VERSION"
curl --proto '=https' --tlsv1.2 -fL --retry 3 --connect-timeout 15 -o "$archive" "$RELEASE_URL"
printf '%s  %s\n' "${RELEASE_SHA256,,}" "$archive" | sha256sum -c - >/dev/null || bootstrap_fail "发布包 SHA-256 校验失败"

bootstrap_archive_validate "$archive" "$RELEASE_VERSION" || bootstrap_fail "发布包结构或路径安全校验失败" 65

tar -xzf "$archive" -C "$unpack_dir" --no-same-owner
release_source="$unpack_dir/shdome-$RELEASE_VERSION"
[[ -x "$release_source/bin/k" && -f "$release_source/src/shdome.sh" && -d "$release_source/catalog" ]] || \
    bootstrap_fail "发布包结构不完整"
IFS= read -r main_shebang <"$release_source/src/shdome.sh"
IFS= read -r entry_shebang <"$release_source/bin/k"
[[ "$main_shebang" == '#!/usr/bin/env bash' && "$entry_shebang" == '#!/usr/bin/env bash' ]] || \
    bootstrap_fail "发布包入口脚本 Shebang 校验失败"

runtime_root="$INSTALL_ROOT/runtime"
release_target="$runtime_root/$RELEASE_VERSION"
mkdir -p "$runtime_root"
bootstrap_assert_secure_directory "$runtime_root"
if [[ ! -d "$release_target" ]]; then
    mv "$release_source" "$release_target"
fi
[[ -x "$release_target/bin/k" && -f "$release_target/src/shdome.sh" && -d "$release_target/catalog" ]] || \
    bootstrap_fail "已存在的版本目录结构异常，请人工检查：$release_target"
[[ "$(stat -c '%u' "$release_target")" == "0" ]] || bootstrap_fail "版本目录不属于 root：$release_target"
chmod 755 "$release_target/bin/k" "$release_target/src/shdome.sh" "$release_target/bootstrap/install.sh"

current_link="$INSTALL_ROOT/current"
next_link="$INSTALL_ROOT/.current.$$.new"
bootstrap_assert_current_link "$current_link"
ln -s "$release_target" "$next_link"
mv -Tf "$next_link" "$current_link"
install -d -m 755 /usr/local/bin

bootstrap_safe_link "$current_link/bin/k" /usr/local/bin/k

user_home="${HOME:-/root}"
[[ "$user_home" == /* ]] || bootstrap_fail "HOME 不是绝对路径"
bootstrap_safe_link "$current_link/src/shdome.sh" "$user_home/shdome.sh"

metadata="$INSTALL_ROOT/install-meta.env"
metadata_temp="$INSTALL_ROOT/.install-meta.$$.tmp"
{
    printf 'SHDOME_RELEASE_VERSION=%q\n' "$RELEASE_VERSION"
    printf 'SHDOME_RELEASE_URL=%q\n' "$RELEASE_URL"
    printf 'SHDOME_RELEASE_SHA256=%q\n' "${RELEASE_SHA256,,}"
} >"$metadata_temp"
chmod 600 "$metadata_temp"
mv -f "$metadata_temp" "$metadata"

metadata_json="$INSTALL_ROOT/install-meta.json"
metadata_json_temp="$INSTALL_ROOT/.install-meta.$$.json.tmp"
python3 - "$metadata_json_temp" "$RELEASE_VERSION" "$RELEASE_URL" "${RELEASE_SHA256,,}" <<'PY'
import json, re, sys
output, version, url, sha256 = sys.argv[1:]
match = re.fullmatch(r"https://github\.com/([^/]+/[^/]+)/releases/download/[^/]+/[^/]+", url)
if not match:
    raise SystemExit("invalid GitHub release URL")
with open(output, "w", encoding="utf-8") as handle:
    json.dump({
        "schema": 1,
        "releaseVersion": version,
        "releaseUrl": url,
        "releaseSha256": sha256,
        "repository": match.group(1),
        "installedAt": __import__("datetime").datetime.now(__import__("datetime").timezone.utc).replace(microsecond=0).isoformat(),
    }, handle, ensure_ascii=False, indent=2)
    handle.write("\n")
PY
chmod 600 "$metadata_json_temp"
mv -f "$metadata_json_temp" "$metadata_json"

printf '[SHDome] %s 安装完成，快捷命令：k\n' "$RELEASE_VERSION"
if [[ "$NO_LAUNCH" != "1" ]]; then
    SCRIPT_PATH="/usr/local/bin/k"
    exec "$SCRIPT_PATH" "$@"
fi
