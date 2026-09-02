#!/usr/bin/env bash

declare -ag SHDOME_MODULE_IDS=()
declare -ag SHDOME_MODULE_HANDLERS=()

module_register() {
    local module_id="$1" handler="$2" existing
    [[ "$module_id" =~ ^[a-z][a-z0-9_]*$ ]] || { fail "无效模块 ID：$module_id" 70; return; }
    declare -F "$handler" >/dev/null || { fail "模块注册函数不存在：$handler" 70; return; }
    for existing in "${SHDOME_MODULE_IDS[@]:-}"; do
        [[ "$existing" != "$module_id" ]] || { fail "模块重复注册：$module_id" 70; return; }
    done
    SHDOME_MODULE_IDS+=("$module_id")
    SHDOME_MODULE_HANDLERS+=("$handler")
}

modules_load() {
    local module_entry
    for module_entry in "$SHDOME_SOURCE_DIR"/modules/*/module.sh; do
        [[ -f "$module_entry" ]] || continue
        # 模块入口属于经过发布包校验的可信源码。
        # shellcheck source=/dev/null
        source "$module_entry"
    done
}

modules_activate() {
    local handler
    for handler in "${SHDOME_MODULE_HANDLERS[@]:-}"; do
        "$handler"
    done
}
