# shellcheck shell=bash
# lib/providers.sh — CLI provider metadata, inspection, and list status logic.
# Requires lib/common.sh to be sourced first.

if [ -z "${CLOUD_CLI_REPO:-}" ]; then
    CLOUD_CLI_REPO="${HOME:-}/github/aktus-tk/cloud-cli"
fi
export CLOUD_CLI_REPO

# Standard set: uv first (tccli depends on it).
# shellcheck disable=SC2034
STANDARD_SET=(uv gh glow coscli tccli aws gcloud az)

SUPPORTED_CLIS=(uv gh glow coscli tccli aws gcloud az awst gcloudt tcclit)
UNSUPPORTED_CLIS=()

is_supported() {
    local name="$1" c
    for c in "${SUPPORTED_CLIS[@]}"; do
        [ "$c" = "$name" ] && return 0
    done
    return 1
}

is_known_cli() {
    is_supported "$1"
}

unsupported_reason() {
    printf '%s' "unknown CLI"
}

# Preferred provider per CLI (fixed policy).
cli_preferred_provider() {
    case "$1" in
        uv | aws) printf '%s' "official-installer" ;;
        tccli) printf '%s' "uv-tool" ;;
        gh | gcloud | az) printf '%s' "official-package" ;;
        glow | coscli) printf '%s' "release-binary" ;;
        awst | gcloudt | tcclit) printf '%s' "local-wrapper" ;;
        *) printf '%s' "unknown" ;;
    esac
}

# APT package name for official-package CLIs.
cli_apt_package() {
    case "$1" in
        gh) printf '%s' "gh" ;;
        gcloud) printf '%s' "google-cloud-cli" ;;
        az) printf '%s' "azure-cli" ;;
    esac
}

# uv tool package name (PyPI) for uv-tool CLIs.
cli_uv_tool_package() {
    case "$1" in
        tccli) printf '%s' "tccli" ;;
    esac
}

# Wrapper source path inside CLOUD_CLI_REPO.
cli_wrapper_source() {
    case "$1" in
        awst) printf '%s' "aws-cli/bin/awst" ;;
        gcloudt) printf '%s' "g-cli/bin/gcloudt" ;;
        tcclit) printf '%s' "tc-cli/bin/tcclit" ;;
    esac
}

# Native CLI dependencies for local wrappers.
cli_wrapper_requires() {
    case "$1" in
        awst) printf '%s' "aws" ;;
        gcloudt) printf '%s' "gcloud" ;;
        tcclit) printf '%s' "tccli" ;;
    esac
}

manifest_path() {
    printf '%s' "$CLOUD_TOOLBOX_HOME/state/manifest.tsv"
}

manifest_ensure() {
    mkdir -p "$CLOUD_TOOLBOX_HOME/state"
    [ -f "$(manifest_path)" ] || : >"$(manifest_path)"
}

# manifest_record <cli> <provider> <version> <path>
manifest_record() {
    manifest_ensure
    local cli="$1" provider="$2" ver="$3" path="$4" tmp
    tmp=$(mktemp)
    awk -v c="$cli" -v p="$provider" -v v="$ver" -v pa="$path" '
        BEGIN { done=0 }
        $1 == c { print c "\t" p "\t" v "\t" pa; done=1; next }
        { print }
        END { if (!done) print c "\t" p "\t" v "\t" pa }
    ' "$(manifest_path)" >"$tmp" && mv -f "$tmp" "$(manifest_path)"
}

# manifest_lookup <cli>: prints provider<TAB>version<TAB>path or empty.
manifest_lookup() {
    local cli="$1"
    [ -f "$(manifest_path)" ] || return 1
    awk -F '\t' -v c="$cli" '$1 == c { print $2 "\t" $3 "\t" $4; exit }' "$(manifest_path)"
}

# get_installed_version <cli>: version managed by cli-toolbox policy for this CLI.
get_installed_version() {
    local cli="$1" path=""
    case "$(cli_preferred_provider "$cli")" in
        uv-tool)
            path=$(uv_tool_executable_path "$cli") || path=""
            [ -n "$path" ] && _parse_version "$cli" "$path"
            return 0
            ;;
        official-package)
            path=$(cli_apt_package "$cli")
            apt_installed_version "$path"
            return 0
            ;;
    esac
    if [ ! -e "$CLOUD_TOOLBOX_HOME/bin/$cli" ] && [ ! -L "$CLOUD_TOOLBOX_HOME/bin/$cli" ]; then
        return 0
    fi
    _parse_version "$cli" "$CLOUD_TOOLBOX_HOME/bin/$cli"
}

# resolve_real_path <path>: follow symlinks to a regular file path.
resolve_real_path() {
    local p="$1"
    [ -n "$p" ] || return 1
    if [ -L "$p" ]; then
        p=$(readlink -f "$p" 2>/dev/null) || p=$(readlink "$p" 2>/dev/null)
    fi
    [ -n "$p" ] && printf '%s\n' "$p"
}

# path_is_pyenv_shim <path>: true when path is a pyenv shim.
path_is_pyenv_shim() {
    local p="$1"
    case "$p" in
        "$HOME"/.pyenv/shims/* | */.pyenv/shims/*) return 0 ;;
    esac
    return 1
}

# pyenv_real_path <cli>: resolve pyenv shim to real binary when possible.
pyenv_real_path() {
    local cli="$1"
    if cmd_exists pyenv; then
        pyenv which "$cli" 2>/dev/null
        return
    fi
    return 1
}

# path_is_dpkg_managed <path>: true for files owned by an apt/dpkg package.
path_is_dpkg_managed() {
    local p="$1" owner=""
    [ -e "$p" ] || return 1
    if ! cmd_exists dpkg-query; then
        return 1
    fi
    owner=$(dpkg-query -S "$p" 2>/dev/null | head -1)
    [ -n "$owner" ]
}

# path_is_snap <path>: true for snap-managed executables.
path_is_snap() {
    case "$1" in
        /snap/* | /var/lib/snapd/*) return 0 ;;
    esac
    return 1
}

# uv_bin: first uv on PATH (toolbox bin first).
uv_bin() {
    PATH="$CLOUD_TOOLBOX_HOME/bin:$PATH"
    command -v uv 2>/dev/null
}

# uv_tool_bin_dir: directory where uv tool places console scripts.
uv_tool_bin_dir() {
    if [ -n "${UV_TOOL_BIN_DIR:-}" ]; then
        printf '%s\n' "$UV_TOOL_BIN_DIR"
        return 0
    fi
    printf '%s\n' "${HOME:-}/.local/bin"
}

# uv_tool_list_packages: one package name per line from `uv tool list`.
uv_tool_list_packages() {
    local uv=""
    uv=$(uv_bin) || return 1
    "$uv" tool list 2>/dev/null | awk '{print $1}'
}

# uv_tool_has <package>: true when package is installed via uv tool.
uv_tool_has() {
    local pkg="$1" p dir="" exe=""
    while IFS= read -r p; do
        [ "$p" = "$pkg" ] && return 0
    done <<< "$(uv_tool_list_packages 2>/dev/null)"
    dir=$(uv_tool_bin_dir)
    case "$pkg" in
        tccli) exe="tccli" ;;
    esac
    [ -n "$exe" ] && [ -x "$dir/$exe" ] && return 0
    return 1
}

# uv_tool_executable_path <cli>: path to the uv-managed executable, if any.
uv_tool_executable_path() {
    local cli="$1" pkg dir candidate real
    pkg=$(cli_uv_tool_package "$cli")
    [ -n "$pkg" ] || return 1
    if ! uv_tool_has "$pkg"; then
        return 1
    fi
    dir=$(uv_tool_bin_dir)
    candidate="$dir/$cli"
    if [ -x "$candidate" ]; then
        real=$(resolve_real_path "$candidate") || real="$candidate"
        printf '%s\n' "$real"
        return 0
    fi
    return 1
}

# path_is_uv_tool_managed <path> <cli>: true when path is a uv tool install.
path_is_uv_tool_managed() {
    local path="$1" cli="$2" uv_path=""
    uv_path=$(uv_tool_executable_path "$cli") || return 1
    [ "$path" = "$uv_path" ]
}

# can_sudo: non-interactive sudo available (or already root).
can_sudo() {
    [ "$(id -u)" -eq 0 ] && return 0
    sudo -n true 2>/dev/null
}

# has_apt: Debian/Ubuntu style apt is available.
has_apt() {
    cmd_exists apt-get && cmd_exists apt-cache
}

# apt_installed_version <pkg>
apt_installed_version() {
    local pkg="$1"
    dpkg-query -W -f='${Version}' "$pkg" 2>/dev/null
}

# apt_candidate_version <pkg>
apt_candidate_version() {
    local pkg="$1" ver=""
    ver=$(apt-cache policy "$pkg" 2>/dev/null | awk '/Candidate:/ { print $2; exit }')
    [ "$ver" = "(none)" ] && ver=""
    printf '%s\n' "$ver"
}

# classify_path_provider <cli> <path>: echo provider slug for an existing binary.
classify_path_provider() {
    local cli="$1" path="$2" real=""
    [ -n "$path" ] || { printf '%s' "unknown"; return 0; }

    real=$(resolve_real_path "$path") || real="$path"

    if is_managed "$real" || is_managed "$path"; then
        case "$(cli_preferred_provider "$cli")" in
            official-installer | release-binary | local-wrapper)
                printf '%s' "$(cli_preferred_provider "$cli")"
                return 0
                ;;
        esac
    fi

    if path_is_uv_tool_managed "$real" "$cli"; then
        printf '%s' "uv-tool"
        return 0
    fi

    if path_is_snap "$real" || path_is_dpkg_managed "$real"; then
        printf '%s' "system-package"
        return 0
    fi

    case "$real" in
        /usr/bin/* | /usr/local/bin/* | /bin/*)
            printf '%s' "system-package"
            return 0
            ;;
    esac

    if path_is_pyenv_shim "$path"; then
        printf '%s' "pyenv"
        return 0
    fi

    case "$real" in
        */.local/bin/* | */.local/share/uv/*)
            if [ "$cli" = "tccli" ] && uv_tool_has tccli; then
                printf '%s' "uv-tool"
            elif [ "$cli" = "tccli" ]; then
                printf '%s' "pip-user"
            else
                printf '%s' "unknown"
            fi
            return 0
            ;;
    esac

    manifest_lookup "$cli" >/dev/null 2>&1 && {
        printf '%s' "$(cli_preferred_provider "$cli")"
        return 0
    }

    printf '%s' "unknown"
}

# inspect_cli <name>: sets TB_LIST_* globals (never fails the caller).
inspect_cli() {
    local name="$1"
    local preferred="" path="" current="" latest="" status="missing" provider="" state=""
    local pkg="" uv_path="" manifest_info="" m_provider="" m_ver="" m_path=""

    preferred=$(cli_preferred_provider "$name")
    TB_LIST_STATUS="missing"
    TB_LIST_PROVIDER="$preferred"
    TB_LIST_PATH="-"
    TB_LIST_CURRENT="-"
    TB_LIST_STATE="install-required"
    TB_LIST_LATEST="unknown"

    if ! is_supported "$name"; then
        TB_LIST_STATUS="unsupported"
        TB_LIST_PROVIDER="unknown"
        TB_LIST_STATE="unsupported"
        return 0
    fi

    case "$preferred" in
        official-package)
            if ! has_apt; then
                TB_LIST_STATUS="unsupported"
                TB_LIST_STATE="unsupported"
                return 0
            fi
            pkg=$(cli_apt_package "$name")
            current=$(apt_installed_version "$pkg")
            latest=$(apt_candidate_version "$pkg")
            [ -z "$latest" ] && latest="unknown"
            TB_LIST_LATEST="$latest"
            if [ -z "$current" ] && ! can_sudo; then
                TB_LIST_STATUS="requires-root"
                TB_LIST_STATE="install-required"
                return 0
            fi
            if [ -n "$current" ]; then
                path=$(command -v "$name" 2>/dev/null) || path=""
                provider=$(classify_path_provider "$name" "$path")
                if manifest_lookup "$name" >/dev/null 2>&1; then
                    status="managed"
                else
                    status="system"
                fi
                TB_LIST_STATUS="$status"
                TB_LIST_PROVIDER="$provider"
                TB_LIST_PATH="${path:--}"
                TB_LIST_CURRENT="$current"
            else
                TB_LIST_STATUS="missing"
                TB_LIST_PROVIDER="$preferred"
            fi
            ;;
        uv-tool)
            uv_path=$(uv_tool_executable_path "$name") || uv_path=""
            path=$(resolve_path "$name") || path=""
            latest=$(list_latest_version "$name" 2>/dev/null) || latest="unknown"
            TB_LIST_LATEST="$latest"
            if [ -n "$uv_path" ]; then
                TB_LIST_STATUS="managed"
                TB_LIST_PROVIDER="uv-tool"
                TB_LIST_PATH="$uv_path"
                TB_LIST_CURRENT=$(_parse_version "$name" "$uv_path")
            elif [ -n "$path" ]; then
                TB_LIST_STATUS="system"
                TB_LIST_PROVIDER=$(classify_path_provider "$name" "$path")
                TB_LIST_PATH="$path"
                TB_LIST_CURRENT=$(_parse_version "$name" "$path")
                TB_LIST_STATE="migration-available"
                return 0
            fi
            ;;
        official-installer | release-binary | local-wrapper)
            manifest_info=$(manifest_lookup "$name" 2>/dev/null) || manifest_info=""
            if [ -n "$manifest_info" ]; then
                m_provider=${manifest_info%%$'\t'*}
                m_ver=${manifest_info#*$'\t'}
                m_ver=${m_ver%%$'\t'*}
                m_path=${manifest_info#*$'\t'}
                m_path=${m_path#*$'\t'}
                m_path=${m_path#*$'\t'}
            fi
            if [ -e "$CLOUD_TOOLBOX_HOME/bin/$name" ] || [ -L "$CLOUD_TOOLBOX_HOME/bin/$name" ]; then
                status="managed"
                path="$CLOUD_TOOLBOX_HOME/bin/$name"
                provider="$preferred"
                current=$(get_installed_version "$name")
            elif [ -n "$m_path" ] && { [ -e "$m_path" ] || [ -L "$m_path" ]; }; then
                status="managed"
                path="$m_path"
                provider="${m_provider:-$preferred}"
                current=${m_ver:-$(_parse_version "$name" "$path")}
            else
                path=$(resolve_path "$name") || path=""
                if [ -n "$path" ]; then
                    status="system"
                    provider=$(classify_path_provider "$name" "$path")
                    current=$(_parse_version "$name" "$path")
                fi
            fi
            TB_LIST_STATUS="$status"
            TB_LIST_PROVIDER="$provider"
            TB_LIST_PATH="${path:--}"
            TB_LIST_CURRENT="${current:--}"
            latest=$(list_latest_version "$name" 2>/dev/null) || latest="unknown"
            TB_LIST_LATEST="$latest"
            ;;
    esac

    if [ "$TB_LIST_STATUS" = "requires-root" ] || [ "$TB_LIST_STATUS" = "unsupported" ]; then
        return 0
    fi
    if [ "$TB_LIST_STATE" = "migration-available" ]; then
        return 0
    fi

    latest="${TB_LIST_LATEST:-unknown}"
    current="${TB_LIST_CURRENT:--}"
    if [ "$preferred" = "local-wrapper" ] && [ "$TB_LIST_STATUS" = "managed" ]; then
        TB_LIST_STATE="unchanged"
        return 0
    fi
    if [ "$current" = "-" ] || [ -z "$current" ]; then
        TB_LIST_STATE="install-required"
    elif [ "$latest" = "unknown" ]; then
        TB_LIST_STATE="unknown"
    elif [ "$latest" = "wrapper" ]; then
        TB_LIST_STATE="unchanged"
    elif [ "$current" = "$latest" ]; then
        TB_LIST_STATE="unchanged"
    elif version_gt "$latest" "$current"; then
        TB_LIST_STATE="update-available"
    else
        TB_LIST_STATE="unknown"
    fi
    return 0
}

# list_latest_version <cli>: best-effort latest stable version.
list_latest_version() {
    local name="$1" body ver="" pkg=""
    case "$name" in
        glow | coscli)
            body=$(github_release_json "$(list_repo "$name")" 2>/dev/null) || body=""
            [ -n "$body" ] && ver=$(github_version_from_json "$body" 2>/dev/null)
            ;;
        uv)
            body=$(github_release_json astral-sh/uv 2>/dev/null) || body=""
            [ -n "$body" ] && ver=$(github_version_from_json "$body" 2>/dev/null)
            ;;
        tccli)
            ver=$(get_latest_version_pypi tccli 2>/dev/null)
            ;;
        aws)
            ver=$(http_get "https://awscli.amazonaws.com/v2/version.txt" 2>/dev/null | tr -d '[:space:]')
            ;;
        gh | gcloud | az)
            pkg=$(cli_apt_package "$name")
            if has_apt; then
                ver=$(apt_candidate_version "$pkg")
            fi
            ;;
        awst | gcloudt | tcclit)
            ver="wrapper"
            ;;
    esac
    if [ -z "$ver" ]; then
        printf '%s\n' "unknown"
        return 0
    fi
    printf '%s\n' "$ver"
    return 0
}

list_repo() {
    case "$1" in
        glow) printf '%s' "charmbracelet/glow" ;;
        coscli) printf '%s' "tencentyun/coscli" ;;
    esac
}

# format_list_row: prints one TSV-safe row (tab-separated) for list output.
format_list_row() {
    local cli="$1" status="$2" current="$3" latest="$4" path="$5" provider="$6" state="$7"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$cli" "$status" "$current" "$latest" "$path" "$provider" "$state"
}

# print_list_table <rows-tsv>: column-aligned table from tab-separated rows.
print_list_table() {
    local header
    header=$'CLI\tSTATUS\tCURRENT\tLATEST\tPATH\tPROVIDER\tSTATE'
    {
        printf '%s\n' "$header"
        printf '%s' "$1"
    } | awk -F '\t' '
        NR == 1 {
            w[1]=3; w[2]=12; w[3]=14; w[4]=14; w[5]=30; w[6]=20; w[7]=20
            for (i=1; i<=7; i++) {
                if (length($i) > w[i]) w[i]=length($i)
            }
            printf "%-*s %-*s %-*s %-*s %-*s %-*s %-*s\n", w[1],$1,w[2],$2,w[3],$3,w[4],$4,w[5],$5,w[6],$6,w[7],$7
            next
        }
        {
            printf "%-*s %-*s %-*s %-*s %-*s %-*s %-*s\n", w[1],$1,w[2],$2,w[3],$3,w[4],$4,w[5],$5,w[6],$6,w[7],$7
        }
    '
}
