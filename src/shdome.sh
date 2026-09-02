#!/usr/bin/env bash
set -Eeuo pipefail

shdome_entry_path="${BASH_SOURCE[0]}"
while [[ -L "$shdome_entry_path" ]]; do
    shdome_entry_dir="$(cd "$(dirname "$shdome_entry_path")" && pwd)"
    shdome_entry_path="$(readlink "$shdome_entry_path")"
    [[ "$shdome_entry_path" == /* ]] || shdome_entry_path="$shdome_entry_dir/$shdome_entry_path"
done
SHDOME_SOURCE_DIR="$(cd "$(dirname "$shdome_entry_path")" && pwd)"
export SHDOME_SOURCE_DIR

shdome_load() {
    local file
    for file in \
        core/config.sh \
        core/terminal.sh \
        core/logger.sh \
        core/locks.sh \
        core/state.sh \
        core/module_registry.sh \
        core/menu_registry.sh \
        core/router.sh \
        core/self_update.sh; do
        # shellcheck source=/dev/null
        source "$SHDOME_SOURCE_DIR/$file"
    done
    modules_load
}

shdome_main() {
    shdome_load
    shdome_auto_elevate "$@"
    shdome_config_init
    shdome_register_builtin_commands
    modules_activate
    route_command "$@"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    shdome_main "$@"
fi
