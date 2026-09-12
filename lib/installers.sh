# shellcheck shell=bash
# lib/installers.sh — per-CLI installers for cli-toolbox
# Requires lib/common.sh, lib/packages.sh, and lib/providers.sh.

# ---------------------------------------------------------------------------
# shared scaffolding
# ---------------------------------------------------------------------------

_installer_start() {
    TB_STATE=error
    TB_DETAIL=""
    detect_platform || {
        TB_DETAIL="unsupported platform (${TB_OS:-?}/${TB_ARCH:-?})"
        return 1
    }
    return 0
}

_find_in_archive() {
    local root="$1" name="$2"
    shift 2
    local cand
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
    find_file_limited "$root" 3 "$name"
}

_finish_install() {
    local cli="$1" before="$2" ver="$3"
    if [ -z "$ver" ]; then
        TB_STATE=error
        TB_DETAIL="installed but version check failed"
        return 1
    fi
    if [ -n "$before" ]; then
        if [ "$before" = "$ver" ]; then
            TB_STATE=unchanged
            TB_DETAIL="$ver"
        else
            TB_STATE=updated
            TB_DETAIL="${before} -> ${ver}"
        fi
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

_release_os_label() {
    case "$TB_OS" in
        linux) printf '%s' "Linux" ;;
        darwin) printf '%s' "Darwin" ;;
        *) return 1 ;;
    esac
}

_release_arch_label() {
    case "$TB_ARCH" in
        amd64) printf '%s' "x86_64" ;;
        arm64) printf '%s' "arm64" ;;
        *) return 1 ;;
    esac
}

# ---------------------------------------------------------------------------
# uv — official standalone installer
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
    url="${CLI_TOOLBOX_UV_INSTALL_URL:-https://astral.sh/uv/install.sh}"
    log_info "uv: downloading installer ${url}"
    if ! download_file "$url" "$tmp/install.sh"; then
        TB_DETAIL="download failed (uv installer)"
        return 1
    fi
    chmod +x "$tmp/install.sh"
    mkdir -p "$CLI_TOOLBOX_HOME/bin" || { TB_DETAIL="cannot create bin directory"; return 1; }
    log_info "uv: running official standalone installer (UV_INSTALL_DIR=${CLI_TOOLBOX_HOME}/bin)"
    if ! UV_INSTALL_DIR="$CLI_TOOLBOX_HOME/bin" UV_NO_MODIFY_PATH=1 UV_UNMANAGED_INSTALL=1 \
        sh "$tmp/install.sh" >/dev/null 2>&1; then
        TB_DETAIL="uv installer failed"
        return 1
    fi
    ver=$(get_installed_version uv)
    manifest_record uv official-installer "$ver" "$CLI_TOOLBOX_HOME/bin/uv"
    _finish_install uv "$installed" "$ver"
}

# ---------------------------------------------------------------------------
# tccli — uv tool
# ---------------------------------------------------------------------------

_ensure_uv_on_path() {
    _ensure_path_prefix "$CLI_TOOLBOX_HOME/bin"
    if ! cmd_exists uv; then
        log_info "tccli: uv not found; installing uv first"
        install_uv || return 1
        _ensure_path_prefix "$CLI_TOOLBOX_HOME/bin"
    fi
    cmd_exists uv
}

_warn_tccli_path_collision() {
    local uv_path="" other="" uv_real="" other_real="" uv_bin_dir=""
    uv_path=$(uv_tool_executable_path tccli) || uv_path=""
    other=$(command -v tccli 2>/dev/null) || other=""
    if [ -z "$other" ] || [ -z "$uv_path" ]; then
        return 0
    fi
    uv_real=$(resolve_real_path "$uv_path") || uv_real="$uv_path"
    other_real=$(resolve_real_path "$other") || other_real="$other"
    if [ "$uv_real" = "$other_real" ]; then
        return 0
    fi
    uv_bin_dir=$(uv_tool_bin_dir)
    log_warn "tccli: another tccli exists at ${other}; ensure ${uv_bin_dir} is before it on PATH"
    case ":$PATH:" in
        *":${uv_bin_dir}:"*) ;;
        *) log_warn "tccli: add export PATH=\"${uv_bin_dir}:\$PATH\" so uv-managed tccli is preferred" ;;
    esac
}

_prepare_tccli_tool_bin() {
    local tool_bin="$1" candidate="" real=""
    candidate="$tool_bin/tccli"
    [ -e "$candidate" ] || [ -L "$candidate" ] || return 0
    real=$(resolve_real_path "$candidate") || real="$candidate"
    if path_is_pipx "$real"; then
        log_warn "tccli: replacing pipx-managed ${candidate} with uv tool install"
        rm -f "$candidate"
        return 0
    fi
    if ! uv_tool_has tccli; then
        log_warn "tccli: removing existing ${candidate} before uv tool install"
        rm -f "$candidate"
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
    local latest installed ver uv="" tool_bin="" uv_path=""
    latest=$(get_latest_version_pypi tccli 2>/dev/null) || latest=""
    installed=""
    uv_path=$(uv_tool_executable_path tccli 2>/dev/null) || uv_path=""
    if [ -n "$uv_path" ]; then
        installed=$(_parse_version tccli "$uv_path")
    fi
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
    if uv_tool_has tccli; then
        UV_TOOL_BIN_DIR="$tool_bin" "$uv" tool uninstall tccli >/dev/null 2>&1 || true
    fi
    _prepare_tccli_tool_bin "$tool_bin"
    log_info "tccli: uv tool install --upgrade tccli (bin dir: ${tool_bin})"
    if ! UV_TOOL_BIN_DIR="$tool_bin" "$uv" tool install --upgrade --force tccli >/dev/null 2>&1; then
        TB_DETAIL="uv tool install failed for tccli"
        return 1
    fi
    if ! uv_tool_has tccli; then
        TB_DETAIL="uv tool install failed for tccli"
        return 1
    fi
    ver=""
    uv_path=$(uv_tool_executable_path tccli 2>/dev/null) || uv_path=""
    if [ -n "$uv_path" ]; then
        ver=$(_parse_version tccli "$uv_path")
    fi
    if [ -z "$ver" ]; then
        TB_DETAIL="installed but version check failed"
        return 1
    fi
    if [ -n "$latest" ] && [ "$ver" != "$latest" ] && version_gt "$latest" "$ver"; then
        TB_DETAIL="still ${ver} after install (latest ${latest})"
        return 1
    fi
    manifest_record tccli uv-tool "$ver" "${uv_path:-$tool_bin/tccli}"
    _warn_tccli_path_collision
    _finish_install tccli "$installed" "$ver"
}

# ---------------------------------------------------------------------------
# apt / brew package CLIs
# ---------------------------------------------------------------------------

install_package_cli() {
    local cli="$1" provider="$2" pkg="" installed="" latest="" ver="" path=""
    TB_STATE=error
    TB_DETAIL=""
    _installer_start || return 1
    if ! package_manager_available "$provider"; then
        if [ "$provider" = "brew" ]; then
            TB_DETAIL="Homebrew is required on macOS (install from https://brew.sh)"
        else
            TB_DETAIL="apt is required for ${cli} on this platform"
        fi
        return 1
    fi
    if [ "$provider" = "apt" ]; then
        if ! can_sudo; then
            pkg=$(cli_package_name "$cli" apt)
            TB_DETAIL="requires root (sudo apt install ${pkg})"
            return 1
        fi
        if ! apt_ensure_repo "$cli"; then
            TB_DETAIL="failed to configure apt repository for ${cli}"
            return 1
        fi
        apt_cleanup_conflicts "$cli"
    fi
    pkg=$(cli_package_name "$cli" "$provider")
    installed=$(package_installed_version "$provider" "$pkg")
    latest=$(package_latest_version "$provider" "$pkg")
    if [ -n "$installed" ] && [ -n "$latest" ] && [ "$installed" = "$latest" ]; then
        TB_STATE=unchanged
        TB_DETAIL="$installed"
        path=$(command -v "$cli" 2>/dev/null) || path=""
        manifest_record "$cli" "$provider" "$installed" "${path:-unknown}"
        return 0
    fi
    if [ "$provider" = "apt" ]; then
        apt_update_quiet "$cli"
    fi
    log_info "${cli}: ${provider} install/upgrade ${pkg}"
    if ! package_install_or_upgrade "$provider" "$pkg"; then
        TB_DETAIL="${provider} install failed for ${pkg}"
        return 1
    fi
    ver=$(package_installed_version "$provider" "$pkg")
    path=$(command -v "$cli" 2>/dev/null) || path=""
    manifest_record "$cli" "$provider" "$ver" "${path:-unknown}"
    _finish_install "$cli" "$installed" "$ver"
}

install_gh() {
    local provider=""
    _installer_start || return 1
    provider=$(resolve_provider gh "$TB_OS")
    install_package_cli gh "$provider"
}

install_az() {
    local provider=""
    _installer_start || return 1
    provider=$(resolve_provider az "$TB_OS")
    install_package_cli az "$provider"
}

install_terraform() {
    local provider=""
    _installer_start || return 1
    provider=$(resolve_provider terraform "$TB_OS")
    install_package_cli terraform "$provider"
}

install_brew_cli() {
    install_package_cli "$1" brew
}

# ---------------------------------------------------------------------------
# gcloud — official archive (Linux + macOS)
# ---------------------------------------------------------------------------

_warn_gcloud_path_collision() {
    local managed="" other="" managed_real="" other_real=""
    managed=$(gcloud_managed_bin)
    other=$(command -v gcloud 2>/dev/null) || other=""
    if [ -z "$other" ] || [ ! -e "$managed" ]; then
        return 0
    fi
    managed_real=$(resolve_real_path "$managed") || managed_real="$managed"
    other_real=$(resolve_real_path "$other") || other_real="$other"
    if [ "$managed_real" = "$other_real" ]; then
        return 0
    fi
    log_warn "gcloud: another gcloud exists at ${other}; ensure ${CLI_TOOLBOX_HOME}/bin is before it on PATH"
    case ":$PATH:" in
        *":${CLI_TOOLBOX_HOME}/bin:"*) ;;
        *) log_warn "gcloud: add export PATH=\"${CLI_TOOLBOX_HOME}/bin:\$PATH\" so managed gcloud is preferred" ;;
    esac
}

_gcloud_prune_versions() {
    local root versions_dir current_ver="" dir ver count=0
    root=$(gcloud_sdk_root)
    versions_dir="$root/versions"
    [ -d "$versions_dir" ] || return 0
    if [ -L "$root/current" ]; then
        current_ver=$(basename "$(readlink "$root/current")")
    fi
    for dir in "$versions_dir"/*; do
        [ -d "$dir" ] || continue
        ver=$(basename "$dir")
        [ "$ver" = "$current_ver" ] && continue
        count=$((count + 1))
        if [ "$count" -gt 1 ]; then
            rm -rf "$dir"
        fi
    done
}

install_gcloud() {
    TB_STATE=error
    TB_DETAIL=""
    _installer_start || return 1
    local latest installed url tmp tarball sdk_root versions_dir ver_dir current_link ver
    latest=$(gcloud_latest_version) || {
        TB_DETAIL="cannot determine latest version"
        return 1
    }
    installed=$(gcloud_managed_version 2>/dev/null) || installed=""
    if [ -n "$installed" ] && [ "$installed" = "$latest" ]; then
        TB_STATE=unchanged
        TB_DETAIL="$installed"
        _warn_gcloud_path_collision
        return 0
    fi
    url=$(gcloud_archive_url "$latest" "$TB_OS" "$TB_ARCH") || {
        TB_DETAIL="unsupported platform for gcloud archive (${TB_OS}/${TB_ARCH})"
        return 1
    }
    tarball=$(basename "$url")
    if ! make_tempdir; then
        TB_DETAIL="cannot create temp directory"
        return 1
    fi
    tmp="$TB_TMPDIR"
    log_info "gcloud: downloading ${url}"
    if ! download_file "$url" "$tmp/$tarball"; then
        TB_DETAIL="download failed"
        return 1
    fi
    if ! extract_archive "$tmp/$tarball" "$tmp/x"; then
        TB_DETAIL="extraction failed"
        return 1
    fi
    if [ ! -d "$tmp/x/google-cloud-sdk" ]; then
        TB_DETAIL="google-cloud-sdk directory not found in archive"
        return 1
    fi
    sdk_root=$(gcloud_sdk_root)
    versions_dir="$sdk_root/versions"
    ver_dir="$versions_dir/$latest"
    mkdir -p "$versions_dir" "$CLI_TOOLBOX_HOME/bin" || {
        TB_DETAIL="cannot create gcloud directories"
        return 1
    }
    if [ -d "$ver_dir" ]; then
        rm -rf "$ver_dir"
    fi
    if ! mv "$tmp/x/google-cloud-sdk" "$ver_dir"; then
        TB_DETAIL="cannot place SDK version directory"
        return 1
    fi
    ver=$("$ver_dir/bin/gcloud" version 2>/dev/null | sed -n 's/.*Google Cloud SDK \([0-9][^ ]*\).*/\1/p' | head -1)
    if [ -z "$ver" ]; then
        rm -rf "$ver_dir"
        TB_DETAIL="gcloud version check failed after extraction"
        return 1
    fi
    current_link="$sdk_root/current"
    if ! atomic_symlink "versions/$latest" "$current_link"; then
        rm -rf "$ver_dir"
        TB_DETAIL="failed to update current symlink"
        return 1
    fi
    if ! atomic_symlink "../tools/google-cloud-sdk/current/bin/gcloud" "$CLI_TOOLBOX_HOME/bin/gcloud"; then
        TB_DETAIL="failed to create gcloud symlink in bin"
        return 1
    fi
    _gcloud_prune_versions
    manifest_record gcloud official-archive "$ver" "$CLI_TOOLBOX_HOME/bin/gcloud"
    _warn_gcloud_path_collision
    _finish_install gcloud "$installed" "$ver"
}

# ---------------------------------------------------------------------------
# GitHub release binaries (or brew on macOS when available)
# ---------------------------------------------------------------------------

_rg_release_asset() {
    local ver="$1" os="$2" arch="$3"
    case "$os" in
        linux)
            case "$arch" in
                amd64) printf 'ripgrep-%s-x86_64-unknown-linux-musl.tar.gz' "$ver" ;;
                arm64) printf 'ripgrep-%s-aarch64-unknown-linux-musl.tar.gz' "$ver" ;;
            esac
            ;;
        darwin)
            case "$arch" in
                amd64) printf 'ripgrep-%s-x86_64-apple-darwin.tar.gz' "$ver" ;;
                arm64) printf 'ripgrep-%s-aarch64-apple-darwin.tar.gz' "$ver" ;;
            esac
            ;;
    esac
}

_mlr_release_asset() {
    local ver="$1" os="$2" arch="$3"
    case "$os" in
        linux)
            case "$arch" in
                amd64) printf 'miller-%s-linux-amd64.tar.gz' "$ver" ;;
                arm64) printf 'miller-%s-linux-arm64.tar.gz' "$ver" ;;
            esac
            ;;
        darwin)
            case "$arch" in
                amd64) printf 'miller-%s-darwin-amd64.tar.gz' "$ver" ;;
                arm64) printf 'miller-%s-darwin-arm64.tar.gz' "$ver" ;;
            esac
            ;;
    esac
}

install_glow() {
    local provider=""
    _installer_start || return 1
    provider=$(resolve_provider glow "$TB_OS")
    if [ "$provider" = "brew" ]; then
        install_package_cli glow brew
        return $?
    fi
    TB_STATE=error
    TB_DETAIL=""
    local body latest installed os_label arch_label
    body=$(github_release_json charmbracelet/glow) || { TB_DETAIL="cannot determine latest version"; return 1; }
    latest=$(github_version_from_json "$body") || { TB_DETAIL="cannot determine latest version"; return 1; }
    installed=$(get_installed_version glow)
    if [ -n "$installed" ] && [ "$installed" = "$latest" ]; then
        TB_STATE=unchanged
        TB_DETAIL="$installed"
        return 0
    fi
    os_label=$(_release_os_label) || { TB_DETAIL="unsupported OS"; return 1; }
    arch_label=$(_release_arch_label) || { TB_DETAIL="unsupported arch"; return 1; }
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
    asset="glow_${latest}_${os_label}_${arch_label}.tar.gz"
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
    src=$(_find_in_archive "$tmp/x" glow "glow_${latest}_${os_label}_${arch_label}")
    [ -n "$src" ] || { TB_DETAIL="binary not found in archive"; return 1; }
    if ! atomic_install "$src" "$CLI_TOOLBOX_HOME/bin/glow"; then
        TB_DETAIL="failed to place binary"
        return 1
    fi
    ver=$(get_installed_version glow)
    manifest_record glow release-binary "$ver" "$CLI_TOOLBOX_HOME/bin/glow"
    _finish_install glow "$installed" "$ver"
}

install_coscli() {
    TB_STATE=error
    TB_DETAIL=""
    _installer_start || return 1
    local body latest installed os_name
    body=$(github_release_json tencentyun/coscli) || { TB_DETAIL="cannot determine latest version"; return 1; }
    latest=$(github_version_from_json "$body") || { TB_DETAIL="cannot determine latest version"; return 1; }
    installed=$(get_installed_version coscli)
    if [ -n "$installed" ] && [ "$installed" = "$latest" ]; then
        TB_STATE=unchanged
        TB_DETAIL="$installed"
        return 0
    fi
    case "$TB_OS" in
        linux) os_name=linux ;;
        darwin) os_name=darwin ;;
        *) TB_DETAIL="unsupported OS"; return 1 ;;
    esac
    local tmp asset tag asset_url checksum_url cktext expected ver
    if ! make_tempdir; then
        TB_DETAIL="cannot create temp directory"
        return 1
    fi
    tmp="$TB_TMPDIR"
    asset="coscli-v${latest}-${os_name}-${TB_ARCH}"
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
    if ! atomic_install "$tmp/$asset" "$CLI_TOOLBOX_HOME/bin/coscli"; then
        TB_DETAIL="failed to place binary"
        return 1
    fi
    ver=$(get_installed_version coscli)
    manifest_record coscli release-binary "$ver" "$CLI_TOOLBOX_HOME/bin/coscli"
    _finish_install coscli "$installed" "$ver"
}

install_rg() {
    local provider=""
    _installer_start || return 1
    provider=$(resolve_provider rg "$TB_OS")
    if [ "$provider" = "brew" ]; then
        install_package_cli rg brew
        return $?
    fi
    TB_STATE=error
    TB_DETAIL=""
    local body latest installed asset tag asset_url checksum_url cktext expected tmp src ver
    body=$(github_release_json BurntSushi/ripgrep) || { TB_DETAIL="cannot determine latest version"; return 1; }
    latest=$(github_version_from_json "$body") || { TB_DETAIL="cannot determine latest version"; return 1; }
    installed=$(get_installed_version rg)
    if [ -n "$installed" ] && [ "$installed" = "$latest" ]; then
        TB_STATE=unchanged
        TB_DETAIL="$installed"
        return 0
    fi
    asset=$(_rg_release_asset "$latest" "$TB_OS" "$TB_ARCH")
    [ -n "$asset" ] || { TB_DETAIL="unsupported platform"; return 1; }
    tag="$latest"
    if ! make_tempdir; then
        TB_DETAIL="cannot create temp directory"
        return 1
    fi
    tmp="$TB_TMPDIR"
    asset_url=$(github_asset_url BurntSushi/ripgrep "$tag" "$asset" "$body")
    checksum_url=$(github_asset_url BurntSushi/ripgrep "$tag" "${asset}.sha256" "$body")
    log_info "rg: downloading ${asset_url}"
    if ! download_file "$checksum_url" "$tmp/checksums.sha256"; then
        TB_DETAIL="download failed (checksums)"
        return 1
    fi
    cktext=$(<"$tmp/checksums.sha256")
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
    src=$(_find_in_archive "$tmp/x" rg "${asset%.tar.gz}")
    [ -n "$src" ] || { TB_DETAIL="binary not found in archive"; return 1; }
    if ! atomic_install "$src" "$CLI_TOOLBOX_HOME/bin/rg"; then
        TB_DETAIL="failed to place binary"
        return 1
    fi
    ver=$(get_installed_version rg)
    manifest_record rg release-binary "$ver" "$CLI_TOOLBOX_HOME/bin/rg"
    _finish_install rg "$installed" "$ver"
}

install_mlr() {
    local provider=""
    _installer_start || return 1
    provider=$(resolve_provider mlr "$TB_OS")
    if [ "$provider" = "brew" ]; then
        install_package_cli mlr brew
        return $?
    fi
    TB_STATE=error
    TB_DETAIL=""
    local body latest installed asset tag asset_url checksum_url cktext expected tmp src ver
    body=$(github_release_json johnkerl/miller) || { TB_DETAIL="cannot determine latest version"; return 1; }
    latest=$(github_version_from_json "$body") || { TB_DETAIL="cannot determine latest version"; return 1; }
    installed=$(get_installed_version mlr)
    if [ -n "$installed" ] && [ "$installed" = "$latest" ]; then
        TB_STATE=unchanged
        TB_DETAIL="$installed"
        return 0
    fi
    asset=$(_mlr_release_asset "$latest" "$TB_OS" "$TB_ARCH")
    [ -n "$asset" ] || { TB_DETAIL="unsupported platform"; return 1; }
    tag="v${latest}"
    if ! make_tempdir; then
        TB_DETAIL="cannot create temp directory"
        return 1
    fi
    tmp="$TB_TMPDIR"
    asset_url=$(github_asset_url johnkerl/miller "$tag" "$asset" "$body")
    checksum_url=$(github_asset_url johnkerl/miller "$tag" "miller-${latest}-checksums.txt" "$body")
    log_info "mlr: downloading ${asset_url}"
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
    src=$(_find_in_archive "$tmp/x" mlr "${asset%.tar.gz}")
    [ -n "$src" ] || { TB_DETAIL="binary not found in archive"; return 1; }
    if ! atomic_install "$src" "$CLI_TOOLBOX_HOME/bin/mlr"; then
        TB_DETAIL="failed to place binary"
        return 1
    fi
    ver=$(get_installed_version mlr)
    manifest_record mlr release-binary "$ver" "$CLI_TOOLBOX_HOME/bin/mlr"
    _finish_install mlr "$installed" "$ver"
}

_kubectl_platform() {
    local os="$1" arch="$2" os_name="" arch_name=""
    case "$os" in
        linux) os_name=linux ;;
        darwin) os_name=darwin ;;
        *) return 1 ;;
    esac
    case "$arch" in
        amd64) arch_name=amd64 ;;
        arm64) arch_name=arm64 ;;
        *) return 1 ;;
    esac
    printf '%s/%s' "$os_name" "$arch_name"
}

_helm_platform_suffix() {
    local os="$1" arch="$2"
    case "$os-$arch" in
        linux-amd64) printf '%s' "linux-amd64" ;;
        linux-arm64) printf '%s' "linux-arm64" ;;
        darwin-amd64) printf '%s' "darwin-amd64" ;;
        darwin-arm64) printf '%s' "darwin-arm64" ;;
        *) return 1 ;;
    esac
}

install_kubectl() {
    TB_STATE=error
    TB_DETAIL=""
    _installer_start || return 1
    local latest installed platform tag asset_url checksum_url tmp expected ver
    latest=$(kubectl_latest_version) || { TB_DETAIL="cannot determine latest version"; return 1; }
    installed=$(get_installed_version kubectl)
    if [ -n "$installed" ] && [ "$installed" = "$latest" ]; then
        TB_STATE=unchanged
        TB_DETAIL="$installed"
        return 0
    fi
    platform=$(_kubectl_platform "$TB_OS" "$TB_ARCH") || { TB_DETAIL="unsupported platform"; return 1; }
    tag="v${latest}"
    asset_url="https://dl.k8s.io/release/${tag}/bin/${platform}/kubectl"
    checksum_url="${asset_url}.sha256"
    if ! make_tempdir; then
        TB_DETAIL="cannot create temp directory"
        return 1
    fi
    tmp="$TB_TMPDIR"
    log_info "kubectl: downloading ${asset_url}"
    if ! download_file "$checksum_url" "$tmp/kubectl.sha256"; then
        TB_DETAIL="download failed (checksum)"
        return 1
    fi
    expected=$(tr -d '[:space:]' <"$tmp/kubectl.sha256")
    if ! download_file "$asset_url" "$tmp/kubectl"; then
        TB_DETAIL="download failed"
        return 1
    fi
    if ! verify_sha256 "$tmp/kubectl" "$expected"; then
        TB_DETAIL="checksum mismatch"
        return 1
    fi
    if ! atomic_install "$tmp/kubectl" "$CLI_TOOLBOX_HOME/bin/kubectl"; then
        TB_DETAIL="failed to place binary"
        return 1
    fi
    ver=$(get_installed_version kubectl)
    manifest_record kubectl release-binary "$ver" "$CLI_TOOLBOX_HOME/bin/kubectl"
    _finish_install kubectl "$installed" "$ver"
}

install_helm() {
    TB_STATE=error
    TB_DETAIL=""
    _installer_start || return 1
    local latest installed suffix asset asset_url checksum_url tmp cktext expected src ver
    latest=$(helm_latest_version) || { TB_DETAIL="cannot determine latest version"; return 1; }
    installed=$(get_installed_version helm)
    if [ -n "$installed" ] && [ "$installed" = "$latest" ]; then
        TB_STATE=unchanged
        TB_DETAIL="$installed"
        return 0
    fi
    suffix=$(_helm_platform_suffix "$TB_OS" "$TB_ARCH") || { TB_DETAIL="unsupported platform"; return 1; }
    asset="helm-v${latest}-${suffix}.tar.gz"
    asset_url="https://get.helm.sh/${asset}"
    checksum_url="${asset_url}.sha256sum"
    if ! make_tempdir; then
        TB_DETAIL="cannot create temp directory"
        return 1
    fi
    tmp="$TB_TMPDIR"
    log_info "helm: downloading ${asset_url}"
    if ! download_file "$checksum_url" "$tmp/checksums.sha256sum"; then
        TB_DETAIL="download failed (checksums)"
        return 1
    fi
    cktext=$(<"$tmp/checksums.sha256sum")
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
    src=$(_find_in_archive "$tmp/x" helm "${suffix}" "${asset%.tar.gz}")
    [ -n "$src" ] || { TB_DETAIL="binary not found in archive"; return 1; }
    if ! atomic_install "$src" "$CLI_TOOLBOX_HOME/bin/helm"; then
        TB_DETAIL="failed to place binary"
        return 1
    fi
    ver=$(get_installed_version helm)
    manifest_record helm release-binary "$ver" "$CLI_TOOLBOX_HOME/bin/helm"
    _finish_install helm "$installed" "$ver"
}

install_oci() {
    local provider=""
    _installer_start || return 1
    provider=$(resolve_provider oci "$TB_OS")
    if [ "$provider" = "brew" ]; then
        install_package_cli oci brew
        return $?
    fi
    TB_STATE=error
    TB_DETAIL=""
    local installed latest url tmp ver path
    installed=$(get_installed_version oci)
    latest=$(official_installer_latest_version oci 2>/dev/null) || latest=""
    if [ -n "$installed" ] && [ -n "$latest" ] && [ "$installed" = "$latest" ]; then
        TB_STATE=unchanged
        TB_DETAIL="$installed"
        path=$(resolve_path oci) || path=""
        [ -n "$path" ] && manifest_record oci official-installer "$installed" "$path"
        return 0
    fi
    url=$(official_installer_url oci)
    if ! make_tempdir; then
        TB_DETAIL="cannot create temp directory"
        return 1
    fi
    tmp="$TB_TMPDIR"
    log_info "oci: downloading installer ${url}"
    if ! download_file "$url" "$tmp/install.sh"; then
        TB_DETAIL="download failed (installer)"
        return 1
    fi
    chmod +x "$tmp/install.sh"
    mkdir -p "$CLI_TOOLBOX_HOME/bin" "$CLI_TOOLBOX_HOME/tools/oci-cli"
    log_info "oci: running official installer (--install-dir ${CLI_TOOLBOX_HOME}/tools/oci-cli --exec-dir ${CLI_TOOLBOX_HOME}/bin)"
    if ! sh "$tmp/install.sh" --accept-all-defaults --no-tty \
        --install-dir "$CLI_TOOLBOX_HOME/tools/oci-cli" \
        --exec-dir "$CLI_TOOLBOX_HOME/bin" >/dev/null 2>&1; then
        TB_DETAIL="official installer failed"
        return 1
    fi
    path="$CLI_TOOLBOX_HOME/bin/oci"
    if [ ! -x "$path" ]; then
        path=$(resolve_path oci) || path=""
    fi
    if [ -z "$path" ]; then
        TB_DETAIL="installed but binary not found on PATH"
        return 1
    fi
    ver=$(_parse_version oci "$path")
    if [ -z "$ver" ]; then
        TB_DETAIL="installed but version check failed"
        return 1
    fi
    manifest_record oci official-installer "$ver" "$path"
    _finish_install oci "$installed" "$ver"
}

# ---------------------------------------------------------------------------
# AI agent / utility CLIs
# ---------------------------------------------------------------------------

_opencode_release_asset() {
    local ver="$1" os="$2" arch="$3"
    case "$os" in
        linux)
            case "$arch" in
                amd64) printf 'opencode-linux-x64.tar.gz' ;;
                arm64) printf 'opencode-linux-arm64.tar.gz' ;;
            esac
            ;;
        darwin)
            case "$arch" in
                amd64) printf 'opencode-darwin-x64.zip' ;;
                arm64) printf 'opencode-darwin-arm64.zip' ;;
            esac
            ;;
    esac
}

_run_official_installer_script() {
    local cli="$1" url="$2"
    shift 2
    TB_STATE=error
    TB_DETAIL=""
    _installer_start || return 1
    local installed="" latest="" ver="" tmp="" path=""
    installed=$(get_installed_version "$cli")
    latest=$(official_installer_latest_version "$cli" 2>/dev/null) || latest=""
    if [ -n "$installed" ] && [ -n "$latest" ] && [ "$installed" = "$latest" ]; then
        TB_STATE=unchanged
        TB_DETAIL="$installed"
        path=$(resolve_path "$cli") || path=""
        [ -n "$path" ] && manifest_record "$cli" official-installer "$installed" "$path"
        return 0
    fi
    if ! make_tempdir; then
        TB_DETAIL="cannot create temp directory"
        return 1
    fi
    tmp="$TB_TMPDIR"
    log_info "${cli}: downloading installer ${url}"
    if ! download_file "$url" "$tmp/install.sh"; then
        TB_DETAIL="download failed (installer)"
        return 1
    fi
    chmod +x "$tmp/install.sh"
    log_info "${cli}: running official installer"
    if [ "$#" -gt 0 ]; then
        if ! sh "$tmp/install.sh" "$@" >/dev/null 2>&1; then
            TB_DETAIL="official installer failed"
            return 1
        fi
    elif ! sh "$tmp/install.sh" >/dev/null 2>&1; then
        TB_DETAIL="official installer failed"
        return 1
    fi
    path=$(resolve_path "$cli") || path=""
    if [ -z "$path" ]; then
        TB_DETAIL="installed but binary not found on PATH"
        return 1
    fi
    ver=$(_parse_version "$cli" "$path")
    if [ -z "$ver" ]; then
        TB_DETAIL="installed but version check failed"
        return 1
    fi
    manifest_record "$cli" official-installer "$ver" "$path"
    _finish_install "$cli" "$installed" "$ver"
}

install_opencode() {
    local provider=""
    _installer_start || return 1
    provider=$(resolve_provider opencode "$TB_OS")
    if [ "$provider" = "brew" ]; then
        install_package_cli opencode brew
        return $?
    fi
    TB_STATE=error
    TB_DETAIL=""
    local body latest installed asset tag asset_url tmp src ver
    body=$(github_release_json anomalyco/opencode) || { TB_DETAIL="cannot determine latest version"; return 1; }
    latest=$(github_version_from_json "$body") || { TB_DETAIL="cannot determine latest version"; return 1; }
    installed=$(get_installed_version opencode)
    if [ -n "$installed" ] && [ "$installed" = "$latest" ]; then
        TB_STATE=unchanged
        TB_DETAIL="$installed"
        return 0
    fi
    asset=$(_opencode_release_asset "$latest" "$TB_OS" "$TB_ARCH")
    [ -n "$asset" ] || { TB_DETAIL="unsupported platform"; return 1; }
    tag="v${latest}"
    if ! make_tempdir; then
        TB_DETAIL="cannot create temp directory"
        return 1
    fi
    tmp="$TB_TMPDIR"
    asset_url=$(github_asset_url anomalyco/opencode "$tag" "$asset" "$body")
    log_warn "opencode: no standalone checksum file published; skipping checksum verification"
    log_info "opencode: downloading ${asset_url}"
    if ! download_file "$asset_url" "$tmp/$asset"; then
        TB_DETAIL="download failed"
        return 1
    fi
    case "$asset" in
        *.zip)
            if ! extract_archive "$tmp/$asset" "$tmp/x"; then
                TB_DETAIL="extraction failed"
                return 1
            fi
            ;;
        *)
            if ! extract_archive "$tmp/$asset" "$tmp/x"; then
                TB_DETAIL="extraction failed"
                return 1
            fi
            ;;
    esac
    src=$(_find_in_archive "$tmp/x" opencode "${asset%.tar.gz}" "${asset%.zip}")
    [ -n "$src" ] || { TB_DETAIL="binary not found in archive"; return 1; }
    if ! atomic_install "$src" "$CLI_TOOLBOX_HOME/bin/opencode"; then
        TB_DETAIL="failed to place binary"
        return 1
    fi
    ver=$(get_installed_version opencode)
    manifest_record opencode release-binary "$ver" "$CLI_TOOLBOX_HOME/bin/opencode"
    _finish_install opencode "$installed" "$ver"
}

install_agent() {
    local url=""
    url=$(official_installer_url agent)
    log_warn "agent: official installer does not publish checksums; skipping checksum verification"
    _run_official_installer_script agent "$url"
}

install_claude() {
    local url=""
    url=$(official_installer_url claude)
    _run_official_installer_script claude "$url" stable
}

install_codex() {
    local cli="codex" url="" installed="" latest="" ver="" tmp="" path=""
    url=$(official_installer_url codex)
    TB_STATE=error
    TB_DETAIL=""
    _installer_start || return 1
    installed=$(get_installed_version codex)
    latest=$(official_installer_latest_version codex 2>/dev/null) || latest=""
    if [ -n "$installed" ] && [ -n "$latest" ] && [ "$installed" = "$latest" ]; then
        TB_STATE=unchanged
        TB_DETAIL="$installed"
        path=$(resolve_path codex) || path=""
        [ -n "$path" ] && manifest_record codex official-installer "$installed" "$path"
        return 0
    fi
    if ! make_tempdir; then
        TB_DETAIL="cannot create temp directory"
        return 1
    fi
    tmp="$TB_TMPDIR"
    log_info "codex: downloading installer ${url}"
    if ! download_file "$url" "$tmp/install.sh"; then
        TB_DETAIL="download failed (installer)"
        return 1
    fi
    chmod +x "$tmp/install.sh"
    log_info "codex: running official installer"
    if ! env CODEX_INSTALL_DIR="$CLI_TOOLBOX_HOME/bin" CODEX_NON_INTERACTIVE=true \
        sh "$tmp/install.sh" >/dev/null 2>&1; then
        TB_DETAIL="official installer failed"
        return 1
    fi
    path=$(resolve_path codex) || path=""
    if [ -z "$path" ]; then
        TB_DETAIL="installed but binary not found on PATH"
        return 1
    fi
    ver=$(_parse_version codex "$path")
    if [ -z "$ver" ]; then
        TB_DETAIL="installed but version check failed"
        return 1
    fi
    manifest_record codex official-installer "$ver" "$path"
    _finish_install codex "$installed" "$ver"
}

install_agy() {
    local url=""
    url=$(official_installer_url agy)
    _run_official_installer_script agy "$url" --dir "$CLI_TOOLBOX_HOME/bin"
}

install_codebuddy() {
    local provider="" url=""
    _installer_start || return 1
    provider=$(resolve_provider codebuddy "$TB_OS")
    if [ "$provider" = "brew" ]; then
        install_package_cli codebuddy brew
        return $?
    fi
    if [ "$provider" = "unknown" ]; then
        TB_STATE=error
        TB_DETAIL="unsupported platform for codebuddy"
        return 1
    fi
    url=$(official_installer_url codebuddy)
    _run_official_installer_script codebuddy "$url"
}

_delete_manifest_binary() {
    local cli="$1" info="" path=""
    TB_STATE=error
    TB_DETAIL=""
    if ! manifest_lookup "$cli" >/dev/null 2>&1; then
        TB_STATE=skipped-not-managed
        TB_DETAIL="not managed by cli-toolbox"
        return 0
    fi
    info=$(manifest_lookup "$cli")
    path=${info#*$'\t'}
    path=${path#*$'\t'}
    if [ -e "$path" ] || [ -L "$path" ]; then
        rm -f "$path"
    fi
    _remove_bin_link "$cli"
    manifest_remove "$cli"
    TB_STATE=deleted
    TB_DETAIL="removed managed binary"
    return 0
}

# ---------------------------------------------------------------------------
# aws — official installer (Linux) or brew (macOS)
# ---------------------------------------------------------------------------

install_aws() {
    local provider=""
    _installer_start || return 1
    provider=$(resolve_provider aws "$TB_OS")
    if [ "$provider" = "brew" ]; then
        install_package_cli aws brew
        return $?
    fi
    TB_STATE=error
    TB_DETAIL=""
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
    log_info "aws: running official installer (--install-dir ${CLI_TOOLBOX_HOME}/tools/aws-cli --bin-dir ${CLI_TOOLBOX_HOME}/bin --update)"
    if ! "$tmp/x/aws/install" \
        --install-dir "$CLI_TOOLBOX_HOME/tools/aws-cli" \
        --bin-dir "$CLI_TOOLBOX_HOME/bin" \
        --update >/dev/null 2>&1; then
        TB_DETAIL="aws installer failed"
        return 1
    fi
    ver=$(get_installed_version aws)
    manifest_record aws official-installer "$ver" "$CLI_TOOLBOX_HOME/bin/aws"
    _finish_install aws "$installed" "$ver"
}

# ---------------------------------------------------------------------------
# delete — remove cli-toolbox managed artifacts only (never system apt/brew)
# ---------------------------------------------------------------------------

_remove_bin_link() {
    local name="$1"
    local path="$CLI_TOOLBOX_HOME/bin/$name"
    [ -e "$path" ] || [ -L "$path" ] || return 0
    rm -f "$path"
}

_delete_uv() {
    TB_STATE=error
    TB_DETAIL=""
    if ! cli_is_toolbox_managed uv; then
        TB_STATE=skipped-not-managed
        TB_DETAIL="not managed by cli-toolbox"
        return 0
    fi
    _remove_bin_link uv
    _remove_bin_link uvx
    manifest_remove uv
    TB_STATE=deleted
    TB_DETAIL="removed from ${CLI_TOOLBOX_HOME}/bin"
    return 0
}

_delete_tccli() {
    local uv="" tool_bin="" exe=""
    TB_STATE=error
    TB_DETAIL=""
    if ! cli_is_toolbox_managed tccli; then
        TB_STATE=skipped-not-managed
        TB_DETAIL="not managed by cli-toolbox"
        return 0
    fi
    tool_bin=$(uv_tool_bin_dir)
    if uv=$(uv_bin); then
        UV_TOOL_BIN_DIR="$tool_bin" "$uv" tool uninstall tccli >/dev/null 2>&1 || true
    fi
    exe="$tool_bin/tccli"
    if [ -e "$exe" ] || [ -L "$exe" ]; then
        rm -f "$exe"
    fi
    manifest_remove tccli
    TB_STATE=deleted
    TB_DETAIL="removed uv-tool install"
    return 0
}

_delete_gcloud() {
    TB_STATE=error
    TB_DETAIL=""
    if ! cli_is_toolbox_managed gcloud; then
        TB_STATE=skipped-not-managed
        TB_DETAIL="not managed by cli-toolbox"
        return 0
    fi
    _remove_bin_link gcloud
    rm -rf "$(gcloud_sdk_root)"
    manifest_remove gcloud
    TB_STATE=deleted
    TB_DETAIL="removed archive install"
    return 0
}

_delete_oci() {
    local provider=""
    TB_STATE=error
    TB_DETAIL=""
    if ! cli_is_toolbox_managed oci; then
        TB_STATE=skipped-not-managed
        TB_DETAIL="not managed by cli-toolbox"
        return 0
    fi
    provider=$(manifest_lookup oci 2>/dev/null | awk -F '\t' '{print $2}')
    if [ -z "$provider" ]; then
        provider=$(resolve_provider oci "${TB_OS:-linux}")
    fi
    if [ "$provider" = "brew" ]; then
        _delete_package_cli oci
        return $?
    fi
    rm -f "$CLI_TOOLBOX_HOME/bin/oci"
    rm -rf "$CLI_TOOLBOX_HOME/tools/oci-cli"
    manifest_remove oci
    TB_STATE=deleted
    TB_DETAIL="removed oci-cli"
    return 0
}

_delete_aws() {
    TB_STATE=error
    TB_DETAIL=""
    if ! cli_is_toolbox_managed aws; then
        TB_STATE=skipped-not-managed
        TB_DETAIL="not managed by cli-toolbox"
        return 0
    fi
    _remove_bin_link aws
    rm -rf "$CLI_TOOLBOX_HOME/tools/aws-cli"
    manifest_remove aws
    TB_STATE=deleted
    TB_DETAIL="removed official installer tree"
    return 0
}

_delete_release_binary() {
    local cli="$1"
    TB_STATE=error
    TB_DETAIL=""
    if ! cli_is_toolbox_managed "$cli"; then
        TB_STATE=skipped-not-managed
        TB_DETAIL="not managed by cli-toolbox"
        return 0
    fi
    _remove_bin_link "$cli"
    manifest_remove "$cli"
    TB_STATE=deleted
    TB_DETAIL="removed from ${CLI_TOOLBOX_HOME}/bin"
    return 0
}

_delete_package_cli() {
    local cli="$1" provider="" pkg=""
    TB_STATE=error
    TB_DETAIL=""
    detect_platform 2>/dev/null || true
    provider=$(resolve_provider "$cli" "${TB_OS:-linux}")
    if ! manifest_lookup "$cli" >/dev/null 2>&1; then
        TB_STATE=skipped-not-managed
        TB_DETAIL="not managed by cli-toolbox"
        return 0
    fi
    pkg=$(cli_package_name "$cli" "$provider")
    manifest_remove "$cli"
    case "$provider" in
        apt)
            TB_STATE=skipped-system
            TB_DETAIL="manifest cleared; remove system package with: sudo apt remove ${pkg}"
            ;;
        brew)
            TB_STATE=skipped-system
            TB_DETAIL="manifest cleared; remove with: brew uninstall ${pkg}"
            ;;
        *)
            TB_STATE=deleted
            TB_DETAIL="manifest cleared"
            ;;
    esac
    return 0
}

run_uninstaller() {
    local name="$1" provider=""
    detect_platform 2>/dev/null || true
    case "$name" in
        uv) _delete_uv ;;
        tccli) _delete_tccli ;;
        gh | az | terraform) _delete_package_cli "$name" ;;
        gcloud) _delete_gcloud ;;
        glow | rg | mlr | opencode)
            provider=$(resolve_provider "$name" "${TB_OS:-linux}")
            if [ "$provider" = "brew" ]; then
                _delete_package_cli "$name"
            else
                _delete_release_binary "$name"
            fi
            ;;
        coscli | kubectl | helm) _delete_release_binary "$name" ;;
        oci) _delete_oci ;;
        agent | claude | codex | agy) _delete_manifest_binary "$name" ;;
        codebuddy)
            provider=$(resolve_provider codebuddy "${TB_OS:-linux}")
            if [ "$provider" = "brew" ]; then
                _delete_package_cli codebuddy
            else
                _delete_manifest_binary codebuddy
            fi
            ;;
        aws)
            provider=$(resolve_provider aws "${TB_OS:-linux}")
            if [ "$provider" = "brew" ]; then
                _delete_package_cli aws
            else
                _delete_aws
            fi
            ;;
        *) TB_STATE=error; TB_DETAIL="no uninstaller for ${name}"; return 1 ;;
    esac
    case "${TB_STATE:-error}" in
        error) return 1 ;;
    esac
    return 0
}

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
        terraform) install_terraform ;;
        glow) install_glow ;;
        coscli) install_coscli ;;
        rg) install_rg ;;
        mlr) install_mlr ;;
        kubectl) install_kubectl ;;
        helm) install_helm ;;
        oci) install_oci ;;
        opencode) install_opencode ;;
        agent) install_agent ;;
        codebuddy) install_codebuddy ;;
        claude) install_claude ;;
        codex) install_codex ;;
        agy) install_agy ;;
        aws) install_aws ;;
        *) TB_STATE=error; TB_DETAIL="no installer for ${name}" ;;
    esac
    case "${TB_STATE:-error}" in
        error) return 1 ;;
    esac
    return 0
}
