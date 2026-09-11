# shellcheck shell=bash
# lib/targets.sh — targets.txt parsing for default install/list/doctor scope.
# Requires lib/providers.sh (is_known_cli, SUPPORTED_CLIS).

# targets_file_path: path to the repo-root targets.txt.
targets_file_path() {
    if [ -z "${TB_ROOT:-}" ]; then
        log_error "TB_ROOT is not set; cannot locate targets.txt"
        return 1
    fi
    printf '%s' "${TB_ROOT}/targets.txt"
}

# _normalize_target_line: strip comments and surrounding whitespace.
_normalize_target_line() {
    local line="$1" name=""
    name=${line%%#*}
    name=$(printf '%s' "$name" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
    printf '%s' "$name"
}

# load_targets: read targets.txt into TB_TARGETS (deduplicated, order preserved).
# Fails when the file is missing, has no valid entries, or contains unknown names.
load_targets() {
    TB_TARGETS=()
    local path="" line="" name="" seen=""
    local names
    names=()
    path=$(targets_file_path) || return 1
    if [ ! -f "$path" ]; then
        log_error "targets file not found: $path"
        return 1
    fi
    while IFS= read -r line || [ -n "$line" ]; do
        name=$(_normalize_target_line "$line")
        [ -z "$name" ] && continue
        if ! is_known_cli "$name"; then
            log_error "unknown CLI in targets.txt: $name"
            log_error "supported: ${SUPPORTED_CLIS[*]}"
            return 2
        fi
        seen=""
        for n in "${names[@]}"; do
            if [ "$n" = "$name" ]; then
                seen=1
                break
            fi
        done
        [ -n "$seen" ] && continue
        names+=("$name")
    done <"$path"
    if [ "${#names[@]}" -eq 0 ]; then
        log_error "no valid CLI entries in targets.txt: $path"
        return 1
    fi
    TB_TARGETS=("${names[@]}")
    return 0
}

# resolve_command_clis <use_targets> [name...]
# When use_targets=1 and no names are given, loads TB_TARGETS from targets.txt.
# Otherwise uses the provided names. Populates TB_COMMAND_CLIS.
resolve_command_clis() {
    local use_targets="$1"
    shift
    TB_COMMAND_CLIS=()
    if [ "$use_targets" -eq 1 ] && [ "$#" -eq 0 ]; then
        load_targets || return $?
        TB_COMMAND_CLIS=("${TB_TARGETS[@]}")
        return 0
    fi
    if [ "$#" -eq 0 ]; then
        log_error "no CLI names specified"
        return 2
    fi
    TB_COMMAND_CLIS=("$@")
    return 0
}

# validate_cli_names: ensure every name is supported.
validate_cli_names() {
    local name=""
    for name in "$@"; do
        if ! is_known_cli "$name"; then
            log_error "unknown CLI: $name"
            log_error "supported: ${SUPPORTED_CLIS[*]}"
            log_error "recognized but unsupported: ${UNSUPPORTED_CLIS[*]}"
            return 2
        fi
    done
    return 0
}
