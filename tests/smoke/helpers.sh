#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TEST_ROOT="$(mktemp -d /tmp/shdome-helpers.XXXXXX)"
trap 'rm -rf -- "$TEST_ROOT"' EXIT

export SHDOME_ROOT="$TEST_ROOT/runtime"
export SHDOME_ALLOW_NON_ROOT=1
# shellcheck source=/dev/null
source "$PROJECT_DIR/src/shdome.sh"
shdome_load
shdome_config_init
shdome_register_builtin_commands
modules_activate

[[ "${SHDOME_MODULE_IDS[*]}" == "app_market" ]]
[[ "${SHDOME_MENU_NUMBERS[*]}" == "1 2 3" ]]
[[ "${SHDOME_HELP_HANDLERS[*]}" == "app_market_help" ]]
[[ "$(catalog_resolve_selector 1)" == "cloudreve" ]]
[[ "$(catalog_resolve_selector Cloudreve)" == "cloudreve" ]]
[[ "$(catalog_resolve_selector 4)" == "uptime-kuma" ]]
[[ "$(catalog_resolve_selector 'Uptime Kuma')" == "uptime-kuma" ]]
[[ "$(catalog_resolve_selector 禅道)" == "zentao" ]]
if catalog_resolve_selector does-not-exist >/dev/null 2>&1; then exit 1; fi
(
    selections=(4 0)
    selection_index=0
    managed_app=""
    # shellcheck disable=SC2317
    terminal_read() {
        local target_variable="$1"
        printf -v "$target_variable" '%s' "${selections[$selection_index]}"
        selection_index=$((selection_index + 1))
    }
    # shellcheck disable=SC2317
    app_list() { return 0; }
    # shellcheck disable=SC2317
    state_exists() { [[ "$1" == "uptime-kuma" ]]; }
    # shellcheck disable=SC2317
    app_manage_menu() { managed_app="$1"; }
    app_market_menu >/dev/null
    [[ "$managed_app" == "uptime-kuma" ]]
)
test_future_menu_handler() { :; }
menu_register 20 "测试系统模块" test_future_menu_handler
menu_register 10 "测试网站模块" test_future_menu_handler
[[ "${SHDOME_MENU_NUMBERS[*]}" == "1 2 3 10 20" ]]
menu_count="${#SHDOME_MENU_NUMBERS[@]}"
if menu_register 1 "重复菜单" test_future_menu_handler >/dev/null 2>&1; then exit 1; fi
[[ "${#SHDOME_MENU_NUMBERS[@]}" == "$menu_count" ]]
(
    # shellcheck disable=SC2317
    port_registered_to_other_app() { touch "$TEST_ROOT/invalid-port-continued"; }
    if port_assert_available invalid app >/dev/null 2>&1; then exit 1; fi
    [[ ! -e "$TEST_ROOT/invalid-port-continued" ]]
)

release_api="$TEST_ROOT/release-api.json"
release_checksum="$TEST_ROOT/release.sha256"
release_metadata="$SHDOME_ROOT/install-meta.json"
release_archive_url="https://github.com/example/shdome/releases/download/v1.2.3/shdome-v1.2.3.tar.gz"
release_checksum_url="$release_archive_url.sha256"
python3 - "$release_api" "$release_archive_url" "$release_checksum_url" <<'PY'
import json, sys
path, archive_url, checksum_url = sys.argv[1:]
with open(path, "w", encoding="utf-8") as handle:
    json.dump({
        "tag_name": "v1.2.3", "draft": False, "prerelease": False,
        "assets": [
            {"name": "shdome-v1.2.3.tar.gz", "browser_download_url": archive_url},
            {"name": "shdome-v1.2.3.tar.gz.sha256", "browser_download_url": checksum_url},
        ],
    }, handle)
PY
printf '%064d  shdome-v1.2.3.tar.gz\n' 0 >"$release_checksum"
printf '{"schema":1,"repository":"example/shdome","releaseVersion":"v1.0.0"}\n' >"$release_metadata"
[[ "$(self_update_parse_release_api "$release_api" example/shdome)" == $'v1.2.3\t'"$release_archive_url"$'\t'"$release_checksum_url" ]]
[[ "$(self_update_parse_checksum "$release_checksum" shdome-v1.2.3.tar.gz)" == "$(printf '%064d' 0)" ]]
self_update_release_url_validate "$release_archive_url" v1.2.3
if self_update_release_url_validate "$release_archive_url" v1.2.4; then exit 1; fi
if self_update_release_url_validate "https://github.com/example/shdome/releases/download/v1.2.3/other.tar.gz" v1.2.3; then exit 1; fi

bad_release_api="$TEST_ROOT/release-api-untrusted.json"
python3 - "$bad_release_api" <<'PY'
import json, sys
with open(sys.argv[1], "w", encoding="utf-8") as handle:
    json.dump({
        "tag_name": "v1.2.3", "draft": False, "prerelease": False,
        "assets": [
            {"name": "shdome-v1.2.3.tar.gz", "browser_download_url": "https://github.com/evil/repo/releases/download/v1.2.3/shdome-v1.2.3.tar.gz"},
            {"name": "shdome-v1.2.3.tar.gz.sha256", "browser_download_url": "https://github.com/evil/repo/releases/download/v1.2.3/shdome-v1.2.3.tar.gz.sha256"},
        ],
    }, handle)
PY
if self_update_parse_release_api "$bad_release_api" example/shdome >/dev/null 2>&1; then exit 1; fi
printf '%064d  shdome-v1.2.3.tar.gz\n%064d  shdome-v1.2.3.tar.gz\n' 0 1 >"$TEST_ROOT/duplicate.sha256"
if self_update_parse_checksum "$TEST_ROOT/duplicate.sha256" shdome-v1.2.3.tar.gz >/dev/null 2>&1; then exit 1; fi

(
    export SHDOME_INSTALLER_LIBRARY_ONLY=1
    export SHDOME_INSTALL_ROOT="$TEST_ROOT/installer"
    export MSYS=winsymlinks:sys
    SHDOME_INSTALL_OWNER_UID="$(id -u)"
    export SHDOME_INSTALL_OWNER_UID
    # shellcheck source=/dev/null
    source "$PROJECT_DIR/bootstrap/install.sh"
    mkdir -p "$INSTALL_ROOT/runtime/v1.2.3/bin"
    chmod 755 "$INSTALL_ROOT" "$INSTALL_ROOT/runtime"
    printf '#!/usr/bin/env bash\n' >"$INSTALL_ROOT/runtime/v1.2.3/bin/k"
    chmod 755 "$INSTALL_ROOT/runtime/v1.2.3/bin/k"
    ln -s "$INSTALL_ROOT/runtime/v1.2.3" "$INSTALL_ROOT/current"
    bootstrap_assert_secure_directory "$INSTALL_ROOT"
    bootstrap_assert_secure_directory "$INSTALL_ROOT/runtime"
    bootstrap_assert_current_link "$INSTALL_ROOT/current"
    bootstrap_release_url_validate "$release_archive_url" v1.2.3
    bootstrap_safe_link "$INSTALL_ROOT/current/bin/k" "$TEST_ROOT/k-link"
    [[ "$(readlink -f "$TEST_ROOT/k-link")" == "$INSTALL_ROOT/runtime/v1.2.3/bin/k" ]]
    ln -sfn "$TEST_ROOT" "$TEST_ROOT/foreign-link"
    if (bootstrap_safe_link "$INSTALL_ROOT/current/bin/k" "$TEST_ROOT/foreign-link") >/dev/null 2>&1; then exit 1; fi
    ln -s "$TEST_ROOT" "$INSTALL_ROOT/foreign-current"
    if (bootstrap_assert_current_link "$INSTALL_ROOT/foreign-current") >/dev/null 2>&1; then exit 1; fi
    printf 'existing\n' >"$TEST_ROOT/regular-file"
    if (bootstrap_safe_link "$INSTALL_ROOT/current/bin/k" "$TEST_ROOT/regular-file") >/dev/null 2>&1; then exit 1; fi

    malicious_archive="$TEST_ROOT/malicious-release.tar.gz"
    python3 - "$malicious_archive" <<'PY'
import io, tarfile, sys
with tarfile.open(sys.argv[1], "w:gz") as handle:
    value = tarfile.TarInfo("../outside")
    value.size = 4
    handle.addfile(value, io.BytesIO(b"evil"))
PY
    if (bootstrap_archive_validate "$malicious_archive" v1.2.3) >/dev/null 2>&1; then exit 1; fi
)

for manifest in "$PROJECT_DIR"/catalog/*.json; do
    manifest_validate "$manifest"
done
for manifest in "$PROJECT_DIR"/tests/fixtures/multi-app/*.json; do
    manifest_validate "$manifest"
done
for manifest in "$PROJECT_DIR"/tests/fixtures/failure-app/*.json; do
    manifest_validate "$manifest"
done

gitea_manifest="$PROJECT_DIR/catalog/gitea.json"
ports_json="$(manifest_ports_json "$gitea_manifest" http=3100 ssh=2223)"
[[ "$(ports_json_primary_host "$ports_json")" == "3100" ]]
[[ "$(ports_json_each "$ports_json" | wc -l | tr -d ' ')" == "2" ]]
ports_json_each "$ports_json" | grep -q $'ssh\t2223\t22\ttcp\tfalse'

env_file="$TEST_ROOT/zentao.env"
manifest_generate_env "$PROJECT_DIR/catalog/zentao.json" "$env_file"
grep -Eq '^ZT_MYSQL_PASSWORD=[a-f0-9]{48}$' "$env_file"
first_secret="$(cat "$env_file")"
manifest_generate_env "$PROJECT_DIR/catalog/zentao.json" "$env_file"
[[ "$(cat "$env_file")" == "$first_secret" ]]

cloudreve_dir="$TEST_ROOT/cloudreve"
manifest_prepare_volumes "$PROJECT_DIR/catalog/cloudreve.json" "$cloudreve_dir"
[[ -d "$cloudreve_dir/data/config" && -d "$cloudreve_dir/data/uploads" ]]
[[ -f "$cloudreve_dir/data/cloudreve.db" && ! -d "$cloudreve_dir/data/cloudreve.db" ]]
python3 - "$cloudreve_dir/data/cloudreve.db" <<'PY'
import sqlite3, sys
connection = sqlite3.connect(sys.argv[1])
connection.execute("CREATE TABLE settings (name TEXT PRIMARY KEY, value TEXT NOT NULL)")
connection.execute("INSERT INTO settings VALUES ('site_name', 'SHDome')")
connection.commit()
connection.close()
PY
logical_stage="$TEST_ROOT/logical-stage"
mkdir -p "$logical_stage"
logical_dump="$(backup_logical_dump_prepare "$PROJECT_DIR/catalog/cloudreve.json" "$cloudreve_dir" "$logical_stage")"
grep -q 'CREATE TABLE settings' "$logical_dump"
grep -q "INSERT INTO \"settings\" VALUES('site_name','SHDome');" "$logical_dump"
bad_backup_manifest="$TEST_ROOT/bad-backup-manifest.json"
python3 - "$PROJECT_DIR/catalog/cloudreve.json" "$bad_backup_manifest" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as handle:
    value = json.load(handle)
value["backup"]["logical"]["source"] = "uploads"
with open(sys.argv[2], "w", encoding="utf-8") as handle:
    json.dump(value, handle)
PY
if manifest_validate "$bad_backup_manifest" >/dev/null 2>&1; then exit 1; fi

app_dir="$SHDOME_APPS_DIR/gitea"
mkdir -p "$app_dir"
compose_generate "$gitea_manifest" "$ports_json" "$app_dir/compose.yml" 127.0.0.1
grep -q '127.0.0.1:3100:3000' "$app_dir/compose.yml"
grep -q '127.0.0.1:2223:22' "$app_dir/compose.yml"
SHDOME_FORCE_IPV6=1 compose_generate "$gitea_manifest" "$ports_json" "$app_dir/compose-ipv6.yml" 0.0.0.0
grep -q '\[::\]:3100:3000' "$app_dir/compose-ipv6.yml"
SHDOME_FORCE_IPV6=0 compose_generate "$gitea_manifest" "$ports_json" "$app_dir/compose-ipv4.yml" 0.0.0.0
if grep -q '\[::\]' "$app_dir/compose-ipv4.yml"; then exit 1; fi

state_write gitea "$gitea_manifest" "$ports_json" container-id image-digest
[[ "$(state_get gitea hostPort)" == "3100" ]]
[[ "$(state_get gitea containerPort)" == "3000" ]]
[[ "$(ports_json_each "$(state_ports_json gitea)" | wc -l | tr -d ' ')" == "2" ]]
(
    # shellcheck disable=SC2317
    docker_runtime_ready() { return 1; }
    # shellcheck disable=SC2317
    docker_compose() { touch "$TEST_ROOT/docker-action-continued"; }
    if app_compose_action gitea start >/dev/null 2>&1; then exit 1; fi
    [[ ! -e "$TEST_ROOT/docker-action-continued" ]]
)
install -m 600 "$gitea_manifest" "$app_dir/manifest.json"
printf 'TEST_SECRET=original\n' >"$app_dir/.env"
mkdir -p "$app_dir/data"
printf 'old-data\n' >"$app_dir/data/rollback-marker.txt"

(
    # shellcheck disable=SC2317
    docker() {
        if [[ "${1:-}" == "inspect" && "${2:-}" == "-f" ]]; then printf 'false\n'; return 0; fi
        return 1
    }
    # shellcheck disable=SC2317
    docker_compose() { :; }
    app_backup_locked gitea >/dev/null
    [[ -f "$SHDOME_LAST_BACKUP_ARCHIVE" && -f "$SHDOME_LAST_BACKUP_ARCHIVE.sha256" ]]
    backup_metadata_validate "$SHDOME_LAST_BACKUP_ARCHIVE" \
        "${SHDOME_LAST_BACKUP_ARCHIVE%.tar.gz}.metadata.json" "" gitea
)
backup_archives=("$SHDOME_BACKUP_DIR/apps/gitea/"*.tar.gz)
[[ "${#backup_archives[@]}" == "1" ]]
rollback_archive="${backup_archives[0]}"
before_backup_count="${#backup_archives[@]}"
(
    # shellcheck disable=SC2317
    docker() {
        if [[ "${1:-}" == "inspect" && "${2:-}" == "-f" ]]; then printf 'false\n'; return 0; fi
        return 1
    }
    # shellcheck disable=SC2317
    docker_compose() { :; }
    # shellcheck disable=SC2317
    backup_metadata_write() { return 1; }
    if app_backup_locked gitea >/dev/null 2>&1; then exit 1; fi
)
backup_archives=("$SHDOME_BACKUP_DIR/apps/gitea/"*.tar.gz)
[[ "${#backup_archives[@]}" == "$before_backup_count" ]]
if find "$SHDOME_BACKUP_DIR/apps/gitea" -mindepth 1 -maxdepth 1 -type d -name '.*' -print -quit | grep -q .; then exit 1; fi

printf 'new-data\n' >"$app_dir/data/rollback-marker.txt"
printf 'TEST_SECRET=changed\n' >"$app_dir/.env"
(
    # shellcheck disable=SC2317
    docker_compose() { :; }
    # shellcheck disable=SC2317
    app_healthcheck() { :; }
    app_update_restore_snapshot gitea "$rollback_archive" 1
)
grep -qx 'old-data' "$app_dir/data/rollback-marker.txt"
grep -qx 'TEST_SECRET=original' "$app_dir/.env"
if find "$SHDOME_APPS_DIR" -mindepth 1 -maxdepth 1 -type d -name '.failed-update-gitea-*' -print -quit | grep -q .; then exit 1; fi
(
    # shellcheck disable=SC2317
    docker_compose() { :; }
    restore_rollback_dir="$SHDOME_APPS_DIR/.restore-gitea-test"
    mv "$app_dir" "$restore_rollback_dir"
    mkdir -p "$app_dir/data"
    printf 'partial-restore\n' >"$app_dir/data/rollback-marker.txt"
    # shellcheck disable=SC2034
    SHDOME_RESTORE_ACTIVE=1
    # shellcheck disable=SC2034
    SHDOME_RESTORE_APP_ID=gitea
    # shellcheck disable=SC2034
    SHDOME_RESTORE_APP_DIR="$app_dir"
    # shellcheck disable=SC2034
    SHDOME_RESTORE_ROLLBACK_DIR="$restore_rollback_dir"
    app_restore_abort_cleanup
)
grep -qx 'old-data' "$app_dir/data/rollback-marker.txt"
[[ ! -e "$SHDOME_APPS_DIR/.restore-gitea-test" ]]

metadata_archive="$TEST_ROOT/20260901T000000Z.tar.gz"
metadata_nginx="$TEST_ROOT/20260901T000000Z.nginx.conf"
metadata_file="$TEST_ROOT/20260901T000000Z.metadata.json"
printf 'archive-content\n' >"$metadata_archive"
printf 'server {}\n' >"$metadata_nginx"
backup_metadata_write "$metadata_archive" "$metadata_nginx" "$(state_file_for gitea)" \
    "$metadata_file" "$TEST_ROOT/no-certificates"
backup_metadata_validate "$metadata_archive" "$metadata_file" "$metadata_nginx" gitea
python3 - "$metadata_file" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as handle:
    value = json.load(handle)
assert value["schema"] == 1
assert value["appId"] == "gitea"
assert value["archive"]["name"] == "20260901T000000Z.tar.gz"
assert len(value["archive"]["sha256"]) == 64
assert value["nginx"]["name"] == "20260901T000000Z.nginx.conf"
assert value["routing"]["accessMode"] == "direct"
assert value["certificateMetadata"] == {}
PY
printf 'tampered\n' >>"$metadata_archive"
if backup_metadata_validate "$metadata_archive" "$metadata_file" "$metadata_nginx" gitea >/dev/null 2>&1; then exit 1; fi
printf 'archive-content\n' >"$metadata_archive"
backup_metadata_validate "$metadata_archive" "$metadata_file" "$metadata_nginx" gitea

inspect_fixture="$TEST_ROOT/docker-inspect.json"
cat >"$inspect_fixture" <<'JSON'
[{"Config":{"Labels":{"io.shdome.managed":"true","io.shdome.app-id":"gitea"}},"NetworkSettings":{"Ports":{"3000/tcp":[{"HostPort":"3100"}],"22/tcp":[{"HostPort":"2223"}]}},"State":{"Status":"running"}}]
JSON
docker() {
    if [[ "${1:-}" == "inspect" ]]; then cat "$inspect_fixture"; return 0; fi
    return 1
}
app_reconcile_one gitea 0 | grep -q '一致'
sed -i 's/"3100"/"3999"/' "$inspect_fixture"
if app_reconcile_one gitea 0 >/dev/null 2>&1; then exit 1; fi

gateway_paths_init
[[ "$(stat -c '%a' "$SHDOME_GATEWAY_WEBROOT")" == "755" ]]
[[ "$(stat -c '%a' "$SHDOME_GATEWAY_WEBROOT/.well-known")" == "755" ]]
[[ "$(stat -c '%a' "$SHDOME_GATEWAY_WEBROOT/.well-known/acme-challenge")" == "755" ]]
http_config="$TEST_ROOT/example.http.conf"
https_config="$TEST_ROOT/example.https.conf"
gateway_write_http_candidate example.com 3100 "$http_config"
gateway_write_https_candidate example.com 3100 "$https_config"
grep -q 'proxy_pass http://127.0.0.1:3100;' "$http_config"
grep -q 'ssl_certificate /etc/letsencrypt/live/example.com/fullchain.pem;' "$https_config"
SHDOME_FORCE_IPV6=0 gateway_write_https_candidate example.com 3100 "$TEST_ROOT/no-ipv6.conf"
if grep -q '\[::\]' "$TEST_ROOT/no-ipv6.conf"; then exit 1; fi
SHDOME_FORCE_IPV6=1 gateway_write_https_candidate example.com 3100 "$TEST_ROOT/with-ipv6.conf"
grep -q 'listen \[::\]:443 ssl;' "$TEST_ROOT/with-ipv6.conf"

(
    # Certbot must support both optional email modes without passing an empty --email value.
    certbot_args="$TEST_ROOT/certbot-args"
    # shellcheck disable=SC2317
    docker() {
        [[ "${1:-}" == "run" ]] || return 0
        printf '%s\n' "$@" >"$certbot_args"
    }
    # shellcheck disable=SC2317
    certificate_validate() { :; }
    certificate_issue example.com ""
    grep -Fqx -- '--register-unsafely-without-email' "$certbot_args"
    if grep -Fqx -- '--email' "$certbot_args"; then exit 1; fi
    certificate_issue example.com admin@example.com
    grep -Fqx -- '--email' "$certbot_args"
    grep -Fqx -- 'admin@example.com' "$certbot_args"
    if grep -Fqx -- '--register-unsafely-without-email' "$certbot_args"; then exit 1; fi
)

(
    # A failed config test must prevent a live Nginx reload.
    # shellcheck disable=SC2317
    gateway_config_test() { return 1; }
    # shellcheck disable=SC2317
    docker() { touch "$TEST_ROOT/unexpected-gateway-reload"; }
    if gateway_reload >/dev/null 2>&1; then exit 1; fi
    [[ ! -e "$TEST_ROOT/unexpected-gateway-reload" ]]
)

(
    # A failed Certbot run must not validate stale certificates or reload Nginx.
    # shellcheck disable=SC2317
    gateway_paths_init() { :; }
    # shellcheck disable=SC2317
    gateway_container_running() { return 0; }
    # shellcheck disable=SC2317
    docker() { [[ "${1:-}" != "run" ]] || return 42; }
    # shellcheck disable=SC2317
    certificate_validate() { touch "$TEST_ROOT/unexpected-renew-validation"; }
    # shellcheck disable=SC2317
    gateway_reload() { touch "$TEST_ROOT/unexpected-renew-reload"; }
    if certificate_renew_all_locked >/dev/null 2>&1; then exit 1; fi
    [[ ! -e "$TEST_ROOT/unexpected-renew-validation" ]]
    [[ ! -e "$TEST_ROOT/unexpected-renew-reload" ]]
    if certificate_renew_one_locked example.com >/dev/null 2>&1; then exit 1; fi
    [[ ! -e "$TEST_ROOT/unexpected-renew-validation" ]]
    [[ ! -e "$TEST_ROOT/unexpected-renew-reload" ]]
)

(
    # Import failure after replacing files must restore both certificate and config.
    import_domain="import.example.com"
    gateway_paths_init
    import_live_dir="$SHDOME_GATEWAY_CERTS/live/$import_domain"
    import_config="$SHDOME_GATEWAY_CONF_DIR/$import_domain.conf"
    mkdir -p "$import_live_dir"
    printf 'old-certificate\n' >"$import_live_dir/fullchain.pem"
    printf 'old-private-key\n' >"$import_live_dir/privkey.pem"
    printf 'old-nginx-config\n' >"$import_config"
    printf 'new-certificate\n' >"$TEST_ROOT/import-new.crt"
    printf 'new-private-key\n' >"$TEST_ROOT/import-new.key"
    # shellcheck disable=SC2317
    gateway_ensure() { gateway_paths_init; }
    # shellcheck disable=SC2317
    certificate_validate_files() { :; }
    # shellcheck disable=SC2317
    certificate_validate() { :; }
    # shellcheck disable=SC2317
    gateway_commit_candidate() {
        mv -f "$1" "$SHDOME_GATEWAY_CONF_DIR/$2.conf"
        return 1
    }
    # shellcheck disable=SC2317
    app_switch_access_mode() { touch "$TEST_ROOT/unexpected-import-routing"; }
    # shellcheck disable=SC2317
    docker() { return 1; }
    if certificate_import_locked gitea "$import_domain" \
        "$TEST_ROOT/import-new.crt" "$TEST_ROOT/import-new.key" direct >/dev/null 2>&1; then
        exit 1
    fi
    grep -qx 'old-certificate' "$import_live_dir/fullchain.pem"
    grep -qx 'old-private-key' "$import_live_dir/privkey.pem"
    grep -qx 'old-nginx-config' "$import_config"
    [[ ! -e "$TEST_ROOT/unexpected-import-routing" ]]
    if find "$SHDOME_GATEWAY_DIR" -mindepth 1 -maxdepth 1 -type d -name ".cert-${import_domain}.rollback.*" -print -quit | grep -q .; then exit 1; fi
    if find "$import_live_dir" -mindepth 1 -maxdepth 1 -type f \( -name '.fullchain.*' -o -name '.privkey.*' \) -print -quit | grep -q .; then exit 1; fi
)

if command -v openssl >/dev/null 2>&1; then
    openssl req -x509 -nodes -newkey rsa:2048 -days 2 \
        -subj '/CN=example.com' -addext 'subjectAltName=DNS:example.com' \
        -keyout "$TEST_ROOT/example.key" -out "$TEST_ROOT/example.crt" >/dev/null 2>&1
    certificate_validate_files example.com "$TEST_ROOT/example.crt" "$TEST_ROOT/example.key"
fi

printf 'Helper smoke tests passed\n'
