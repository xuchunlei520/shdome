#!/usr/bin/env bash

system_distribution() {
    local os_id="unknown" os_version="unknown"
    if [[ -r /etc/os-release ]]; then
        os_id="$(awk -F= '$1 == "ID" {gsub(/^"|"$/, "", $2); print tolower($2)}' /etc/os-release)"
        os_version="$(awk -F= '$1 == "VERSION_ID" {gsub(/^"|"$/, "", $2); print $2}' /etc/os-release)"
    fi
    printf '%s\t%s\n' "$os_id" "$os_version"
}

require_supported_distribution() {
    local os_id os_version
    IFS=$'\t' read -r os_id os_version < <(system_distribution)
    case "$os_id" in
        ubuntu|debian|rocky|almalinux|alpine) return 0 ;;
        *) fail "不支持的 Linux 发行版：$os_id ${os_version:-}" 69 ;;
    esac
}

normalized_architecture() {
    case "$(uname -m)" in
        x86_64|amd64) printf 'amd64\n' ;;
        aarch64|arm64) printf 'arm64\n' ;;
        *) printf 'unsupported\n' ;;
    esac
}

network_endpoint_reachable() {
    local url="$1"
    curl -sSIL --max-time 8 --connect-timeout 5 "$url" >/dev/null 2>&1
}

system_time_status() {
    if command -v timedatectl >/dev/null 2>&1; then
        local synced
        synced="$(timedatectl show -p NTPSynchronized --value 2>/dev/null || true)"
        [[ "$synced" == "yes" ]] && printf '已同步' || printf '未确认同步'
    elif command -v chronyc >/dev/null 2>&1 && chronyc tracking >/dev/null 2>&1; then
        printf 'chrony 正常'
    else
        printf '无法检测'
    fi
}

environment_check() {
    local failures=0 os_id os_version arch disk_mb memory_mb swap_mb
    require_linux || return
    IFS=$'\t' read -r os_id os_version < <(system_distribution)
    arch="$(normalized_architecture)"
    disk_mb="$(df -Pk "$SHDOME_ROOT" 2>/dev/null | awk 'NR == 2 {print int($4 / 1024)}')"
    memory_mb="$(awk '/^MemAvailable:/ {print int($2 / 1024)}' /proc/meminfo)"
    swap_mb="$(awk '/^SwapTotal:/ {print int($2 / 1024)}' /proc/meminfo)"

    printf '权限：%s\n' "$([[ ${EUID:-$(id -u)} -eq 0 ]] && printf 'root' || printf '非 root（管理操作不可用）')"
    case "$os_id" in
        ubuntu|debian|rocky|almalinux|alpine) printf '系统：%s %s（支持）\n' "$os_id" "$os_version" ;;
        *) printf '系统：%s %s（不支持）\n' "$os_id" "$os_version"; failures=$((failures + 1)) ;;
    esac
    if [[ "$arch" == "unsupported" ]]; then
        printf '架构：%s（不支持）\n' "$(uname -m)"
        failures=$((failures + 1))
    else
        printf '架构：%s\n' "$arch"
    fi
    printf '可用内存：%s MB\n' "${memory_mb:-未知}"
    printf 'Swap：%s MB\n' "${swap_mb:-未知}"
    printf '可用磁盘：%s MB（%s）\n' "${disk_mb:-未知}" "$SHDOME_ROOT"
    printf '系统时间：%s\n' "$(system_time_status)"

    if network_endpoint_reachable https://api.github.com/; then
        printf 'GitHub：可访问\n'
    else
        printf 'GitHub：不可访问\n'
        failures=$((failures + 1))
    fi
    if network_endpoint_reachable https://registry-1.docker.io/v2/; then
        printf 'Docker Hub：可访问\n'
    else
        printf 'Docker Hub：未确认（401 响应也可能表示网络正常）\n'
    fi
    printf 'Docker：%s\n' "$(docker_runtime_ready && printf '可用' || printf '未就绪')"
    printf '80 端口：%s\n' "$(port_listening 80 && printf '已占用' || printf '空闲')"
    printf '443 端口：%s\n' "$(port_listening 443 && printf '已占用' || printf '空闲')"
    if command -v ufw >/dev/null 2>&1; then
        printf '防火墙：ufw %s\n' "$(ufw status 2>/dev/null | awk 'NR == 1 {$1=""; sub(/^ /, ""); print}' || printf '未知')"
    elif command -v firewall-cmd >/dev/null 2>&1; then
        printf '防火墙：firewalld %s\n' "$(firewall-cmd --state 2>/dev/null || printf '未运行')"
    else
        printf '防火墙：未检测到 ufw/firewalld，请同时检查云安全组\n'
    fi
    ((failures == 0)) || fail "环境检查发现 $failures 项阻塞问题" 69
}

docker_managed_containers() {
    docker_runtime_ready || { fail "Docker 服务不可用" 69; return; }
    printf 'SHDome 管理的容器：\n'
    docker ps -a --filter label=io.shdome.managed=true --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'
    printf '\n外部容器：\n'
    docker ps -a --filter label=io.shdome.managed!=true --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'
}

docker_images() {
    docker_runtime_ready || { fail "Docker 服务不可用" 69; return; }
    docker image ls --digests
}

docker_networks() {
    docker_runtime_ready || { fail "Docker 服务不可用" 69; return; }
    docker network ls
}

docker_resource_usage() {
    docker_runtime_ready || { fail "Docker 服务不可用" 69; return; }
    docker stats --no-stream --format 'table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.NetIO}}\t{{.BlockIO}}'
}

docker_prune_images() {
    local assume_yes=0
    [[ "${1:-}" == "--yes" || "${1:-}" == "-y" ]] && assume_yes=1
    require_root || return
    docker_runtime_ready || { fail "Docker 服务不可用" 69; return; }
    if [[ "$assume_yes" != "1" ]] && ! terminal_confirm "只清理未被容器引用的悬空镜像，是否继续？"; then
        info "已取消清理"
        return 0
    fi
    docker image prune -f
    log_event INFO docker-prune-images "清理悬空镜像"
}
