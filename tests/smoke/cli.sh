#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TEST_ROOT="$(mktemp -d /tmp/shdome-smoke.XXXXXX)"
trap 'rm -rf -- "$TEST_ROOT"' EXIT

export SHDOME_ROOT="$TEST_ROOT/runtime"
export SHDOME_ALLOW_NON_ROOT=1

version_output="$(bash "$PROJECT_DIR/src/shdome.sh" version)"
grep -q '^SHDome ' <<<"$version_output"

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
    fake_bin="$TEST_ROOT/fake-bin"
    mkdir -p "$fake_bin"
    printf '%s\n' '#!/usr/bin/env bash' 'printf "sudo-arg=%s\\n" "$@"' >"$fake_bin/sudo"
    chmod 755 "$fake_bin/sudo"
    elevation_output="$(env -u SHDOME_ALLOW_NON_ROOT PATH="$fake_bin:$PATH" \
        bash "$PROJECT_DIR/src/shdome.sh" app installed)"
    grep -q '^sudo-arg=-H$' <<<"$elevation_output"
    grep -Fxq "sudo-arg=$PROJECT_DIR/src/shdome.sh" <<<"$elevation_output"
    grep -q '^sudo-arg=installed$' <<<"$elevation_output"

    restricted_root="$TEST_ROOT/restricted"
    mkdir -p "$restricted_root/apps"
    chmod 000 "$restricted_root/apps"
    if permission_output="$(SHDOME_ROOT="$restricted_root" SHDOME_ALLOW_NON_ROOT=1 \
        bash "$PROJECT_DIR/src/shdome.sh" app installed 2>&1)"; then
        printf '不可读状态目录不应报告为空\n' >&2
        exit 1
    fi
    grep -q '无法读取应用状态目录' <<<"$permission_output"
    chmod 700 "$restricted_root/apps"
fi

app_list_output="$(bash "$PROJECT_DIR/src/shdome.sh" app list)"
grep -q '序号.*名称.*版本.*状态.*说明' <<<"$app_list_output"
grep -q 'Uptime Kuma.*轻量易用的服务可用性监控面板' <<<"$app_list_output"
grep -q '禅道.*项目管理与研发协作平台' <<<"$app_list_output"
if grep -q '应用 ID' <<<"$app_list_output"; then
    printf '应用市场不应显示应用 ID 列\n' >&2
    exit 1
fi
narrow_app_list_output="$(COLUMNS=72 bash "$PROJECT_DIR/src/shdome.sh" app list)"
python3 - "$narrow_app_list_output" <<'PY'
import sys
import unicodedata

output = sys.argv[1]


def width(value):
    result = 0
    for character in value:
        if unicodedata.combining(character) or unicodedata.category(character) in {"Cf", "Me"}:
            continue
        result += 2 if unicodedata.east_asian_width(character) in {"W", "F"} else 1
    return result


lines = output.splitlines()
assert all(width(line) <= 72 for line in lines), output
header = next(line for line in lines if "序号" in line and "说明" in line)
expected_columns = [width(header[:header.index(label)]) for label in ["序号", "名称", "版本", "状态", "说明"]]
for name in ["Cloudreve", "青龙面板", "Uptime Kuma", "禅道"]:
    line = next(line for line in lines if name in line)
    fields = [line.index(name), line.index(next(value for value in ["3.8.3", "2.17.12", "1.23.16", "21.7"] if value in line))]
    assert width(line[:fields[0]]) == expected_columns[1], line
    assert width(line[:fields[1]]) == expected_columns[2], line
gitea_start = next(index for index, line in enumerate(lines) if "Gitea" in line)
gitea_end = next(index for index in range(gitea_start + 1, len(lines)) if lines[index].startswith("3"))
gitea_block = "".join(lines[gitea_start:gitea_end]).replace(" ", "")
assert "轻量级自托管Git服务，示范Web与SSH多端口部署" in gitea_block, output
PY
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
