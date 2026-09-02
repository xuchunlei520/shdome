#!/usr/bin/env bash

lock_run() {
    local lock_name="$1"
    shift
    valid_lock_name "$lock_name" || { fail "无效锁名称：$lock_name" 70; return; }
    require_command flock || return
    local lock_file="$SHDOME_LOCK_DIR/${lock_name}.lock"
    mkdir -p "$SHDOME_LOCK_DIR" || { fail "无法创建锁目录：$SHDOME_LOCK_DIR" 70; return; }
    (
        flock -n 9 || { fail "另一个 SHDome 操作正在占用锁：$lock_name" 75; return; }
        "$@"
    ) 9>"$lock_file"
}

valid_lock_name() {
    [[ "$1" =~ ^[a-zA-Z0-9._-]+$ ]]
}
