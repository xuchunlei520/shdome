#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TEST_ROOT="$(mktemp -d /tmp/shdome-smoke.XXXXXX)"
trap 'rm -rf -- "$TEST_ROOT"' EXIT

export SHDOME_ROOT="$TEST_ROOT/runtime"
export SHDOME_ALLOW_NON_ROOT=1

version_output="$(bash "$PROJECT_DIR/src/shdome.sh" version)"
grep -q '^SHDome ' <<<"$version_output"
app_list_output="$(bash "$PROJECT_DIR/src/shdome.sh" app list)"
grep -q 'uptime-kuma' <<<"$app_list_output"
grep -q 'zentao' <<<"$app_list_output"
app_details_output="$(bash "$PROJECT_DIR/src/shdome.sh" app details cloudreve)"
grep -q 'Cloudreve' <<<"$app_details_output"
help_output="$(bash "$PROJECT_DIR/src/shdome.sh" help)"
grep -q 'k app install <id>' <<<"$help_output"
bash "$PROJECT_DIR/src/shdome.sh" app list --json | python3 -c 'import json,sys; data=json.load(sys.stdin); assert any(item["id"] == "gitea" and len(item["ports"]) == 2 for item in data)'
env_status_output="$(bash "$PROJECT_DIR/src/shdome.sh" env status)"
grep -q '数据目录' <<<"$env_status_output"
self_update_output="$(bash "$PROJECT_DIR/src/shdome.sh" self-update --version v9.9.9 \
    --url https://github.com/example/shdome/releases/download/v9.9.9/shdome-v9.9.9.tar.gz \
    --sha256 aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
    --check)"
grep -q '最新版本：v9.9.9' <<<"$self_update_output"

if bash "$PROJECT_DIR/src/shdome.sh" unknown-command >/dev/null 2>&1; then
    printf '未知命令应返回非零退出码\n' >&2
    exit 1
fi
if bash "$PROJECT_DIR/src/shdome.sh" app install zentao --port >/dev/null 2>&1; then
    printf '缺少 --port 值应返回非零退出码\n' >&2
    exit 1
fi
if bash "$PROJECT_DIR/src/shdome.sh" self-update --version >/dev/null 2>&1; then
    printf '不完整的更新参数应返回非零退出码\n' >&2
    exit 1
fi
if bash "$PROJECT_DIR/src/shdome.sh" app details does-not-exist >/dev/null 2>&1; then
    printf '不存在的应用详情应返回非零退出码\n' >&2
    exit 1
fi

printf 'CLI smoke tests passed\n'
