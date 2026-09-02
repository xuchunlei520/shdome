#!/usr/bin/env bash

port_validate() {
    [[ "$1" =~ ^[0-9]+$ ]] && ((10#$1 >= 1 && 10#$1 <= 65535))
}

port_listening() {
    local port="$1"
    if command -v ss >/dev/null 2>&1; then
        ss -H -lntu 2>/dev/null | awk -v target="$port" '
            { address=$5; sub(/%.*/, "", address); n=split(address, parts, ":"); if (parts[n] == target) found=1 }
            END { exit(found ? 0 : 1) }
        '
    elif command -v netstat >/dev/null 2>&1; then
        netstat -lntu 2>/dev/null | awk -v target="$port" '
            NR > 2 { n=split($4, parts, ":"); if (parts[n] == target) found=1 }
            END { exit(found ? 0 : 1) }
        '
    else
        return 2
    fi
}

port_registered_to_other_app() {
    local port="$1" current_app_id="${2:-}"
    python3 - "$SHDOME_APPS_DIR" "$port" "$current_app_id" <<'PY'
import glob, json, os, sys
root, port, current = sys.argv[1], int(sys.argv[2]), sys.argv[3]
for path in glob.glob(os.path.join(root, "*", "state.json")):
    try:
        with open(path, encoding="utf-8") as handle:
            state = json.load(handle)
    except (OSError, json.JSONDecodeError):
        continue
    if state.get("id") == current:
        continue
    registered = state.get("ports") or [{"hostPort": state.get("hostPort")}]
    if any(mapping.get("hostPort") == port for mapping in registered):
        print(state.get("id", "unknown"))
        raise SystemExit(0)
raise SystemExit(1)
PY
}

port_assert_available() {
    local port="$1" app_id="${2:-}" owner
    port_validate "$port" || { fail "端口必须是 1-65535 的整数：$port" 64; return; }
    owner="$(port_registered_to_other_app "$port" "$app_id" 2>/dev/null || true)"
    [[ -z "$owner" ]] || { fail "端口 $port 已登记给应用 $owner" 73; return; }
    if port_listening "$port"; then
        fail "宿主机端口 $port 已被进程或容器占用" 73
    elif [[ $? -eq 2 ]]; then
        warn "系统缺少 ss/netstat，将由 Docker 执行最终端口绑定校验"
    fi
}
