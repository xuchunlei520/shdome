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
[[ "$(catalog_resolve_selector 1)" == "alist" ]]
[[ "$(catalog_resolve_selector Cloudreve)" == "cloudreve" ]]
[[ "$(catalog_resolve_selector 7)" == "uptime-kuma" ]]
[[ "$(catalog_resolve_selector 'Uptime Kuma')" == "uptime-kuma" ]]
[[ "$(catalog_resolve_selector 禅道)" == "zentao" ]]
if catalog_resolve_selector uptime-kuma >/dev/null 2>&1; then exit 1; fi
if catalog_resolve_selector does-not-exist >/dev/null 2>&1; then exit 1; fi
(
    selections=(7 0)
    selection_index=0
    managed_app=""
    # shellcheck disable=SC2317,SC2030
    terminal_read() {
        local target_variable="$1"
        printf -v "$target_variable" '%s' "${selections[$selection_index]}"
        selection_index=$((selection_index + 1))
    }
    # shellcheck disable=SC2317
    app_list() { return 0; }
    # shellcheck disable=SC2317
    state_exists() { return 0; }
    # shellcheck disable=SC2317
    app_manage_menu() { managed_app="$1"; }
    app_market_menu >/dev/null
    [[ "$managed_app" == "uptime-kuma" ]]
)
(
    selections=(7 0)
    selection_index=0
    installed_app=""
    # shellcheck disable=SC2317,SC2030
    terminal_read() {
        local target_variable="$1"
        printf -v "$target_variable" '%s' "${selections[$selection_index]}"
        selection_index=$((selection_index + 1))
    }
    # shellcheck disable=SC2317
    app_list() { return 0; }
    # shellcheck disable=SC2317
    state_exists() { return 1; }
    # shellcheck disable=SC2317
    app_install() { installed_app="$1"; }
    # shellcheck disable=SC2317
    terminal_pause() { :; }
    app_market_menu >/dev/null
    [[ "$installed_app" == "uptime-kuma" ]]
)
(
    selections=(1 2 3 5 6 7 8 0)
    selection_index=0
    action_file="$TEST_ROOT/app-menu-actions"
    # shellcheck disable=SC2317,SC2030
    terminal_read() {
        local target_variable="$1"
        printf -v "$target_variable" '%s' "${selections[$selection_index]}"
        selection_index=$((selection_index + 1))
    }
    # shellcheck disable=SC2317
    terminal_pause() { :; }
    # shellcheck disable=SC2317
    app_runtime_status() { printf '运行中'; }
    # shellcheck disable=SC2317
    state_exists() { return 0; }
    # shellcheck disable=SC2317
    state_get() {
        case "$2" in
            domain) printf 'app.example.com' ;;
            accessMode) printf 'domain_only' ;;
        esac
    }
    # shellcheck disable=SC2317
    app_install() { printf 'install:%s\n' "$*" >>"$action_file"; }
    # shellcheck disable=SC2317
    app_update() { printf 'update:%s\n' "$*" >>"$action_file"; }
    # shellcheck disable=SC2317
    app_remove() { printf 'remove:%s\n' "$*" >>"$action_file"; }
    # shellcheck disable=SC2317
    app_domain() { printf 'domain:%s\n' "$*" >>"$action_file"; }
    # shellcheck disable=SC2317
    app_access_mode() { printf 'access:%s\n' "$*" >>"$action_file"; }
    app_manage_menu uptime-kuma >/dev/null
    expected_actions="$(printf '%s\n' \
        'install:uptime-kuma' \
        'update:uptime-kuma' \
        'remove:uptime-kuma' \
        'domain:uptime-kuma --configure --access domain-only' \
        'domain:uptime-kuma --remove' \
        'access:uptime-kuma direct' \
        'access:uptime-kuma domain-only')"
    actual_actions="$(<"$action_file")"
    [[ "$actual_actions" == "$expected_actions" ]]
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
(
    # shellcheck disable=SC2317
    port_available_for_auto() { [[ "$1" == "18084" ]]; }
    [[ "$(port_find_available 18082 demo-app '')" == "18084" ]]
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

image_source_is_docker_hub redis:7-alpine
image_source_is_docker_hub vaultwarden/server:1.37.2-alpine
image_source_is_docker_hub docker.io/library/redis:7-alpine
if image_source_is_docker_hub ghcr.io/example/demo:1.0.0; then exit 1; fi
if image_source_is_docker_hub localhost:5000/example/demo:1.0.0; then exit 1; fi
[[ "$(image_source_docker_hub_repository redis:7-alpine)" == "library/redis:7-alpine" ]]
[[ "$(image_source_docker_hub_repository docker.io/example/demo:1.0.0)" == "example/demo:1.0.0" ]]
[[ "$(image_source_mirror_reference redis:7-alpine https://mirror.example.com)" == "mirror.example.com/library/redis:7-alpine" ]]
[[ "$(image_source_url_normalize https://Mirror.Example.com/)" == "https://mirror.example.com" ]]
for invalid_mirror in \
    http://mirror.example.com \
    https://user:password@mirror.example.com \
    https://mirror.example.com/path \
    'https://mirror.example.com/?token=secret' \
    'https://mirror.example.com/#fragment'; do
    if image_source_url_normalize "$invalid_mirror" >/dev/null 2>&1; then exit 1; fi
done

image_source_config_write official ""
policy_rows="$(image_source_policy_rows_safe)"
[[ "$(head -n 1 <<<"$policy_rows")" == $'POLICY\tofficial\t' ]]
[[ "$(image_source_pull_order)" == $'官方源\tofficial\t' ]]
image_source_command set https://manual.example.com >/dev/null
policy_rows="$(image_source_policy_rows_safe)"
[[ "$(head -n 1 <<<"$policy_rows")" == $'POLICY\tmanual\thttps://manual.example.com' ]]
[[ "$(stat -c '%a' "$SHDOME_IMAGE_SOURCE_CONFIG")" == "640" ]]
image_source_command auto >/dev/null
policy_rows="$(image_source_policy_rows_safe)"
[[ "$(head -n 1 <<<"$policy_rows")" == $'POLICY\tauto\t' ]]
printf '%s\n' '{"schema":1,"mode":"auto","manualMirror":"","mirrors":["http://unsafe.example.com"]}' >"$SHDOME_IMAGE_SOURCE_CONFIG"
image_source_config_write auto ""
python3 -c 'import json,sys; value=json.load(open(sys.argv[1])); assert value["mirrors"] == []' "$SHDOME_IMAGE_SOURCE_CONFIG"

(
    # shellcheck disable=SC2030
    export SHDOME_IMAGE_SOURCE_STATE="$TEST_ROOT/image-source-fast-official-state.json"
    probe_log="$TEST_ROOT/image-source-fast-official-probes.log"
    # shellcheck disable=SC2317
    image_source_probe() {
        printf '%s\n' "$1" >>"$probe_log"
        case "$1" in
            https://registry-1.docker.io) printf '100\n' ;;
            https://docker.1ms.run) printf '40\n' ;;
            https://docker.m.daocloud.io) printf '30\n' ;;
            *) return 1 ;;
        esac
    }
    fast_order="$(image_source_pull_order)"
    [[ "$(head -n 1 <<<"$fast_order")" == $'官方源\tofficial\t100' ]]
    [[ "$(wc -l <"$probe_log")" == "1" ]]
)
(
    # shellcheck disable=SC2030,SC2031
    export SHDOME_IMAGE_SOURCE_STATE="$TEST_ROOT/image-source-slow-official-state.json"
    # shellcheck disable=SC2317
    image_source_probe() {
        case "$1" in
            https://registry-1.docker.io) printf '4500\n' ;;
            https://docker.1ms.run) printf '80\n' ;;
            https://docker.m.daocloud.io) printf '25\n' ;;
            *) return 1 ;;
        esac
    }
    slow_order="$(image_source_pull_order)"
    [[ "$(head -n 1 <<<"$slow_order")" == $'docker.m.daocloud.io\thttps://docker.m.daocloud.io\t25' ]]
    [[ "$(tail -n 1 <<<"$slow_order")" == $'官方源\tofficial\t4500' ]]
)

(
    pull_log="$TEST_ROOT/image-source-pull.log"
    # shellcheck disable=SC2030,SC2031
    export SHDOME_IMAGE_SOURCE_STATE="$TEST_ROOT/image-source-fallback-state.json"
    # shellcheck disable=SC2317
    image_source_pull_order() {
        printf '%s\n' \
            $'官方源\tofficial\t20' \
            $'测试镜像源\thttps://mirror.example.com\t30'
    }
    # shellcheck disable=SC2317
    docker() {
        case "${1:-}" in
            pull)
                printf 'pull\t%s\n' "$2" >>"$pull_log"
                [[ "$2" == mirror.example.com/library/redis:7-alpine ]]
                ;;
            tag) printf 'tag\t%s\t%s\n' "$2" "$3" >>"$pull_log" ;;
            image) return 0 ;;
            *) return 1 ;;
        esac
    }
    image_source_pull redis:7-alpine >/dev/null 2>&1
    image_source_pull redis:7-alpine >/dev/null 2>&1
    [[ "$(grep -c '^pull' "$pull_log")" == "2" ]]
    grep -Fxq $'pull\tredis:7-alpine' "$pull_log"
    grep -Fxq $'pull\tmirror.example.com/library/redis:7-alpine' "$pull_log"
    grep -Fxq $'tag\tmirror.example.com/library/redis:7-alpine\tredis:7-alpine' "$pull_log"
    python3 -c 'import json,sys; value=json.load(open(sys.argv[1])); assert value["selected"] == "https://mirror.example.com"' "$SHDOME_IMAGE_SOURCE_STATE"
)
(
    # shellcheck disable=SC2030,SC2031
    export SHDOME_IMAGE_SOURCE_STATE="$TEST_ROOT/image-source-cache-state.json"
    # shellcheck disable=SC2317
    image_source_pull_order() { printf '%s\n' $'官方源\tofficial\t20'; }
    # shellcheck disable=SC2317
    docker() {
        case "${1:-} ${2:-}" in
            'pull redis:7-alpine') return 1 ;;
            'image inspect') return 0 ;;
            *) return 1 ;;
        esac
    }
    image_source_pull redis:7-alpine >/dev/null 2>&1
    python3 -c 'import json,sys; value=json.load(open(sys.argv[1])); assert value["selected"] == "cache"' "$SHDOME_IMAGE_SOURCE_STATE"
)
(
    pull_log="$TEST_ROOT/image-source-private.log"
    # shellcheck disable=SC2030,SC2031
    export SHDOME_IMAGE_SOURCE_STATE="$TEST_ROOT/image-source-private-state.json"
    # shellcheck disable=SC2317
    docker() {
        printf '%s\n' "$*" >>"$pull_log"
        return 1
    }
    if image_source_pull ghcr.io/example/private:1.0.0 >/dev/null 2>&1; then exit 1; fi
    [[ "$(wc -l <"$pull_log")" == "2" ]]
    grep -Fxq 'pull ghcr.io/example/private:1.0.0' "$pull_log"
    grep -Fxq 'image inspect ghcr.io/example/private:1.0.0' "$pull_log"
)
(
    pull_log="$TEST_ROOT/image-source-authenticated.log"
    docker_config="$TEST_ROOT/docker-config"
    mkdir -p "$docker_config"
    printf '%s\n' '{"auths":{"https://index.docker.io/v1/":{"auth":"redacted"}}}' >"$docker_config/config.json"
    # shellcheck disable=SC2030
    export DOCKER_CONFIG="$docker_config"
    # shellcheck disable=SC2030,SC2031
    export SHDOME_IMAGE_SOURCE_STATE="$TEST_ROOT/image-source-authenticated-state.json"
    # shellcheck disable=SC2317
    docker() {
        printf '%s\n' "$*" >>"$pull_log"
        [[ "${1:-}" == "pull" ]]
    }
    image_source_pull private-example:1.0.0 >/dev/null
    [[ "$(wc -l <"$pull_log")" == "1" ]]
    grep -Fxq 'pull private-example:1.0.0' "$pull_log"
)
image_source_state_record https://docker.1ms.run failed "" timeout
image_source_state_record https://docker.1ms.run failed "" timeout
image_source_state_in_cooldown https://docker.1ms.run
image_source_status | grep -q 'https://docker.1ms.run：拉取失败.*连续失败 2 次'
image_source_state_record https://docker.1ms.run success 25
if image_source_state_in_cooldown https://docker.1ms.run; then exit 1; fi
(
    # shellcheck disable=SC2317
    curl() {
        [[ "$*" != *registry-1.docker.io* ]] || return 1
        printf '200\t0.050\n'
    }
    image_source_test >"$TEST_ROOT/image-source-test-output"
    grep -q 'Docker Hub 官方源.*不可用' "$TEST_ROOT/image-source-test-output"
    grep -q 'docker.1ms.run.*可用' "$TEST_ROOT/image-source-test-output"
)
image_source_command reset >/dev/null
# shellcheck disable=SC2031
[[ ! -e "$SHDOME_IMAGE_SOURCE_CONFIG" && ! -e "$SHDOME_IMAGE_SOURCE_STATE" ]]

custom_inspect="$TEST_ROOT/custom-image-inspect.json"
custom_no_port_inspect="$TEST_ROOT/custom-image-no-port.json"
custom_candidate="$TEST_ROOT/custom-demo.json"
cat >"$custom_inspect" <<'JSON'
[{"Config":{"ExposedPorts":{"8080/tcp":{},"9090/tcp":{}},"Volumes":{"/app/data":{}}}}]
JSON
printf '[{"Config":{"ExposedPorts":{},"Volumes":{}}}]\n' >"$custom_no_port_inspect"
custom_generate_manifest "$custom_inspect" "$custom_candidate" \
    example/custom-demo:1.2.3 custom-demo "Custom Demo" amd64 8080 18090
manifest_validate "$custom_candidate"
latest_manifest="$TEST_ROOT/custom-latest.json"
python3 - "$custom_candidate" "$latest_manifest" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as handle:
    value = json.load(handle)
value["services"]["app"]["image"] = "example/custom-demo:latest"
with open(sys.argv[2], "w", encoding="utf-8") as handle:
    json.dump(value, handle)
PY
if manifest_validate "$latest_manifest" >/dev/null 2>&1; then exit 1; fi
dangerous_manifest="$TEST_ROOT/custom-dangerous.json"
python3 - "$custom_candidate" "$dangerous_manifest" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as handle:
    value = json.load(handle)
value["services"]["app"]["privileged"] = True
with open(sys.argv[2], "w", encoding="utf-8") as handle:
    json.dump(value, handle)
PY
if manifest_validate "$dangerous_manifest" >/dev/null 2>&1; then exit 1; fi
custom_manifest_install "$custom_candidate" 1
[[ -f "$SHDOME_CUSTOM_CATALOG_DIR/custom-demo.json" ]]
[[ "$(catalog_manifest_source "$(catalog_manifest_path custom-demo)")" == "我的" ]]
app_list_json | python3 -c 'import json,sys; value=json.load(sys.stdin); item=next(x for x in value if x["id"] == "custom-demo"); assert item["source"] == "custom" and item["ports"][0]["defaultHostPort"] == 18090'
custom_validate custom-demo >/dev/null
custom_export custom-demo "$TEST_ROOT/custom-export.json" >/dev/null
python3 - "$SHDOME_CUSTOM_CATALOG_DIR/custom-demo.json" "$TEST_ROOT/custom-export.json" <<'PY'
import pathlib, sys
assert pathlib.Path(sys.argv[1]).read_bytes() == pathlib.Path(sys.argv[2]).read_bytes()
PY
if custom_manifest_install "$PROJECT_DIR/catalog/uptime-kuma.json" 1 >/dev/null 2>&1; then exit 1; fi
mkdir -p "$SHDOME_APPS_DIR/custom-demo"
printf '{}\n' >"$SHDOME_APPS_DIR/custom-demo/state.json"
if custom_delete custom-demo --yes >/dev/null 2>&1; then exit 1; fi
rm -f -- "$SHDOME_APPS_DIR/custom-demo/state.json"
custom_delete custom-demo --yes >/dev/null
[[ ! -e "$SHDOME_CUSTOM_CATALOG_DIR/custom-demo.json" ]]
(
    # shellcheck disable=SC2317
    image_source_pull() { docker pull "$1"; }
    # shellcheck disable=SC2317
    docker() {
        case "${1:-} ${2:-}" in
            'info '|"pull "*) return 0 ;;
            'image inspect')
                if [[ "${3:-}" == example/no-port:* ]]; then cat "$custom_no_port_inspect"; else cat "$custom_inspect"; fi
                ;;
            *) return 1 ;;
        esac
    }
    custom_add example/quick-app:1.0.0 --host-port 18091 --no-install --yes >/dev/null
    custom_add example/quick-app:1.0.1 --host-port 18091 --no-install --yes >/dev/null
    if custom_add example/no-port:1.0.0 --no-install --yes >/dev/null 2>&1; then exit 1; fi
)
(
    # shellcheck disable=SC2317
    image_source_pull() { docker pull "$1" || docker image inspect "$1" >/dev/null; }
    # shellcheck disable=SC2317
    docker() {
        case "${1:-} ${2:-}" in
            'info ') return 0 ;;
            'pull ') return 1 ;;
            'image inspect') cat "$custom_inspect" ;;
            *) return 1 ;;
        esac
    }
    custom_add example/cached-app:1.0.0 --no-install --yes >/dev/null
)
(
    # shellcheck disable=SC2317
    image_source_pull() { return 0; }
    app_compose_pull_or_cached /tmp/compose.yml shdome-cached example/cached-app:1.0.0 >/dev/null
)
(
    # shellcheck disable=SC2317
    image_source_pull() { return 1; }
    if app_compose_pull_or_cached /tmp/compose.yml shdome-missing example/missing:1.0.0 >/dev/null 2>&1; then exit 1; fi
)
[[ -f "$SHDOME_CUSTOM_CATALOG_DIR/quick-app.json" ]]
[[ "$(manifest_get "$SHDOME_CUSTOM_CATALOG_DIR/quick-app.json" routing.defaultHostPort)" == "18091" ]]
[[ "$(manifest_get "$SHDOME_CUSTOM_CATALOG_DIR/quick-app.json" version)" == "1.0.1" ]]
custom_delete quick-app --yes >/dev/null
[[ -f "$SHDOME_CUSTOM_CATALOG_DIR/cached-app.json" ]]
custom_delete cached-app --yes >/dev/null

if command -v openssl >/dev/null 2>&1; then
    catalog_private_key="$TEST_ROOT/catalog-private.pem"
    catalog_public_key="$TEST_ROOT/catalog-public.pem"
    catalog_archive="$TEST_ROOT/catalog-test.tar.gz"
    catalog_signature="$TEST_ROOT/catalog-test.tar.gz.sig"
    catalog_extract="$TEST_ROOT/catalog-extract"
    openssl genpkey -algorithm ED25519 -out "$catalog_private_key" >/dev/null 2>&1
    openssl pkey -in "$catalog_private_key" -pubout -out "$catalog_public_key" >/dev/null 2>&1
    tar -czf "$catalog_archive" -C "$PROJECT_DIR/catalog" .
    openssl pkeyutl -sign -inkey "$catalog_private_key" -rawin -in "$catalog_archive" -out "$catalog_signature"
    catalog_signature_verify "$catalog_archive" "$catalog_signature" "$catalog_public_key"
    catalog_archive_extract "$catalog_archive" "$catalog_extract"
    catalog_release_validate "$catalog_extract"
    malicious_catalog="$TEST_ROOT/malicious-catalog.tar.gz"
    python3 - "$malicious_catalog" <<'PY'
import tarfile, sys
with tarfile.open(sys.argv[1], "w:gz") as handle:
    link = tarfile.TarInfo("escape.json")
    link.type = tarfile.SYMTYPE
    link.linkname = "../outside.json"
    handle.addfile(link)
PY
    if catalog_archive_extract "$malicious_catalog" "$TEST_ROOT/malicious-extract" >/dev/null 2>&1; then exit 1; fi

    tls_key="$TEST_ROOT/catalog-server.key"
    tls_cert="$TEST_ROOT/catalog-server.crt"
    openssl req -x509 -nodes -newkey rsa:2048 -days 1 -subj '/CN=127.0.0.1' \
        -addext 'subjectAltName=IP:127.0.0.1' -keyout "$tls_key" -out "$tls_cert" >/dev/null 2>&1
    python3 - "$TEST_ROOT" "$tls_cert" "$tls_key" <<'PY' >"$TEST_ROOT/catalog-server.log" 2>&1 &
import http.server, os, ssl, sys
directory, certificate, private_key = sys.argv[1:]
os.chdir(directory)
server = http.server.ThreadingHTTPServer(("127.0.0.1", 18443), http.server.SimpleHTTPRequestHandler)
context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
context.load_cert_chain(certificate, private_key)
server.socket = context.wrap_socket(server.socket, server_side=True)
server.serve_forever()
PY
    # shellcheck disable=SC2031
    catalog_server_pid=$!
    export NO_PROXY=127.0.0.1
    catalog_server_ready=0
    for _ in {1..20}; do
        if curl --connect-timeout 1 --max-time 2 --cacert "$tls_cert" -fsS https://127.0.0.1:18443/catalog-test.tar.gz -o /dev/null; then
            catalog_server_ready=1
            break
        fi
        sleep 0.1
    done
    if [[ "$catalog_server_ready" != "1" ]]; then
        cat "$TEST_ROOT/catalog-server.log" >&2
        kill "$catalog_server_pid" >/dev/null 2>&1 || true
        wait "$catalog_server_pid" 2>/dev/null || true
        exit 1
    fi
    refresh_status=0
    CURL_CA_BUNDLE="$tls_cert" catalog_refresh \
        --url https://127.0.0.1:18443/catalog-test.tar.gz \
        --signature-url https://127.0.0.1:18443/catalog-test.tar.gz.sig \
        --public-key "$catalog_public_key" --version test-remote >/dev/null || refresh_status=$?
    kill "$catalog_server_pid" >/dev/null 2>&1 || true
    wait "$catalog_server_pid" 2>/dev/null || true
    [[ "$refresh_status" == "0" ]]
    [[ "$(readlink "$SHDOME_OFFICIAL_CATALOG_ROOT/current")" == "releases/test-remote" ]]
    [[ "$(catalog_official_dir)" == "$SHDOME_OFFICIAL_RELEASES_DIR/test-remote" ]]

    printf 'tampered\n' >>"$catalog_archive"
    if catalog_signature_verify "$catalog_archive" "$catalog_signature" "$catalog_public_key"; then exit 1; fi

    first_release="$TEST_ROOT/catalog-release-one"
    second_release="$TEST_ROOT/catalog-release-two"
    cp -a "$catalog_extract" "$first_release"
    cp -a "$catalog_extract" "$second_release"
    catalog_release_activate "$first_release" test-v1 https://example.com/catalog-v1.tar.gz "$(printf '%064d' 1)"
    [[ "$(readlink "$SHDOME_OFFICIAL_CATALOG_ROOT/current")" == "releases/test-v1" ]]
    catalog_release_activate "$second_release" test-v2 https://example.com/catalog-v2.tar.gz "$(printf '%064d' 2)"
    [[ "$(readlink "$SHDOME_OFFICIAL_CATALOG_ROOT/current")" == "releases/test-v2" ]]
    [[ "$(readlink "$SHDOME_OFFICIAL_CATALOG_ROOT/previous")" == "releases/test-v1" ]]
    catalog_rollback >/dev/null
    [[ "$(readlink "$SHDOME_OFFICIAL_CATALOG_ROOT/current")" == "releases/test-v1" ]]
fi

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
