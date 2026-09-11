# shellcheck shell=bash
# lib/installers.sh — per-CLI installers for cli-toolbox

# Requires lib/common.sh and lib/providers.sh to be sourced first.

# ---------------------------------------------------------------------------
# shared scaffolding
# ---------------------------------------------------------------------------

_installer_start() {
    TB_STATE=error
    TB_DETAIL=""
    if ! detect_platform; then
        TB_DETAIL="unsupported platform (${TB_OS:-?}/${TB_ARCH:-?})"
        return 1
    fi
    if [ "$TB_OS" != "linux" ]; then
        TB_DETAIL="macOS is not yet supported (Linux amd64/arm64 is the primary target)"
        return 1
    fi
    return 0
}

_find_in_archive() {
    local root="$1" name="$2"
    shift 2
    local cand p
    if [ -f "$root/$name" ]; then
        printf '%s\n' "$root/$name"
        return 0
    fi
    for cand in "$@"; do
        if [ -f "$root/$cand/$name" ]; then
            printf '%s\n' "$root/$cand/$name"
            return 0
        fi
    done
    while IFS= read -r p; do
        [ -n "$p" ] || continue
        if [ -f "$p" ]; then
            printf '%s\n' "$p"
            return 0
        fi
    done <<< "$(find "$root" -maxdepth 3 -type f -name "$name" 2>/dev/null)"
    return 1
}

_finish_install() {
    local cli="$1" before="$2" ver="$3"
    if [ -z "$ver" ]; then
        TB_STATE=error
        TB_DETAIL="installed but version check failed"
        return 1
    fi
    if [ -n "$before" ]; then
        TB_STATE=updated
        TB_DETAIL="${before} -> ${ver}"
    else
        TB_STATE=installed
        TB_DETAIL="${ver}"
    fi
    return 0
}

_ensure_path_prefix() {
    local dir="$1"
    case ":$PATH:" in
        *":$dir:"*) return 0 ;;
    esac
    export PATH="$dir:$PATH"
}

# ---------------------------------------------------------------------------
# uv — official standalone installer (download script, run separately)
# ---------------------------------------------------------------------------

install_uv() {
    TB_STATE=error
    TB_DETAIL=""
    _installer_start || return 1
    local latest installed url tmp ver body=""
    body=$(github_release_json astral-sh/uv 2>/dev/null) || body=""
    latest=$(github_version_from_json "$body" 2>/dev/null) || latest=""
    installed=$(get_installed_version uv)
    if [ -n "$installed" ] && [ -n "$latest" ] && [ "$installed" = "$latest" ]; then
        TB_STATE=unchanged
        TB_DETAIL="$installed"
        return 0
    fi
    if ! make_tempdir; then
        TB_DETAIL="cannot create temp directory"
        return 1
    fi
    tmp="$TB_TMPDIR"
    url="${CLOUD_TOOLBOX_UV_INSTALL_URL:-https://astral.sh/uv/install.sh}"
    log_info "uv: downloading installer ${url}"
    if ! download_file "$url" "$tmp/install.sh"; then
        TB_DETAIL="download failed (uv installer)"
        return 1
    fi
    chmod +x "$tmp/install.sh"
    mkdir -p "$CLOUD_TOOLBOX_HOME/bin" || { TB_DETAIL="cannot create bin directory"; return 1; }
    log_info "uv: running official standalone installer (UV_INSTALL_DIR=${CLOUD_TOOLBOX_HOME}/bin)"
    if ! UV_INSTALL_DIR="$CLOUD_TOOLBOX_HOME/bin" UV_NO_MODIFY_PATH=1 UV_UNMANAGED_INSTALL=1 \
        sh "$tmp/install.sh" >/dev/null 2>&1; then
        TB_DETAIL="uv installer failed"
        return 1
    fi
    ver=$(get_installed_version uv)
    manifest_record uv official-installer "$ver" "$CLOUD_TOOLBOX_HOME/bin/uv"
    _finish_install uv "$installed" "$ver"
}

# ---------------------------------------------------------------------------
# tccli — uv tool (isolated; never pip/venv directly)
# ---------------------------------------------------------------------------

_ensure_uv_on_path() {
    _ensure_path_prefix "$CLOUD_TOOLBOX_HOME/bin"
    if ! cmd_exists uv; then
        log_info "tccli: uv not found; installing uv first"
        install_uv || return 1
        _ensure_path_prefix "$CLOUD_TOOLBOX_HOME/bin"
    fi
    cmd_exists uv
}

_warn_tccli_path_collision() {
    local uv_path="" other="" uv_bin_dir=""
    uv_path=$(uv_tool_executable_path tccli) || uv_path=""
    other=$(command -v tccli 2>/dev/null) || other=""
    uv_bin_dir=$(uv_tool_bin_dir)
    if [ -n "$other" ] && [ "$other" != "$uv_path" ]; then
        log_warn "tccli: another tccli exists at ${other}; ensure ${uv_bin_dir} is before it on PATH"
        case ":$PATH:" in
            *":${uv_bin_dir}:"*) ;;
            *) log_warn "tccli: add export PATH=\"${uv_bin_dir}:\$PATH\" so uv-managed tccli is preferred" ;;
        esac
    fi
}

install_tccli() {
    TB_STATE=error
    TB_DETAIL=""
    _installer_start || return 1
    if ! _ensure_uv_on_path; then
        TB_DETAIL="uv is required for tccli (install uv first)"
        return 1
    fi
    local latest installed ver uv="" tool_bin=""
    latest=$(get_latest_version_pypi tccli 2>/dev/null) || latest=""
    installed=$(get_installed_version tccli)
    if [ -n "$installed" ] && [ -n "$latest" ] && [ "$installed" = "$latest" ]; then
        TB_STATE=unchanged
        TB_DETAIL="$installed"
        _warn_tccli_path_collision
        return 0
    fi
    uv=$(uv_bin)
    tool_bin=$(uv_tool_bin_dir)
    mkdir -p "$tool_bin"
    _ensure_path_prefix "$tool_bin"
    log_info "tccli: uv tool install --upgrade tccli (bin dir: ${tool_bin})"
    UV_TOOL_BIN_DIR="$tool_bin" "$uv" tool install --upgrade tccli >/dev/null 2>&1 || true
    if ! uv_tool_has tccli; then
        TB_DETAIL="uv tool install failed for tccli"
        return 1
    fi
    ver=$(get_installed_version tccli)
    manifest_record tccli uv-tool "$ver" "$(uv_tool_executable_path tccli 2>/dev/null || printf '%s' "$tool_bin/tccli")"
    _warn_tccli_path_collision
    _finish_install tccli "$installed" "$ver"
}

# ---------------------------------------------------------------------------
# APT packages — gh, gcloud, az (overridable for tests)
# ---------------------------------------------------------------------------

apt_run() {
    if [ "$(id -u)" -eq 0 ]; then
        "$@"
    else
        sudo "$@"
    fi
}

apt_require_sudo() {
    if can_sudo; then
        return 0
    fi
    TB_DETAIL="requires root (sudo apt install $(cli_apt_package "$1"))"
    return 1
}

apt_setup_repo_gh() {
    apt_run mkdir -p -m 755 /etc/apt/keyrings
    download_file "https://cli.github.com/packages/githubcli-archive-keyring.gpg" \
        "/tmp/githubcli-archive-keyring.gpg"
    apt_run cp /tmp/githubcli-archive-keyring.gpg /etc/apt/keyrings/githubcli-archive-keyring.gpg
    apt_run chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg
    printf '%s\n' \
        "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
        | apt_run tee /etc/apt/sources.list.d/github-cli.list >/dev/null
}

apt_setup_repo_gcloud() {
    apt_run mkdir -p -m 755 /etc/apt/keyrings
    download_file "https://packages.cloud.google.com/apt/doc/apt-key.gpg" "/tmp/cloud-google.gpg"
    apt_run cp /tmp/cloud-google.gpg /etc/apt/keyrings/cloud.google.gpg
    apt_run chmod go+r /etc/apt/keyrings/cloud.google.gpg
    printf '%s\n' \
        "deb [signed-by=/etc/apt/keyrings/cloud.google.gpg] https://packages.cloud.google.com/apt cloud-sdk main" \
        | apt_run tee /etc/apt/sources.list.d/google-cloud-sdk.list >/dev/null
}

apt_setup_repo_az() {
    apt_run mkdir -p -m 755 /etc/apt/keyrings
    download_file "https://packages.microsoft.com/keys/microsoft.asc" "/tmp/microsoft.asc"
    gpg --dearmor < /tmp/microsoft.asc > /tmp/microsoft.gpg
    apt_run cp /tmp/microsoft.gpg /etc/apt/keyrings/microsoft.gpg
    apt_run chmod go+r /etc/apt/keyrings/microsoft.gpg
    printf '%s\n' \
        "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/microsoft.gpg] https://packages.microsoft.com/repos/azure-cli/ $(. /etc/os-release && echo "$VERSION_CODENAME") main" \
        | apt_run tee /etc/apt/sources.list.d/azure-cli.list >/dev/null
}

apt_ensure_repo() {
    local cli="$1"
    case "$cli" in
        gh)
            [ -f /etc/apt/sources.list.d/github-cli.list ] || apt_setup_repo_gh
            ;;
        gcloud)
            [ -f /etc/apt/sources.list.d/google-cloud-sdk.list ] || apt_setup_repo_gcloud
            ;;
        az)
            [ -f /etc/apt/sources.list.d/azure-cli.list ] || apt_setup_repo_az
            ;;
    esac
}

install_apt_cli() {
    local cli="$1" pkg="" installed="" latest="" ver=""
    TB_STATE=error
    TB_DETAIL=""
    _installer_start || return 1
    if ! has_apt; then
        TB_DETAIL="apt is required for ${cli} on this platform"
        return 1
    fi
    apt_require_sudo "$cli" || return 1
    pkg=$(cli_apt_package "$cli")
    installed=$(apt_installed_version "$pkg")
    apt_ensure_repo "$cli"
    apt_run apt-get update -qq
    latest=$(apt_candidate_version "$pkg")
    if [ -n "$installed" ] && [ -n "$latest" ] && [ "$installed" = "$latest" ]; then
        TB_STATE=unchanged
        TB_DETAIL="$installed"
        manifest_record "$cli" official-package "$installed" "$(command -v "$cli" 2>/dev/null || echo "/usr/bin/$cli")"
        return 0
    fi
    log_info "${cli}: apt-get install -y ${pkg}"
    if ! apt_run env DEBIAN_FRONTEND=noninteractive apt-get install -y "$pkg" >/dev/null 2>&1; then
        TB_DETAIL="apt install failed for ${pkg}"
        return 1
    fi
    ver=$(apt_installed_version "$pkg")
    manifest_record "$cli" official-package "$ver" "$(command -v "$cli" 2>/dev/null || echo "/usr/bin/$cli")"
    _finish_install "$cli" "$installed" "$ver"
}

install_gh() { install_apt_cli gh; }
install_gcloud() { install_apt_cli gcloud; }
install_az() { install_apt_cli az; }

# ---------------------------------------------------------------------------
# glow / coscli — GitHub release binaries
# ---------------------------------------------------------------------------

install_glow() {
    TB_STATE=error
    TB_DETAIL=""
    _installer_start || return 1
    local body latest installed
    body=$(github_release_json charmbracelet/glow) || { TB_DETAIL="cannot determine latest version"; return 1; }
    latest=$(github_version_from_json "$body") || { TB_DETAIL="cannot determine latest version"; return 1; }
    installed=$(get_installed_version glow)
    if [ -n "$installed" ] && [ "$installed" = "$latest" ]; then
        TB_STATE=unchanged
        TB_DETAIL="$installed"
        return 0
    fi
    local arch asset tmp tag asset_url checksum_url cktext expected src ver
    case "$TB_ARCH" in
        amd64) arch=x86_64 ;;
        arm64) arch=arm64 ;;
    esac
    if ! make_tempdir; then
        TB_DETAIL="cannot create temp directory"
        return 1
    fi
    tmp="$TB_TMPDIR"
    asset="glow_${latest}_Linux_${arch}.tar.gz"
    tag="v${latest}"
    asset_url=$(github_asset_url charmbracelet/glow "$tag" "$asset" "$body")
    checksum_url=$(github_asset_url charmbracelet/glow "$tag" "checksums.txt" "$body")
    log_info "glow: downloading ${asset_url}"
    if ! download_file "$checksum_url" "$tmp/checksums.txt"; then
        TB_DETAIL="download failed (checksums)"
        return 1
    fi
    cktext=$(<"$tmp/checksums.txt")
    expected=$(checksum_for "$cktext" "$asset") || { TB_DETAIL="checksum entry not found for ${asset}"; return 1; }
    if ! download_file "$asset_url" "$tmp/$asset"; then
        TB_DETAIL="download failed"
        return 1
    fi
    if ! verify_sha256 "$tmp/$asset" "$expected"; then
        TB_DETAIL="checksum mismatch"
        return 1
    fi
    if ! extract_archive "$tmp/$asset" "$tmp/x"; then
        TB_DETAIL="extraction failed"
        return 1
    fi
    src=$(_find_in_archive "$tmp/x" glow "glow_${latest}_Linux_${arch}")
    [ -n "$src" ] || { TB_DETAIL="binary not found in archive"; return 1; }
    if ! atomic_install "$src" "$CLOUD_TOOLBOX_HOME/bin/glow"; then
        TB_DETAIL="failed to place binary"
        return 1
    fi
    ver=$(get_installed_version glow)
    manifest_record glow release-binary "$ver" "$CLOUD_TOOLBOX_HOME/bin/glow"
    _finish_install glow "$installed" "$ver"
}

install_coscli() {
    TB_STATE=error
    TB_DETAIL=""
    _installer_start || return 1
    local body latest installed
    body=$(github_release_json tencentyun/coscli) || { TB_DETAIL="cannot determine latest version"; return 1; }
    latest=$(github_version_from_json "$body") || { TB_DETAIL="cannot determine latest version"; return 1; }
    installed=$(get_installed_version coscli)
    if [ -n "$installed" ] && [ "$installed" = "$latest" ]; then
        TB_STATE=unchanged
        TB_DETAIL="$installed"
        return 0
    fi
    local tmp asset tag asset_url checksum_url cktext expected ver
    if ! make_tempdir; then
        TB_DETAIL="cannot create temp directory"
        return 1
    fi
    tmp="$TB_TMPDIR"
    asset="coscli-v${latest}-linux-${TB_ARCH}"
    tag="v${latest}"
    asset_url=$(github_asset_url tencentyun/coscli "$tag" "$asset" "$body")
    checksum_url=$(github_asset_url tencentyun/coscli "$tag" "sha256sum.log" "$body")
    log_info "coscli: downloading ${asset_url}"
    if ! download_file "$checksum_url" "$tmp/sha256sum.log"; then
        TB_DETAIL="download failed (checksums)"
        return 1
    fi
    cktext=$(<"$tmp/sha256sum.log")
    expected=$(checksum_for "$cktext" "$asset") || { TB_DETAIL="checksum entry not found for ${asset}"; return 1; }
    if ! download_file "$asset_url" "$tmp/$asset"; then
        TB_DETAIL="download failed"
        return 1
    fi
    if ! verify_sha256 "$tmp/$asset" "$expected"; then
        TB_DETAIL="checksum mismatch"
        return 1
    fi
    if ! atomic_install "$tmp/$asset" "$CLOUD_TOOLBOX_HOME/bin/coscli"; then
        TB_DETAIL="failed to place binary"
        return 1
    fi
    ver=$(get_installed_version coscli)
    manifest_record coscli release-binary "$ver" "$CLOUD_TOOLBOX_HOME/bin/coscli"
    _finish_install coscli "$installed" "$ver"
}

# ---------------------------------------------------------------------------
# aws — AWS CLI v2 official installer (never uv tool / awscli v1)
# ---------------------------------------------------------------------------

install_aws() {
    TB_STATE=error
    TB_DETAIL=""
    _installer_start || return 1
    local latest
    latest=$(http_get "https://awscli.amazonaws.com/v2/version.txt" | tr -d '[:space:]')
    if [ -z "$latest" ]; then
        TB_DETAIL="cannot determine latest version"
        return 1
    fi
    log_warn "aws: no official sha256 checksum published (PGP signature only); skipping checksum verification"
    local installed
    installed=$(get_installed_version aws)
    if [ -n "$installed" ] && [ "$installed" = "$latest" ]; then
        TB_STATE=unchanged
        TB_DETAIL="$installed"
        return 0
    fi
    local arch zip_url tmp ver
    case "$TB_ARCH" in
        amd64) arch=x86_64 ;;
        arm64) arch=aarch64 ;;
    esac
    zip_url="https://awscli.amazonaws.com/awscli-exe-linux-${arch}.zip"
    if ! make_tempdir; then
        TB_DETAIL="cannot create temp directory"
        return 1
    fi
    tmp="$TB_TMPDIR"
    log_info "aws: downloading ${zip_url}"
    if ! download_file "$zip_url" "$tmp/awscli.zip"; then
        TB_DETAIL="download failed"
        return 1
    fi
    if ! extract_archive "$tmp/awscli.zip" "$tmp/x"; then
        TB_DETAIL="extraction failed"
        return 1
    fi
    if [ ! -x "$tmp/x/aws/install" ]; then
        TB_DETAIL="aws installer not found in archive"
        return 1
    fi
    log_info "aws: running official installer (--install-dir ${CLOUD_TOOLBOX_HOME}/tools/aws-cli --bin-dir ${CLOUD_TOOLBOX_HOME}/bin --update)"
    if ! "$tmp/x/aws/install" \
        --install-dir "$CLOUD_TOOLBOX_HOME/tools/aws-cli" \
        --bin-dir "$CLOUD_TOOLBOX_HOME/bin" \
        --update >/dev/null 2>&1; then
        TB_DETAIL="aws installer failed"
        return 1
    fi
    ver=$(get_installed_version aws)
    manifest_record aws official-installer "$ver" "$CLOUD_TOOLBOX_HOME/bin/aws"
    _finish_install aws "$installed" "$ver"
}

# ---------------------------------------------------------------------------
# local wrappers — cloud-cli repo (symlink; never delete existing CLIs)
# ---------------------------------------------------------------------------

install_wrapper() {
    local name="$1" src="" dep="" dep_path=""
    TB_STATE=error
    TB_DETAIL=""
    _installer_start || return 1
    src="$CLOUD_CLI_REPO/$(cli_wrapper_source "$name")"
    if [ ! -f "$src" ]; then
        TB_DETAIL="wrapper source not found: ${src} (set CLOUD_CLI_REPO)"
        return 1
    fi
    dep=$(cli_wrapper_requires "$name")
    dep_path=$(resolve_path "$dep") || dep_path=""
    if [ -z "$dep_path" ]; then
        TB_DETAIL="native CLI '${dep}' not found (required by ${name})"
        return 1
    fi
    local current=""
    if [ -L "$CLOUD_TOOLBOX_HOME/bin/$name" ]; then
        current=$(readlink "$CLOUD_TOOLBOX_HOME/bin/$name" 2>/dev/null)
        if [ "$current" = "$src" ]; then
            TB_STATE=unchanged
            TB_DETAIL="wrapper"
            manifest_record "$name" local-wrapper "wrapper" "$CLOUD_TOOLBOX_HOME/bin/$name"
            return 0
        fi
    fi
    if ! atomic_symlink "$src" "$CLOUD_TOOLBOX_HOME/bin/$name"; then
        TB_DETAIL="failed to place wrapper symlink"
        return 1
    fi
    manifest_record "$name" local-wrapper "wrapper" "$CLOUD_TOOLBOX_HOME/bin/$name"
    TB_STATE=installed
    TB_DETAIL="wrapper -> ${src}"
    return 0
}

install_awst() { install_wrapper awst; }
install_gcloudt() { install_wrapper gcloudt; }
install_tcclit() { install_wrapper tcclit; }

# ---------------------------------------------------------------------------
# dispatch
# ---------------------------------------------------------------------------

run_installer() {
    local name="$1"
    case "$name" in
        uv) install_uv ;;
        tccli) install_tccli ;;
        gh) install_gh ;;
        gcloud) install_gcloud ;;
        az) install_az ;;
        glow) install_glow ;;
        coscli) install_coscli ;;
        aws) install_aws ;;
        awst) install_awst ;;
        gcloudt) install_gcloudt ;;
        tcclit) install_tcclit ;;
        *) TB_STATE=error; TB_DETAIL="no installer for ${name}" ;;
    esac
    case "${TB_STATE:-error}" in
        error) return 1 ;;
    esac
    return 0
}
