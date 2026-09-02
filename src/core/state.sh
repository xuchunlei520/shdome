#!/usr/bin/env bash

state_file_for() {
    local app_id="$1"
    printf '%s/%s/state.json\n' "$SHDOME_APPS_DIR" "$app_id"
}

state_exists() {
    [[ -f "$(state_file_for "$1")" ]]
}

state_get() {
    local app_id="$1" field="$2" state_file
    state_file="$(state_file_for "$app_id")"
    [[ -f "$state_file" ]] || return 1
    python3 - "$state_file" "$field" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as handle:
    value = json.load(handle)
for part in sys.argv[2].split('.'):
    if not isinstance(value, dict) or part not in value:
        raise SystemExit(1)
    value = value[part]
if isinstance(value, bool):
    print(str(value).lower())
elif isinstance(value, (dict, list)):
    print(json.dumps(value, ensure_ascii=False, separators=(",", ":")))
elif value is not None:
    print(value)
PY
}

state_write() {
    local app_id="$1" manifest_file="$2" ports_json="$3" container_id="$4" image_digest="$5"
    local app_dir state_file temp_file
    app_dir="$SHDOME_APPS_DIR/$app_id"
    state_file="$app_dir/state.json"
    mkdir -p "$app_dir"
    temp_file="$(mktemp "$app_dir/.state.XXXXXX")"
    python3 - "$manifest_file" "$temp_file" "$ports_json" "$container_id" "$image_digest" <<'PY'
import hashlib, json, os, sys
manifest_path, output, ports_json, container_id, digest = sys.argv[1:]
with open(manifest_path, "rb") as handle:
    raw = handle.read()
manifest = json.loads(raw)
old = {}
state_path = os.path.join(os.path.dirname(output), "state.json")
if os.path.isfile(state_path):
    with open(state_path, encoding="utf-8") as handle:
        old = json.load(handle)
now = __import__("datetime").datetime.now(__import__("datetime").timezone.utc).replace(microsecond=0).isoformat()
ports = json.loads(ports_json)
primary = next(port for port in ports if port.get("primary"))
state = {
    "schema": 1,
    "id": manifest["id"],
    "name": manifest["name"],
    "version": manifest["version"],
    "image": manifest["services"]["app"]["image"],
    "imageDigest": digest,
    "containerName": manifest["services"]["app"]["containerName"],
    "containerId": container_id,
    "ports": ports,
    "containerPort": primary["containerPort"],
    "hostPort": primary["hostPort"],
    "accessMode": old.get("accessMode", "direct"),
    "domain": old.get("domain", ""),
    "dataDirectory": os.path.dirname(output),
    "manifestSha256": hashlib.sha256(raw).hexdigest(),
    "installedAt": old.get("installedAt", now),
    "updatedAt": now,
}
with open(output, "w", encoding="utf-8") as handle:
    json.dump(state, handle, ensure_ascii=False, indent=2)
    handle.write("\n")
PY
    chmod 600 "$temp_file"
    mv -f "$temp_file" "$state_file"
}

state_remove() {
    local app_id="$1"
    rm -f "$(state_file_for "$app_id")"
}

state_ports_json() {
    local app_id="$1" ports
    ports="$(state_get "$app_id" ports 2>/dev/null || true)"
    if [[ -n "$ports" ]]; then
        printf '%s\n' "$ports"
        return
    fi
    python3 - "$(state_get "$app_id" hostPort)" "$(state_get "$app_id" containerPort)" <<'PY'
import json, sys
print(json.dumps([{
    "name": "http", "hostPort": int(sys.argv[1]), "containerPort": int(sys.argv[2]),
    "protocol": "tcp", "primary": True,
}], separators=(",", ":")))
PY
}

state_set_routing() {
    local app_id="$1" access_mode="$2" domain="$3" state_file temp_file
    state_file="$(state_file_for "$app_id")"
    [[ -f "$state_file" ]] || return 1
    temp_file="$(mktemp "$(dirname "$state_file")/.routing.XXXXXX")" || return 1
    if ! python3 - "$state_file" "$temp_file" "$access_mode" "$domain" <<'PY'
import datetime, json, sys
source, output, access_mode, domain = sys.argv[1:]
if access_mode not in ("direct", "domain_only"):
    raise SystemExit("invalid access mode")
with open(source, encoding="utf-8") as handle:
    state = json.load(handle)
state["accessMode"] = access_mode
state["domain"] = domain
state["updatedAt"] = datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0).isoformat()
with open(output, "w", encoding="utf-8") as handle:
    json.dump(state, handle, ensure_ascii=False, indent=2)
    handle.write("\n")
PY
    then
        rm -f -- "$temp_file"
        return 1
    fi
    chmod 600 "$temp_file" || { rm -f -- "$temp_file"; return 1; }
    mv -f "$temp_file" "$state_file" || { rm -f -- "$temp_file"; return 1; }
}
