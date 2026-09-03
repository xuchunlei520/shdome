#!/usr/bin/env bash

manifest_validate() {
    local manifest_file="$1"
    require_command python3 || return
    python3 - "$manifest_file" <<'PY'
import json, os, re, sys

path = sys.argv[1]
try:
    with open(path, encoding="utf-8") as handle:
        item = json.load(handle)
except (OSError, json.JSONDecodeError) as exc:
    print(f"Manifest 无法读取：{exc}", file=sys.stderr)
    raise SystemExit(65)

def need(condition, message):
    if not condition:
        print(f"Manifest 校验失败：{message}", file=sys.stderr)
        raise SystemExit(65)

def object_keys(value, allowed, path):
    need(isinstance(value, dict), f"{path} 必须是对象")
    unknown = set(value) - set(allowed)
    need(not unknown, f"{path} 包含不支持的字段：{','.join(sorted(unknown))}")

object_keys(item, (
    "schema", "id", "name", "version", "description", "category", "architectures",
    "services", "resources", "environment", "secrets", "volumes", "ports",
    "backup", "healthcheck", "routing",
), "Manifest")
need(item.get("schema") == 1, "schema 必须为 1")
need(bool(re.fullmatch(r"[a-z0-9][a-z0-9-]{1,62}", str(item.get("id", "")))), "id 格式错误")
for key in ("name", "version", "description", "category"):
    need(isinstance(item.get(key), str) and bool(item[key].strip()), f"缺少 {key}")
    need(len(item[key]) <= 500, f"{key} 过长")
services = item.get("services", {})
object_keys(services, ("app",), "services")
service = services.get("app", {})
object_keys(service, ("image", "containerName", "containerPort"), "services.app")
image = str(service.get("image", ""))
need(bool(re.fullmatch(r"(?:[a-zA-Z0-9.-]+(?::[0-9]+)?/)*[a-zA-Z0-9][a-zA-Z0-9._-]*:[a-zA-Z0-9][a-zA-Z0-9._-]*", image)), "镜像必须使用固定 tag")
need(image.rsplit(":", 1)[1].lower() != "latest", "镜像不能使用 latest")
need(bool(re.fullmatch(r"shdome-[a-z0-9][a-z0-9-]{1,62}", str(service.get("containerName", "")))), "containerName 格式错误")
routing = item.get("routing", {})
object_keys(routing, ("enabled", "defaultAccessMode", "defaultHostPort"), "routing")
need(routing.get("enabled") is True, "routing.enabled 必须为 true")
need(routing.get("defaultAccessMode") == "direct", "默认访问模式必须为 direct")
ports = item.get("ports")
if ports is None:
    need(isinstance(service.get("containerPort"), int) and 1 <= service["containerPort"] <= 65535, "containerPort 越界")
    need(isinstance(routing.get("defaultHostPort"), int) and 1 <= routing["defaultHostPort"] <= 65535, "defaultHostPort 越界")
else:
    need(isinstance(ports, list) and ports, "ports 必须是非空数组")
    names, container_keys, primary_count = set(), set(), 0
    for port in ports:
        need(isinstance(port, dict), "ports 项必须是对象")
        object_keys(port, ("name", "containerPort", "defaultHostPort", "protocol", "primary"), "ports 项")
        name = str(port.get("name", ""))
        need(bool(re.fullmatch(r"[a-z][a-z0-9-]{0,31}", name)), "端口 name 格式错误")
        need(name not in names, f"端口 name 重复：{name}")
        names.add(name)
        need(isinstance(port.get("containerPort"), int) and 1 <= port["containerPort"] <= 65535, f"{name}.containerPort 越界")
        need(isinstance(port.get("defaultHostPort"), int) and 1 <= port["defaultHostPort"] <= 65535, f"{name}.defaultHostPort 越界")
        protocol = port.get("protocol", "tcp")
        need(protocol in ("tcp", "udp"), f"{name}.protocol 只允许 tcp/udp")
        container_key = (port["containerPort"], protocol)
        need(container_key not in container_keys, f"容器端口重复：{container_key}")
        container_keys.add(container_key)
        primary_count += int(port.get("primary", False))
    need(primary_count == 1, "ports 必须且只能有一个 primary=true")
resources = item.get("resources", {})
object_keys(resources, ("diskGB", "memoryMB"), "resources")
need(isinstance(resources.get("diskGB"), int) and 1 <= resources["diskGB"] <= 10240, "diskGB 越界")
need(isinstance(resources.get("memoryMB"), int) and 64 <= resources["memoryMB"] <= 1048576, "memoryMB 越界")
architectures = item.get("architectures", [])
need(isinstance(architectures, list) and architectures, "architectures 不能为空")
need(all(x in ("amd64", "arm64") for x in architectures), "architectures 只允许 amd64/arm64")
need(len(architectures) == len(set(architectures)), "architectures 不能重复")
volumes = item.get("volumes", [])
need(isinstance(volumes, list) and len(volumes) <= 64, "volumes 必须是最多 64 项的数组")
volume_sources, volume_targets = set(), set()
for volume in volumes:
    need(isinstance(volume, dict), "volumes 项必须是对象")
    object_keys(volume, ("source", "target", "type"), "volumes 项")
    need(bool(re.fullmatch(r"[a-zA-Z0-9][a-zA-Z0-9._-]*", str(volume.get("source", "")))), "卷 source 格式错误")
    target = str(volume.get("target", ""))
    need(bool(re.fullmatch(r"/[a-zA-Z0-9_./-]+", target)) and ".." not in target.split("/"), "卷 target 必须是安全绝对路径")
    need(volume.get("type", "directory") in ("directory", "file"), "卷 type 只允许 directory/file")
    need(volume["source"] not in volume_sources, f"卷 source 重复：{volume['source']}")
    need(target not in volume_targets, f"卷 target 重复：{target}")
    volume_sources.add(volume["source"])
    volume_targets.add(target)
environment = item.get("environment", {})
need(isinstance(environment, dict), "environment 必须是对象")
need(all(re.fullmatch(r"[A-Z_][A-Z0-9_]*", key) for key in environment), "环境变量名格式错误")
need(all(isinstance(value, (str, int, float, bool)) for value in environment.values()), "环境变量值必须是标量")
need(all("${" not in str(value) for value in environment.values()), "环境变量值不允许 Compose 变量展开")
secrets = item.get("secrets", [])
need(isinstance(secrets, list), "secrets 必须是数组")
secret_names = set()
for secret in secrets:
    need(isinstance(secret, dict), "secrets 项必须是对象")
    object_keys(secret, ("name", "bytes"), "secrets 项")
    name = str(secret.get("name", ""))
    need(bool(re.fullmatch(r"[A-Z_][A-Z0-9_]*", name)), "secret name 格式错误")
    need(name not in secret_names and name not in environment, f"secret 名称重复：{name}")
    secret_names.add(name)
    need(isinstance(secret.get("bytes"), int) and 16 <= secret["bytes"] <= 64, f"{name}.bytes 必须为 16-64")
backup = item.get("backup", {"strategy": "cold-filesystem"})
need(isinstance(backup, dict), "backup 必须是对象")
object_keys(backup, ("strategy", "logical"), "backup")
need(backup.get("strategy", "cold-filesystem") == "cold-filesystem", "backup.strategy 只允许 cold-filesystem")
logical = backup.get("logical")
if logical is not None:
    need(isinstance(logical, dict), "backup.logical 必须是对象")
    object_keys(logical, ("type", "source", "output"), "backup.logical")
    need(logical.get("type") == "sqlite", "backup.logical.type 目前只允许 sqlite")
    source = str(logical.get("source", ""))
    output = str(logical.get("output", ""))
    need(bool(re.fullmatch(r"[a-zA-Z0-9][a-zA-Z0-9._-]*", source)), "backup.logical.source 格式错误")
    need(bool(re.fullmatch(r"[a-zA-Z0-9][a-zA-Z0-9._-]*\.sql", output)), "backup.logical.output 必须是安全的 .sql 文件名")
    file_sources = {str(volume.get("source", "")) for volume in item.get("volumes", []) if volume.get("type", "directory") == "file"}
    need(source in file_sources, "SQLite 逻辑备份源必须是已声明的文件卷")
health = item.get("healthcheck", {})
object_keys(health, ("type", "path", "timeoutSeconds"), "healthcheck")
need(health.get("type") in ("http", "tcp", "container"), "健康检查类型错误")
need(isinstance(health.get("timeoutSeconds"), int) and 5 <= health["timeoutSeconds"] <= 600, "健康检查超时越界")
if health.get("type") == "http":
    path = health.get("path", "/")
    need(isinstance(path, str) and path.startswith("/") and len(path) <= 500 and not any(ord(x) < 32 for x in path), "HTTP 健康检查路径错误")
PY
}

manifest_ports_json() {
    local manifest_file="$1"
    shift
    python3 - "$manifest_file" "$@" <<'PY'
import json, re, sys
with open(sys.argv[1], encoding="utf-8") as handle:
    item = json.load(handle)
ports = item.get("ports")
if ports is None:
    service = item["services"]["app"]
    routing = item["routing"]
    ports = [{
        "name": "http",
        "containerPort": service["containerPort"],
        "defaultHostPort": routing["defaultHostPort"],
        "protocol": "tcp",
        "primary": True,
    }]
else:
    ports = [dict(port) for port in ports]
for port in ports:
    port.setdefault("protocol", "tcp")
    port.setdefault("primary", False)
    port["hostPort"] = port["defaultHostPort"]
overrides = sys.argv[2:]
primary = next(port for port in ports if port["primary"])
for override in overrides:
    if "=" in override:
        name, value = override.split("=", 1)
    else:
        name, value = primary["name"], override
    if not re.fullmatch(r"[a-z][a-z0-9-]{0,31}", name):
        raise SystemExit(f"端口名称格式错误：{name}")
    if not value.isdigit() or not 1 <= int(value) <= 65535:
        raise SystemExit(f"端口必须是 1-65535 的整数：{value}")
    matches = [port for port in ports if port["name"] == name]
    if not matches:
        raise SystemExit(f"Manifest 不存在端口：{name}")
    matches[0]["hostPort"] = int(value)
host_keys = [(port["hostPort"], port["protocol"]) for port in ports]
if len(host_keys) != len(set(host_keys)):
    raise SystemExit("同一应用的宿主机端口和协议不能重复")
result = [{
    "name": port["name"],
    "hostPort": port["hostPort"],
    "containerPort": port["containerPort"],
    "protocol": port["protocol"],
    "primary": bool(port["primary"]),
} for port in ports]
print(json.dumps(result, ensure_ascii=False, separators=(",", ":")))
PY
}

ports_json_each() {
    local ports_json="$1"
    python3 - "$ports_json" <<'PY'
import json, sys
for port in json.loads(sys.argv[1]):
    print("\t".join([
        port["name"], str(port["hostPort"]), str(port["containerPort"]),
        port.get("protocol", "tcp"), "true" if port.get("primary") else "false"
    ]))
PY
}

ports_json_primary_host() {
    local ports_json="$1"
    python3 - "$ports_json" <<'PY'
import json, sys
ports = json.loads(sys.argv[1])
print(next(port["hostPort"] for port in ports if port.get("primary")))
PY
}

manifest_generate_env() {
    local manifest_file="$1" output_file="$2"
    python3 - "$manifest_file" "$output_file" <<'PY'
import json, os, secrets, sys
with open(sys.argv[1], encoding="utf-8") as handle:
    item = json.load(handle)
old = {}
if os.path.isfile(sys.argv[2]):
    with open(sys.argv[2], encoding="utf-8") as handle:
        for line in handle:
            name, separator, value = line.rstrip("\n").partition("=")
            if separator:
                old[name] = value
temporary = sys.argv[2] + ".tmp"
with open(temporary, "w", encoding="utf-8") as handle:
    for secret in item.get("secrets", []):
        value = old.get(secret["name"]) or secrets.token_hex(secret["bytes"])
        handle.write(f"{secret['name']}={value}\n")
os.replace(temporary, sys.argv[2])
PY
    chmod 600 "$output_file"
}

manifest_prepare_volumes() {
    local manifest_file="$1" app_dir="$2"
    python3 - "$manifest_file" "$app_dir" <<'PY'
import json, os, sys
with open(sys.argv[1], encoding="utf-8") as handle:
    item = json.load(handle)
data_root = os.path.join(sys.argv[2], "data")
os.makedirs(data_root, mode=0o750, exist_ok=True)
for volume in item.get("volumes", []):
    path = os.path.join(data_root, volume["source"])
    if volume.get("type", "directory") == "file":
        os.makedirs(os.path.dirname(path), mode=0o750, exist_ok=True)
        if not os.path.exists(path):
            descriptor = os.open(path, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
            os.close(descriptor)
        elif not os.path.isfile(path):
            raise SystemExit(f"卷需要文件但路径不是文件：{path}")
    else:
        if os.path.exists(path) and not os.path.isdir(path):
            raise SystemExit(f"卷需要目录但路径不是目录：{path}")
        os.makedirs(path, mode=0o750, exist_ok=True)
PY
}

manifest_get() {
    local manifest_file="$1" path="$2"
    python3 - "$manifest_file" "$path" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as handle:
    value = json.load(handle)
for part in sys.argv[2].split('.'):
    value = value[part]
if isinstance(value, bool):
    print(str(value).lower())
elif isinstance(value, (dict, list)):
    print(json.dumps(value, ensure_ascii=False))
else:
    print(value)
PY
}

manifest_supports_current_arch() {
    local manifest_file="$1" machine arch
    machine="$(uname -m)"
    case "$machine" in
        x86_64|amd64) arch=amd64 ;;
        aarch64|arm64) arch=arm64 ;;
        *) fail "不支持的 CPU 架构：$machine" 69; return ;;
    esac
    python3 - "$manifest_file" "$arch" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as handle:
    item = json.load(handle)
raise SystemExit(0 if sys.argv[2] in item["architectures"] else 1)
PY
}
