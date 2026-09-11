# shellcheck shell=bash
# lib/packages.sh — package manager abstraction (apt, brew).
# Requires lib/common.sh to be sourced first.

# ---------------------------------------------------------------------------
# package name mapping
# ---------------------------------------------------------------------------

# cli_package_name <cli> <provider>
cli_package_name() {
    local cli="$1" provider="$2"
    case "$provider" in
        apt | brew)
            case "$cli" in
                gh) printf '%s' "gh" ;;
                az) printf '%s' "azure-cli" ;;
                aws) printf '%s' "awscli" ;;
                glow) printf '%s' "glow" ;;
                rg) printf '%s' "ripgrep" ;;
                mlr) printf '%s' "miller" ;;
                opencode) printf '%s' "opencode" ;;
                codebuddy) printf '%s' "codebuddy-code" ;;
                terraform) printf '%s' "terraform" ;;
                oci) printf '%s' "oci-cli" ;;
            esac
            ;;
        brew-cask)
            case "$cli" in
                *) printf '%s' "$cli" ;;
            esac
            ;;
    esac
}

# ---------------------------------------------------------------------------
# availability
# ---------------------------------------------------------------------------

brew_bin() {
    local b=""
    b=$(command -v brew 2>/dev/null) || b=""
    if [ -n "$b" ]; then
        printf '%s\n' "$b"
        return 0
    fi
    if [ -x /opt/homebrew/bin/brew ]; then
        printf '%s\n' "/opt/homebrew/bin/brew"
        return 0
    fi
    if [ -x /usr/local/bin/brew ]; then
        printf '%s\n' "/usr/local/bin/brew"
        return 0
    fi
    return 1
}

has_brew() {
    brew_bin >/dev/null 2>&1
}

has_apt() {
    cmd_exists apt-get && cmd_exists apt-cache && cmd_exists dpkg-query
}

# package_manager_available <provider>
package_manager_available() {
    case "$1" in
        apt) has_apt ;;
        brew | brew-cask) has_brew ;;
        *) return 1 ;;
    esac
}

can_sudo() {
    [ "$(id -u)" -eq 0 ] && return 0
    sudo -n true 2>/dev/null
}

apt_run() {
    if [ "$(id -u)" -eq 0 ]; then
        "$@"
    else
        sudo "$@"
    fi
}

# ---------------------------------------------------------------------------
# APT
# ---------------------------------------------------------------------------

apt_installed_version() {
    local pkg="$1"
    dpkg-query -W -f='${Version}' "$pkg" 2>/dev/null
}

apt_candidate_version() {
    local pkg="$1" ver=""
    ver=$(apt-cache policy "$pkg" 2>/dev/null | awk '/Candidate:/ { print $2; exit }')
    [ "$ver" = "(none)" ] && ver=""
    printf '%s\n' "$ver"
}

# apt_repo_host <cli>: apt host fragment used to scope update/warnings.
apt_repo_host() {
    case "$1" in
        gh) printf '%s' "cli.github.com" ;;
        az) printf '%s' "packages.microsoft.com/repos/azure-cli" ;;
        terraform) printf '%s' "apt.releases.hashicorp.com" ;;
    esac
}

# apt_source_list <cli>: primary apt source file for scoped update.
apt_source_list() {
    case "$1" in
        gh) printf '%s' "/etc/apt/sources.list.d/github-cli.list" ;;
        az)
            if [ -f /etc/apt/sources.list.d/azure-cli.sources ]; then
                printf '%s' "/etc/apt/sources.list.d/azure-cli.sources"
            else
                printf '%s' "/etc/apt/sources.list.d/azure-cli.list"
            fi
            ;;
        terraform) printf '%s' "/etc/apt/sources.list.d/hashicorp.list" ;;
    esac
}

apt_cleanup_conflicts() {
    local cli="$1"
    case "$cli" in
        az)
            if [ -f /etc/apt/sources.list.d/azure-cli.sources ] \
                && [ -f /etc/apt/sources.list.d/azure-cli.list ]; then
                apt_run rm -f /etc/apt/sources.list.d/azure-cli.list
                log_info "apt: removed duplicate azure-cli.list (azure-cli.sources is used)"
            fi
            ;;
    esac
}

# apt_update_quiet <cli>: update only the repo cli-toolbox uses; warn on its errors only.
apt_update_quiet() {
    local cli="${1:-}" host="" list="" err
    host=$(apt_repo_host "$cli")
    list=$(apt_source_list "$cli")
    if [ -z "$host" ] || [ ! -f "$list" ]; then
        return 0
    fi
    err=$(mktemp "${TMPDIR:-/tmp}/cli-toolbox.apt.XXXXXX") || return 0
    apt_run apt-get update -qq \
        -o "Dir::Etc::sourcelist=$list" \
        -o Dir::Etc::sourceparts=- \
        -o APT::Get::List-Cleanup=0 \
        2>"$err" || true
    if grep -qi "$host" "$err"; then
        grep -iE '^[EW]:' "$err" | grep -i "$host" \
            | while IFS= read -r line; do
                log_warn "apt: ${line#*: }"
            done
    fi
    rm -f "$err"
}

apt_setup_repo_gh() {
    local tmp
    apt_run mkdir -p -m 755 /etc/apt/keyrings
    if ! make_tempdir; then
        return 1
    fi
    tmp="$TB_TMPDIR/githubcli-archive-keyring.gpg"
    if ! download_file "https://cli.github.com/packages/githubcli-archive-keyring.gpg" "$tmp"; then
        log_error "failed to download GitHub CLI apt keyring"
        return 1
    fi
    apt_run cp "$tmp" /etc/apt/keyrings/githubcli-archive-keyring.gpg
    apt_run chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg
    # Always refresh list so signed-by matches the current keyring (cli/cli#13118).
    printf '%s\n' \
        "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
        | apt_run tee /etc/apt/sources.list.d/github-cli.list >/dev/null
    return 0
}

apt_setup_repo_az() {
    local tmp
    if [ -f /etc/apt/sources.list.d/azure-cli.sources ]; then
        apt_cleanup_conflicts az
        return 0
    fi
    apt_run mkdir -p -m 755 /etc/apt/keyrings
    if ! make_tempdir; then
        return 1
    fi
    tmp="$TB_TMPDIR"
    if ! download_file "https://packages.microsoft.com/keys/microsoft.asc" "$tmp/microsoft.asc"; then
        log_error "failed to download Microsoft apt signing key"
        return 1
    fi
    if ! gpg --dearmor --yes -o "$tmp/microsoft.gpg" "$tmp/microsoft.asc" 2>/dev/null; then
        log_error "failed to dearmor Microsoft apt signing key"
        return 1
    fi
    apt_run cp "$tmp/microsoft.gpg" /etc/apt/keyrings/microsoft.gpg
    apt_run chmod go+r /etc/apt/keyrings/microsoft.gpg
    if [ ! -f /etc/apt/sources.list.d/azure-cli.list ]; then
        printf '%s\n' \
            "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/microsoft.gpg] https://packages.microsoft.com/repos/azure-cli/ $(. /etc/os-release && echo "$VERSION_CODENAME") main" \
            | apt_run tee /etc/apt/sources.list.d/azure-cli.list >/dev/null
    fi
    return 0
}

apt_setup_repo_hashicorp() {
    local tmp codename=""
    apt_run mkdir -p -m 755 /etc/apt/keyrings
    if ! make_tempdir; then
        return 1
    fi
    tmp="$TB_TMPDIR"
    if ! download_file "https://apt.releases.hashicorp.com/gpg" "$tmp/hashicorp.asc"; then
        log_error "failed to download HashiCorp apt signing key"
        return 1
    fi
    if ! gpg --dearmor --yes -o "$tmp/hashicorp.gpg" "$tmp/hashicorp.asc" 2>/dev/null; then
        log_error "failed to dearmor HashiCorp apt signing key"
        return 1
    fi
    apt_run cp "$tmp/hashicorp.gpg" /etc/apt/keyrings/hashicorp-archive-keyring.gpg
    apt_run chmod go+r /etc/apt/keyrings/hashicorp-archive-keyring.gpg
    codename=$(. /etc/os-release && printf '%s' "${VERSION_CODENAME:-}")
    if [ -z "$codename" ] && cmd_exists lsb_release; then
        codename=$(lsb_release -cs 2>/dev/null)
    fi
    if [ -z "$codename" ]; then
        log_error "cannot determine apt suite codename for HashiCorp repository"
        return 1
    fi
    printf '%s\n' \
        "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com ${codename} main" \
        | apt_run tee /etc/apt/sources.list.d/hashicorp.list >/dev/null
    return 0
}

apt_ensure_repo() {
    local cli="$1"
    case "$cli" in
        gh) apt_setup_repo_gh || return 1 ;;
        az) apt_setup_repo_az || return 1 ;;
        terraform) apt_setup_repo_hashicorp || return 1 ;;
    esac
    return 0
}

apt_install_or_upgrade() {
    local pkg="$1"
    apt_run env DEBIAN_FRONTEND=noninteractive apt-get install -y "$pkg" >/dev/null 2>&1
}

# ---------------------------------------------------------------------------
# Homebrew
# ---------------------------------------------------------------------------

brew_installed_version() {
    local pkg="$1" brew="" line=""
    brew=$(brew_bin) || return 1
    line=$("$brew" list --versions "$pkg" 2>/dev/null | head -1)
    [ -z "$line" ] && return 0
    printf '%s\n' "$line" | awk '{print $2}'
}

brew_latest_version() {
    local pkg="$1" brew="" ver=""
    brew=$(brew_bin) || return 1
    if cmd_exists python3; then
        ver=$("$brew" info --json=v2 "$pkg" 2>/dev/null | python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(1)
for f in data:
    for v in f.get("installed", []):
        pass
    ver = f.get("versions", {}).get("stable", "")
    if ver:
        print(ver)
        sys.exit(0)
sys.exit(1)
' 2>/dev/null) || ver=""
    fi
    if [ -z "$ver" ]; then
        ver=$("$brew" info "$pkg" 2>/dev/null | head -1 | sed 's/:.*//' | awk '{print $NF}' | tr -d ',')
    fi
    printf '%s\n' "$ver"
}

brew_install_or_upgrade() {
    local pkg="$1" brew="" installed="" formula=""
    brew=$(brew_bin) || return 1
    formula="$pkg"
    if [ "$pkg" = "terraform" ]; then
        "$brew" tap hashicorp/tap >/dev/null 2>&1 || true
        formula="hashicorp/tap/terraform"
    elif [ "$pkg" = "codebuddy-code" ]; then
        "$brew" tap Tencent-CodeBuddy/tap >/dev/null 2>&1 || true
        formula="Tencent-CodeBuddy/tap/codebuddy-code"
    fi
    installed=$(brew_installed_version "$pkg")
    if [ -n "$installed" ]; then
        "$brew" upgrade "$formula" >/dev/null 2>&1
    else
        "$brew" install "$formula" >/dev/null 2>&1
    fi
}

# ---------------------------------------------------------------------------
# generic package API
# ---------------------------------------------------------------------------

# package_installed_version <provider> <package>
package_installed_version() {
    case "$1" in
        apt) apt_installed_version "$2" ;;
        brew | brew-cask) brew_installed_version "$2" ;;
        *) return 1 ;;
    esac
}

# package_latest_version <provider> <package>
package_latest_version() {
    case "$1" in
        apt) apt_candidate_version "$2" ;;
        brew | brew-cask) brew_latest_version "$2" ;;
        *) return 1 ;;
    esac
}

# package_install_or_upgrade <provider> <package>
package_install_or_upgrade() {
    case "$1" in
        apt) apt_install_or_upgrade "$2" ;;
        brew | brew-cask) brew_install_or_upgrade "$2" ;;
        *) return 1 ;;
    esac
}
