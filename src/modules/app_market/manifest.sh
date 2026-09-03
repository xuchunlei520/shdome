#!/usr/bin/env bash

manifest_validate() {
    local manifest_file="$1"
    require_command python3 || return
    python3 - "$manifest_file" <<'PY'
import json, re, sys

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
    "services", "resources", "secrets", "ports", "backup", "healthcheck", "routing",
), "Manifest")
need(item.get("schema") == 2, "schema 必须为 2")
need(bool(re.fullmatch(r"[a-z0-9][a-z0-9-]{1,62}", str(item.get("id", "")))), "id 格式错误")
for key in ("name", "version", "description", "category"):
    need(isinstance(item.get(key), str) and bool(item[key].strip()), f"缺少 {key}")
    need(len(item[key]) <= 500, f"{key} 过长")

services = item.get("services")
need(isinstance(services, dict) and services, "services 必须是非空对象")
need(len(services) <= 16, "services 最多包含 16 个服务")
container_names = set()
secret_references = set()
volume_sources = {}
image_pattern = r"(?:[a-zA-Z0-9.-]+(?::[0-9]+)?/)*[a-zA-Z0-9][a-zA-Z0-9._-]*:[a-zA-Z0-9][a-zA-Z0-9._-]*"
for service_name, service in services.items():
    need(bool(re.fullmatch(r"[a-z][a-z0-9-]{0,31}", service_name)), f"服务名格式错误：{service_name}")
    object_keys(service, ("image", "containerName", "environment", "secretEnvironment", "volumes", "dependsOn"), f"services.{service_name}")
    image = str(service.get("image", ""))
    need(bool(re.fullmatch(image_pattern, image)), f"{service_name}.image 必须使用固定 tag")
    need(image.rsplit(":", 1)[1].lower() != "latest", f"{service_name}.image 不能使用 latest")
    container_name = str(service.get("containerName", ""))
    need(bool(re.fullmatch(r"shdome-[a-z0-9][a-z0-9-]{1,62}", container_name)), f"{service_name}.containerName 格式错误")
    need(container_name not in container_names, f"containerName 重复：{container_name}")
    container_names.add(container_name)

    environment = service.get("environment", {})
    need(isinstance(environment, dict), f"{service_name}.environment 必须是对象")
    need(all(re.fullmatch(r"[A-Z_][A-Z0-9_]*", key) for key in environment), f"{service_name}.environment 变量名格式错误")
    need(all(isinstance(value, (str, int, float, bool)) for value in environment.values()), f"{service_name}.environment 值必须是标量")
    need(all("${" not in str(value) for value in environment.values()), f"{service_name}.environment 不允许 Compose 变量展开")

    secret_environment = service.get("secretEnvironment", {})
    need(isinstance(secret_environment, dict), f"{service_name}.secretEnvironment 必须是对象")
    need(all(re.fullmatch(r"[A-Z_][A-Z0-9_]*", key) for key in secret_environment), f"{service_name}.secretEnvironment 变量名格式错误")
    need(not (set(environment) & set(secret_environment)), f"{service_name} 的普通变量与 secret 变量重复")
    for secret_name in secret_environment.values():
        need(isinstance(secret_name, str) and bool(re.fullmatch(r"[A-Z_][A-Z0-9_]*", secret_name)), f"{service_name}.secretEnvironment 引用格式错误")
        secret_references.add(secret_name)

    volumes = service.get("volumes", [])
    need(isinstance(volumes, list) and len(volumes) <= 64, f"{service_name}.volumes 必须是最多 64 项的数组")
    sources, targets = set(), set()
    for volume in volumes:
        need(isinstance(volume, dict), f"{service_name}.volumes 项必须是对象")
        object_keys(volume, ("source", "target", "type"), f"{service_name}.volumes 项")
        source = str(volume.get("source", ""))
        target = str(volume.get("target", ""))
        need(bool(re.fullmatch(r"[a-zA-Z0-9][a-zA-Z0-9._-]*", source)), f"{service_name}.volume source 格式错误")
        need(bool(re.fullmatch(r"/[a-zA-Z0-9_./-]+", target)) and ".." not in target.split("/"), f"{service_name}.volume target 必须是安全绝对路径")
        need(volume.get("type", "directory") in ("directory", "file"), f"{service_name}.volume type 只允许 directory/file")
        need(source not in sources, f"{service_name}.volume source 重复：{source}")
        need(target not in targets, f"{service_name}.volume target 重复：{target}")
        sources.add(source)
        targets.add(target)
    volume_sources[service_name] = {str(volume["source"]): volume.get("type", "directory") for volume in volumes}

    depends_on = service.get("dependsOn", [])
    need(isinstance(depends_on, list), f"{service_name}.dependsOn 必须是数组")
    need(len(depends_on) == len(set(depends_on)), f"{service_name}.dependsOn 不能重复")
    need(all(isinstance(value, str) and value in services and value != service_name for value in depends_on), f"{service_name}.dependsOn 包含未知服务或自身")

resources = item.get("resources", {})
object_keys(resources, ("diskGB", "memoryMB"), "resources")
need(isinstance(resources.get("diskGB"), int) and 1 <= resources["diskGB"] <= 10240, "diskGB 越界")
need(isinstance(resources.get("memoryMB"), int) and 64 <= resources["memoryMB"] <= 1048576, "memoryMB 越界")
architectures = item.get("architectures", [])
need(isinstance(architectures, list) and architectures, "architectures 不能为空")
need(all(value in ("amd64", "arm64") for value in architectures), "architectures 只允许 amd64/arm64")
need(len(architectures) == len(set(architectures)), "architectures 不能重复")

secrets = item.get("secrets", [])
need(isinstance(secrets, list), "secrets 必须是数组")
secret_names = set()
for secret in secrets:
    need(isinstance(secret, dict), "secrets 项必须是对象")
    object_keys(secret, ("name", "bytes"), "secrets 项")
    name = str(secret.get("name", ""))
    need(bool(re.fullmatch(r"[A-Z_][A-Z0-9_]*", name)), "secret name 格式错误")
    need(name not in secret_names, f"secret 名称重复：{name}")
    secret_names.add(name)
    need(isinstance(secret.get("bytes"), int) and 16 <= secret["bytes"] <= 64, f"{name}.bytes 必须为 16-64")
need(secret_references <= secret_names, f"引用了未声明的 secret：{','.join(sorted(secret_references - secret_names))}")

ports = item.get("ports")
need(isinstance(ports, list) and ports, "ports 必须是非空数组")
names, container_keys, host_keys, primary_count = set(), set(), set(), 0
for port in ports:
    need(isinstance(port, dict), "ports 项必须是对象")
    object_keys(port, ("name", "service", "containerPort", "defaultHostPort", "protocol", "primary"), "ports 项")
    name = str(port.get("name", ""))
    service_name = str(port.get("service", ""))
    protocol = port.get("protocol", "tcp")
    need(bool(re.fullmatch(r"[a-z][a-z0-9-]{0,31}", name)), "端口 name 格式错误")
    need(name not in names, f"端口 name 重复：{name}")
    names.add(name)
    need(service_name in services, f"{name}.service 不存在")
    need(isinstance(port.get("containerPort"), int) and 1 <= port["containerPort"] <= 65535, f"{name}.containerPort 越界")
    need(isinstance(port.get("defaultHostPort"), int) and 1 <= port["defaultHostPort"] <= 65535, f"{name}.defaultHostPort 越界")
    need(protocol in ("tcp", "udp"), f"{name}.protocol 只允许 tcp/udp")
    need((service_name, port["containerPort"], protocol) not in container_keys, f"服务容器端口重复：{service_name}/{port['containerPort']}/{protocol}")
    need((port["defaultHostPort"], protocol) not in host_keys, f"宿主机端口重复：{port['defaultHostPort']}/{protocol}")
    container_keys.add((service_name, port["containerPort"], protocol))
    host_keys.add((port["defaultHostPort"], protocol))
    primary_count += int(port.get("primary", False))
need(primary_count == 1, "ports 必须且只能有一个 primary=true")

routing = item.get("routing", {})
object_keys(routing, ("enabled", "service", "port", "scheme", "defaultAccessMode"), "routing")
need(routing.get("enabled") is True, "routing.enabled 必须为 true")
need(routing.get("service") in services, "routing.service 不存在")
need(routing.get("scheme") in ("http", "https", "tcp"), "routing.scheme 只允许 http/https/tcp")
need(routing.get("defaultAccessMode") == "direct", "默认访问模式必须为 direct")
primary = next(port for port in ports if port.get("primary"))
need(routing.get("port") == primary["name"] and routing.get("service") == primary["service"], "routing 必须引用主端口")
need(primary.get("protocol", "tcp") == "tcp", "主端口必须使用 TCP")

health = item.get("healthcheck", {})
object_keys(health, ("type", "service", "port", "path", "timeoutSeconds"), "healthcheck")
need(health.get("type") in ("http", "tcp", "container"), "健康检查类型错误")
need(health.get("service") in services, "healthcheck.service 不存在")
need(isinstance(health.get("timeoutSeconds"), int) and 5 <= health["timeoutSeconds"] <= 600, "健康检查超时越界")
if health.get("type") in ("http", "tcp"):
    matching = [port for port in ports if port["name"] == health.get("port") and port["service"] == health["service"]]
    need(bool(matching), "healthcheck.port 必须引用已发布端口")
    need(matching[0].get("primary") is True, "healthcheck.port 必须引用主端口")
if health.get("type") == "http":
    path_value = health.get("path", "/")
    need(isinstance(path_value, str) and path_value.startswith("/") and len(path_value) <= 500 and not any(ord(char) < 32 for char in path_value), "HTTP 健康检查路径错误")

backup = item.get("backup", {"strategy": "cold-filesystem"})
need(isinstance(backup, dict), "backup 必须是对象")
object_keys(backup, ("strategy", "logical"), "backup")
need(backup.get("strategy", "cold-filesystem") == "cold-filesystem", "backup.strategy 只允许 cold-filesystem")
logical = backup.get("logical")
if logical is not None:
    need(isinstance(logical, dict), "backup.logical 必须是对象")
    object_keys(logical, ("type", "service", "source", "output"), "backup.logical")
    need(logical.get("type") == "sqlite", "backup.logical.type 目前只允许 sqlite")
    service_name = logical.get("service")
    source = str(logical.get("source", ""))
    output = str(logical.get("output", ""))
    need(service_name in services, "backup.logical.service 不存在")
    need(volume_sources.get(service_name, {}).get(source) == "file", "SQLite 逻辑备份源必须是指定服务的文件卷")
    need(bool(re.fullmatch(r"[a-zA-Z0-9][a-zA-Z0-9._-]*\.sql", output)), "backup.logical.output 必须是安全的 .sql 文件名")
PY
}

manifest_ports_json() {
    local manifest_file="$1"
    shift
    python3 - "$manifest_file" "$@" <<'PY'
import json, re, sys
with open(sys.argv[1], encoding="utf-8") as handle:
    item = json.load(handle)
ports = [dict(port) for port in item["ports"]]
for override in sys.argv[2:]:
    if "=" in override:
        name, raw = override.split("=", 1)
    else:
        name = next(port["name"] for port in ports if port.get("primary"))
        raw = override
    if not re.fullmatch(r"[1-9][0-9]{0,4}", raw) or not 1 <= int(raw) <= 65535:
        raise SystemExit(f"端口必须是 1-65535 的整数：{raw}")
    matches = [port for port in ports if port["name"] == name]
    if not matches:
        raise SystemExit(f"Manifest 不存在端口：{name}")
    matches[0]["hostPort"] = int(raw)
for port in ports:
    port.setdefault("protocol", "tcp")
    port.setdefault("primary", False)
    port.setdefault("hostPort", port["defaultHostPort"])
    port.pop("defaultHostPort", None)
host_keys = [(port["hostPort"], port["protocol"]) for port in ports]
if len(host_keys) != len(set(host_keys)):
    raise SystemExit("同一应用的宿主机端口和协议不能重复")
print(json.dumps(ports, ensure_ascii=False, separators=(",", ":")))
PY
}

ports_json_each() {
    local ports_json="$1"
    python3 - "$ports_json" <<'PY'
import json, sys
for port in json.loads(sys.argv[1]):
    print(
        port["name"], str(port["hostPort"]), str(port["containerPort"]),
        port.get("protocol", "tcp"), "true" if port.get("primary") else "false",
        port["service"], sep="\t",
    )
PY
}

ports_json_primary_host() {
    local ports_json="$1"
    python3 - "$ports_json" <<'PY'
import json, sys
print(next(port["hostPort"] for port in json.loads(sys.argv[1]) if port.get("primary")))
PY
}

manifest_services_each() {
    local manifest_file="$1"
    python3 - "$manifest_file" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as handle:
    item = json.load(handle)
for name, service in item["services"].items():
    print(name, service["image"], service["containerName"], sep="\t")
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
app_dir = os.path.dirname(sys.argv[2])
for filename in os.listdir(app_dir):
    if filename.startswith(".env."):
        path = os.path.join(app_dir, filename)
        if os.path.isfile(path):
            os.remove(path)
with open(sys.argv[2], encoding="utf-8") as handle:
    values = dict(line.rstrip("\n").split("=", 1) for line in handle if "=" in line)
for service_name, service in item["services"].items():
    mappings = service.get("secretEnvironment", {})
    if not mappings:
        continue
    service_env = os.path.join(app_dir, f".env.{service_name}")
    with open(service_env, "w", encoding="utf-8") as handle:
        for target, secret_name in sorted(mappings.items()):
            handle.write(f"{target}={values[secret_name]}\n")
    os.chmod(service_env, 0o600)
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
for service_name, service in item["services"].items():
    service_root = os.path.join(data_root, service_name)
    for volume in service.get("volumes", []):
        path = os.path.join(service_root, volume["source"])
        os.makedirs(os.path.dirname(path), mode=0o750, exist_ok=True)
        if volume.get("type", "directory") == "file":
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
