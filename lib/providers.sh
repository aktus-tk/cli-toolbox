# shellcheck shell=bash
# lib/providers.sh — CLI provider metadata, inspection, and list status logic.
# Requires lib/common.sh and lib/packages.sh to be sourced first.

SUPPORTED_CLIS=(uv gh glow coscli rg mlr tccli aws gcloud az terraform \
    kubectl helm oci opencode agent codebuddy claude codex agy)
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

# cli_display_name: user-facing label (help/doctor); defaults to the CLI name.
cli_display_name() {
    case "$1" in
        agent) printf '%s' "agent (Cursor Agent CLI)" ;;
        *) printf '%s' "$1" ;;
    esac
}

# resolve_provider <cli> <os>: preferred provider for CLI on the given OS.
resolve_provider() {
    local cli="$1" os="$2"
    case "$cli" in
        uv) printf '%s' "official-installer" ;;
        tccli) printf '%s' "uv-tool" ;;
        gcloud) printf '%s' "official-archive" ;;
        coscli) printf '%s' "release-binary" ;;
        aws)
            case "$os" in
                darwin) printf '%s' "brew" ;;
                *) printf '%s' "official-installer" ;;
            esac
            ;;
        gh | az | terraform)
            case "$os" in
                darwin) printf '%s' "brew" ;;
                *) printf '%s' "apt" ;;
            esac
            ;;
        glow | rg | mlr | opencode)
            case "$os" in
                darwin)
                    if has_brew; then
                        printf '%s' "brew"
                    else
                        printf '%s' "release-binary"
                    fi
                    ;;
                *) printf '%s' "release-binary" ;;
            esac
            ;;
        kubectl | helm)
            printf '%s' "release-binary"
            ;;
        oci)
            case "$os" in
                darwin)
                    if has_brew; then
                        printf '%s' "brew"
                    else
                        printf '%s' "official-installer"
                    fi
                    ;;
                linux)
                    printf '%s' "official-installer"
                    ;;
                *) printf '%s' "unknown" ;;
            esac
            ;;
        agent | claude | codex | agy)
            printf '%s' "official-installer"
            ;;
        codebuddy)
            case "$os" in
                darwin | linux)
                    if has_brew; then
                        printf '%s' "brew"
                    else
                        printf '%s' "official-installer"
                    fi
                    ;;
                *) printf '%s' "unknown" ;;
            esac
            ;;
        *) printf '%s' "unknown" ;;
    esac
}

# cli_preferred_provider <cli>: uses TB_OS when set, else detect_platform.
cli_preferred_provider() {
    local cli="$1" os=""
    if [ -n "${TB_OS:-}" ]; then
        os="$TB_OS"
    elif detect_platform 2>/dev/null; then
        os="$TB_OS"
    else
        os="linux"
    fi
    resolve_provider "$cli" "$os"
}

# Backward-compatible alias used by installers.
cli_apt_package() {
    cli_package_name "$1" apt
}

cli_uv_tool_package() {
    case "$1" in
        tccli) printf '%s' "tccli" ;;
    esac
}

gcloud_sdk_root() {
    printf '%s' "$CLI_TOOLBOX_HOME/tools/google-cloud-sdk"
}

gcloud_managed_bin() {
    printf '%s' "$CLI_TOOLBOX_HOME/bin/gcloud"
}

gcloud_managed_version() {
    local bin=""
    bin=$(gcloud_managed_bin)
    if [ -e "$bin" ] || [ -L "$bin" ]; then
        _parse_version gcloud "$bin"
        return 0
    fi
    return 1
}

# gcloud_archive_url <version> <os> <arch>
gcloud_archive_url() {
    local ver="$1" os="$2" arch="$3" garch=""
    case "$arch" in
        amd64) garch=x86_64 ;;
        arm64) garch=arm ;;
        *) return 1 ;;
    esac
    case "$os" in
        linux)
            printf 'https://dl.google.com/dl/cloudsdk/channels/rapid/downloads/google-cloud-cli-%s-linux-%s.tar.gz' \
                "$ver" "$garch"
            ;;
        darwin)
            printf 'https://dl.google.com/dl/cloudsdk/channels/rapid/downloads/google-cloud-cli-%s-darwin-%s.tar.gz' \
                "$ver" "$garch"
            ;;
        *) return 1 ;;
    esac
}

# gcloud_latest_version: stable version from Google components JSON.
gcloud_latest_version() {
    local body ver=""
    body=$(http_get "https://dl.google.com/dl/cloudsdk/channels/rapid/components-2.json") || return 1
    ver=$(printf '%s\n' "$body" \
        | grep -o '"version"[[:space:]]*:[[:space:]]*"[0-9][^"]*"' \
        | head -1 \
        | sed 's/.*"version"[[:space:]]*:[[:space:]]*"\([0-9][^"]*\)".*/\1/')
    [ -n "$ver" ] || return 1
    printf '%s\n' "$ver"
}

manifest_path() {
    printf '%s' "$CLI_TOOLBOX_HOME/state/manifest.tsv"
}

manifest_ensure() {
    mkdir -p "$CLI_TOOLBOX_HOME/state"
    [ -f "$(manifest_path)" ] || : >"$(manifest_path)"
}

manifest_record() {
    manifest_ensure
    local cli="$1" provider="$2" ver="$3" path="$4" tmp
    tmp=$(mktemp "${TMPDIR:-/tmp}/cli-toolbox.manifest.XXXXXX")
    awk -v c="$cli" -v p="$provider" -v v="$ver" -v pa="$path" '
        BEGIN { done=0 }
        $1 == c { print c "\t" p "\t" v "\t" pa; done=1; next }
        { print }
        END { if (!done) print c "\t" p "\t" v "\t" pa }
    ' "$(manifest_path)" >"$tmp" && mv -f "$tmp" "$(manifest_path)"
}

manifest_lookup() {
    local cli="$1"
    [ -f "$(manifest_path)" ] || return 1
    awk -F '\t' -v c="$cli" '$1 == c { print $2 "\t" $3 "\t" $4; exit }' "$(manifest_path)"
}

# manifest_remove <cli>: drop CLI from manifest (no-op if absent).
manifest_remove() {
    local cli="$1" tmp
    [ -f "$(manifest_path)" ] || return 0
    tmp=$(mktemp "${TMPDIR:-/tmp}/cli-toolbox.manifest.XXXXXX")
    awk -F '\t' -v c="$cli" '$1 != c { print }' "$(manifest_path)" >"$tmp" \
        && mv -f "$tmp" "$(manifest_path)"
}

# cli_is_toolbox_managed <cli>: true when cli-toolbox has install artifacts to remove.
cli_is_toolbox_managed() {
    local cli="$1" info="" provider="" path=""
    if manifest_lookup "$cli" >/dev/null 2>&1; then
        return 0
    fi
    case "$cli" in
        gcloud)
            [ -e "$(gcloud_managed_bin)" ] || [ -L "$(gcloud_managed_bin)" ] \
                || [ -d "$(gcloud_sdk_root)" ]
            ;;
        aws)
            [ -e "$CLI_TOOLBOX_HOME/bin/aws" ] || [ -L "$CLI_TOOLBOX_HOME/bin/aws" ] \
                || [ -d "$CLI_TOOLBOX_HOME/tools/aws-cli" ]
            ;;
        tccli)
            path=$(uv_tool_executable_path "$cli" 2>/dev/null) || path=""
            [ -n "$path" ] && path_is_uv_tool_managed "$path" "$cli"
            ;;
        *)
            [ -e "$CLI_TOOLBOX_HOME/bin/$cli" ] || [ -L "$CLI_TOOLBOX_HOME/bin/$cli" ]
            ;;
    esac
}

get_installed_version() {
    local cli="$1" path="" provider="" pkg=""
    provider=$(cli_preferred_provider "$cli")
    case "$provider" in
        uv-tool)
            path=$(uv_tool_executable_path "$cli") || path=""
            [ -n "$path" ] && _parse_version "$cli" "$path"
            return 0
            ;;
        apt | brew)
            pkg=$(cli_package_name "$cli" "$provider")
            package_installed_version "$provider" "$pkg"
            return 0
            ;;
        official-archive)
            gcloud_managed_version
            return 0
            ;;
    esac
    if [ ! -e "$CLI_TOOLBOX_HOME/bin/$cli" ] && [ ! -L "$CLI_TOOLBOX_HOME/bin/$cli" ]; then
        return 0
    fi
    _parse_version "$cli" "$CLI_TOOLBOX_HOME/bin/$cli"
}

path_is_pyenv_shim() {
    local p="$1"
    case "$p" in
        "$HOME"/.pyenv/shims/* | */.pyenv/shims/*) return 0 ;;
    esac
    return 1
}

path_is_pipx() {
    local p="$1"
    case "$p" in
        */.local/share/pipx/* | */pipx/venvs/*) return 0 ;;
    esac
    return 1
}

pyenv_real_path() {
    local cli="$1"
    if cmd_exists pyenv; then
        pyenv which "$cli" 2>/dev/null
        return
    fi
    return 1
}

path_is_dpkg_managed() {
    local p="$1" owner=""
    [ -e "$p" ] || return 1
    if ! cmd_exists dpkg-query; then
        return 1
    fi
    owner=$(dpkg-query -S "$p" 2>/dev/null | head -1)
    [ -n "$owner" ]
}

path_is_brew_managed() {
    local p="$1" brew=""
    brew=$(brew_bin) || return 1
    "$brew" list --versions 2>/dev/null | grep -q .
    case "$p" in
        /opt/homebrew/* | /usr/local/Cellar/* | /usr/local/bin/*) return 0 ;;
    esac
    return 1
}

path_is_snap() {
    case "$1" in
        /snap/* | /var/lib/snapd/*) return 0 ;;
    esac
    return 1
}

uv_bin() {
    PATH="$CLI_TOOLBOX_HOME/bin:$PATH"
    command -v uv 2>/dev/null
}

uv_tool_bin_dir() {
    if [ -n "${UV_TOOL_BIN_DIR:-}" ]; then
        printf '%s\n' "$UV_TOOL_BIN_DIR"
        return 0
    fi
    printf '%s\n' "${HOME:-}/.local/bin"
}

uv_tool_list_packages() {
    local uv=""
    uv=$(uv_bin) || return 1
    "$uv" tool list 2>/dev/null | awk '{print $1}'
}

uv_tool_has() {
    local pkg="$1" p=""
    while IFS= read -r p; do
        [ "$p" = "$pkg" ] && return 0
    done <<< "$(uv_tool_list_packages 2>/dev/null)"
    return 1
}

uv_tool_executable_path() {
    local cli="$1" pkg="" uv="" path="" candidate="" real=""
    pkg=$(cli_uv_tool_package "$cli")
    [ -n "$pkg" ] || return 1
    if ! uv_tool_has "$pkg"; then
        return 1
    fi
    uv=$(uv_bin) || return 1
    path=$("$uv" tool list --show-paths 2>/dev/null \
        | sed -n "s/^- ${cli} (\\(.*\\))\$/\\1/p" | head -1)
    if [ -n "$path" ] && [ -x "$path" ]; then
        real=$(resolve_real_path "$path") || real="$path"
        if path_is_pipx "$real"; then
            return 1
        fi
        printf '%s\n' "$real"
        return 0
    fi
    candidate="$(uv_tool_bin_dir)/$cli"
    if [ -x "$candidate" ]; then
        real=$(resolve_real_path "$candidate") || real="$candidate"
        if path_is_pipx "$real"; then
            return 1
        fi
        printf '%s\n' "$real"
        return 0
    fi
    return 1
}

path_is_uv_tool_managed() {
    local path="$1" cli="$2" uv_path="" path_real="" uv_real=""
    uv_path=$(uv_tool_executable_path "$cli") || return 1
    path_real=$(resolve_real_path "$path") || path_real="$path"
    uv_real=$(resolve_real_path "$uv_path") || uv_real="$uv_path"
    [ "$path_real" = "$uv_real" ]
}

classify_path_provider() {
    local cli="$1" path="$2" real=""
    [ -n "$path" ] || { printf '%s' "unknown"; return 0; }

    real=$(resolve_real_path "$path") || real="$path"

    if is_managed "$real" || is_managed "$path"; then
        case "$(cli_preferred_provider "$cli")" in
            official-installer | official-archive | release-binary)
                printf '%s' "$(cli_preferred_provider "$cli")"
                return 0
                ;;
        esac
    fi

    if path_is_uv_tool_managed "$real" "$cli"; then
        printf '%s' "uv-tool"
        return 0
    fi

    if path_is_pipx "$real"; then
        printf '%s' "pipx"
        return 0
    fi

    if path_is_snap "$real" || path_is_dpkg_managed "$real"; then
        printf '%s' "system-package"
        return 0
    fi

    if path_is_brew_managed "$real"; then
        printf '%s' "brew"
        return 0
    fi

    case "$real" in
        /usr/bin/* | /usr/local/bin/* | /bin/* | /opt/homebrew/bin/*)
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

# _inspect_package_cli <name> <provider>
_inspect_package_cli() {
    local name="$1" provider="$2" pkg="" current="" latest="" path=""
    if ! package_manager_available "$provider"; then
        TB_LIST_STATUS="requires-package-manager"
        TB_LIST_PROVIDER="$provider"
        TB_LIST_STATE="install-required"
        return 0
    fi
    pkg=$(cli_package_name "$name" "$provider")
    current=$(package_installed_version "$provider" "$pkg")
    latest=$(package_latest_version "$provider" "$pkg")
    [ -z "$latest" ] && latest="unknown"
    TB_LIST_LATEST="$latest"
    if [ "$provider" = "apt" ] && [ -z "$current" ] && ! can_sudo; then
        TB_LIST_STATUS="requires-root"
        TB_LIST_STATE="install-required"
        return 0
    fi
    if [ -n "$current" ]; then
        path=$(command -v "$name" 2>/dev/null) || path=""
        if manifest_lookup "$name" >/dev/null 2>&1; then
            TB_LIST_STATUS="managed"
        else
            TB_LIST_STATUS="system"
        fi
        TB_LIST_PROVIDER=$(classify_path_provider "$name" "$path")
        TB_LIST_PATH="${path:--}"
        TB_LIST_CURRENT="$current"
    else
        TB_LIST_STATUS="missing"
        TB_LIST_PROVIDER="$provider"
    fi
}

inspect_cli() {
    local name="$1"
    local preferred="" path="" current="" latest="" status="missing" provider="" state=""
    local pkg="" uv_path="" manifest_info="" m_provider="" m_ver="" m_path=""

    detect_platform 2>/dev/null || true
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
        apt | brew)
            _inspect_package_cli "$name" "$preferred"
            ;;
        official-archive)
            latest=$(gcloud_latest_version 2>/dev/null) || latest="unknown"
            TB_LIST_LATEST="$latest"
            current=$(gcloud_managed_version 2>/dev/null) || current=""
            if [ -n "$current" ]; then
                TB_LIST_STATUS="managed"
                TB_LIST_PROVIDER="official-archive"
                TB_LIST_PATH="$(gcloud_managed_bin)"
                TB_LIST_CURRENT="$current"
            else
                path=$(resolve_path "$name") || path=""
                if [ -n "$path" ]; then
                    TB_LIST_STATUS="system"
                    TB_LIST_PROVIDER=$(classify_path_provider "$name" "$path")
                    TB_LIST_PATH="$path"
                    TB_LIST_CURRENT=$(_parse_version "$name" "$path")
                    TB_LIST_STATE="migration-available"
                    return 0
                fi
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
        official-installer | release-binary)
            manifest_info=$(manifest_lookup "$name" 2>/dev/null) || manifest_info=""
            if [ -n "$manifest_info" ]; then
                m_provider=${manifest_info%%$'\t'*}
                m_ver=${manifest_info#*$'\t'}
                m_ver=${m_ver%%$'\t'*}
                m_path=${manifest_info#*$'\t'}
                m_path=${m_path#*$'\t'}
                m_path=${m_path#*$'\t'}
            fi
            if [ -e "$CLI_TOOLBOX_HOME/bin/$name" ] || [ -L "$CLI_TOOLBOX_HOME/bin/$name" ]; then
                status="managed"
                path="$CLI_TOOLBOX_HOME/bin/$name"
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

    if [ "$TB_LIST_STATUS" = "requires-root" ] \
        || [ "$TB_LIST_STATUS" = "unsupported" ] \
        || [ "$TB_LIST_STATUS" = "requires-package-manager" ]; then
        return 0
    fi
    if [ "$TB_LIST_STATE" = "migration-available" ]; then
        return 0
    fi

    latest="${TB_LIST_LATEST:-unknown}"
    current="${TB_LIST_CURRENT:--}"
    if [ "$current" = "-" ] || [ -z "$current" ]; then
        TB_LIST_STATE="install-required"
    elif [ "$latest" = "unknown" ]; then
        TB_LIST_STATE="unknown"
    elif [ "$current" = "$latest" ]; then
        TB_LIST_STATE="unchanged"
    elif version_gt "$latest" "$current"; then
        TB_LIST_STATE="update-available"
    else
        TB_LIST_STATE="unknown"
    fi
    return 0
}

list_latest_version() {
    local name="$1" body ver="" pkg="" provider=""
    provider=$(cli_preferred_provider "$name")
    case "$name" in
        glow | coscli | rg | mlr | opencode)
            body=$(github_release_json "$(list_repo "$name")" 2>/dev/null) || body=""
            [ -n "$body" ] && ver=$(github_version_from_json "$body" 2>/dev/null)
            ;;
        agent | claude | codex | agy | codebuddy)
            ver=$(official_installer_latest_version "$name" 2>/dev/null) || ver=""
            ;;
        uv)
            body=$(github_release_json astral-sh/uv 2>/dev/null) || body=""
            [ -n "$body" ] && ver=$(github_version_from_json "$body" 2>/dev/null)
            ;;
        tccli)
            ver=$(get_latest_version_pypi tccli 2>/dev/null)
            ;;
        aws)
            if [ "$provider" = "brew" ]; then
                pkg=$(cli_package_name aws brew)
                ver=$(package_latest_version brew "$pkg" 2>/dev/null)
            else
                ver=$(http_get "https://awscli.amazonaws.com/v2/version.txt" 2>/dev/null | tr -d '[:space:]')
            fi
            ;;
        gcloud)
            ver=$(gcloud_latest_version 2>/dev/null)
            ;;
        gh | az | terraform)
            pkg=$(cli_package_name "$name" "$provider")
            if package_manager_available "$provider"; then
                ver=$(package_latest_version "$provider" "$pkg")
            fi
            ;;
        oci)
            if [ "$provider" = "brew" ]; then
                pkg=$(cli_package_name oci brew)
                ver=$(package_latest_version brew "$pkg" 2>/dev/null)
            else
                ver=$(official_installer_latest_version oci 2>/dev/null) || ver=""
            fi
            ;;
        kubectl)
            ver=$(kubectl_latest_version 2>/dev/null) || ver=""
            ;;
        helm)
            ver=$(helm_latest_version 2>/dev/null) || ver=""
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
        rg) printf '%s' "BurntSushi/ripgrep" ;;
        mlr) printf '%s' "johnkerl/miller" ;;
        opencode) printf '%s' "anomalyco/opencode" ;;
        oci) printf '%s' "oracle/oci-cli" ;;
    esac
}

# kubectl_latest_version: stable client version from dl.k8s.io.
kubectl_latest_version() {
    local ver=""
    ver=$(http_get "https://dl.k8s.io/release/stable.txt" 2>/dev/null) || ver=""
    ver=$(normalize_version "$ver")
    [ -n "$ver" ] || return 1
    printf '%s\n' "$ver"
    return 0
}

# helm_latest_version: latest helm release from get.helm.sh.
helm_latest_version() {
    local ver=""
    ver=$(http_get "https://get.helm.sh/helm-latest-version" 2>/dev/null) || ver=""
    ver=$(normalize_version "$ver")
    [ -n "$ver" ] || return 1
    printf '%s\n' "$ver"
    return 0
}

# official_installer_url <cli>
official_installer_url() {
    case "$1" in
        agent)
            if [ -n "${CLI_TOOLBOX_AGENT_INSTALL_URL:-}" ]; then
                printf '%s' "$CLI_TOOLBOX_AGENT_INSTALL_URL"
            else
                printf '%s' "https://cursor.com/install"
            fi
            ;;
        claude)
            if [ -n "${CLI_TOOLBOX_CLAUDE_INSTALL_URL:-}" ]; then
                printf '%s' "$CLI_TOOLBOX_CLAUDE_INSTALL_URL"
            else
                printf '%s' "https://claude.ai/install.sh"
            fi
            ;;
        codex)
            if [ -n "${CLI_TOOLBOX_CODEX_INSTALL_URL:-}" ]; then
                printf '%s' "$CLI_TOOLBOX_CODEX_INSTALL_URL"
            else
                printf '%s' "https://chatgpt.com/codex/install.sh"
            fi
            ;;
        agy)
            if [ -n "${CLI_TOOLBOX_AGY_INSTALL_URL:-}" ]; then
                printf '%s' "$CLI_TOOLBOX_AGY_INSTALL_URL"
            else
                printf '%s' "https://antigravity.google/cli/install.sh"
            fi
            ;;
        codebuddy)
            if [ -n "${CLI_TOOLBOX_CODEBUDDY_INSTALL_URL:-}" ]; then
                printf '%s' "$CLI_TOOLBOX_CODEBUDDY_INSTALL_URL"
            else
                printf '%s' "https://www.codebuddy.cn/cli/install.sh"
            fi
            ;;
        oci)
            if [ -n "${CLI_TOOLBOX_OCI_INSTALL_URL:-}" ]; then
                printf '%s' "$CLI_TOOLBOX_OCI_INSTALL_URL"
            else
                printf '%s' "https://raw.githubusercontent.com/oracle/oci-cli/master/scripts/install/install.sh"
            fi
            ;;
    esac
}

# official_installer_latest_version <cli>: best-effort stable version lookup.
official_installer_latest_version() {
    local cli="$1" body="" ver="" platform=""
    case "$cli" in
        opencode)
            body=$(github_release_json anomalyco/opencode 2>/dev/null) || body=""
            [ -n "$body" ] && ver=$(github_version_from_json "$body" 2>/dev/null)
            ;;
        claude)
            body=$(http_get "https://downloads.claude.ai/claude-code-releases/stable/manifest.json" 2>/dev/null) || body=""
            ver=$(printf '%s\n' "$body" | sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([0-9][^"]*\)".*/\1/p' | head -1)
            ;;
        codex)
            body=$(http_get "https://releases.openai.com/codex/latest/manifest.json" 2>/dev/null) || body=""
            ver=$(printf '%s\n' "$body" | sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([0-9][^"]*\)".*/\1/p' | head -1)
            ;;
        agy)
            detect_platform 2>/dev/null || true
            case "${TB_OS:-linux}-${TB_ARCH:-amd64}" in
                linux-amd64) platform=linux_amd64 ;;
                linux-arm64) platform=linux_arm64 ;;
                darwin-amd64) platform=darwin_amd64 ;;
                darwin-arm64) platform=darwin_arm64 ;;
            esac
            [ -n "$platform" ] || return 1
            body=$(http_get "https://antigravity-cli-auto-updater-974169037036.us-central1.run.app/manifests/${platform}.json" 2>/dev/null) || body=""
            ver=$(printf '%s\n' "$body" | sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([0-9][^"]*\)".*/\1/p' | head -1)
            ;;
        agent | codebuddy)
            return 1
            ;;
        oci)
            body=$(github_release_json oracle/oci-cli 2>/dev/null) || body=""
            [ -n "$body" ] && ver=$(github_version_from_json "$body" 2>/dev/null)
            ;;
    esac
    [ -n "$ver" ] || return 1
    printf '%s\n' "$ver"
    return 0
}

format_list_row() {
    local cli="$1" status="$2" current="$3" latest="$4" path="$5" provider="$6" state="$7"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$cli" "$status" "$current" "$latest" "$path" "$provider" "$state"
}

print_list_table() {
    local header
    header=$'CLI\tSTATUS\tCURRENT\tLATEST\tPATH\tPROVIDER\tSTATE'
    {
        printf '%s\n' "$header"
        printf '%s' "$1"
    } | awk -F '\t' '
        function print_row(i,    j) {
            printf "%-*s %-*s %-*s %-*s %-*s %-*s %-*s\n", \
                w[1], f[1], w[2], f[2], w[3], f[3], w[4], f[4], \
                w[5], f[5], w[6], f[6], w[7], f[7]
        }
        {
            lines[++n] = $0
            for (i = 1; i <= 7; i++) {
                if (length($i) > w[i]) w[i] = length($i)
            }
        }
        BEGIN {
            w[1]=3; w[2]=6; w[3]=7; w[4]=6; w[5]=4; w[6]=8; w[7]=5
        }
        END {
            for (i = 1; i <= n; i++) {
                nf = split(lines[i], f, "\t")
                for (j = nf + 1; j <= 7; j++) f[j] = ""
                print_row(i)
            }
        }
    '
}
