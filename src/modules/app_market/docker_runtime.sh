#!/usr/bin/env bash

docker_compose() {
    if docker compose version >/dev/null 2>&1; then
        docker compose "$@"
    elif command -v docker-compose >/dev/null 2>&1; then
        docker-compose "$@"
    else
        fail "Docker Compose 不可用，请执行 k env install" 69
    fi
}

docker_runtime_ready() {
    command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1 && \
        (docker compose version >/dev/null 2>&1 || command -v docker-compose >/dev/null 2>&1)
}

docker_runtime_install() {
    require_root || return
    require_linux || return
    if docker_runtime_ready; then
        success "Docker 与 Compose 已可用"
        return
    fi
    info "正在使用系统软件源安装 Docker 与 Compose"
    if command -v apt-get >/dev/null 2>&1; then
        apt-get update
        DEBIAN_FRONTEND=noninteractive apt-get install -y docker.io docker-compose-v2 || \
            DEBIAN_FRONTEND=noninteractive apt-get install -y docker.io docker-compose
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y docker docker-compose-plugin || dnf install -y docker docker-compose
    elif command -v yum >/dev/null 2>&1; then
        yum install -y docker docker-compose-plugin || yum install -y docker docker-compose
    elif command -v apk >/dev/null 2>&1; then
        apk add --no-cache docker docker-cli-compose
        rc-update add docker default >/dev/null 2>&1 || true
    else
        fail "不支持的包管理器，请手动安装 Docker Engine 和 Compose v2" 69
        return
    fi
    if command -v systemctl >/dev/null 2>&1; then
        systemctl enable --now docker
    else
        service docker start
    fi
    docker_runtime_ready || { fail "Docker 安装完成但服务不可用，请检查 systemctl status docker" 69; return; }
    success "Docker 与 Compose 安装完成"
}

docker_runtime_ensure() {
    local assume_yes="${1:-0}"
    docker_runtime_ready && return 0
    if [[ "$assume_yes" == "1" ]] || terminal_confirm "未检测到可用的 Docker/Compose，是否现在安装？"; then
        lock_run docker-install docker_runtime_install
    else
        fail "安装应用需要 Docker 与 Compose" 69
    fi
}

docker_runtime_status() {
    printf 'Docker CLI：%s\n' "$(command -v docker 2>/dev/null || printf '未安装')"
    if command -v docker >/dev/null 2>&1; then
        printf 'Docker 服务：%s\n' "$(docker info >/dev/null 2>&1 && printf '运行中' || printf '不可用')"
        printf 'Docker 版本：%s\n' "$(docker version --format '{{.Server.Version}}' 2>/dev/null || printf '未知')"
        printf 'Compose：%s\n' "$(docker compose version --short 2>/dev/null || docker-compose version --short 2>/dev/null || printf '未安装')"
    fi
    printf '数据目录：%s\n' "$SHDOME_ROOT"
}

host_ipv6_available() {
    [[ "${SHDOME_FORCE_IPV6:-}" != "1" ]] || return 0
    [[ "${SHDOME_FORCE_IPV6:-}" != "0" ]] || return 1
    [[ -s /proc/net/if_inet6 ]] && [[ "$(cat /proc/sys/net/ipv6/conf/all/disable_ipv6 2>/dev/null || printf '1')" == "0" ]]
}

compose_generate() {
    local manifest_file="$1" ports_json="$2" output_file="$3" bind_address="${4:-0.0.0.0}" app_dir publish_ipv6=0
    app_dir="$(dirname "$output_file")"
    [[ "$bind_address" == "0.0.0.0" || "$bind_address" == "127.0.0.1" ]] || { fail "无效绑定地址" 70; return; }
    [[ "$bind_address" != "0.0.0.0" ]] || ! host_ipv6_available || publish_ipv6=1
    python3 - "$manifest_file" "$ports_json" "$app_dir" "$output_file" "$bind_address" "$publish_ipv6" <<'PY'
import json, os, sys
manifest_path, ports_json, app_dir, output, bind_address, publish_ipv6 = sys.argv[1:]
with open(manifest_path, encoding="utf-8") as handle:
    item = json.load(handle)
ports = json.loads(ports_json)
service = item["services"]["app"]
def q(value):
    return json.dumps(str(value), ensure_ascii=False)
lines = [
    "services:",
    "  app:",
    f"    image: {q(service['image'])}",
    f"    container_name: {q(service['containerName'])}",
    "    restart: unless-stopped",
    "    labels:",
    "      io.shdome.managed: \"true\"",
    f"      io.shdome.app-id: {q(item['id'])}",
    "    ports:",
]
for port in ports:
    mapping = f"{bind_address}:{port['hostPort']}:{port['containerPort']}"
    if port.get("protocol", "tcp") != "tcp":
        mapping += "/" + port["protocol"]
    lines.append(f"      - {q(mapping)}")
    if publish_ipv6 == "1":
        ipv6_mapping = f"[::]:{port['hostPort']}:{port['containerPort']}"
        if port.get("protocol", "tcp") != "tcp":
            ipv6_mapping += "/" + port["protocol"]
        lines.append(f"      - {q(ipv6_mapping)}")
if item.get("secrets"):
    lines.extend(["    env_file:", "      - .env"])
environment = item.get("environment", {})
if environment:
    lines.append("    environment:")
    for key, value in sorted(environment.items()):
        lines.append(f"      {key}: {q(value)}")
volumes = item.get("volumes", [])
if volumes:
    lines.append("    volumes:")
    for volume in volumes:
        source = os.path.join(app_dir, "data", volume["source"])
        lines.append(f"      - {q(source + ':' + volume['target'])}")
with open(output, "w", encoding="utf-8") as handle:
    handle.write("\n".join(lines) + "\n")
PY
    chmod 600 "$output_file"
}
