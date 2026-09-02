#!/usr/bin/env bash

app_backup() {
    local app_id="${1:-}" assume_yes=0
    shift || true
    [[ "${1:-}" == "--yes" || "${1:-}" == "-y" ]] && assume_yes=1
    app_require_installed "$app_id" || return
    require_root || return
    SHDOME_ASSUME_YES="$assume_yes" lock_run "app-$app_id" app_backup_locked "$app_id"
}

backup_metadata_write() {
    local archive="$1" nginx_backup="$2" state_file="$3" metadata="$4" cert_root="$5"
    python3 - "$archive" "$nginx_backup" "$state_file" "$metadata" "$cert_root" <<'PY'
import datetime, hashlib, json, os, subprocess, sys
archive, nginx_path, state_path, output, cert_root = sys.argv[1:]
with open(state_path, encoding="utf-8") as handle:
    state = json.load(handle)
def digest(path):
    if not path or not os.path.isfile(path):
        return ""
    value = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            value.update(chunk)
    return value.hexdigest()
domain = state.get("domain", "")
cert = os.path.join(cert_root, "live", domain, "fullchain.pem") if domain else ""
certificate = {}
if cert and os.path.isfile(cert):
    try:
        output_text = subprocess.check_output(
            ["openssl", "x509", "-in", cert, "-noout", "-issuer", "-enddate", "-serial"],
            text=True, stderr=subprocess.DEVNULL,
        )
        certificate = dict(line.split("=", 1) for line in output_text.strip().splitlines() if "=" in line)
    except (OSError, subprocess.CalledProcessError):
        certificate = {"status": "unreadable"}
metadata_value = {
    "schema": 1,
    "appId": state["id"],
    "appVersion": state["version"],
    "createdAt": datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0).isoformat(),
    "archive": {"name": os.path.basename(archive), "sha256": digest(archive)},
    "routing": {"domain": domain, "accessMode": state.get("accessMode", "direct")},
    "nginx": {"name": os.path.basename(nginx_path) if nginx_path else "", "sha256": digest(nginx_path)},
    "certificateMetadata": certificate,
}
with open(output, "w", encoding="utf-8") as handle:
    json.dump(metadata_value, handle, ensure_ascii=False, indent=2)
    handle.write("\n")
PY
}

backup_logical_dump_prepare() {
    local manifest_file="$1" app_dir="$2" stage_dir="$3"
    python3 - "$manifest_file" "$app_dir" "$stage_dir" <<'PY'
import json, os, sqlite3, sys
manifest_path, app_dir, stage_dir = sys.argv[1:]
with open(manifest_path, encoding="utf-8") as handle:
    manifest = json.load(handle)
logical = manifest.get("backup", {}).get("logical")
if not logical:
    raise SystemExit(0)
if logical.get("type") != "sqlite":
    raise SystemExit("unsupported logical backup adapter")
source = os.path.join(app_dir, "data", logical["source"])
if not os.path.isfile(source):
    raise SystemExit(f"SQLite backup source is missing: {source}")
output_dir = os.path.join(stage_dir, "logical")
os.makedirs(output_dir, mode=0o700, exist_ok=True)
output = os.path.join(output_dir, logical["output"])
temporary = output + ".tmp"
connection = sqlite3.connect(f"file:{source}?mode=ro", uri=True)
try:
    integrity = connection.execute("PRAGMA integrity_check").fetchone()
    if not integrity or integrity[0] != "ok":
        raise SystemExit("SQLite integrity check failed")
    with open(temporary, "w", encoding="utf-8", newline="\n") as handle:
        for line in connection.iterdump():
            handle.write(line)
            handle.write("\n")
finally:
    connection.close()
os.replace(temporary, output)
print(output)
PY
}

app_backup_locked() {
    local app_id="$1" app_dir backup_dir backup_id archive container_name was_running=0 domain nginx_source
    local stage_dir stage_archive stage_checksum stage_nginx stage_metadata final_nginx final_metadata final_checksum nginx_metadata_path=""
    local cert_root="$SHDOME_ROOT/gateway/letsencrypt" logical_dump="" logical_archive_dir
    app_dir="$SHDOME_APPS_DIR/$app_id"
    logical_archive_dir="$app_dir/.shdome-logical"
    container_name="$(state_get "$app_id" containerName)"
    [[ "$(docker inspect -f '{{.State.Running}}' "$container_name" 2>/dev/null || true)" == "true" ]] && was_running=1
    backup_id="$(date -u +'%Y%m%dT%H%M%SZ')"
    backup_dir="$SHDOME_BACKUP_DIR/apps/$app_id"
    archive="$backup_dir/$backup_id.tar.gz"
    mkdir -p "$backup_dir"
    while [[ -e "$archive" || -e "$archive.tmp" ]]; do
        sleep 1
        backup_id="$(date -u +'%Y%m%dT%H%M%SZ')"
        archive="$backup_dir/$backup_id.tar.gz"
    done
    stage_dir="$(mktemp -d "$backup_dir/.${backup_id}.XXXXXX")"
    stage_archive="$stage_dir/$backup_id.tar.gz"
    stage_checksum="$stage_dir/$backup_id.tar.gz.sha256"
    stage_nginx="$stage_dir/$backup_id.nginx.conf"
    stage_metadata="$stage_dir/$backup_id.metadata.json"
    final_checksum="$archive.sha256"
    final_nginx="$backup_dir/$backup_id.nginx.conf"
    final_metadata="$backup_dir/$backup_id.metadata.json"
    SHDOME_BACKUP_ACTIVE=1
    SHDOME_BACKUP_APP_ID="$app_id"
    SHDOME_BACKUP_APP_DIR="$app_dir"
    SHDOME_BACKUP_TEMP_DIR="$stage_dir"
    SHDOME_BACKUP_FINAL_PREFIX="$backup_dir/$backup_id"
    SHDOME_BACKUP_LOGICAL_DIR="$logical_archive_dir"
    SHDOME_BACKUP_WAS_RUNNING="$was_running"
    trap app_backup_abort_cleanup EXIT
    if [[ "$was_running" == "1" ]]; then
        info "为保证单容器应用数据一致性，备份期间将短暂停止应用"
        if ! docker_compose -f "$app_dir/compose.yml" -p "shdome-$app_id" stop; then
            app_backup_abort_cleanup
            trap - EXIT
            fail "无法停止应用，备份已取消" 74
            return
        fi
    fi
    if ! logical_dump="$(backup_logical_dump_prepare "$app_dir/manifest.json" "$app_dir" "$stage_dir")"; then
        app_backup_abort_cleanup
        trap - EXIT
        fail "数据库逻辑备份失败，备份未发布" 74
        return
    fi
    if [[ -n "$logical_dump" ]]; then
        if [[ -e "$logical_archive_dir" ]]; then
            case "$logical_archive_dir" in
                "$app_dir/.shdome-logical") rm -rf -- "$logical_archive_dir" ;;
                *) app_backup_abort_cleanup; trap - EXIT; fail "逻辑备份暂存路径异常" 70; return ;;
            esac
        fi
        if ! mkdir -p "$logical_archive_dir" || ! install -m 600 "$logical_dump" "$logical_archive_dir/$(basename "$logical_dump")"; then
            app_backup_abort_cleanup
            trap - EXIT
            fail "无法把数据库逻辑备份加入归档" 74
            return
        fi
    fi
    if ! tar -czf "$stage_archive" -C "$SHDOME_APPS_DIR" --exclude="$app_id/logs" "$app_id"; then
        app_backup_abort_cleanup
        trap - EXIT
        fail "备份失败" 74
        return
    fi
    if [[ -d "$logical_archive_dir" ]]; then
        rm -rf -- "$logical_archive_dir"
    fi
    SHDOME_BACKUP_LOGICAL_DIR=""
    if [[ "$was_running" == "1" ]]; then
        if ! docker_compose -f "$app_dir/compose.yml" -p "shdome-$app_id" start; then
            app_backup_abort_cleanup
            trap - EXIT
            fail "备份已生成，但应用恢复启动失败；未发布此次备份" 74
            return
        fi
        SHDOME_BACKUP_WAS_RUNNING=0
    fi
    domain="$(state_get "$app_id" domain 2>/dev/null || true)"
    if [[ -n "$domain" ]]; then
        gateway_paths_init
        nginx_source="$SHDOME_GATEWAY_CONF_DIR/$domain.conf"
        if [[ -f "$nginx_source" ]]; then
            if ! install -m 600 "$nginx_source" "$stage_nginx"; then
                app_backup_abort_cleanup
                trap - EXIT
                fail "无法暂存 Nginx 配置，备份未发布" 74
                return
            fi
        fi
    fi
    [[ ! -f "$stage_nginx" ]] || nginx_metadata_path="$stage_nginx"
    if ! backup_metadata_write "$stage_archive" "$nginx_metadata_path" \
        "$(state_file_for "$app_id")" "$stage_metadata" "$cert_root"; then
        app_backup_abort_cleanup
        trap - EXIT
        fail "无法生成备份元数据，备份未发布" 74
        return
    fi
    if ! (cd "$stage_dir" && sha256sum "$backup_id.tar.gz" >"$backup_id.tar.gz.sha256") || \
       ! chmod 600 "$stage_archive" "$stage_checksum" "$stage_metadata"; then
        app_backup_abort_cleanup
        trap - EXIT
        fail "无法生成备份摘要，备份未发布" 74
        return
    fi
    if [[ -f "$stage_nginx" ]] && ! mv -f "$stage_nginx" "$final_nginx"; then
        app_backup_abort_cleanup
        trap - EXIT
        fail "无法发布备份 Nginx 配置" 74
        return
    fi
    if ! mv -f "$stage_metadata" "$final_metadata" || \
       ! mv -f "$stage_checksum" "$final_checksum" || \
       ! mv -f "$stage_archive" "$archive"; then
        app_backup_abort_cleanup
        trap - EXIT
        fail "无法原子发布备份产物" 74
        return
    fi
    SHDOME_BACKUP_ACTIVE=0
    trap - EXIT
    rmdir "$stage_dir" 2>/dev/null || true
    # 由更新流程读取，用于失败时恢复一致性数据快照。
    # shellcheck disable=SC2034
    SHDOME_LAST_BACKUP_ID="$backup_id"
    # shellcheck disable=SC2034
    SHDOME_LAST_BACKUP_ARCHIVE="$archive"
    log_event INFO app-backup "$app_id backup=$backup_id"
    success "备份完成：$archive"
}

app_backup_abort_cleanup() {
    [[ "${SHDOME_BACKUP_ACTIVE:-0}" == "1" ]] || return 0
    SHDOME_BACKUP_ACTIVE=0
    if [[ -n "${SHDOME_BACKUP_TEMP_DIR:-}" ]]; then
        case "$SHDOME_BACKUP_TEMP_DIR" in
            "$SHDOME_BACKUP_DIR/apps/$SHDOME_BACKUP_APP_ID"/.*) rm -rf -- "$SHDOME_BACKUP_TEMP_DIR" ;;
            *) warn "拒绝清理异常备份临时目录：$SHDOME_BACKUP_TEMP_DIR" ;;
        esac
    fi
    if [[ -n "${SHDOME_BACKUP_LOGICAL_DIR:-}" ]]; then
        case "$SHDOME_BACKUP_LOGICAL_DIR" in
            "$SHDOME_BACKUP_APP_DIR/.shdome-logical") rm -rf -- "$SHDOME_BACKUP_LOGICAL_DIR" ;;
            *) warn "拒绝清理异常逻辑备份目录：$SHDOME_BACKUP_LOGICAL_DIR" ;;
        esac
    fi
    if [[ -n "${SHDOME_BACKUP_FINAL_PREFIX:-}" ]]; then
        rm -f -- "$SHDOME_BACKUP_FINAL_PREFIX.tar.gz" "$SHDOME_BACKUP_FINAL_PREFIX.tar.gz.sha256" \
            "$SHDOME_BACKUP_FINAL_PREFIX.nginx.conf" "$SHDOME_BACKUP_FINAL_PREFIX.metadata.json"
    fi
    if [[ "${SHDOME_BACKUP_WAS_RUNNING:-0}" == "1" && -f "${SHDOME_BACKUP_APP_DIR:-}/compose.yml" ]]; then
        docker_compose -f "$SHDOME_BACKUP_APP_DIR/compose.yml" -p "shdome-$SHDOME_BACKUP_APP_ID" start >/dev/null 2>&1 || true
        SHDOME_BACKUP_WAS_RUNNING=0
    fi
    log_event WARN app-backup "备份中断并恢复应用 $SHDOME_BACKUP_APP_ID"
}

app_backups() {
    local app_id="${1:-}" backup_dir
    [[ "$app_id" =~ ^[a-z0-9][a-z0-9-]{1,62}$ ]] || { fail "应用 ID 格式错误：$app_id" 64; return; }
    backup_dir="$SHDOME_BACKUP_DIR/apps/$app_id"
    if [[ -d "$backup_dir" ]]; then
        find "$backup_dir" -maxdepth 1 -type f -name '*.tar.gz' -printf '%f\n' | LC_ALL=C sort -r
    else
        info "应用暂无备份：$app_id"
    fi
}

backup_archive_validate() {
    local archive="$1" app_id="$2"
    python3 - "$archive" "$app_id" <<'PY'
import posixpath, sys, tarfile
archive, app_id = sys.argv[1:]
with tarfile.open(archive, "r:gz") as handle:
    members = handle.getmembers()
    if not members:
        raise SystemExit("备份为空")
    for member in members:
        normalized = posixpath.normpath(member.name)
        if member.name.startswith("/") or normalized == ".." or normalized.startswith("../"):
            raise SystemExit(f"不安全的备份路径：{member.name}")
        if normalized != app_id and not normalized.startswith(app_id + "/"):
            raise SystemExit(f"备份包含其他应用路径：{member.name}")
        if member.issym() or member.islnk():
            if member.linkname.startswith("/"):
                raise SystemExit(f"不安全的绝对链接：{member.name}")
            link = posixpath.normpath(posixpath.join(posixpath.dirname(normalized), member.linkname))
            if link != app_id and not link.startswith(app_id + "/"):
                raise SystemExit(f"链接越出应用目录：{member.name}")
PY
}

backup_metadata_validate() {
    local archive="$1" metadata="$2" nginx_backup="$3" app_id="$4"
    [[ -f "$metadata" ]] || return 0
    python3 - "$archive" "$metadata" "$nginx_backup" "$app_id" <<'PY'
import hashlib, json, os, sys
from datetime import datetime
archive, metadata_path, nginx_path, app_id = sys.argv[1:]
with open(metadata_path, encoding="utf-8") as handle:
    metadata = json.load(handle)
if metadata.get("schema") != 1:
    raise SystemExit("unsupported backup metadata schema")
if metadata.get("appId") != app_id:
    raise SystemExit("backup app id mismatch")
if not isinstance(metadata.get("appVersion"), str) or not metadata["appVersion"]:
    raise SystemExit("backup app version is missing")
try:
    created_at = datetime.fromisoformat(metadata.get("createdAt", ""))
except (TypeError, ValueError):
    raise SystemExit("backup timestamp is invalid")
if created_at.tzinfo is None:
    raise SystemExit("backup timestamp has no timezone")
def digest(path):
    value = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            value.update(chunk)
    return value.hexdigest()
archive_value = metadata.get("archive", {})
if archive_value.get("name") != os.path.basename(archive):
    raise SystemExit("archive name mismatch")
if digest(archive) != archive_value.get("sha256"):
    raise SystemExit("archive digest mismatch")
nginx_value = metadata.get("nginx", {})
expected_nginx = nginx_value.get("sha256", "")
if expected_nginx:
    if nginx_value.get("name") != os.path.basename(nginx_path) or not os.path.isfile(nginx_path) or digest(nginx_path) != expected_nginx:
        raise SystemExit("nginx config digest mismatch")
routing = metadata.get("routing", {})
if not isinstance(routing.get("domain", ""), str) or routing.get("accessMode") not in {"direct", "domain_only"}:
    raise SystemExit("routing metadata is invalid")
if not isinstance(metadata.get("certificateMetadata"), dict):
    raise SystemExit("certificate metadata is invalid")
PY
}

app_restore() {
    local app_id="${1:-}" backup_id="${2:-}" assume_yes=0
    shift 2 2>/dev/null || true
    [[ "${1:-}" == "--yes" || "${1:-}" == "-y" ]] && assume_yes=1
    app_require_installed "$app_id" || return
    require_root || return
    [[ "$backup_id" =~ ^[0-9]{8}T[0-9]{6}Z$ ]] || { fail "备份 ID 格式错误" 64; return; }
    SHDOME_ASSUME_YES="$assume_yes" lock_run "app-$app_id" app_restore_locked "$app_id" "$backup_id" "$assume_yes"
}

app_restore_safe_remove_dir() {
    local path="$1" app_id="$2"
    [[ "$path" == "$SHDOME_APPS_DIR/$app_id" ]] || { warn "拒绝删除异常恢复路径：$path"; return 70; }
    rm -rf -- "$path"
}

app_restore_abort_cleanup() {
    [[ "${SHDOME_RESTORE_ACTIVE:-0}" == "1" ]] || return 0
    SHDOME_RESTORE_ACTIVE=0
    local app_id="$SHDOME_RESTORE_APP_ID" app_dir="$SHDOME_RESTORE_APP_DIR" rollback_dir="$SHDOME_RESTORE_ROLLBACK_DIR"
    if [[ -d "$rollback_dir" ]]; then
        if [[ -f "$app_dir/compose.yml" ]]; then
            docker_compose -f "$app_dir/compose.yml" -p "shdome-$app_id" down >/dev/null 2>&1 || true
        fi
        [[ ! -e "$app_dir" ]] || app_restore_safe_remove_dir "$app_dir" "$app_id" || true
        if mv "$rollback_dir" "$app_dir"; then
            docker_compose -f "$app_dir/compose.yml" -p "shdome-$app_id" up -d >/dev/null 2>&1 || true
            log_event WARN app-restore "恢复中断并还原操作前数据 $app_id"
            return 0
        fi
        log_event ERROR app-restore "恢复中断且操作前数据未能归位 $app_id rollback=$rollback_dir"
        return 1
    fi
    if [[ -f "$app_dir/compose.yml" ]]; then
        docker_compose -f "$app_dir/compose.yml" -p "shdome-$app_id" up -d >/dev/null 2>&1 || true
    fi
    log_event WARN app-restore "恢复在替换数据前中断 $app_id"
}

app_restore_locked() {
    local app_id="$1" backup_id="$2" assume_yes="$3" archive app_dir rollback_dir host_port manifest_file metadata nginx_backup
    archive="$SHDOME_BACKUP_DIR/apps/$app_id/$backup_id.tar.gz"
    app_dir="$SHDOME_APPS_DIR/$app_id"
    rollback_dir="$SHDOME_APPS_DIR/.restore-$app_id-$$"
    metadata="$SHDOME_BACKUP_DIR/apps/$app_id/$backup_id.metadata.json"
    nginx_backup="$SHDOME_BACKUP_DIR/apps/$app_id/$backup_id.nginx.conf"
    [[ -f "$archive" && -f "$archive.sha256" ]] || { fail "备份不存在或缺少校验文件：$backup_id" 66; return; }
    (cd "$(dirname "$archive")" && sha256sum -c "$(basename "$archive").sha256") || { fail "备份 SHA-256 校验失败" 65; return; }
    backup_archive_validate "$archive" "$app_id" || { fail "备份归档结构校验失败" 65; return; }
    backup_metadata_validate "$archive" "$metadata" "$nginx_backup" "$app_id" || { fail "备份元数据校验失败" 65; return; }
    if [[ "$assume_yes" != "1" ]] && ! terminal_confirm "恢复会用备份 $backup_id 替换 $app_id 当前数据，是否继续？"; then
        info "已取消恢复"
        return 0
    fi
    app_backup_locked "$app_id" || return
    SHDOME_RESTORE_ACTIVE=1
    SHDOME_RESTORE_APP_ID="$app_id"
    SHDOME_RESTORE_APP_DIR="$app_dir"
    SHDOME_RESTORE_ROLLBACK_DIR="$rollback_dir"
    trap app_restore_abort_cleanup EXIT
    if ! docker_compose -f "$app_dir/compose.yml" -p "shdome-$app_id" down; then
        app_restore_abort_cleanup
        trap - EXIT
        fail "无法停止应用，恢复已取消" 70
        return
    fi
    if [[ -e "$rollback_dir" ]]; then
        app_restore_abort_cleanup
        trap - EXIT
        fail "恢复临时路径已存在：$rollback_dir" 73
        return
    fi
    if ! mv "$app_dir" "$rollback_dir"; then
        app_restore_abort_cleanup
        trap - EXIT
        fail "无法暂存当前应用数据，恢复已取消" 70
        return
    fi
    if tar -xzf "$archive" -C "$SHDOME_APPS_DIR" --no-same-owner && \
       [[ -f "$app_dir/compose.yml" && -f "$app_dir/state.json" && -f "$app_dir/manifest.json" ]]; then
        manifest_file="$app_dir/manifest.json"
        if manifest_validate "$manifest_file"; then
            host_port="$(state_get "$app_id" hostPort)"
            if docker_compose -f "$app_dir/compose.yml" -p "shdome-$app_id" up -d && \
               app_healthcheck "$manifest_file" "$host_port"; then
                case "$rollback_dir" in
                    "$SHDOME_APPS_DIR/.restore-$app_id-"*) rm -rf -- "$rollback_dir" ;;
                    *) warn "拒绝删除异常恢复临时目录：$rollback_dir" ;;
                esac
                SHDOME_RESTORE_ACTIVE=0
                trap - EXIT
                if ! lock_run nginx backup_restore_gateway "$app_id" "$nginx_backup"; then
                    warn "应用数据已恢复，但域名入口恢复失败，请重新执行 k app domain $app_id"
                fi
                log_event INFO app-restore "$app_id backup=$backup_id"
                success "应用已恢复到备份：$backup_id"
                return 0
            fi
        fi
    fi
    warn "恢复失败，正在还原恢复前的数据"
    app_restore_abort_cleanup
    trap - EXIT
    fail "恢复失败，已恢复操作前状态" 70
}

backup_restore_gateway() {
    local app_id="$1" nginx_backup="$2" domain candidate
    domain="$(state_get "$app_id" domain 2>/dev/null || true)"
    [[ -n "$domain" && -f "$nginx_backup" ]] || return 0
    gateway_paths_init || return
    if [[ -s "$SHDOME_GATEWAY_CERTS/live/$domain/fullchain.pem" && -s "$SHDOME_GATEWAY_CERTS/live/$domain/privkey.pem" ]]; then
        if gateway_ensure; then
            candidate="$(mktemp "$SHDOME_GATEWAY_CONF_DIR/.${domain}.restore.XXXXXX")" || candidate=""
            if [[ -n "$candidate" ]] && ! cp "$nginx_backup" "$candidate"; then
                rm -f -- "$candidate"
                candidate=""
            fi
            [[ -n "$candidate" ]] || { warn "无法准备备份中的 Nginx 配置"; app_switch_access_mode "$app_id" direct ""; return; }
            if gateway_commit_candidate "$candidate" "$domain"; then
                return 0
            fi
        fi
    fi
    warn "备份中的域名缺少可用证书或网关不可用，恢复为 IP+端口访问"
    app_switch_access_mode "$app_id" direct ""
}

app_backup_all() {
    local assume_yes=0 state_file app_id failures=0 found=0
    [[ "${1:-}" == "--yes" || "${1:-}" == "-y" ]] && assume_yes=1
    require_root || return
    if [[ "$assume_yes" != "1" ]] && ! terminal_confirm "将依次短暂停止并备份全部已安装应用，是否继续？"; then
        info "已取消全量备份"
        return 0
    fi
    while IFS= read -r state_file; do
        app_id="$(basename "$(dirname "$state_file")")"
        found=1
        if ! app_backup "$app_id" --yes; then
            failures=$((failures + 1))
        fi
    done < <(find "$SHDOME_APPS_DIR" -mindepth 2 -maxdepth 2 -type f -name state.json -print | LC_ALL=C sort)
    [[ "$found" == "1" ]] || { info "当前没有已安装应用"; return 0; }
    ((failures == 0)) || { fail "全量备份有 $failures 个应用失败" 74; return; }
    success "全部应用备份完成"
}

app_restore_by_id() {
    local backup_id="${1:-}" assume_yes=0 archive app_id found=0
    shift || true
    [[ "${1:-}" == "--yes" || "${1:-}" == "-y" ]] && assume_yes=1
    [[ "$backup_id" =~ ^[0-9]{8}T[0-9]{6}Z$ ]] || { fail "备份 ID 格式错误" 64; return; }
    while IFS= read -r archive; do
        [[ -n "$archive" ]] || continue
        app_id="$(basename "$(dirname "$archive")")"
        found=$((found + 1))
    done < <(find "$SHDOME_BACKUP_DIR/apps" -mindepth 2 -maxdepth 2 -type f -name "$backup_id.tar.gz" -print 2>/dev/null)
    ((found > 0)) || { fail "找不到备份：$backup_id" 66; return; }
    ((found == 1)) || { fail "多个应用存在相同备份 ID，请使用 k app restore <应用ID> $backup_id" 73; return; }
    if [[ "$assume_yes" == "1" ]]; then
        app_restore "$app_id" "$backup_id" --yes
    else
        app_restore "$app_id" "$backup_id"
    fi
}
