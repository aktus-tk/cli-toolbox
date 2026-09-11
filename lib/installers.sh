# shellcheck shell=bash
# lib/installers.sh — per-CLI installers for cli-toolbox
#
# Each install_<cli> function:
#   1. detect_platform
#   2. determine latest stable version
#   3. compare with installed version (unchanged short-circuit)
#   4. download to a mktemp dir, verify checksum (when published)
#   5. extract / place atomically (old binary kept on any failure)
#   6. re-read the version to confirm
#
# On return, TB_STATE is one of installed|updated|unchanged|error and
# TB_DETAIL holds the human-readable detail. run_installer sets these globals
# and returns non-zero on error; the caller formats the result line. Installers
# run in the caller's shell (never inside $(...)) so temp-dir cleanup works.

# ---------------------------------------------------------------------------
# standard set and support lists
# ---------------------------------------------------------------------------

# Standard set: installed when `cli-toolbox install` runs with no arguments.
# (Referenced by the cli-toolbox entrypoint after sourcing this file.)
# shellcheck disable=SC2034
STANDARD_SET=(gh glow coscli uv tccli pipx aws gcloud)

# Every CLI that has an installer.
SUPPORTED_CLIS=(gh glow coscli uv tccli pipx aws gcloud)

# Recognized but intentionally unsupported (reported, never installed).
UNSUPPORTED_CLIS=(az awst gcloudt tcclit)

is_supported() {
    local name="$1" c
    for c in "${SUPPORTED_CLIS[@]}"; do
        [ "$c" = "$name" ] && return 0
    done
    return 1
}

is_known_cli() {
    local name="$1" c
    for c in "${SUPPORTED_CLIS[@]}" "${UNSUPPORTED_CLIS[@]}"; do
        [ "$c" = "$name" ] && return 0
    done
    return 1
}

unsupported_reason() {
    case "$1" in
        az)
            printf '%s' "no self-contained non-root binary (pipx/venv only, ~1GB, tarball needs Python 3.14)"
            ;;
        awst | gcloudt | tcclit)
            printf '%s' "no release binaries in cloud-cli (bash wrappers requiring native CLIs + tc-assume)"
            ;;
        *)
            printf '%s' "unknown CLI"
            ;;
    esac
}

# ---------------------------------------------------------------------------
# per-CLI version parsing
# ---------------------------------------------------------------------------

# _parse_version <cli> <path>: run the binary at path and extract the version.
_parse_version() {
    local cli="$1" path="$2" out=""
    case "$cli" in
        gh)
            out=$("$path" --version 2>/dev/null | sed -n 's/.*gh version \([0-9][^ ]*\).*/\1/p' | head -1)
            ;;
        glow)
            out=$("$path" --version 2>/dev/null | sed -n 's/.*glow version \([0-9][^ ]*\).*/\1/p' | head -1)
            # Non-release builds print e.g. "glow version unknown (built from
            # source)"; surface that instead of showing an empty version.
            if [ -z "$out" ]; then
                out=$("$path" --version 2>/dev/null | grep -i 'glow version' | head -1 \
                    | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' \
                    | sed 's/^glow[[:space:]][[:space:]]*version[[:space:]][[:space:]]*//')
            fi
            ;;
        coscli)
            out=$("$path" --version 2>/dev/null | sed -n 's/.*coscli version v\?\([0-9][^ ]*\).*/\1/p' | head -1)
            ;;
        uv)
            out=$("$path" --version 2>/dev/null | sed -n 's/.*uv \([0-9][^ ]*\).*/\1/p' | head -1)
            ;;
        tccli | pipx)
            out=$("$path" --version 2>/dev/null | head -1 | tr -d '[:space:]')
            ;;
        aws)
            out=$("$path" --version 2>&1 | sed -n 's/.*aws-cli\/\([0-9][^ ]*\).*/\1/p' | head -1)
            ;;
        gcloud)
            out=$("$path" version 2>/dev/null | sed -n 's/.*Google Cloud SDK \([0-9][^ ]*\).*/\1/p' | head -1)
            ;;
    esac
    out=$(normalize_version "$out")
    printf '%s\n' "$out"
}

# get_installed_version <cli>: version of the CLI managed by the toolbox
# (reads $CLOUD_TOOLBOX_HOME/bin/<cli>); empty when not managed.
get_installed_version() {
    local cli="$1"
    if [ ! -e "$CLOUD_TOOLBOX_HOME/bin/$cli" ] && [ ! -L "$CLOUD_TOOLBOX_HOME/bin/$cli" ]; then
        return 0
    fi
    _parse_version "$cli" "$CLOUD_TOOLBOX_HOME/bin/$cli"
}

# ---------------------------------------------------------------------------
# shared scaffolding
# ---------------------------------------------------------------------------

# _installer_start: platform checks; sets TB_STATE/TB_DETAIL on failure.
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

# _find_in_archive <extract_dir> <binary> [version_dir...]: locate a binary
# inside an extracted archive. Tries, in order: the archive root, each given
# version-named top dir, then a shallow scoped find (maxdepth 3, regular
# files only). Echoes the first match path (empty if none).
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

# _uv_bin_dir <extract_dir> <target_dir>: echo the single directory that
# contains BOTH uv and uvx (they must come from the same tree). Tries
# $root/<target>/, $root/, then locates uv via a shallow find and uses its
# dirname. Echoes empty when either binary is missing.
_uv_bin_dir() {
    local root="$1" target="$2" uv_path
    if [ -f "$root/$target/uv" ] && [ -f "$root/$target/uvx" ]; then
        printf '%s\n' "$root/$target"
        return 0
    fi
    if [ -f "$root/uv" ] && [ -f "$root/uvx" ]; then
        printf '%s\n' "$root"
        return 0
    fi
    uv_path=$(find "$root" -maxdepth 3 -type f -name uv 2>/dev/null | head -1)
    if [ -n "$uv_path" ] && [ -f "$(dirname "$uv_path")/uvx" ]; then
        printf '%s\n' "$(dirname "$uv_path")"
        return 0
    fi
    return 1
}

# _finish_install <cli> <installed_before> <ver>: set TB_STATE/TB_DETAIL after
# a successful placement.
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

# ---------------------------------------------------------------------------
# gh (GitHub CLI) — repo cli/cli
# ---------------------------------------------------------------------------

install_gh() {
    TB_STATE=error
    TB_DETAIL=""
    _installer_start || return 1
    local body latest installed
    body=$(github_release_json cli/cli) || { TB_DETAIL="cannot determine latest version"; return 1; }
    latest=$(github_version_from_json "$body") || { TB_DETAIL="cannot determine latest version"; return 1; }
    installed=$(get_installed_version gh)
    if [ -n "$installed" ] && [ "$installed" = "$latest" ]; then
        TB_STATE=unchanged
        TB_DETAIL="$installed"
        return 0
    fi
    local tmp asset tag asset_url checksum_url cktext expected src ver
    if ! make_tempdir; then
        TB_DETAIL="cannot create temp directory"
        return 1
    fi
    tmp="$TB_TMPDIR"
    asset="gh_${latest}_linux_${TB_ARCH}.tar.gz"
    tag="v${latest}"
    asset_url=$(github_asset_url cli/cli "$tag" "$asset" "$body")
    checksum_url=$(github_asset_url cli/cli "$tag" "gh_${latest}_checksums.txt" "$body")
    log_info "gh: downloading ${asset_url}"
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
    src="$tmp/x/gh_${latest}_linux_${TB_ARCH}/bin/gh"
    [ -f "$src" ] || { TB_DETAIL="binary not found in archive"; return 1; }
    if ! atomic_install "$src" "$CLOUD_TOOLBOX_HOME/bin/gh"; then
        TB_DETAIL="failed to place binary"
        return 1
    fi
    ver=$(get_installed_version gh)
    _finish_install gh "$installed" "$ver"
}

# ---------------------------------------------------------------------------
# glow — repo charmbracelet/glow
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
    # Real releases nest the binary in a version-named top dir
    # (glow_<V>_Linux_<arch>/glow); some archives keep it at the root.
    src=$(_find_in_archive "$tmp/x" glow "glow_${latest}_Linux_${arch}")
    [ -n "$src" ] || { TB_DETAIL="binary not found in archive"; return 1; }
    if ! atomic_install "$src" "$CLOUD_TOOLBOX_HOME/bin/glow"; then
        TB_DETAIL="failed to place binary"
        return 1
    fi
    ver=$(get_installed_version glow)
    _finish_install glow "$installed" "$ver"
}

# ---------------------------------------------------------------------------
# coscli — repo tencentyun/coscli (raw binary, no archive)
# ---------------------------------------------------------------------------

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
    _finish_install coscli "$installed" "$ver"
}

# ---------------------------------------------------------------------------
# uv — repo astral-sh/uv (tag has no v prefix; ships uv and uvx)
# ---------------------------------------------------------------------------

install_uv() {
    TB_STATE=error
    TB_DETAIL=""
    _installer_start || return 1
    local body latest installed
    body=$(github_release_json astral-sh/uv) || { TB_DETAIL="cannot determine latest version"; return 1; }
    latest=$(github_version_from_json "$body") || { TB_DETAIL="cannot determine latest version"; return 1; }
    installed=$(get_installed_version uv)
    if [ -n "$installed" ] && [ "$installed" = "$latest" ]; then
        TB_STATE=unchanged
        TB_DETAIL="$installed"
        return 0
    fi
    local plat asset tmp asset_url checksum_url cktext expected ver
    case "$TB_ARCH" in
        amd64) plat="x86_64-unknown-linux-gnu" ;;
        arm64) plat="aarch64-unknown-linux-gnu" ;;
    esac
    if ! make_tempdir; then
        TB_DETAIL="cannot create temp directory"
        return 1
    fi
    tmp="$TB_TMPDIR"
    asset="uv-${plat}.tar.gz"
    asset_url=$(github_asset_url astral-sh/uv "$latest" "$asset" "$body")
    checksum_url=$(github_asset_url astral-sh/uv "$latest" "${asset}.sha256" "$body")
    log_info "uv: downloading ${asset_url}"
    if ! download_file "$checksum_url" "$tmp/${asset}.sha256"; then
        TB_DETAIL="download failed (checksums)"
        return 1
    fi
    cktext=$(<"$tmp/${asset}.sha256")
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
    # Real releases nest uv+uvx in a target-named top dir
    # (uv-x86_64-unknown-linux-gnu/uv and .../uvx); some archives keep them at
    # the root. Both must come from the SAME directory.
    local uvdir
    uvdir=$(_uv_bin_dir "$tmp/x" "uv-${plat}")
    if [ -z "$uvdir" ]; then
        TB_DETAIL="uv/uvx not found in archive"
        return 1
    fi
    if ! atomic_install "$uvdir/uv" "$CLOUD_TOOLBOX_HOME/bin/uv" \
        || ! atomic_install "$uvdir/uvx" "$CLOUD_TOOLBOX_HOME/bin/uvx"; then
        TB_DETAIL="failed to place binary"
        return 1
    fi
    ver=$(get_installed_version uv)
    _finish_install uv "$installed" "$ver"
}

# ---------------------------------------------------------------------------
# Python packages (tccli, pipx) — PyPI wheel into a per-CLI venv
# ---------------------------------------------------------------------------

# python_install_wheel <name> <wheel_url> <wheel_sha> <tmpdir>
python_install_wheel() {
    local name="$1" url="$2" sha="$3" tmp="$4"
    local venv="$CLOUD_TOOLBOX_HOME/python/$name"
    if [ ! -x "$venv/bin/python" ]; then
        if ! python3 -m venv "$venv" >/dev/null 2>&1; then
            TB_DETAIL="failed to create venv for ${name}"
            return 1
        fi
    fi
    # pip validates the wheel filename, so keep the original name from the URL.
    local wheel
    wheel="$tmp/$(basename "$url")"
    if ! download_file "$url" "$wheel"; then
        TB_DETAIL="download failed (wheel)"
        return 1
    fi
    if ! verify_sha256 "$wheel" "$sha"; then
        TB_DETAIL="checksum mismatch (wheel)"
        return 1
    fi
    # The primary wheel's sha256 was verified above; dependencies are resolved
    # from PyPI (they are not individually checksum-verified).
    if ! "$venv/bin/python" -m pip install --upgrade "$wheel" >/dev/null 2>&1; then
        TB_DETAIL="pip install failed for ${name}"
        return 1
    fi
    if [ -x "$venv/bin/$name" ]; then
        if ! atomic_symlink "$venv/bin/$name" "$CLOUD_TOOLBOX_HOME/bin/$name"; then
            TB_DETAIL="failed to link ${name}"
            return 1
        fi
    else
        TB_DETAIL="console script ${name} not found in venv"
        return 1
    fi
    return 0
}

install_tccli() {
    TB_STATE=error
    TB_DETAIL=""
    _installer_start || return 1
    if ! cmd_exists python3; then
        TB_DETAIL="python3 not found (required for tccli)"
        return 1
    fi
    local body latest installed
    body=$(http_get "${CLOUD_TOOLBOX_PYPI_BASE:-https://pypi.org}/pypi/tccli/json") || {
        TB_DETAIL="cannot fetch PyPI metadata"
        return 1
    }
    latest=$(pypi_version_from_body "$body") || { TB_DETAIL="cannot determine latest version"; return 1; }
    installed=$(get_installed_version tccli)
    if [ -n "$installed" ] && [ "$installed" = "$latest" ]; then
        TB_STATE=unchanged
        TB_DETAIL="$installed"
        return 0
    fi
    local wheel_info wheel_url wheel_sha tmp ver
    wheel_info=$(pypi_wheel_info "$body" tccli "$latest") || {
        TB_DETAIL="wheel not found for tccli ${latest}"
        return 1
    }
    wheel_url=$(printf '%s\n' "$wheel_info" | cut -f1)
    wheel_sha=$(printf '%s\n' "$wheel_info" | cut -f2)
    if ! make_tempdir; then
        TB_DETAIL="cannot create temp directory"
        return 1
    fi
    tmp="$TB_TMPDIR"
    log_info "tccli: installing wheel ${wheel_url}"
    if ! python_install_wheel tccli "$wheel_url" "$wheel_sha" "$tmp"; then
        return 1
    fi
    ver=$(get_installed_version tccli)
    _finish_install tccli "$installed" "$ver"
}

install_pipx() {
    TB_STATE=error
    TB_DETAIL=""
    _installer_start || return 1
    if ! cmd_exists python3; then
        TB_DETAIL="python3 not found (required for pipx)"
        return 1
    fi
    if ! python3 -c 'import sys; raise SystemExit(0 if sys.version_info >= (3, 10) else 1)' 2>/dev/null; then
        TB_DETAIL="pipx requires Python >= 3.10 (found $(python3 --version 2>&1 | head -1))"
        return 1
    fi
    local body latest installed
    body=$(http_get "${CLOUD_TOOLBOX_PYPI_BASE:-https://pypi.org}/pypi/pipx/json") || {
        TB_DETAIL="cannot fetch PyPI metadata"
        return 1
    }
    latest=$(pypi_version_from_body "$body") || { TB_DETAIL="cannot determine latest version"; return 1; }
    installed=$(get_installed_version pipx)
    if [ -n "$installed" ] && [ "$installed" = "$latest" ]; then
        TB_STATE=unchanged
        TB_DETAIL="$installed"
        return 0
    fi
    local wheel_info wheel_url wheel_sha tmp ver
    wheel_info=$(pypi_wheel_info "$body" pipx "$latest") || {
        TB_DETAIL="wheel not found for pipx ${latest}"
        return 1
    }
    wheel_url=$(printf '%s\n' "$wheel_info" | cut -f1)
    wheel_sha=$(printf '%s\n' "$wheel_info" | cut -f2)
    if ! make_tempdir; then
        TB_DETAIL="cannot create temp directory"
        return 1
    fi
    tmp="$TB_TMPDIR"
    log_info "pipx: installing wheel ${wheel_url}"
    if ! python_install_wheel pipx "$wheel_url" "$wheel_sha" "$tmp"; then
        return 1
    fi
    ver=$(get_installed_version pipx)
    _finish_install pipx "$installed" "$ver"
}

# ---------------------------------------------------------------------------
# aws (AWS CLI v2) — official user-space installer zip
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
    _finish_install aws "$installed" "$ver"
}

# ---------------------------------------------------------------------------
# gcloud (Google Cloud CLI) — official tarball into tools/
# ---------------------------------------------------------------------------

install_gcloud() {
    TB_STATE=error
    TB_DETAIL=""
    _installer_start || return 1
    local body latest
    body=$(http_get "https://dl.google.com/dl/cloudsdk/channels/rapid/components-2.json") || {
        TB_DETAIL="cannot determine latest version"
        return 1
    }
    latest=$(printf '%s\n' "$body" \
        | grep -o '"version"[[:space:]]*:[[:space:]]*"[0-9][^"]*"' \
        | head -1 \
        | sed 's/.*"version"[[:space:]]*:[[:space:]]*"\([0-9][^"]*\)".*/\1/')
    if [ -z "$latest" ]; then
        TB_DETAIL="cannot determine latest version"
        return 1
    fi
    log_warn "gcloud: no machine-readable checksum published (docs table only); skipping checksum verification"
    local installed
    installed=$(get_installed_version gcloud)
    if [ -n "$installed" ] && [ "$installed" = "$latest" ]; then
        TB_STATE=unchanged
        TB_DETAIL="$installed"
        return 0
    fi
    local arch tarball url tmp sdk_dir old_sdk ver
    case "$TB_ARCH" in
        amd64) arch=x86_64 ;;
        arm64) arch=arm ;;
    esac
    tarball="google-cloud-cli-${latest}-linux-${arch}.tar.gz"
    url="https://dl.google.com/dl/cloudsdk/channels/rapid/downloads/${tarball}"
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
    mkdir -p "$CLOUD_TOOLBOX_HOME/tools" || { TB_DETAIL="cannot create tools directory"; return 1; }
    sdk_dir="$CLOUD_TOOLBOX_HOME/tools/google-cloud-sdk"
    old_sdk=""
    if [ -d "$sdk_dir" ] || [ -L "$sdk_dir" ]; then
        old_sdk="${sdk_dir}.old.$$"
        if ! mv "$sdk_dir" "$old_sdk"; then
            TB_DETAIL="cannot move existing SDK aside"
            return 1
        fi
    fi
    if ! mv "$tmp/x/google-cloud-sdk" "$sdk_dir"; then
        if [ -n "$old_sdk" ] && [ -d "$old_sdk" ]; then
            mv "$old_sdk" "$sdk_dir" 2>/dev/null
        fi
        TB_DETAIL="cannot place new SDK into tools"
        return 1
    fi
    # Create/verify the new symlink BEFORE removing the old SDK, so a symlink
    # failure never leaves the tool broken (restore the old SDK in that case).
    if ! atomic_symlink "$sdk_dir/bin/gcloud" "$CLOUD_TOOLBOX_HOME/bin/gcloud"; then
        TB_DETAIL="failed to create gcloud symlink"
        if [ -n "$old_sdk" ] && [ -d "$old_sdk" ]; then
            rm -rf "$sdk_dir"
            mv "$old_sdk" "$sdk_dir" 2>/dev/null
        fi
        return 1
    fi
    [ -n "$old_sdk" ] && rm -rf "$old_sdk"
    ver=$(get_installed_version gcloud)
    _finish_install gcloud "$installed" "$ver"
}

# ---------------------------------------------------------------------------
# dispatch
# ---------------------------------------------------------------------------

# run_installer <name>: dispatch to the matching installer. Runs in the
# CURRENT shell (never a command substitution) so make_tempdir's cleanup
# registry stays in this process and the EXIT trap removes temp dirs.
# Sets globals TB_STATE (installed|updated|unchanged|error) and TB_DETAIL;
# returns 0 on success, non-zero on error. The caller formats the output.
run_installer() {
    local name="$1"
    case "$name" in
        gh) install_gh ;;
        glow) install_glow ;;
        coscli) install_coscli ;;
        uv) install_uv ;;
        tccli) install_tccli ;;
        pipx) install_pipx ;;
        aws) install_aws ;;
        gcloud) install_gcloud ;;
        *) TB_STATE=error; TB_DETAIL="no installer for ${name}" ;;
    esac
    case "${TB_STATE:-error}" in
        error) return 1 ;;
    esac
    return 0
}