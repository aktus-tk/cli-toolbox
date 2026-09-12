#!/usr/bin/env bash
# cli-toolbox — idempotent installer for cloud/ops CLIs (terraform-apply style)
#
# States: not installed -> install; old -> update; stable-latest -> unchanged;
# failure -> keep existing good binary; unmanaged CLI -> never deleted.
set -u

TB_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export TB_ROOT
# shellcheck source=lib/common.sh
. "$TB_ROOT/lib/common.sh"
# shellcheck source=lib/packages.sh
. "$TB_ROOT/lib/packages.sh"
# shellcheck source=lib/providers.sh
. "$TB_ROOT/lib/providers.sh"
# shellcheck source=lib/targets.sh
. "$TB_ROOT/lib/targets.sh"
# shellcheck source=lib/installers.sh
. "$TB_ROOT/lib/installers.sh"

usage() {
    cat <<'EOF'
cli-toolbox.sh — idempotent installer for cloud/ops CLIs

Usage:
  cli-toolbox.sh install [CLI...]   converge CLIs to official stable-latest (install or update)
  cli-toolbox.sh delete [CLI...]    remove cli-toolbox managed installs (system apt/brew untouched)
  cli-toolbox.sh doctor             check environment and installed CLIs from targets.txt
  cli-toolbox.sh list [CLI...]      show status table (CLI, status, current, latest, path, provider, state)
  cli-toolbox.sh help               show this help

When install, list, or doctor is run without CLI arguments, targets.txt in the repo root is used.

Supported CLIs (install explicitly when omitted from targets.txt):
  az coscli oci kubectl helm awst gcloudt tcclit

AI agent CLIs (install explicitly; not in targets.txt by default):
  opencode agent (Cursor Agent CLI) codebuddy claude codex agy
EOF
}

# ---------------------------------------------------------------------------
# install
# ---------------------------------------------------------------------------

cmd_install() {
    local clis=()
    if ! resolve_command_clis 1 "$@"; then
        return $?
    fi
    clis=("${TB_COMMAND_CLIS[@]}")
    validate_cli_names "${clis[@]}" || return $?

    require_cmd curl

    local installed=0 updated=0 unchanged=0 failed=0
    local -a failed_names=()
    local state detail name
    for name in "${clis[@]}"; do
        run_installer "$name"
        state="${TB_STATE:-error}"
        detail="${TB_DETAIL:-}"
        printf '%-10s %-10s %s\n' "$(cli_display_name "$name")" "$state" "$detail"
        case "$state" in
            installed) installed=$((installed + 1)) ;;
            updated) updated=$((updated + 1)) ;;
            unchanged) unchanged=$((unchanged + 1)) ;;
            *)
                failed=$((failed + 1))
                failed_names+=("$name")
                ;;
        esac
    done

    printf '\nApply complete: %d installed, %d updated, %d unchanged, %d failed\n' \
        "$installed" "$updated" "$unchanged" "$failed"
    if [ "$failed" -gt 0 ]; then
        local joined="" n
        for n in "${failed_names[@]}"; do
            if [ -n "$joined" ]; then
                joined="${joined}, ${n}"
            else
                joined="$(cli_display_name "$n")"
            fi
        done
        printf 'Failed: %s\n' "$joined"
        return 1
    fi
    return 0
}

# ---------------------------------------------------------------------------
# delete
# ---------------------------------------------------------------------------

cmd_delete() {
    local clis=()
    if [ $# -eq 0 ]; then
        log_error "delete requires at least one CLI name"
        log_error "example: cli-toolbox.sh delete glow gcloud"
        return 2
    fi
    clis=("$@")
    validate_cli_names "${clis[@]}" || return $?

    local deleted=0 skipped=0 failed=0
    local -a failed_names=()
    local state detail name
    for name in "${clis[@]}"; do
        run_uninstaller "$name"
        state="${TB_STATE:-error}"
        detail="${TB_DETAIL:-}"
        printf '%-10s %-20s %s\n' "$(cli_display_name "$name")" "$state" "$detail"
        case "$state" in
            deleted) deleted=$((deleted + 1)) ;;
            skipped-not-managed | skipped-system) skipped=$((skipped + 1)) ;;
            *)
                failed=$((failed + 1))
                failed_names+=("$name")
                ;;
        esac
    done

    printf '\nDelete complete: %d deleted, %d skipped, %d failed\n' \
        "$deleted" "$skipped" "$failed"
    if [ "$failed" -gt 0 ]; then
        local joined="" n
        for n in "${failed_names[@]}"; do
            if [ -n "$joined" ]; then
                joined="${joined}, ${n}"
            else
                joined="$(cli_display_name "$n")"
            fi
        done
        printf 'Failed: %s\n' "$joined"
        return 1
    fi
    return 0
}

# ---------------------------------------------------------------------------
# doctor
# ---------------------------------------------------------------------------

doctor_config() {
    local name="$1" found="no" what=""
    case "$name" in
        gh)
            if [ -n "${GH_TOKEN:-}" ] || [ -n "${GITHUB_TOKEN:-}" ] || [ -f "$HOME/.config/gh/hosts.yml" ]; then
                found=yes
                what="GH_TOKEN/GITHUB_TOKEN/gh hosts.yml"
            fi
            ;;
        aws)
            if [ -n "${AWS_PROFILE:-}" ] || [ -d "$HOME/.aws" ]; then
                found=yes
                what="AWS_PROFILE/~/.aws"
            fi
            ;;
        gcloud)
            if [ -n "${CLOUDSDK_CONFIG:-}" ] || [ -d "$HOME/.config/gcloud" ]; then
                found=yes
                what="CLOUDSDK_CONFIG/~/.config/gcloud"
            fi
            ;;
        tccli)
            if [ -d "$HOME/.tccli" ] || env | grep -q '^TENCENTCLOUD_'; then
                found=yes
                what='$HOME/.tccli or TENCENTCLOUD_* env'
            fi
            ;;
        az)
            if [ -n "${AZURE_CONFIG_DIR:-}" ] || [ -d "$HOME/.azure" ]; then
                found=yes
                what="AZURE_CONFIG_DIR/~/.azure"
            fi
            ;;
        terraform)
            if [ -n "${TF_CLI_CONFIG_FILE:-}" ] || [ -f "$HOME/.terraformrc" ] \
                || [ -d "$HOME/.terraform.d" ]; then
                found=yes
                what="TF_CLI_CONFIG_FILE/~/.terraformrc/~/.terraform.d"
            fi
            ;;
        kubectl)
            if [ -n "${KUBECONFIG:-}" ] || [ -f "$HOME/.kube/config" ]; then
                found=yes
                what="KUBECONFIG/~/.kube/config"
            fi
            ;;
        helm)
            if [ -n "${HELM_CACHE_HOME:-}" ] || [ -d "$HOME/.config/helm" ]; then
                found=yes
                what="HELM_CACHE_HOME/~/.config/helm"
            fi
            ;;
        oci)
            if [ -n "${OCI_CLI_CONFIG:-}" ] || [ -f "$HOME/.oci/config" ]; then
                found=yes
                what="OCI_CLI_CONFIG/~/.oci/config"
            fi
            ;;
        opencode | agent | codebuddy | claude | codex | agy)
            printf 'OK   %-10s config: n/a (auth not managed by cli-toolbox)\n' "$(cli_display_name "$name")"
            return 0
            ;;
        *)
            printf 'OK   %-10s config: n/a\n' "$name"
            return 0
            ;;
    esac
    if [ "$found" = "yes" ]; then
        printf 'OK   %-10s config present (%s)\n' "$(cli_display_name "$name")" "$what"
    else
        printf 'WARN %-10s no config/env found (%s)\n' "$(cli_display_name "$name")" "$what"
    fi
}

# doctor_one <cli>: prints OK/WARN/ERROR lines; returns 1 only on ERROR.
doctor_one() {
    local name="$1" r=0
    local resolved="" exe="no" ver="" managed="no" label=""
    label=$(cli_display_name "$name")
    if [ -e "$CLI_TOOLBOX_HOME/bin/$name" ] || [ -L "$CLI_TOOLBOX_HOME/bin/$name" ]; then
        managed="yes"
    fi
    resolved=$(resolve_path "$name") || resolved=""
    if [ -z "$resolved" ]; then
        printf 'ERROR %-10s not found on PATH — install with: cli-toolbox.sh install %s\n' "$label" "$name"
        return 1
    fi
    [ -x "$resolved" ] && exe="yes"
    ver=$(_parse_version "$name" "$resolved")
    printf 'OK   %-10s path=%s managed=%s executable=%s version=%s\n' \
        "$label" "$resolved" "$managed" "$exe" "${ver:-?}"
    if [ "$exe" = "no" ]; then
        printf 'ERROR %-10s not executable\n' "$label"
        r=1
    fi
    if [ -z "$ver" ]; then
        printf 'WARN %-10s version could not be determined\n' "$label"
    fi
    if [ "$managed" = "yes" ] && ! is_managed "$resolved"; then
        printf 'WARN %-10s another same-name CLI earlier in PATH shadows the managed binary\n' "$label"
    fi
    case "$name" in
        tccli)
            if uv_tool_has tccli; then
                printf 'OK   %-10s managed by uv tool\n' "$label"
            elif cmd_exists uv; then
                printf 'WARN %-10s not yet installed via uv tool\n' "$label"
            else
                printf 'WARN %-10s uv not found (required for tccli)\n' "$label"
            fi
            ;;
        uv)
            if cmd_exists uv; then
                printf 'OK   %-10s uv present\n' "$label"
            else
                printf 'ERROR %-10s uv missing\n' "$label"
                r=1
            fi
            ;;
    esac
    doctor_config "$name"
    return "$r"
}

cmd_doctor() {
    local rc=0 warns=0 errs=0 name
    local -a clis=()
    if ! resolve_command_clis 1; then
        return $?
    fi
    clis=("${TB_COMMAND_CLIS[@]}")

    if detect_platform; then
        printf 'OK   os/arch: %s/%s\n' "$TB_OS" "$TB_ARCH"
    else
        rc=1
        errs=$((errs + 1))
        printf 'ERROR os/arch: unsupported (%s/%s)\n' "${TB_OS:-?}" "${TB_ARCH:-?}"
    fi

    if printf ':%s:' "$PATH" | grep -Fq ":$CLI_TOOLBOX_HOME/bin:"; then
        printf 'OK   PATH: %s/bin is on PATH\n' "$CLI_TOOLBOX_HOME"
    else
        warns=$((warns + 1))
        printf 'WARN PATH: %s/bin is not on PATH\n' "$CLI_TOOLBOX_HOME"
        if [ "${TB_OS:-}" = "darwin" ]; then
            printf '     add to ~/.zshrc: export PATH="%s/bin:$HOME/.local/bin:$PATH"\n' "$CLI_TOOLBOX_HOME"
        else
            printf '     add: export PATH="%s/bin:$PATH"\n' "$CLI_TOOLBOX_HOME"
        fi
    fi

    if [ "${TB_OS:-}" = "darwin" ] && ! has_brew; then
        warns=$((warns + 1))
        printf 'WARN Homebrew is not installed (required for gh/az/aws on macOS)\n'
        printf '     install: https://brew.sh\n'
    fi

    local tool_bin
    tool_bin=$(uv_tool_bin_dir)
    if printf ':%s:' "$PATH" | grep -Fq ":${tool_bin}:"; then
        printf 'OK   PATH: %s is on PATH (uv tool binaries)\n' "$tool_bin"
    else
        warns=$((warns + 1))
        printf 'WARN PATH: %s is not on PATH (needed for uv-managed tccli)\n' "$tool_bin"
        printf '     add: export PATH="%s:$PATH"\n' "$tool_bin"
    fi

    local broken
    broken=$(detect_broken_symlinks)
    if [ -n "$broken" ]; then
        warns=$((warns + 1))
        printf 'WARN broken symlinks in %s/bin:\n' "$CLI_TOOLBOX_HOME"
        printf '%s\n' "$broken" | sed 's/^/     /'
    else
        printf 'OK   no broken symlinks in %s/bin\n' "$CLI_TOOLBOX_HOME"
    fi

    for name in "${clis[@]}"; do
        if ! doctor_one "$name"; then
            rc=1
            errs=$((errs + 1))
        fi
    done

    printf '\nDoctor summary: %d errors, %d warnings\n' "$errs" "$warns"
    return "$rc"
}

# ---------------------------------------------------------------------------
# list
# ---------------------------------------------------------------------------

list_one() {
    local name="$1"
    inspect_cli "$name" || true
    format_list_row "$(cli_display_name "$name")" \
        "${TB_LIST_STATUS}" \
        "${TB_LIST_CURRENT:--}" \
        "${TB_LIST_LATEST:--}" \
        "${TB_LIST_PATH:--}" \
        "${TB_LIST_PROVIDER}" \
        "${TB_LIST_STATE}"
}

cmd_list() {
    local clis=() name="" rows=""
    if ! resolve_command_clis 1 "$@"; then
        return $?
    fi
    clis=("${TB_COMMAND_CLIS[@]}")
    validate_cli_names "${clis[@]}" || return $?
    for name in "${clis[@]}"; do
        rows+="$(list_one "$name")"
        rows+=$'\n'
    done
    print_list_table "$rows"
    return 0
}

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------

main() {
    local cmd="${1:-help}"
    case "$cmd" in
        install)
            shift
            cmd_install "$@"
            ;;
        delete | remove | uninstall)
            shift
            cmd_delete "$@"
            ;;
        doctor)
            cmd_doctor
            ;;
        list)
            shift
            cmd_list "$@"
            ;;
        help | -h | --help)
            usage
            ;;
        "")
            usage
            ;;
        *)
            log_error "unknown command: $cmd"
            usage
            exit 2
            ;;
    esac
}

main "$@"
