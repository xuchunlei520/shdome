#!/usr/bin/env bash

image_source_policy_rows() {
    python3 - "$SHDOME_IMAGE_SOURCE_CONFIG" "${SHDOME_DOCKER_HUB_MIRRORS:-}" <<'PY'
import ipaddress
import json
import os
import re
import sys
from urllib.parse import urlsplit

path, environment_mirrors = sys.argv[1:]
defaults = [
    "https://docker.1ms.run",
    "https://docker.m.daocloud.io",
    "https://dockerproxy.net",
]


def normalize_url(value):
    if not isinstance(value, str) or not value or any(ord(char) < 33 for char in value):
        raise ValueError("镜像源地址不能为空或包含空白/控制字符")
    parsed = urlsplit(value)
    if parsed.scheme != "https" or not parsed.hostname:
        raise ValueError("镜像源必须使用 HTTPS Origin")
    if parsed.username or parsed.password or parsed.query or parsed.fragment:
        raise ValueError("镜像源不能包含账号、密码、查询参数或片段")
    if parsed.path not in {"", "/"}:
        raise ValueError("镜像源不能包含路径")
    try:
        port = parsed.port
    except ValueError as exc:
        raise ValueError("镜像源端口无效") from exc
    hostname = parsed.hostname.lower().rstrip(".")
    try:
        ipaddress.ip_address(hostname.strip("[]"))
    except ValueError:
        if len(hostname) > 253 or not re.fullmatch(
            r"(?=.{1,253}$)(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)*[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?",
            hostname,
        ):
            raise ValueError("镜像源主机名无效")
    host = f"[{hostname}]" if ":" in hostname else hostname
    if port is not None:
        host += f":{port}"
    return "https://" + host


policy = {"schema": 1, "mode": "auto", "manualMirror": "", "mirrors": []}
if os.path.exists(path):
    try:
        with open(path, encoding="utf-8") as handle:
            loaded = json.load(handle)
        allowed = {"schema", "mode", "manualMirror", "mirrors"}
        if not isinstance(loaded, dict) or set(loaded) - allowed:
            raise ValueError("配置包含未知字段")
        if loaded.get("schema") != 1 or loaded.get("mode") not in {"auto", "official", "manual"}:
            raise ValueError("配置版本或模式无效")
        manual = loaded.get("manualMirror", "")
        mirrors = loaded.get("mirrors", [])
        if not isinstance(mirrors, list) or len(mirrors) > 8:
            raise ValueError("mirrors 必须是最多 8 项的数组")
        normalized_mirrors = []
        for item in mirrors:
            normalized = normalize_url(item)
            if normalized not in normalized_mirrors:
                normalized_mirrors.append(normalized)
        if loaded["mode"] == "manual":
            manual = normalize_url(manual)
        elif manual:
            manual = normalize_url(manual)
        policy = {
            "schema": 1,
            "mode": loaded["mode"],
            "manualMirror": manual,
            "mirrors": normalized_mirrors,
        }
    except (OSError, json.JSONDecodeError, ValueError) as exc:
        print(f"镜像源配置无效，将使用自动默认值：{exc}", file=sys.stderr)
        raise SystemExit(65)

if environment_mirrors:
    candidates = [normalize_url(item.strip()) for item in environment_mirrors.split(",") if item.strip()]
elif policy["mirrors"]:
    candidates = policy["mirrors"]
else:
    candidates = defaults
if len(candidates) > 8:
    raise SystemExit("镜像源候选不能超过 8 项")

deduplicated = []
for candidate in candidates:
    candidate = normalize_url(candidate)
    if candidate not in deduplicated:
        deduplicated.append(candidate)

print("POLICY", policy["mode"], policy["manualMirror"], sep="\t")
for candidate in deduplicated:
    print("MIRROR", urlsplit(candidate).netloc, candidate, sep="\t")
PY
}

image_source_policy_rows_safe() {
    local rows
    if rows="$(image_source_policy_rows)"; then
        printf '%s\n' "$rows"
        return 0
    fi
    warn "镜像源配置已忽略；执行 k env mirror reset 可清除无效配置"
    printf '%s\n' \
        $'POLICY\tauto\t' \
        $'MIRROR\tdocker.1ms.run\thttps://docker.1ms.run' \
        $'MIRROR\tdocker.m.daocloud.io\thttps://docker.m.daocloud.io' \
        $'MIRROR\tdockerproxy.net\thttps://dockerproxy.net'
}

image_source_url_normalize() {
    python3 - "$1" <<'PY'
import ipaddress
import re
import sys
from urllib.parse import urlsplit

value = sys.argv[1]
if not value or any(ord(char) < 33 for char in value):
    raise SystemExit("镜像源地址不能为空或包含空白/控制字符")
parsed = urlsplit(value)
if parsed.scheme != "https" or not parsed.hostname:
    raise SystemExit("镜像源必须使用 HTTPS Origin")
if parsed.username or parsed.password or parsed.query or parsed.fragment:
    raise SystemExit("镜像源不能包含账号、密码、查询参数或片段")
if parsed.path not in {"", "/"}:
    raise SystemExit("镜像源不能包含路径")
try:
    port = parsed.port
except ValueError:
    raise SystemExit("镜像源端口无效")
hostname = parsed.hostname.lower().rstrip(".")
try:
    ipaddress.ip_address(hostname.strip("[]"))
except ValueError:
    if len(hostname) > 253 or not re.fullmatch(
        r"(?=.{1,253}$)(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)*[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?",
        hostname,
    ):
        raise SystemExit("镜像源主机名无效")
host = f"[{hostname}]" if ":" in hostname else hostname
if port is not None:
    host += f":{port}"
print("https://" + host)
PY
}

image_source_is_docker_hub() {
    local image="$1" first
    first="${image%%/*}"
    if [[ "$image" != */* ]]; then
        return 0
    fi
    case "$first" in
        docker.io|index.docker.io|registry-1.docker.io) return 0 ;;
        localhost|*.*|*:*|\[*\]) return 1 ;;
        *) return 0 ;;
    esac
}

image_source_docker_hub_repository() {
    local image="$1" repository first
    repository="$image"
    for first in docker.io/ index.docker.io/ registry-1.docker.io/; do
        repository="${repository#"$first"}"
    done
    [[ "$repository" == */* ]] || repository="library/$repository"
    printf '%s\n' "$repository"
}

image_source_mirror_reference() {
    local image="$1" mirror="$2" host repository
    image_source_is_docker_hub "$image" || return 1
    host="${mirror#https://}"
    repository="$(image_source_docker_hub_repository "$image")" || return
    printf '%s/%s\n' "$host" "$repository"
}

image_source_docker_hub_authenticated() {
    local docker_config="${DOCKER_CONFIG:-${HOME:-/root}/.docker}/config.json"
    python3 - "$docker_config" <<'PY'
import json
import sys

try:
    with open(sys.argv[1], encoding="utf-8") as handle:
        value = json.load(handle)
except (OSError, json.JSONDecodeError):
    raise SystemExit(1)
if value.get("credsStore"):
    raise SystemExit(0)
registries = {"docker.io", "index.docker.io", "registry-1.docker.io", "https://index.docker.io/v1/"}
if registries.intersection((value.get("auths") or {}).keys()):
    raise SystemExit(0)
if registries.intersection((value.get("credHelpers") or {}).keys()):
    raise SystemExit(0)
raise SystemExit(1)
PY
}

image_source_probe() {
    local origin="$1" result status elapsed
    command -v curl >/dev/null 2>&1 || return 1
    result="$(curl --proto '=https' --tlsv1.2 -sS -L -o /dev/null \
        --connect-timeout "${SHDOME_IMAGE_SOURCE_CONNECT_TIMEOUT:-2}" \
        --max-time "${SHDOME_IMAGE_SOURCE_PROBE_TIMEOUT:-4}" \
        -w $'%{http_code}\t%{time_total}' "${origin%/}/v2/" 2>/dev/null)" || return 1
    IFS=$'\t' read -r status elapsed <<<"$result"
    case "$status" in 200|401) ;; *) return 1 ;; esac
    awk -v seconds="$elapsed" 'BEGIN { printf "%d\n", (seconds * 1000) + 0.5 }'
}

image_source_state_record() {
    local source="$1" result="$2" latency_ms="${3:-}" error_summary="${4:-}" image="${5:-}"
    python3 - "$SHDOME_IMAGE_SOURCE_STATE" "$source" "$result" "$latency_ms" "$error_summary" "$image" <<'PY'
import datetime
import json
import os
import tempfile
import time
import sys

path, source, result, latency_raw, error_summary, image = sys.argv[1:]
state = {"schema": 1, "selected": "", "lastSuccessAt": "", "lastSuccessEpoch": 0,
         "lastFailureAt": "", "lastError": "", "sources": {}, "images": {}}
try:
    with open(path, encoding="utf-8") as handle:
        loaded = json.load(handle)
    if isinstance(loaded, dict) and loaded.get("schema") == 1:
        state.update({key: loaded[key] for key in state if key in loaded})
except (OSError, json.JSONDecodeError):
    pass
if not isinstance(state.get("sources"), dict):
    state["sources"] = {}
if not isinstance(state.get("images"), dict):
    state["images"] = {}
now_epoch = int(time.time())
now = datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0).isoformat()
entry = state["sources"].get(source, {})
if not isinstance(entry, dict):
    entry = {}
if latency_raw.isdigit():
    entry["latencyMs"] = int(latency_raw)
if result == "success":
    entry.update({"status": "healthy", "lastSuccessAt": now, "failures": 0, "lastError": ""})
    entry.pop("cooldownUntilEpoch", None)
    state.update({"selected": source, "lastSuccessAt": now, "lastSuccessEpoch": now_epoch, "lastError": ""})
    if image:
        state["images"][image] = {"source": source, "lastSuccessAt": now, "lastSuccessEpoch": now_epoch}
        if len(state["images"]) > 128:
            oldest = sorted(state["images"], key=lambda key: int(state["images"][key].get("lastSuccessEpoch", 0)))
            for key in oldest[:-128]:
                state["images"].pop(key, None)
elif result == "probe":
    entry.update({"status": "healthy", "lastProbeAt": now, "lastProbeEpoch": now_epoch})
elif result == "probe-failed":
    entry.update({"status": "unreachable", "lastProbeAt": now, "lastProbeEpoch": now_epoch})
else:
    failures = int(entry.get("failures", 0)) + 1
    summary = " ".join(error_summary.split())[:400]
    entry.update({"status": "failed", "lastFailureAt": now, "failures": failures, "lastError": summary})
    if failures >= 2:
        entry["cooldownUntilEpoch"] = now_epoch + int(os.environ.get("SHDOME_IMAGE_SOURCE_COOLDOWN", "1800"))
    state.update({"lastFailureAt": now, "lastError": summary})
state["sources"][source] = entry
os.makedirs(os.path.dirname(path), mode=0o750, exist_ok=True)
descriptor, temporary = tempfile.mkstemp(prefix=".image-source-health.", dir=os.path.dirname(path))
try:
    os.fchmod(descriptor, 0o600)
    with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
        json.dump(state, handle, ensure_ascii=False, indent=2)
        handle.write("\n")
    os.replace(temporary, path)
finally:
    if os.path.exists(temporary):
        os.unlink(temporary)
PY
}

image_source_state_cached_selected() {
    python3 - "$SHDOME_IMAGE_SOURCE_STATE" "${SHDOME_IMAGE_SOURCE_HEALTH_TTL:-21600}" <<'PY'
import json
import sys
import time

path, ttl_raw = sys.argv[1:]
try:
    with open(path, encoding="utf-8") as handle:
        state = json.load(handle)
    epoch = int(state.get("lastSuccessEpoch", 0))
    selected = state.get("selected", "")
    if selected and int(time.time()) - epoch <= int(ttl_raw):
        print(selected)
except (OSError, ValueError, TypeError, json.JSONDecodeError):
    pass
PY
}

image_source_image_recent() {
    python3 - "$SHDOME_IMAGE_SOURCE_STATE" "$1" "${SHDOME_IMAGE_SOURCE_IMAGE_TTL:-600}" <<'PY'
import json
import sys
import time

path, image, ttl_raw = sys.argv[1:]
try:
    with open(path, encoding="utf-8") as handle:
        state = json.load(handle)
    entry = (state.get("images") or {}).get(image) or {}
    epoch = int(entry.get("lastSuccessEpoch", 0))
    if epoch and int(time.time()) - epoch <= int(ttl_raw):
        raise SystemExit(0)
except (OSError, ValueError, TypeError, json.JSONDecodeError):
    pass
raise SystemExit(1)
PY
}

image_source_state_in_cooldown() {
    python3 - "$SHDOME_IMAGE_SOURCE_STATE" "$1" <<'PY'
import json
import sys
import time

path, source = sys.argv[1:]
try:
    with open(path, encoding="utf-8") as handle:
        state = json.load(handle)
    entry = (state.get("sources") or {}).get(source) or {}
    if int(entry.get("cooldownUntilEpoch", 0)) > int(time.time()):
        raise SystemExit(0)
except (OSError, ValueError, TypeError, json.JSONDecodeError):
    pass
raise SystemExit(1)
PY
}

image_source_state_cached_probe() {
    python3 - "$SHDOME_IMAGE_SOURCE_STATE" "$1" "${SHDOME_IMAGE_SOURCE_HEALTH_TTL:-21600}" <<'PY'
import json
import sys
import time

path, source, ttl_raw = sys.argv[1:]
try:
    with open(path, encoding="utf-8") as handle:
        state = json.load(handle)
    entry = (state.get("sources") or {}).get(source) or {}
    epoch = int(entry.get("lastProbeEpoch", 0))
    status = entry.get("status", "")
    latency = entry.get("latencyMs", "")
    if status == "healthy" and not isinstance(latency, int):
        raise SystemExit(0)
    if epoch and int(time.time()) - epoch <= int(ttl_raw) and status in {"healthy", "unreachable"}:
        print(status, latency, sep="\t")
except (OSError, ValueError, TypeError, json.JSONDecodeError):
    pass
PY
}

image_source_pull_order() {
    local policy mode manual cached cached_allowed=0 cached_probe probe_status official_preferred=0 official_latency="" row_type label origin latency
    local -a mirrors=() healthy=() unavailable=()
    local -A emitted=()
    policy="$(image_source_policy_rows_safe)"
    IFS=$'\t' read -r _ mode manual <<<"$(printf '%s\n' "$policy" | head -n 1)"
    if [[ "$mode" == "official" ]]; then
        printf '官方源\tofficial\t\n'
        return 0
    fi
    while IFS=$'\t' read -r row_type label origin; do
        [[ "$row_type" == "MIRROR" ]] || continue
        mirrors+=("$label"$'\t'"$origin")
    done <<<"$policy"
    cached="$(image_source_state_cached_selected 2>/dev/null || true)"
    if [[ "$cached" == "official" ]]; then
        cached_allowed=1
    elif [[ "$cached" == https://* ]]; then
        for row_type in "${mirrors[@]}"; do
            IFS=$'\t' read -r _ origin <<<"$row_type"
            [[ "$cached" != "$origin" ]] || cached_allowed=1
        done
    fi
    [[ "$cached_allowed" == "1" ]] || cached=""
    if [[ -n "$cached" ]] && image_source_state_in_cooldown "$cached"; then
        cached=""
    fi

    image_source_emit() {
        local emit_label="$1" emit_origin="$2" emit_latency="${3:-}"
        [[ -z "${emitted[$emit_origin]:-}" ]] || return 0
        emitted["$emit_origin"]=1
        printf '%s\t%s\t%s\n' "$emit_label" "$emit_origin" "$emit_latency"
    }

    if [[ "$mode" == "manual" && -n "$manual" ]]; then
        image_source_emit "手工源" "$manual"
    elif [[ -n "$cached" ]]; then
        if [[ "$cached" == "official" ]]; then
            image_source_emit "官方源" official
        else
            image_source_emit "最近成功源" "$cached"
        fi
    else
        cached_probe="$(image_source_state_cached_probe official 2>/dev/null || true)"
        IFS=$'\t' read -r probe_status official_latency <<<"$cached_probe"
        if [[ "$probe_status" == "healthy" ]]; then
            if ((official_latency <= ${SHDOME_IMAGE_SOURCE_OFFICIAL_FAST_MS:-500})); then
                image_source_emit "官方源" official "$official_latency"
                official_preferred=1
            fi
        elif [[ "$probe_status" == "unreachable" ]]; then
            :
        elif official_latency="$(image_source_probe https://registry-1.docker.io)"; then
            image_source_state_record official probe "$official_latency"
            if ((official_latency <= ${SHDOME_IMAGE_SOURCE_OFFICIAL_FAST_MS:-500})); then
                image_source_emit "官方源" official "$official_latency"
                official_preferred=1
            fi
        else
            image_source_state_record official probe-failed
        fi
        if [[ "$official_preferred" != "1" ]]; then
            for row_type in "${mirrors[@]}"; do
                IFS=$'\t' read -r label origin <<<"$row_type"
                image_source_state_in_cooldown "$origin" && continue
                cached_probe="$(image_source_state_cached_probe "$origin" 2>/dev/null || true)"
                IFS=$'\t' read -r probe_status latency <<<"$cached_probe"
                if [[ "$probe_status" == "healthy" ]]; then
                    healthy+=("$latency"$'\t'"$label"$'\t'"$origin")
                elif [[ "$probe_status" == "unreachable" ]]; then
                    unavailable+=("$label"$'\t'"$origin")
                elif latency="$(image_source_probe "$origin")"; then
                    image_source_state_record "$origin" probe "$latency"
                    healthy+=("$latency"$'\t'"$label"$'\t'"$origin")
                else
                    image_source_state_record "$origin" probe-failed
                    unavailable+=("$label"$'\t'"$origin")
                fi
            done
        fi
        if [[ "$official_preferred" != "1" && "$official_latency" =~ ^[0-9]+$ ]] && \
           ((official_latency <= ${SHDOME_IMAGE_SOURCE_OFFICIAL_THRESHOLD_MS:-3000})); then
            local fastest_mirror=""
            if ((${#healthy[@]})); then
                fastest_mirror="$(printf '%s\n' "${healthy[@]}" | LC_ALL=C sort -n -k1,1 | head -n 1 | cut -f1)"
            fi
            if [[ -z "$fastest_mirror" ]] || \
               ((fastest_mirror * 100 >= official_latency * ${SHDOME_IMAGE_SOURCE_MIRROR_ADVANTAGE_PERCENT:-70})); then
                image_source_emit "官方源" official "$official_latency"
                official_preferred=1
            fi
        fi
        if ((${#healthy[@]})); then
            while IFS=$'\t' read -r latency label origin; do
                image_source_emit "$label" "$origin" "$latency"
            done < <(printf '%s\n' "${healthy[@]}" | LC_ALL=C sort -n -k1,1)
        fi
    fi

    for row_type in "${mirrors[@]}"; do
        IFS=$'\t' read -r label origin <<<"$row_type"
        image_source_state_in_cooldown "$origin" && continue
        image_source_emit "$label" "$origin"
    done
    image_source_emit "官方源" official "$official_latency"
    for row_type in "${unavailable[@]}"; do
        IFS=$'\t' read -r label origin <<<"$row_type"
        image_source_emit "$label" "$origin"
    done
}

image_source_pull() {
    local image="$1" label source latency pull_ref output_file status summary attempts=""
    [[ -n "$image" ]] || { fail "镜像引用不能为空" 64; return; }
    require_command docker || return
    if image_source_image_recent "$image" && docker image inspect "$image" >/dev/null 2>&1; then
        return 0
    fi
    if ! image_source_is_docker_hub "$image" || image_source_docker_hub_authenticated; then
        if docker pull "$image"; then
            image_source_state_record "direct:${image%%/*}" success "" "" "$image"
            return 0
        fi
        if docker image inspect "$image" >/dev/null 2>&1; then
            warn "远程镜像暂时不可用，将使用本机缓存：$image"
            image_source_state_record cache success "" "" "$image"
            return 0
        fi
        fail "无法拉取或读取镜像：$image" 69
        return
    fi

    output_file="$(mktemp "$SHDOME_STATE_DIR/.image-pull.XXXXXX")" || return
    while IFS=$'\t' read -r label source latency; do
        [[ -n "$source" ]] || continue
        if [[ "$source" == "official" ]]; then
            pull_ref="$image"
        else
            pull_ref="$(image_source_mirror_reference "$image" "$source")" || continue
            info "Docker Hub 较慢或不可用，正在使用镜像源：$source"
        fi
        : >"$output_file"
        if docker pull "$pull_ref" 2>&1 | tee "$output_file"; then
            if [[ "$source" != "official" ]]; then
                if ! docker tag "$pull_ref" "$image"; then
                    image_source_state_record "$source" failed "$latency" "镜像标记失败"
                    continue
                fi
                docker image rm "$pull_ref" >/dev/null 2>&1 || true
            fi
            image_source_state_record "$source" success "$latency" "" "$image"
            rm -f -- "$output_file"
            return 0
        else
            status=${PIPESTATUS[0]}
        fi
        summary="$(tail -n 3 "$output_file" | tr '\n\r\t' ' ' | sed 's/[[:space:]][[:space:]]*/ /g')"
        attempts="${attempts:+$attempts；}$label(${status:-1})"
        image_source_state_record "$source" failed "$latency" "$summary"
        if [[ "$source" == "official" && "$summary" =~ [Uu]nauthorized|authentication[[:space:]]required|access[[:space:]]denied|[Ff]orbidden ]]; then
            rm -f -- "$output_file"
            fail "Docker Hub 认证失败；为保护私有仓库信息，未尝试公共镜像源" 69
            return
        fi
        warn "$label 拉取失败，正在尝试其他来源"
    done < <(image_source_pull_order)
    rm -f -- "$output_file"
    if docker image inspect "$image" >/dev/null 2>&1; then
        warn "所有远程来源暂时不可用，将使用本机缓存：$image"
        image_source_state_record cache success "" "" "$image"
        return 0
    fi
    fail "无法拉取镜像 $image；已尝试：${attempts:-无可用来源}" 69
}

image_source_config_write() {
    local mode="$1" manual="${2:-}"
    python3 - "$SHDOME_IMAGE_SOURCE_CONFIG" "$mode" "$manual" <<'PY'
import ipaddress
import json
import os
import re
import tempfile
import sys
from urllib.parse import urlsplit

path, mode, manual = sys.argv[1:]
mirrors = []


def normalize_existing(value):
    if not isinstance(value, str) or not value or any(ord(char) < 33 for char in value):
        raise ValueError
    parsed = urlsplit(value)
    if parsed.scheme != "https" or not parsed.hostname or parsed.username or parsed.password:
        raise ValueError
    if parsed.path not in {"", "/"} or parsed.query or parsed.fragment:
        raise ValueError
    try:
        port = parsed.port
    except ValueError as exc:
        raise ValueError from exc
    hostname = parsed.hostname.lower().rstrip(".")
    try:
        ipaddress.ip_address(hostname.strip("[]"))
    except ValueError:
        if len(hostname) > 253 or not re.fullmatch(
            r"(?=.{1,253}$)(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)*[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?",
            hostname,
        ):
            raise ValueError
    host = f"[{hostname}]" if ":" in hostname else hostname
    if port is not None:
        host += f":{port}"
    return "https://" + host


try:
    with open(path, encoding="utf-8") as handle:
        old = json.load(handle)
    if isinstance(old.get("mirrors"), list):
        for item in old["mirrors"][:8]:
            try:
                normalized = normalize_existing(item)
            except ValueError:
                continue
            if normalized not in mirrors:
                mirrors.append(normalized)
except (OSError, AttributeError, json.JSONDecodeError, TypeError):
    pass
value = {"schema": 1, "mode": mode, "manualMirror": manual, "mirrors": mirrors}
os.makedirs(os.path.dirname(path), mode=0o750, exist_ok=True)
descriptor, temporary = tempfile.mkstemp(prefix=".image-sources.", dir=os.path.dirname(path))
try:
    os.fchmod(descriptor, 0o640)
    with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
        json.dump(value, handle, ensure_ascii=False, indent=2)
        handle.write("\n")
    os.replace(temporary, path)
finally:
    if os.path.exists(temporary):
        os.unlink(temporary)
PY
}

image_source_status() {
    local policy mode manual
    policy="$(image_source_policy_rows_safe)"
    IFS=$'\t' read -r _ mode manual <<<"$(printf '%s\n' "$policy" | head -n 1)"
    printf '模式：%s\n' "$mode"
    [[ -z "$manual" ]] || printf '手工首选：%s\n' "$manual"
    python3 - "$SHDOME_IMAGE_SOURCE_STATE" <<'PY'
import json
import sys

try:
    with open(sys.argv[1], encoding="utf-8") as handle:
        state = json.load(handle)
except (OSError, json.JSONDecodeError):
    print("最近成功来源：尚无记录")
    raise SystemExit(0)
print("最近成功来源：" + (state.get("selected") or "尚无记录"))
if state.get("lastSuccessAt"):
    print("最近成功时间：" + state["lastSuccessAt"])
if state.get("lastFailureAt"):
    print("最近失败时间：" + state["lastFailureAt"])
if state.get("lastError"):
    print("最近失败摘要：" + state["lastError"])
sources = state.get("sources") or {}
if sources:
    print("来源健康：")
    labels = {"healthy": "可用", "unreachable": "不可用", "failed": "拉取失败"}
    for source in sorted(sources):
        entry = sources[source] if isinstance(sources[source], dict) else {}
        status = labels.get(entry.get("status"), "未知")
        latency = entry.get("latencyMs")
        latency_text = f"，{latency} ms" if isinstance(latency, int) else ""
        failures = entry.get("failures", 0)
        failure_text = f"，连续失败 {failures} 次" if isinstance(failures, int) and failures else ""
        print(f"  {source}：{status}{latency_text}{failure_text}")
PY
}

image_source_test() {
    local policy row_type label origin latency available=0
    policy="$(image_source_policy_rows_safe)"
    printf '%-28s %-10s %s\n' '来源' '状态' '延迟'
    if latency="$(image_source_probe https://registry-1.docker.io)"; then
        printf '%-28s %-10s %s ms\n' 'Docker Hub 官方源' '可用' "$latency"
        image_source_state_record official probe "$latency"
        available=1
    else
        printf '%-28s %-10s %s\n' 'Docker Hub 官方源' '不可用' '-'
        image_source_state_record official probe-failed
    fi
    while IFS=$'\t' read -r row_type label origin; do
        [[ "$row_type" == "MIRROR" ]] || continue
        if latency="$(image_source_probe "$origin")"; then
            printf '%-28s %-10s %s ms\n' "$label" '可用' "$latency"
            image_source_state_record "$origin" probe "$latency"
            available=1
        else
            printf '%-28s %-10s %s\n' "$label" '不可用' '-'
            image_source_state_record "$origin" probe-failed
        fi
    done <<<"$policy"
    [[ "$available" == "1" ]]
}

image_source_reset() {
    require_root || return
    rm -f -- "$SHDOME_IMAGE_SOURCE_CONFIG" "$SHDOME_IMAGE_SOURCE_STATE"
    success "已恢复自动镜像源默认策略"
}

image_source_command() {
    local action="${1:-status}" normalized
    case "$action" in
        status) image_source_status ;;
        test) image_source_test ;;
        auto)
            require_root || return
            image_source_config_write auto ""
            success "已启用自动镜像源"
            ;;
        official)
            require_root || return
            image_source_config_write official ""
            success "已设置为仅使用官方源"
            ;;
        set)
            require_root || return
            [[ -n "${2:-}" ]] || { fail "用法：k env mirror set <https-origin>" 64; return; }
            normalized="$(image_source_url_normalize "$2")" || { fail "镜像源地址无效" 64; return; }
            image_source_config_write manual "$normalized"
            success "已设置手工首选镜像源：$normalized"
            ;;
        reset) image_source_reset ;;
        *) fail "用法：k env mirror [status|test|auto|official|set|reset]" 64 ;;
    esac
}
