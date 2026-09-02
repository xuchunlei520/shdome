#!/usr/bin/env bash

log_event() {
    local level="$1" action="$2" message="$3"
    local log_file="${SHDOME_LOG_DIR:-/tmp}/shdome.log"
    mkdir -p "$(dirname "$log_file")"
    printf '%s\t%s\t%s\t%s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$level" "$action" "$message" >>"$log_file"
}
