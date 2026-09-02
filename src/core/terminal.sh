#!/usr/bin/env bash

terminal_is_interactive() {
    [[ -r /dev/tty && -w /dev/tty ]]
}

terminal_read() {
    local __var_name="$1" prompt="$2" default_value="${3:-}" value
    terminal_is_interactive || { fail "当前操作需要交互终端；SSH 请使用 ssh -t，自动化请补全参数并使用 --yes" 64; return; }
    printf '%s' "$prompt" >/dev/tty
    IFS= read -r value </dev/tty || return 130
    [[ -n "$value" ]] || value="$default_value"
    printf -v "$__var_name" '%s' "$value"
}

terminal_confirm() {
    local prompt="$1" answer
    if [[ "${SHDOME_ASSUME_YES:-0}" == "1" ]]; then
        return 0
    fi
    terminal_read answer "$prompt [y/N]: " ""
    [[ "$answer" =~ ^[Yy]([Ee][Ss])?$ ]]
}

terminal_pause() {
    local ignored=""
    terminal_is_interactive || return 0
    terminal_read ignored "按回车键继续..." ""
    : "$ignored"
}

terminal_columns() {
    local columns="" terminal_size=""
    if [[ -t 1 ]] && [[ -r /dev/tty ]]; then
        terminal_size="$(stty size </dev/tty 2>/dev/null || true)"
        columns="${terminal_size##* }"
    elif [[ "${COLUMNS:-}" =~ ^[0-9]+$ ]]; then
        columns="$COLUMNS"
    fi
    [[ "$columns" =~ ^[0-9]+$ ]] && ((columns >= 20)) || columns=160
    printf '%s\n' "$columns"
}

terminal_render_table() {
    local column_count="$1" columns
    columns="$(terminal_columns)"
    python3 - "$column_count" "$columns" 3<&0 <<'PY'
import os
import re
import sys
import unicodedata

column_count = int(sys.argv[1])
terminal_width = int(sys.argv[2])
values = os.fdopen(3, "rb").read().decode("utf-8", "replace").split("\0")
if values and values[-1] == "":
    values.pop()
if not values or len(values) % column_count:
    raise SystemExit("invalid table data")
rows = [values[index:index + column_count] for index in range(0, len(values), column_count)]


def clean(value):
    return "".join(
        character if character in "\n\t" or unicodedata.category(character)[0] != "C" else " "
        for character in value
    ).replace("\t", "    ")


def character_width(character):
    if unicodedata.combining(character) or unicodedata.category(character) in {"Cf", "Me"}:
        return 0
    return 2 if unicodedata.east_asian_width(character) in {"W", "F"} else 1


def display_width(value):
    return sum(character_width(character) for character in value)


def wrap_line(value, width):
    value = value.strip()
    if not value:
        return [""]
    result = []
    while value:
        used = 0
        end = 0
        for end, character in enumerate(value, 1):
            next_width = used + character_width(character)
            if next_width > width and used:
                end -= 1
                break
            used = next_width
        else:
            result.append(value)
            break
        candidate = value[:end]
        whitespace = [match.start() for match in re.finditer(r"\s+", candidate)]
        if whitespace:
            end = whitespace[-1]
            candidate = value[:end]
        candidate = candidate.rstrip()
        if not candidate:
            candidate = value[:max(end, 1)]
            end = max(end, 1)
        result.append(candidate)
        value = value[end:].lstrip()
    return result


def wrap(value, width):
    result = []
    for line in clean(value).splitlines() or [""]:
        result.extend(wrap_line(line, width))
    return result or [""]


def pad(value, width):
    return value + " " * max(0, width - display_width(value))


gap = "  "
fixed_widths = [max(display_width(clean(row[index])) for row in rows) for index in range(column_count - 1)]
description_width = terminal_width - sum(fixed_widths) - len(gap) * (column_count - 1)

# Very narrow terminals get a compact card layout so every value remains readable.
if description_width < 12:
    header, data_rows = rows[0], rows[1:]
    for row in data_rows:
        title_prefix = f"{clean(row[0])}. "
        title_width = max(1, terminal_width - display_width(title_prefix))
        title = f"{clean(row[1])}  {clean(row[2])}  {clean(row[3])}"
        title_lines = wrap(title, title_width)
        print(title_prefix + title_lines[0])
        for line in title_lines[1:]:
            print(" " * display_width(title_prefix) + line)
        description_prefix = f"   {clean(header[-1])}："
        continuation = " " * display_width(description_prefix)
        description_lines = wrap(row[-1], max(1, terminal_width - display_width(description_prefix)))
        print(description_prefix + description_lines[0])
        for line in description_lines[1:]:
            print(continuation + line)
    raise SystemExit(0)

widths = fixed_widths + [description_width]
for row_index, row in enumerate(rows):
    wrapped_cells = [wrap(value, width) for value, width in zip(row, widths)]
    height = max(len(cell) for cell in wrapped_cells)
    for line_index in range(height):
        cells = [cell[line_index] if line_index < len(cell) else "" for cell in wrapped_cells]
        print(gap.join(pad(value, width) for value, width in zip(cells[:-1], widths[:-1])) + gap + cells[-1])
    if row_index == 0:
        print("-" * terminal_width)
PY
}

info() { printf '[信息] %s\n' "$*"; }
success() { printf '[完成] %s\n' "$*"; }
warn() { printf '[警告] %s\n' "$*" >&2; }
error() { printf '[错误] %s\n' "$*" >&2; }

fail() {
    local message="$1" code="${2:-1}"
    error "$message"
    return "$code"
}
