#!/usr/bin/env bash

port_validate() {
    [[ "$1" =~ ^[0-9]+$ ]] && ((10#$1 >= 1 && 10#$1 <= 65535))
}

port_listening() {
    local port="$1" protocol="${2:-}"
    if command -v ss >/dev/null 2>&1; then
        ss -H -lntu 2>/dev/null | awk -v target="$port" -v protocol="$protocol" '
            protocol != "" && $1 !~ "^" protocol { next }
            { address=$5; sub(/%.*/, "", address); n=split(address, parts, ":"); if (parts[n] == target) found=1 }
            END { exit(found ? 0 : 1) }
        '
    elif command -v netstat >/dev/null 2>&1; then
        netstat -lntu 2>/dev/null | awk -v target="$port" -v protocol="$protocol" '
            NR > 2 && (protocol == "" || $1 ~ "^" protocol) { n=split($4, parts, ":"); if (parts[n] == target) found=1 }
            END { exit(found ? 0 : 1) }
        '
    else
        return 2
    fi
}

port_registered_to_other_app() {
    local port="$1" current_app_id="${2:-}" protocol="${3:-}"
    python3 - "$SHDOME_APPS_DIR" "$port" "$current_app_id" "$protocol" <<'PY'
import glob, json, os, sys
root, port, current, protocol = sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4]
for path in glob.glob(os.path.join(root, "*", "state.json")):
    try:
        with open(path, encoding="utf-8") as handle:
            state = json.load(handle)
    except (OSError, json.JSONDecodeError):
        continue
    if state.get("id") == current:
        continue
    registered = state.get("ports", [])
    if any(mapping.get("hostPort") == port and (not protocol or mapping.get("protocol", "tcp") == protocol) for mapping in registered):
        print(state.get("id", "unknown"))
        raise SystemExit(0)
raise SystemExit(1)
PY
}

port_assert_available() {
    local port="$1" app_id="${2:-}" protocol="${3:-tcp}" owner
    port_validate "$port" || { fail "端口必须是 1-65535 的整数：$port" 64; return; }
    owner="$(port_registered_to_other_app "$port" "$app_id" "$protocol" 2>/dev/null || true)"
    [[ -z "$owner" ]] || { fail "端口 $port 已登记给应用 $owner" 73; return; }
    if port_listening "$port" "$protocol"; then
        fail "宿主机端口 $port/$protocol 已被进程或容器占用" 73
    elif [[ $? -eq 2 ]]; then
        warn "系统缺少 ss/netstat，将由 Docker 执行最终端口绑定校验"
    fi
}

port_available_for_auto() {
    local port="$1" app_id="${2:-}" reserved="${3:-}" protocol="${4:-tcp}" owner listen_status
    port_validate "$port" || return 1
    [[ ",$reserved," != *",$port/$protocol,"* ]] || return 1
    owner="$(port_registered_to_other_app "$port" "$app_id" "$protocol" 2>/dev/null || true)"
    [[ -z "$owner" ]] || return 1
    if port_listening "$port" "$protocol"; then
        return 1
    else
        listen_status=$?
    fi
    [[ "$listen_status" == "1" || "$listen_status" == "2" ]]
}

port_find_available() {
    local preferred="$1" app_id="${2:-}" reserved="${3:-}" protocol="${4:-tcp}" candidate
    port_validate "$preferred" || { fail "端口必须是 1-65535 的整数：$preferred" 64; return; }
    for ((candidate = 10#$preferred; candidate <= 65535; candidate++)); do
        if port_available_for_auto "$candidate" "$app_id" "$reserved" "$protocol"; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done
    for ((candidate = 1024; candidate < 10#$preferred; candidate++)); do
        if port_available_for_auto "$candidate" "$app_id" "$reserved" "$protocol"; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done
    fail "没有可用的宿主机端口" 73
}
