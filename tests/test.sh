#!/usr/bin/env bash
# tests/test.sh — offline test suite for cli-toolbox
set -u

TESTDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TBROOT="$(dirname "$TESTDIR")"

PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); printf 'PASS: %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL: %s\n' "$1"; }

__TEST_REG=$(mktemp)
test_tmp() { local d; d=$(mktemp -d) || return 1; printf '%s\n' "$d" >>"$__TEST_REG"; printf '%s\n' "$d"; }
test_file() { local f; f=$(mktemp) || return 1; printf '%s\n' "$f" >>"$__TEST_REG"; printf '%s\n' "$f"; }
test_cleanup() {
    local p
    [ -f "$__TEST_REG" ] && while IFS= read -r p; do [ -n "$p" ] && rm -rf -- "$p"; done <"$__TEST_REG"
    rm -f -- "$__TEST_REG"
}
trap test_cleanup EXIT INT TERM

source_libs() {
    export TB_ROOT="${TB_ROOT:-$TBROOT}"
    # shellcheck source=lib/common.sh
    . "$TBROOT/lib/common.sh"
    # shellcheck source=lib/packages.sh
    . "$TBROOT/lib/packages.sh"
    # shellcheck source=lib/providers.sh
    . "$TBROOT/lib/providers.sh"
    # shellcheck source=lib/targets.sh
    . "$TBROOT/lib/targets.sh"
    # shellcheck source=lib/installers.sh
    . "$TBROOT/lib/installers.sh"
}

cli() {
    local out="$1"
    shift
    "$TBROOT/cli-toolbox.sh" "$@" >"$out" 2>&1
    CLI_RC=$?
}

assert_contains() {
    local desc="$1" hay="$2" needle="$3"
    if printf '%s' "$hay" | grep -qF -- "$needle"; then pass "$desc"; else fail "$desc (missing: $needle)"; fi
}
assert_contains_re() {
    local desc="$1" hay="$2" regex="$3"
    if printf '%s' "$hay" | grep -qE -- "$regex"; then pass "$desc"; else fail "$desc (regex: $regex)"; fi
}
assert_not_contains() {
    local desc="$1" hay="$2" needle="$3"
    if printf '%s' "$hay" | grep -qF -- "$needle"; then fail "$desc (forbidden: $needle)"; else pass "$desc"; fi
}
assert_true() { local desc="$1"; shift; if "$@" >/dev/null 2>&1; then pass "$desc"; else fail "$desc"; fi }

make_bin() {
    local path="$1"
    shift
    mkdir -p "$(dirname "$path")"
    printf '#!/bin/sh\n%s\n' "$*" >"$path"
    chmod +x "$path"
}

make_tarball() {
    local srcdir="$1" tarball="$2"
    shift 2
    tar -C "$srcdir" -czf "$tarball" "$@"
}

# ---------------------------------------------------------------------------
# fixtures
# ---------------------------------------------------------------------------

make_glow_fixture() {
    local base="$1" ver="$2" root
    root="$base/assets/root"
    mkdir -p "$root/glow_${ver}_Linux_x86_64"
    make_bin "$root/glow_${ver}_Linux_x86_64/glow" "echo \"glow version ${ver} (abc)\""
    make_tarball "$root" "$base/assets/glow_${ver}_Linux_x86_64.tar.gz" "glow_${ver}_Linux_x86_64"
    local hash
    hash=$(sha256sum "$base/assets/glow_${ver}_Linux_x86_64.tar.gz" | awk '{print $1}')
    printf '%s  %s\n' "$hash" "glow_${ver}_Linux_x86_64.tar.gz" >"$base/assets/checksums.txt"
    mkdir -p "$base/api/repos/charmbracelet/glow/releases"
    cat >"$base/api/repos/charmbracelet/glow/releases/latest" <<EOF
{"tag_name": "v${ver}", "assets": [
 {"name": "glow_${ver}_Linux_x86_64.tar.gz", "browser_download_url": "file://$base/assets/glow_${ver}_Linux_x86_64.tar.gz"},
 {"name": "checksums.txt", "browser_download_url": "file://$base/assets/checksums.txt"}]}
EOF
}

make_rg_fixture() {
    local base="$1" ver="$2" root asset dir
    asset="ripgrep-${ver}-x86_64-unknown-linux-musl.tar.gz"
    dir="ripgrep-${ver}-x86_64-unknown-linux-musl"
    root="$base/assets/root"
    mkdir -p "$root/$dir"
    make_bin "$root/$dir/rg" "echo \"ripgrep ${ver} (abc)\""
    make_tarball "$root" "$base/assets/$asset" "$dir"
    local hash
    hash=$(sha256sum "$base/assets/$asset" | awk '{print $1}')
    printf '%s  %s\n' "$hash" "$asset" >"$base/assets/${asset}.sha256"
    mkdir -p "$base/api/repos/BurntSushi/ripgrep/releases"
    cat >"$base/api/repos/BurntSushi/ripgrep/releases/latest" <<EOF
{"tag_name": "${ver}", "name": "${ver}", "assets": [
 {"name": "$asset", "browser_download_url": "file://$base/assets/$asset"},
 {"name": "${asset}.sha256", "browser_download_url": "file://$base/assets/${asset}.sha256"}]}
EOF
}

make_granted_fixture() {
    local base="$1" ver="$2" root asset
    asset="granted_${ver}_linux_x86_64.tar.gz"
    root="$base/assets/root"
    mkdir -p "$root"
    make_bin "$root/granted" "echo \"Granted version: ${ver}\""
    make_tarball "$root" "$base/assets/$asset" granted
    local hash
    hash=$(sha256sum "$base/assets/$asset" | awk '{print $1}')
    printf '%s  %s\n' "$hash" "$asset" >"$base/assets/checksums.txt"
    mkdir -p "$base/api/repos/fwdcloudsec/granted/releases"
    cat >"$base/api/repos/fwdcloudsec/granted/releases/latest" <<EOF
{"tag_name": "v${ver}", "assets": [
 {"name": "$asset", "browser_download_url": "file://$base/assets/$asset"},
 {"name": "checksums.txt", "browser_download_url": "file://$base/assets/checksums.txt"}]}
EOF
}

make_saml2aws_fixture() {
    local base="$1" ver="$2" root asset checksum_asset
    asset="saml2aws_${ver}_linux_amd64.tar.gz"
    checksum_asset="saml2aws_${ver}_checksums.txt"
    root="$base/assets/root"
    mkdir -p "$root"
    make_bin "$root/saml2aws" "echo \"${ver}\""
    make_tarball "$root" "$base/assets/$asset" saml2aws
    local hash
    hash=$(sha256sum "$base/assets/$asset" | awk '{print $1}')
    printf '%s  %s\n' "$hash" "$asset" >"$base/assets/$checksum_asset"
    mkdir -p "$base/api/repos/Versent/saml2aws/releases"
    cat >"$base/api/repos/Versent/saml2aws/releases/latest" <<EOF
{"tag_name": "v${ver}", "assets": [
 {"name": "$asset", "browser_download_url": "file://$base/assets/$asset"},
 {"name": "$checksum_asset", "browser_download_url": "file://$base/assets/$checksum_asset"}]}
EOF
}

make_mlr_fixture() {
    local base="$1" ver="$2" root asset dir
    asset="miller-${ver}-linux-amd64.tar.gz"
    dir="miller-${ver}-linux-amd64"
    root="$base/assets/root"
    mkdir -p "$root/$dir"
    make_bin "$root/$dir/mlr" "echo \"mlr ${ver}\""
    make_tarball "$root" "$base/assets/$asset" "$dir"
    local hash
    hash=$(sha256sum "$base/assets/$asset" | awk '{print $1}')
    printf '%s  %s\n' "$hash" "$asset" >"$base/assets/miller-${ver}-checksums.txt"
    mkdir -p "$base/api/repos/johnkerl/miller/releases"
    cat >"$base/api/repos/johnkerl/miller/releases/latest" <<EOF
{"tag_name": "v${ver}", "name": "v${ver}", "assets": [
 {"name": "$asset", "browser_download_url": "file://$base/assets/$asset"},
 {"name": "miller-${ver}-checksums.txt", "browser_download_url": "file://$base/assets/miller-${ver}-checksums.txt"}]}
EOF
}

make_kubectl_fixture() {
    local base="$1" ver="$2"
    mkdir -p "$base/release/v${ver}/bin/linux/amd64"
    make_bin "$base/release/v${ver}/bin/linux/amd64/kubectl" "echo \"Client Version: v${ver}\""
    printf 'v%s\n' "$ver" >"$base/release/stable.txt"
    local hash
    hash=$(sha256sum "$base/release/v${ver}/bin/linux/amd64/kubectl" | awk '{print $1}')
    printf '%s\n' "$hash" >"$base/release/v${ver}/bin/linux/amd64/kubectl.sha256"
}

make_helm_fixture() {
    local base="$1" ver="$2" root asset dir
    asset="helm-v${ver}-linux-amd64.tar.gz"
    dir="linux-amd64"
    root="$base/assets/root"
    mkdir -p "$root/$dir"
    make_bin "$root/$dir/helm" "echo \"version.BuildInfo{Version:\\\"v${ver}\\\",}\""
    make_tarball "$root" "$base/assets/$asset" "$dir"
    local hash
    hash=$(sha256sum "$base/assets/$asset" | awk '{print $1}')
    printf '%s  %s\n' "$hash" "$asset" >"$base/assets/${asset}.sha256sum"
    printf 'v%s\n' "$ver" >"$base/helm-latest-version"
}

make_coscli_fixture() {
    local base="$1" ver="$2" root
    root="$base/assets/root"
    mkdir -p "$root"
    make_bin "$root/coscli-v${ver}-linux-amd64" "echo \"coscli version v${ver}\""
    cp "$root/coscli-v${ver}-linux-amd64" "$base/assets/coscli-v${ver}-linux-amd64"
    local hash
    hash=$(sha256sum "$base/assets/coscli-v${ver}-linux-amd64" | awk '{print $1}')
    printf '%s  %s\n' "$hash" "coscli-v${ver}-linux-amd64" >"$base/assets/sha256sum.log"
    mkdir -p "$base/api/repos/tencentyun/coscli/releases"
    cat >"$base/api/repos/tencentyun/coscli/releases/latest" <<EOF
{"tag_name": "v${ver}", "name": "coscli ${ver}", "assets": [
 {"name": "coscli-v${ver}-linux-amd64", "browser_download_url": "file://$base/assets/coscli-v${ver}-linux-amd64"},
 {"name": "sha256sum.log", "browser_download_url": "file://$base/assets/sha256sum.log"}]}
EOF
}

make_gcloud_fixture() {
    local base="$1" ver="$2" arch="${3:-x86_64}"
    local tarball="google-cloud-cli-${ver}-linux-${arch}.tar.gz"
    local root="$base/assets/root"
    mkdir -p "$root/google-cloud-sdk/bin"
    make_bin "$root/google-cloud-sdk/bin/gcloud" "echo \"Google Cloud SDK ${ver}\""
    make_tarball "$root" "$base/assets/$tarball" "google-cloud-sdk"
    mkdir -p "$base/dl/google/dl/cloudsdk/channels/rapid/downloads"
    cp "$base/assets/$tarball" "$base/dl/google/dl/cloudsdk/channels/rapid/downloads/$tarball"
    printf '{"version": "%s"}\n' "$ver" >"$base/dl/google/dl/cloudsdk/channels/rapid/components-2.json"
}

make_uv_release_fixture() {
    local base="$1" ver="$2"
    mkdir -p "$base/api/repos/astral-sh/uv/releases"
    cat >"$base/api/repos/astral-sh/uv/releases/latest" <<EOF
{"tag_name": "${ver}", "name": "uv ${ver}"}
EOF
}

make_uv_installer_fixture() {
    local base="$1" ver="$2"
    mkdir -p "$base"
    cat >"$base/install.sh" <<EOF
#!/bin/sh
mkdir -p "\$UV_INSTALL_DIR"
cat > "\$UV_INSTALL_DIR/uv" <<'UVBIN'
#!/bin/sh
TOOL_STATE="\${CLI_TOOLBOX_HOME:-\$HOME}/.mock-uv-tool-state"
TOOL_BIN="\${UV_TOOL_BIN_DIR:-\$HOME/.local/bin}"
case "\$1" in
  tool)
    case "\$2" in
      list)
        if [ "\$3" = "--show-paths" ]; then
          if [ -f "\$TOOL_STATE/tccli" ]; then
            echo "tccli v3.1.165.1 (\$TOOL_BIN/tccli)"
            echo "- tccli (\$TOOL_BIN/tccli)"
          fi
          if [ -f "\$TOOL_STATE/oci-cli" ]; then
            echo "oci-cli v3.50.0 (\$TOOL_BIN/oci)"
            echo "- oci (\$TOOL_BIN/oci)"
          fi
          exit 0
        fi
        if [ -f "\$TOOL_STATE/tccli" ]; then
          echo "tccli v3.1.165.1"
          echo "- tccli"
        fi
        if [ -f "\$TOOL_STATE/oci-cli" ]; then
          echo "oci-cli v3.50.0"
          echo "- oci"
        fi
        exit 0
        ;;
      install)
        pkg=""
        shift 2
        while [ \$# -gt 0 ]; do
          case "\$1" in
            --upgrade|--force) shift ;;
            *) pkg="\$1"; shift ;;
          esac
        done
        mkdir -p "\$TOOL_BIN" "\$TOOL_STATE"
        case "\$pkg" in
          tccli)
            printf '%s\n' '#!/bin/sh' 'echo 3.1.165.1' > "\$TOOL_BIN/tccli"
            chmod +x "\$TOOL_BIN/tccli"
            touch "\$TOOL_STATE/tccli"
            ;;
          oci-cli)
            printf '%s\n' '#!/bin/sh' 'echo 3.50.0' > "\$TOOL_BIN/oci"
            chmod +x "\$TOOL_BIN/oci"
            touch "\$TOOL_STATE/oci-cli"
            ;;
        esac
        exit 0
        ;;
      uninstall)
        pkg=""
        shift 2
        while [ \$# -gt 0 ]; do
          case "\$1" in
            *) pkg="\$1"; shift ;;
          esac
        done
        case "\$pkg" in
          tccli) rm -f "\$TOOL_BIN/tccli" "\$TOOL_STATE/tccli" ;;
          oci-cli) rm -f "\$TOOL_BIN/oci" "\$TOOL_STATE/oci-cli" ;;
        esac
        exit 0
        ;;
    esac
    exit 0
    ;;
  --version) echo "uv ${ver}" ;;
esac
exit 0
UVBIN
chmod +x "\$UV_INSTALL_DIR/uv"
EOF
    chmod +x "$base/install.sh"
}

make_pypi_fixture() {
    local base="$1" pkg="$2" ver="$3"
    mkdir -p "$base/pypi/pypi/$pkg"
    cat >"$base/pypi/pypi/$pkg/json" <<EOF
{"info": {"name": "$pkg", "version": "$ver"}, "urls": [
 {"filename": "${pkg}-${ver}-py3-none-any.whl", "url": "file://$base/pypi/$pkg.whl", "digests": {"sha256": "abc"}}]}
EOF
}

make_aws_fixture() {
    local base="$1" ver="$2" root
    root="$base/awsroot"
    mkdir -p "$root/aws/dist"
    cat >"$root/aws/install" <<EOF
#!/bin/sh
install_dir=""; bin_dir=""
while [ \$# -gt 0 ]; do
  case "\$1" in
    --install-dir) install_dir="\$2"; shift 2 ;;
    --bin-dir) bin_dir="\$2"; shift 2 ;;
    --update) shift ;;
    *) shift ;;
  esac
done
mkdir -p "\$install_dir/v2/current/bin" "\$bin_dir"
cat > "\$install_dir/v2/current/bin/aws" <<'SCRIPT'
#!/bin/sh
echo "aws-cli/${ver} Python/3.11.0 Linux/6.1.0 test"
SCRIPT
chmod +x "\$install_dir/v2/current/bin/aws"
ln -sf "\$install_dir/v2/current/bin/aws" "\$bin_dir/aws"
EOF
    chmod +x "$root/aws/install"
    python3 - "$root" "$base/awscli.zip" <<'PY'
import sys, zipfile, os
src, dst = sys.argv[1], sys.argv[2]
with zipfile.ZipFile(dst, 'w', zipfile.ZIP_DEFLATED) as z:
    for root, _, files in os.walk(src):
        for f in files:
            p = os.path.join(root, f)
            z.write(p, os.path.relpath(p, src))
PY
    printf '%s\n' "$ver" >"$base/version.txt"
}

make_opencode_fixture() {
    local base="$1" ver="$2" root asset dir
    asset="opencode-linux-x64.tar.gz"
    dir="opencode-linux-x64"
    root="$base/assets/root"
    mkdir -p "$root/$dir"
    make_bin "$root/$dir/opencode" "echo \"opencode version ${ver}\""
    make_tarball "$root" "$base/assets/$asset" "$dir"
    mkdir -p "$base/api/repos/anomalyco/opencode/releases"
    cat >"$base/api/repos/anomalyco/opencode/releases/latest" <<EOF
{"tag_name": "v${ver}", "name": "v${ver}", "assets": [
 {"name": "$asset", "browser_download_url": "file://$base/assets/$asset"}]}
EOF
}

make_agent_installer_fixture() {
    local base="$1" ver="$2"
    mkdir -p "$base"
    cat >"$base/install.sh" <<EOF
#!/bin/sh
mkdir -p "\$HOME/.local/bin"
cat > "\$HOME/.local/bin/agent" <<'BIN'
#!/bin/sh
echo "agent version ${ver}"
BIN
chmod +x "\$HOME/.local/bin/agent"
EOF
    chmod +x "$base/install.sh"
}

make_codex_installer_fixture() {
    local base="$1" ver="$2"
    mkdir -p "$base"
    cat >"$base/install.sh" <<EOF
#!/bin/sh
bindir="\${CODEX_INSTALL_DIR:-\$HOME/.local/bin}"
mkdir -p "\$bindir"
cat > "\$bindir/codex" <<'BIN'
#!/bin/sh
echo "codex version ${ver}"
BIN
chmod +x "\$bindir/codex"
EOF
    chmod +x "$base/install.sh"
}

make_agy_installer_fixture() {
    local base="$1" ver="$2"
    mkdir -p "$base"
    cat >"$base/install.sh" <<EOF
#!/bin/sh
dir=""
while [ \$# -gt 0 ]; do
  case "\$1" in
    --dir) dir="\$2"; shift 2 ;;
    *) shift ;;
  esac
done
mkdir -p "\$dir"
cat > "\$dir/agy" <<'BIN'
#!/bin/sh
echo "${ver}"
BIN
chmod +x "\$dir/agy"
EOF
    chmod +x "$base/install.sh"
}

make_claude_installer_fixture() {
    local base="$1" ver="$2"
    mkdir -p "$base"
    cat >"$base/install.sh" <<EOF
#!/bin/bash
set -e
TARGET="\$1"
if [[ -n "\$TARGET" ]] && [[ ! "\$TARGET" =~ ^stable\$ ]]; then
    echo "unexpected target: \$TARGET" >&2
    exit 1
fi
mkdir -p "\$HOME/.local/bin"
cat > "\$HOME/.local/bin/claude" <<'BIN'
#!/bin/sh
echo "claude version ${ver}"
BIN
chmod +x "\$HOME/.local/bin/claude"
EOF
    chmod +x "$base/install.sh"
}

write_targets_file() {
    local path="$1"
    shift
    : >"$path"
    while [ "$#" -gt 0 ]; do
        printf '%s\n' "$1" >>"$path"
        shift
    done
}

# make_cli_sandbox [line...]: temp dir with cli-toolbox.sh, lib/, and custom targets.txt.
make_cli_sandbox() {
    local dir
    dir=$(test_tmp)
    ln -s "$TBROOT/cli-toolbox.sh" "$dir/cli-toolbox.sh"
    ln -s "$TBROOT/lib" "$dir/lib"
    write_targets_file "$dir/targets.txt" "$@"
    printf '%s' "$dir"
}

cli_sandbox() {
    local sandbox="$1" out="$2"
    shift 2
    "$sandbox/cli-toolbox.sh" "$@" >"$out" 2>&1
    CLI_RC=$?
}

FIX_GLOW=$(test_tmp); make_glow_fixture "$FIX_GLOW" 3.0.0
FIX_COSCLI=$(test_tmp); make_coscli_fixture "$FIX_COSCLI" 1.0.9
FIX_RG=$(test_tmp); make_rg_fixture "$FIX_RG" 15.0.0
FIX_MLR=$(test_tmp); make_mlr_fixture "$FIX_MLR" 6.20.0
FIX_GRANTED=$(test_tmp); make_granted_fixture "$FIX_GRANTED" 0.39.0
FIX_SAML2AWS=$(test_tmp); make_saml2aws_fixture "$FIX_SAML2AWS" 2.36.19
FIX_GCLOUD=$(test_tmp); make_gcloud_fixture "$FIX_GCLOUD" 502.0.0
FIX_UV_REL=$(test_tmp); make_uv_release_fixture "$FIX_UV_REL" 0.12.12
FIX_UV_INST=$(test_tmp); make_uv_installer_fixture "$FIX_UV_INST" 0.12.12
FIX_PYPI=$(test_tmp); make_pypi_fixture "$FIX_PYPI" tccli 3.1.165.1
make_pypi_fixture "$FIX_PYPI" oci-cli 3.50.0
FIX_AWS=$(test_tmp); make_aws_fixture "$FIX_AWS" 2.36.42
FIX_OPENCODE=$(test_tmp); make_opencode_fixture "$FIX_OPENCODE" 1.0.0
FIX_AGENT=$(test_tmp); make_agent_installer_fixture "$FIX_AGENT" 1.0.0
FIX_CLAUDE=$(test_tmp); make_claude_installer_fixture "$FIX_CLAUDE" 3.0.0
FIX_CODEX=$(test_tmp); make_codex_installer_fixture "$FIX_CODEX" 2.0.0
FIX_AGY=$(test_tmp); make_agy_installer_fixture "$FIX_AGY" 1.2.1
FIX_KUBECTL=$(test_tmp); make_kubectl_fixture "$FIX_KUBECTL" 1.30.0
FIX_HELM=$(test_tmp); make_helm_fixture "$FIX_HELM" 3.14.0
new_home() { test_tmp; }

setup_clean_env() {
    local H="$1"
    export TB_ROOT="$TBROOT"
    export HOME="$H"
    export CLI_TOOLBOX_HOME="$H"
    export CLI_TOOLBOX_API_BASE="file://$FIX_UV_REL/api"
    export CLI_TOOLBOX_PYPI_BASE="file://$FIX_PYPI/pypi"
    export CLI_TOOLBOX_UV_INSTALL_URL="file://$FIX_UV_INST/install.sh"
    export UV_TOOL_BIN_DIR="$H/.local/bin"
    mkdir -p "$H/bin" "$H/.local/bin"
    export PATH="$H/bin:$H/.local/bin:$PATH"
    unset GITHUB_TOKEN CLI_TOOLBOX_CURL
}

# ---------------------------------------------------------------------------
# targets.txt parsing
# ---------------------------------------------------------------------------

TARGETS_OK=$(
    TROOT=$(test_tmp)
    write_targets_file "$TROOT/targets.txt" \
        "# header" \
        "" \
        "uv" \
        "gh   # cloud cli" \
        "uv" \
        "tccli"
    export TB_ROOT="$TROOT"
    source_libs
    load_targets && printf '%s\n' "${TB_TARGETS[*]}"
)
assert_contains "targets ignores comments and blanks" "$TARGETS_OK" "uv gh tccli"
assert_not_contains "targets deduplicates" "$TARGETS_OK" "uv uv"

TARGETS_BAD=$(
    TROOT=$(test_tmp)
    write_targets_file "$TROOT/targets.txt" "not-a-cli"
    export TB_ROOT="$TROOT"
    source_libs
    load_targets 2>&1
    printf 'rc=%s\n' "$?"
)
assert_contains "targets unknown CLI errors" "$TARGETS_BAD" "unknown CLI in targets.txt"
assert_contains "targets unknown CLI rc" "$TARGETS_BAD" "rc=2"

TARGETS_EMPTY=$(
    TROOT=$(test_tmp)
    write_targets_file "$TROOT/targets.txt" "# only comment" ""
    export TB_ROOT="$TROOT"
    source_libs
    load_targets 2>&1
    printf 'rc=%s\n' "$?"
)
assert_contains "targets empty file errors" "$TARGETS_EMPTY" "no valid CLI entries"

DISPLAY=$(
    source_libs
    cli_display_name agent
)
assert_contains "agent display name" "$DISPLAY" "Cursor Agent CLI"

# ---------------------------------------------------------------------------
# unit: ensure_unzip (apt / brew)
# ---------------------------------------------------------------------------

ENSURE_UNZIP_APT=$(
    source_libs
    H=$(test_tmp)
    export TB_OS=linux TB_ARCH=amd64
    export PATH="$H/bin:$PATH"
    has_apt() { return 0; }
    apt_install_or_upgrade() {
        make_bin "$H/bin/unzip" 'exit 0'
        return 0
    }
    ensure_unzip && cmd_exists unzip && printf 'ok'
)
assert_contains "ensure_unzip via apt" "$ENSURE_UNZIP_APT" "ok"

ENSURE_UNZIP_BREW=$(
    source_libs
    H=$(test_tmp)
    export TB_OS=darwin TB_ARCH=arm64
    export PATH="$H/bin:$PATH"
    has_brew() { return 0; }
    brew_install_or_upgrade() {
        make_bin "$H/bin/unzip" 'exit 0'
        return 0
    }
    ensure_unzip && cmd_exists unzip && printf 'ok'
)
assert_contains "ensure_unzip via brew" "$ENSURE_UNZIP_BREW" "ok"

# ---------------------------------------------------------------------------
# unit: extract_archive zip (python3 fallback when unzip is absent)
# ---------------------------------------------------------------------------

ZIP_EXTRACT_OUT=$(
    source_libs
    ensure_unzip() { return 1; }
    base=$(test_tmp)
    mkdir -p "$base/src/sub"
    printf 'hello\n' >"$base/src/sub/file.txt"
    python3 - "$base/src" "$base/test.zip" <<'PY'
import sys, zipfile, os
src, dst = sys.argv[1], sys.argv[2]
with zipfile.ZipFile(dst, 'w', zipfile.ZIP_DEFLATED) as z:
    for root, _, files in os.walk(src):
        for f in files:
            p = os.path.join(root, f)
            z.write(p, os.path.relpath(p, src))
PY
    out=$(test_tmp)
    PATH_NO_UNZIP=$(printf '%s\n' "$PATH" | tr ':' '\n' | while IFS= read -r d; do
        [ -x "$d/unzip" ] || printf '%s\n' "$d"
    done | paste -sd: -)
    PATH="$PATH_NO_UNZIP" extract_archive "$base/test.zip" "$out" \
        && test -f "$out/sub/file.txt" && printf 'ok'
)
assert_contains "extract_archive zip without unzip" "$ZIP_EXTRACT_OUT" "ok"

# ---------------------------------------------------------------------------
# unit: version_gt / resolve_real_path / resolve_provider
# ---------------------------------------------------------------------------

VG_OUT=$(
    source_libs
    version_gt 2.1.0 2.0.9 && echo ok-gt
    version_gt 1.0.0-beta 1.0.0; echo rc=$?
)
assert_contains "version_gt basic" "$VG_OUT" "ok-gt"
assert_not_contains "version_gt prerelease no integer error" "$VG_OUT" "integer expression expected"

RP_OUT=$(
    H=$(new_home)
    mkdir -p "$H/a"
    ln -s b "$H/a/link"
    echo x >"$H/a/b"
    source_libs
    resolve_real_path "$H/a/link"
)
assert_contains "resolve_real_path follows symlink" "$RP_OUT" "/b"

PROV_OUT=$(
    source_libs
    resolve_provider gcloud linux; echo
    resolve_provider gh darwin; echo
    resolve_provider aws darwin; echo
    resolve_provider terraform linux; echo
    resolve_provider terraform darwin; echo
    resolve_provider kubectl linux; echo
    resolve_provider helm darwin; echo
    resolve_provider oci linux
)
assert_contains "resolve_provider gcloud archive" "$PROV_OUT" "official-archive"
assert_contains "resolve_provider gh darwin brew" "$PROV_OUT" "brew"
assert_contains "resolve_provider aws darwin brew" "$PROV_OUT" "brew"
assert_contains "resolve_provider terraform linux apt" "$PROV_OUT" "apt"
assert_contains "resolve_provider terraform darwin brew" "$PROV_OUT" "brew"
assert_contains "resolve_provider kubectl release-binary" "$PROV_OUT" "release-binary"
assert_contains "resolve_provider helm release-binary" "$PROV_OUT" "release-binary"
assert_contains "resolve_provider oci linux uv-tool" "$PROV_OUT" "uv-tool"

OCI_DARWIN_PROV=$(
    source_libs
    has_brew() { return 0; }
    resolve_provider oci darwin
)
assert_contains "resolve_provider oci darwin brew" "$OCI_DARWIN_PROV" "brew"

TF_VER=$(
    H=$(new_home)
    make_bin "$H/bin/terraform" 'echo "Terraform v1.9.8"'
    source_libs
    _parse_version terraform "$H/bin/terraform"
)
assert_contains "terraform version parse" "$TF_VER" "1.9.8"

RG_VER=$(
    H=$(new_home)
    make_bin "$H/bin/rg" 'echo "ripgrep 15.0.0 (abc)"'
    source_libs
    _parse_version rg "$H/bin/rg"
)
assert_contains "rg version parse" "$RG_VER" "15.0.0"

MLR_VER=$(
    H=$(new_home)
    make_bin "$H/bin/mlr" 'echo "mlr 6.20.0"'
    source_libs
    _parse_version mlr "$H/bin/mlr"
)
assert_contains "mlr version parse" "$MLR_VER" "6.20.0"

AGENT_VER=$(
    H=$(new_home)
    make_bin "$H/bin/agent" 'echo "agent version 1.0.0"'
    source_libs
    _parse_version agent "$H/bin/agent"
)
assert_contains "agent version parse (prefixed)" "$AGENT_VER" "1.0.0"

CODEX_VER=$(
    H=$(new_home)
    make_bin "$H/bin/codex" 'echo "codex version 2.0.0"'
    source_libs
    _parse_version codex "$H/bin/codex"
)
assert_contains "codex version parse (legacy)" "$CODEX_VER" "2.0.0"

CODEX_CLI_VER=$(
    H=$(new_home)
    make_bin "$H/bin/codex" 'echo "codex-cli 0.154.0"'
    source_libs
    _parse_version codex "$H/bin/codex"
)
assert_contains "codex version parse (codex-cli)" "$CODEX_CLI_VER" "0.154.0"

SAML2AWS_VER=$(
    H=$(new_home)
    make_bin "$H/bin/saml2aws" 'echo "2.36.19" >&2'
    source_libs
    _parse_version saml2aws "$H/bin/saml2aws"
)
assert_contains "saml2aws version parse (stderr)" "$SAML2AWS_VER" "2.36.19"

AGENT_CAL_VER=$(
    H=$(new_home)
    make_bin "$H/bin/agent" 'echo "2026.09.10-fd3934a"'
    source_libs
    _parse_version agent "$H/bin/agent"
)
assert_contains "agent version parse (bare calendar)" "$AGENT_CAL_VER" "2026.09.10-fd3934a"

KUBECTL_VER=$(
    H=$(new_home)
    make_bin "$H/bin/kubectl" 'echo "Client Version: v1.30.0"'
    source_libs
    _parse_version kubectl "$H/bin/kubectl"
)
assert_contains "kubectl version parse" "$KUBECTL_VER" "1.30.0"

HELM_VER=$(
    H=$(new_home)
    make_bin "$H/bin/helm" 'echo "version.BuildInfo{Version:\"v3.14.0\",}"'
    source_libs
    _parse_version helm "$H/bin/helm"
)
assert_contains "helm version parse" "$HELM_VER" "3.14.0"

OCI_VER=$(
    H=$(new_home)
    make_bin "$H/bin/oci" 'echo "3.50.0"'
    source_libs
    _parse_version oci "$H/bin/oci"
)
assert_contains "oci version parse" "$OCI_VER" "3.50.0"

GCURL_OUT=$(
    source_libs
    gcloud_archive_url 502.0.0 linux amd64; echo
    gcloud_archive_url 502.0.0 darwin arm64
)
assert_contains "gcloud_archive_url linux amd64" "$GCURL_OUT" "linux-x86_64"
assert_contains "gcloud_archive_url darwin arm64" "$GCURL_OUT" "darwin-arm"

GH_API_FALLBACK=$(
    H=$(new_home)
    mkdir -p "$H/assets"
    printf 'fallback-ok' >"$H/assets/asset.txt"
    body='{"assets":[{"name":"asset.txt","browser_download_url":"file:///nonexistent/asset.txt","url":"file://'"$H"'/assets/asset.txt"}]}'
    source_libs
    dest="$H/out.txt"
    download_github_release_asset test/repo v1.0.0 asset.txt "$body" "$dest" && cat "$dest"
)
assert_contains "download_github_release_asset api fallback" "$GH_API_FALLBACK" "fallback-ok"

# ---------------------------------------------------------------------------
# list: pipx absent, PROVIDER column, targets rows, az requires-root/missing
# ---------------------------------------------------------------------------

OUT=$(test_file)
H=$(new_home)
setup_clean_env "$H"
cli "$OUT" list
assert_not_contains "list: pipx not shown" "$(cat "$OUT")" "pipx"
assert_contains "list: PROVIDER header" "$(cat "$OUT")" "PROVIDER"
assert_contains "list: tccli provider uv-tool policy" "$(cat "$OUT")" "tccli"
assert_contains "list: terraform row present (target)" "$(cat "$OUT")" "terraform"
assert_not_contains "list: az omitted (not in targets)" "$(cat "$OUT")" "az"

OUT=$(test_file)
AZ_OUT=$(
    H=$(new_home)
    export CLI_TOOLBOX_HOME="$H"
    export TB_OS=linux TB_ARCH=amd64
    source_libs
    has_apt() { return 0; }
    can_sudo() { return 1; }
    package_manager_available() { [ "$1" = "apt" ] && return 0; return 1; }
    package_installed_version() { return 0; }
    package_latest_version() { printf '%s' "2.77.0"; }
    inspect_cli az
    printf '%s %s %s\n' "$TB_LIST_STATUS" "$TB_LIST_PROVIDER" "$TB_LIST_STATE"
)
assert_contains "az without sudo: requires-root" "$AZ_OUT" "requires-root"
assert_contains "az without sudo: apt provider" "$AZ_OUT" "apt"

AZ_SYS=$(
    H=$(new_home)
    export CLI_TOOLBOX_HOME="$H"
    export TB_OS=linux TB_ARCH=amd64
    source_libs
    has_apt() { return 0; }
    can_sudo() { return 0; }
    package_manager_available() { [ "$1" = "apt" ] && return 0; return 1; }
    package_installed_version() { [ "$2" = "azure-cli" ] && printf '%s' "2.76.0"; }
    package_latest_version() { printf '%s' "2.76.0"; }
    command() {
        if [ "$1" = "-v" ] && [ "$2" = "az" ]; then printf '%s\n' "/usr/bin/az"; return 0; fi
        builtin command "$@"
    }
    _parse_version() { [ "$1" = "az" ] && printf '%s' "2.76.0"; }
    inspect_cli az
    printf '%s %s\n' "$TB_LIST_STATUS" "$TB_LIST_PROVIDER"
)
assert_contains "az installed: system status" "$AZ_SYS" "system"

BREW_MISSING=$(
    H=$(new_home)
    export CLI_TOOLBOX_HOME="$H"
    export TB_OS=darwin TB_ARCH=arm64
    source_libs
    has_brew() { return 1; }
    brew_bin() { return 1; }
    package_manager_available() { return 1; }
    inspect_cli gh
    printf '%s %s\n' "$TB_LIST_STATUS" "$TB_LIST_PROVIDER"
)
assert_contains "macOS brew missing: requires-package-manager" "$BREW_MISSING" "requires-package-manager"
assert_contains "macOS brew missing: brew provider" "$BREW_MISSING" "brew"

# ---------------------------------------------------------------------------
# install uv + tccli
# ---------------------------------------------------------------------------

OUT=$(test_file)
H=$(new_home)
setup_clean_env "$H"
cli "$OUT" install uv
assert_contains_re "uv install" "$(cat "$OUT")" 'uv[[:space:]]+installed'
assert_true "uv binary exists" test -x "$H/bin/uv"

OUT=$(test_file)
cli "$OUT" install uv
assert_contains_re "uv unchanged" "$(cat "$OUT")" 'uv[[:space:]]+unchanged'

OUT=$(test_file)
cli "$OUT" install tccli
assert_contains_re "tccli install" "$(cat "$OUT")" 'tccli[[:space:]]+installed'
assert_true "tccli via uv tool list" "$H/bin/uv" tool list | grep -q '^tccli'
assert_contains "tccli path under UV_TOOL_BIN_DIR" "$(command -v tccli)" "$H/.local/bin/tccli"

OUT=$(test_file)
cli "$OUT" install tccli
assert_contains_re "tccli unchanged" "$(cat "$OUT")" 'tccli[[:space:]]+unchanged'

# ---------------------------------------------------------------------------
# migration-available
# ---------------------------------------------------------------------------

MIG=$(
    H=$(new_home)
    SYSBIN=$(test_tmp)
    make_bin "$SYSBIN/tccli" 'echo 9.9.9'
    export CLI_TOOLBOX_HOME="$H"
    export UV_TOOL_BIN_DIR="$H/.local/bin"
    export TB_OS=linux TB_ARCH=amd64
    PATH="$H/bin:$H/.local/bin:$SYSBIN:$PATH"
    source_libs
    uv_tool_list_packages() { return 0; }
    uv_tool_executable_path() { return 1; }
    inspect_cli tccli
    printf '%s\n' "$TB_LIST_STATE"
)
assert_contains "tccli migration-available" "$MIG" "migration-available"

PIPX_MIG=$(
    H=$(new_home)
    mkdir -p "$H/.local/share/pipx/venvs/tccli/bin"
    make_bin "$H/.local/share/pipx/venvs/tccli/bin/tccli" 'echo 3.1.165.1'
    mkdir -p "$H/.local/bin"
    ln -sf "$H/.local/share/pipx/venvs/tccli/bin/tccli" "$H/.local/bin/tccli"
    export CLI_TOOLBOX_HOME="$H"
    export UV_TOOL_BIN_DIR="$H/.local/bin"
    export TB_OS=linux TB_ARCH=amd64
    PATH="$H/bin:$H/.local/bin:$PATH"
    source_libs
    uv_tool_list_packages() { return 0; }
    inspect_cli tccli
    printf '%s %s\n' "$TB_LIST_PROVIDER" "$TB_LIST_STATE"
)
assert_contains "pipx tccli shows pipx provider" "$PIPX_MIG" "pipx"
assert_contains "pipx tccli migration-available" "$PIPX_MIG" "migration-available"

GCLOUD_MIG=$(
    H=$(new_home)
    SYS=$(test_tmp)
    make_bin "$SYS/gcloud" 'echo "Google Cloud SDK 9.9.9"'
    export CLI_TOOLBOX_HOME="$H"
    export TB_OS=linux TB_ARCH=amd64
    PATH="$SYS:$PATH"
    source_libs
    gcloud_latest_version() { printf '%s' "502.0.0"; }
    inspect_cli gcloud
    printf '%s %s\n' "$TB_LIST_STATUS" "$TB_LIST_STATE"
)
assert_contains "gcloud system migration-available" "$GCLOUD_MIG" "migration-available"
assert_contains "gcloud system status" "$GCLOUD_MIG" "system"

# ---------------------------------------------------------------------------
# gcloud archive install (no apt)
# ---------------------------------------------------------------------------

GCLOUD_INSTALL=$(
    H=$(new_home)
    export CLI_TOOLBOX_HOME="$H"
    export TB_OS=linux TB_ARCH=amd64
    source_libs
    http_get() {
        case "$1" in
            *components-2.json*) cat "$FIX_GCLOUD/dl/google/dl/cloudsdk/channels/rapid/components-2.json" ;;
            *) return 1 ;;
        esac
    }
    download_file() {
        case "$2" in
            */google-cloud-cli-502.0.0-linux-x86_64.tar.gz) cp "$FIX_GCLOUD/assets/google-cloud-cli-502.0.0-linux-x86_64.tar.gz" "$2" ;;
            *) return 1 ;;
        esac
    }
    apt_setup_repo_gcloud() { echo "apt should not be called" >&2; return 1; }
    install_gcloud
    printf 'state=%s ver=%s link=%s\n' "$TB_STATE" "$(gcloud_managed_version)" "$([ -L "$H/bin/gcloud" ] && echo yes || echo no)"
)
assert_contains "gcloud archive install" "$GCLOUD_INSTALL" "state=installed"
assert_contains "gcloud version dir" "$GCLOUD_INSTALL" "502.0.0"
assert_contains "gcloud bin symlink" "$GCLOUD_INSTALL" "link=yes"

GCLOUD_IDEM=$(
    H=$(new_home)
    export CLI_TOOLBOX_HOME="$H"
    export TB_OS=linux TB_ARCH=amd64
    source_libs
    http_get() { cat "$FIX_GCLOUD/dl/google/dl/cloudsdk/channels/rapid/components-2.json"; }
    download_file() { cp "$FIX_GCLOUD/assets/google-cloud-cli-502.0.0-linux-x86_64.tar.gz" "$2"; }
    mkdir -p "$H/bin" "$H/tools/google-cloud-sdk/versions/502.0.0/bin"
    make_bin "$H/tools/google-cloud-sdk/versions/502.0.0/bin/gcloud" 'echo "Google Cloud SDK 502.0.0"'
    ln -s versions/502.0.0 "$H/tools/google-cloud-sdk/current"
    ln -s ../tools/google-cloud-sdk/current/bin/gcloud "$H/bin/gcloud"
    install_gcloud
    printf '%s\n' "$TB_STATE"
)
assert_contains "gcloud unchanged on re-run" "$GCLOUD_IDEM" "unchanged"

# ---------------------------------------------------------------------------
# glow / coscli
# ---------------------------------------------------------------------------

OUT=$(test_file)
H=$(new_home)
setup_clean_env "$H"
export CLI_TOOLBOX_API_BASE="file://$FIX_GLOW/api"
cli "$OUT" install glow
assert_contains_re "glow install" "$(cat "$OUT")" 'glow[[:space:]]+installed'

OUT=$(test_file)
H=$(new_home)
setup_clean_env "$H"
export CLI_TOOLBOX_API_BASE="file://$FIX_COSCLI/api"
cli "$OUT" install coscli
assert_contains_re "coscli install" "$(cat "$OUT")" 'coscli[[:space:]]+installed'

OUT=$(test_file)
H=$(new_home)
setup_clean_env "$H"
export CLI_TOOLBOX_API_BASE="file://$FIX_RG/api"
cli "$OUT" install rg
assert_contains_re "rg install" "$(cat "$OUT")" 'rg[[:space:]]+installed'
assert_true "rg binary exists" test -x "$H/bin/rg"

OUT=$(test_file)
H=$(new_home)
setup_clean_env "$H"
export CLI_TOOLBOX_API_BASE="file://$FIX_MLR/api"
cli "$OUT" install mlr
assert_contains_re "mlr install" "$(cat "$OUT")" 'mlr[[:space:]]+installed'
assert_true "mlr binary exists" test -x "$H/bin/mlr"

OUT=$(test_file)
H=$(new_home)
setup_clean_env "$H"
export CLI_TOOLBOX_API_BASE="file://$FIX_GRANTED/api"
cli "$OUT" install granted
assert_contains_re "granted install" "$(cat "$OUT")" 'granted[[:space:]]+installed'
assert_true "granted binary exists" test -x "$H/bin/granted"

OUT=$(test_file)
H=$(new_home)
setup_clean_env "$H"
export CLI_TOOLBOX_API_BASE="file://$FIX_SAML2AWS/api"
cli "$OUT" install saml2aws
assert_contains_re "saml2aws install" "$(cat "$OUT")" 'saml2aws[[:space:]]+installed'
assert_true "saml2aws binary exists" test -x "$H/bin/saml2aws"

# ---------------------------------------------------------------------------
# kubectl / helm release-binary
# ---------------------------------------------------------------------------

KUBECTL_OUT=$(
    H=$(new_home)
    export CLI_TOOLBOX_HOME="$H"
    export TB_OS=linux TB_ARCH=amd64
    source_libs
    http_get() {
        case "$1" in
            *stable.txt) cat "$FIX_KUBECTL/release/stable.txt" ;;
            *) return 1 ;;
        esac
    }
    download_file() {
        case "$2" in
            *kubectl.sha256) cp "$FIX_KUBECTL/release/v1.30.0/bin/linux/amd64/kubectl.sha256" "$2" ;;
            */kubectl) cp "$FIX_KUBECTL/release/v1.30.0/bin/linux/amd64/kubectl" "$2" ;;
            *) return 1 ;;
        esac
    }
    install_kubectl
    printf 'state=%s ver=%s\n' "$TB_STATE" "$(get_installed_version kubectl)"
)
assert_contains "kubectl installs" "$KUBECTL_OUT" "state=installed"
assert_contains "kubectl version" "$KUBECTL_OUT" "ver=1.30.0"

HELM_OUT=$(
    H=$(new_home)
    export CLI_TOOLBOX_HOME="$H"
    export TB_OS=linux TB_ARCH=amd64
    source_libs
    http_get() {
        case "$1" in
            *helm-latest-version) cat "$FIX_HELM/helm-latest-version" ;;
            *) return 1 ;;
        esac
    }
    download_file() {
        case "$1" in
            *helm-v3.14.0-linux-amd64.tar.gz.sha256sum) cp "$FIX_HELM/assets/helm-v3.14.0-linux-amd64.tar.gz.sha256sum" "$2" ;;
            *helm-v3.14.0-linux-amd64.tar.gz) cp "$FIX_HELM/assets/helm-v3.14.0-linux-amd64.tar.gz" "$2" ;;
            *) return 1 ;;
        esac
    }
    install_helm
    printf 'state=%s ver=%s\n' "$TB_STATE" "$(get_installed_version helm)"
)
assert_contains "helm installs" "$HELM_OUT" "state=installed"
assert_contains "helm version" "$HELM_OUT" "ver=3.14.0"

OCI_OUT=$(
    H=$(new_home)
    setup_clean_env "$H"
    export TB_OS=linux TB_ARCH=amd64
    source_libs
    install_uv >/dev/null 2>&1
    install_oci
    printf 'state=%s ver=%s bin=%s\n' "$TB_STATE" "$(get_installed_version oci)" "$([ -x "$H/.local/bin/oci" ] && echo yes || echo no)"
)
assert_contains "oci installs" "$OCI_OUT" "state=installed"
assert_contains "oci version" "$OCI_OUT" "ver=3.50.0"
assert_contains "oci binary exists" "$OCI_OUT" "bin=yes"

# ---------------------------------------------------------------------------
# aws official installer
# ---------------------------------------------------------------------------

AWS_OUT=$(
    H=$(new_home)
    export CLI_TOOLBOX_HOME="$H"
    export TB_OS=linux TB_ARCH=amd64
    source_libs
    http_get() { [ "$1" = "https://awscli.amazonaws.com/v2/version.txt" ] && cat "$FIX_AWS/version.txt"; return 1; }
    download_file() { cp "$FIX_AWS/awscli.zip" "$2"; }
    install_aws
    printf 'state=%s ver=%s\n' "$TB_STATE" "$(get_installed_version aws)"
)
assert_contains "aws installs" "$AWS_OUT" "state=installed"
assert_contains "aws version" "$AWS_OUT" "ver=2.36.42"

# ---------------------------------------------------------------------------
# brew install mock (darwin)
# ---------------------------------------------------------------------------

BREW_OUT=$(
    H=$(new_home)
    export CLI_TOOLBOX_HOME="$H"
    export TB_OS=darwin TB_ARCH=arm64
    source_libs
    has_brew() { return 0; }
    brew_bin() { printf '%s\n' "$H/mock-brew"; }
    make_bin "$H/mock-brew" 'case "$1" in list) shift; [ "$1" = "--versions" ] && echo "gh 2.80.0" ;; info) echo "gh: stable 2.80.0" ;; install|upgrade) exit 0 ;; esac'
    package_manager_available() { [ "$1" = "brew" ] && return 0; return 1; }
    package_installed_version() {
        [ "$2" = "gh" ] && [ -x "$H/bin/gh" ] && printf '%s' "2.80.0"
    }
    package_latest_version() { printf '%s' "2.80.0"; }
    package_install_or_upgrade() { mkdir -p "$H/bin"; make_bin "$H/bin/gh" 'echo "gh version 2.80.0"'; return 0; }
    command() {
        if [ "$1" = "-v" ] && [ "$2" = "gh" ]; then printf '%s\n' "$H/bin/gh"; return 0; fi
        builtin command "$@"
    }
    install_gh
    printf 'state=%s\n' "$TB_STATE"
)
assert_contains "brew gh install" "$BREW_OUT" "state=installed"

# ---------------------------------------------------------------------------
# system CLI preservation
# ---------------------------------------------------------------------------

OUT=$(test_file)
H=$(new_home)
SYS=$(test_tmp)
make_bin "$SYS/gh" 'echo gh version 9.9.9'
setup_clean_env "$H"
export PATH="$SYS:$PATH"
export CLI_TOOLBOX_API_BASE="file://$FIX_GLOW/api"
cli "$OUT" install glow
assert_contains "system gh still runs" "$("$SYS/gh" --version)" "9.9.9"

# ---------------------------------------------------------------------------
# list after install
# ---------------------------------------------------------------------------

OUT=$(test_file)
H=$(new_home)
setup_clean_env "$H"
cli "$OUT" install uv tccli
OUT=$(test_file)
cli "$OUT" list tccli uv
assert_contains_re "list tccli managed" "$(cat "$OUT")" 'tccli[[:space:]]+managed'
assert_contains "list tccli uv-tool provider" "$(cat "$OUT")" "uv-tool"

assert_true "cli-toolbox.sh executable" test -x "$TBROOT/cli-toolbox.sh"
OUT=$(test_file)
H=$(new_home)
setup_clean_env "$H"
cli "$OUT" help
assert_contains "help shows targets.txt" "$(cat "$OUT")" "targets.txt"
assert_contains "help shows agent label" "$(cat "$OUT")" "agent (Cursor Agent CLI)"
assert_contains "help shows delete" "$(cat "$OUT")" "delete"
assert_not_contains "help omits Environment section" "$(cat "$OUT")" "Environment:"
assert_not_contains "help omits CLI_TOOLBOX_HOME" "$(cat "$OUT")" "CLI_TOOLBOX_HOME"

# ---------------------------------------------------------------------------
# targets-driven install/list
# ---------------------------------------------------------------------------

TROOT=$(make_cli_sandbox "uv")
OUT=$(test_file)
H=$(new_home)
setup_clean_env "$H"
cli_sandbox "$TROOT" "$OUT" install
assert_contains_re "install without args uses targets" "$(cat "$OUT")" 'uv[[:space:]]+installed'
assert_not_contains "install without args skips non-target" "$(cat "$OUT")" "gh"

OUT=$(test_file)
H=$(new_home)
setup_clean_env "$H"
cli "$OUT" install aws
assert_contains_re "install with args only aws" "$(cat "$OUT")" 'aws[[:space:]]+installed'
assert_not_contains "install with args skips others" "$(cat "$OUT")" "uv"

TROOT=$(make_cli_sandbox "uv")
OUT=$(test_file)
H=$(new_home)
setup_clean_env "$H"
export CLI_TOOLBOX_API_BASE="file://$FIX_GLOW/api"
cli_sandbox "$TROOT" "$OUT" install glow
assert_true "glow present before targets install" test -x "$H/bin/glow"
OUT=$(test_file)
cli_sandbox "$TROOT" "$OUT" install
assert_true "commented-out target not auto-deleted" test -x "$H/bin/glow"

OUT=$(test_file)
H=$(new_home)
setup_clean_env "$H"
cli_sandbox "$TROOT" "$OUT" list
assert_contains "list without args uses targets" "$(cat "$OUT")" "uv"
assert_not_contains "list without args omits non-target" "$(cat "$OUT")" "glow"

# ---------------------------------------------------------------------------
# AI agent installs (mocked official installers)
# ---------------------------------------------------------------------------

OUT=$(test_file)
H=$(new_home)
setup_clean_env "$H"
export CLI_TOOLBOX_API_BASE="file://$FIX_OPENCODE/api"
export CLI_TOOLBOX_AGENT_INSTALL_URL="file://$FIX_AGENT/install.sh"
export CLI_TOOLBOX_CLAUDE_INSTALL_URL="file://$FIX_CLAUDE/install.sh"
cli "$OUT" install opencode agent claude
assert_contains_re "opencode install" "$(cat "$OUT")" 'opencode[[:space:]]+installed'
assert_contains_re "agent install" "$(cat "$OUT")" 'agent \(Cursor Agent CLI\)[[:space:]]+installed'
assert_contains_re "claude install" "$(cat "$OUT")" 'claude[[:space:]]+installed'
assert_true "agent binary exists" test -x "$H/.local/bin/agent"
assert_true "claude binary exists" test -x "$H/.local/bin/claude"

OUT=$(test_file)
H=$(new_home)
setup_clean_env "$H"
export CLI_TOOLBOX_CODEX_INSTALL_URL="file://$FIX_CODEX/install.sh"
export CLI_TOOLBOX_AGY_INSTALL_URL="file://$FIX_AGY/install.sh"
cli "$OUT" install codex agy
assert_contains_re "codex install" "$(cat "$OUT")" 'codex[[:space:]]+installed'
assert_contains_re "agy install" "$(cat "$OUT")" 'agy[[:space:]]+installed'
assert_true "codex binary exists" test -x "$H/bin/codex"
assert_true "agy binary exists" test -x "$H/bin/agy"

OUT=$(test_file)
H=$(new_home)
setup_clean_env "$H"
export CLI_TOOLBOX_AGENT_INSTALL_URL="file://$FIX_AGENT/install.sh"
cli "$OUT" install agent
OUT=$(test_file)
cli "$OUT" delete agent
assert_contains_re "delete managed agent" "$(cat "$OUT")" 'agent \(Cursor Agent CLI\)[[:space:]]+deleted'
assert_true "agent removed after delete" test ! -e "$H/.local/bin/agent"

FAIL_KEEP=$(
    H=$(new_home)
    export CLI_TOOLBOX_HOME="$H"
    export TB_OS=linux TB_ARCH=amd64
    export CLI_TOOLBOX_API_BASE="file://$FIX_GLOW/api"
    source_libs
    make_bin "$H/bin/glow" 'echo "glow version 9.9.9"'
    manifest_record glow release-binary 9.9.9 "$H/bin/glow"
    github_release_json() { return 1; }
    install_glow
    printf 'state=%s ver=%s\n' "$TB_STATE" "$("$H/bin/glow" --version)"
)
assert_contains "update failure keeps glow" "$FAIL_KEEP" "state=error"
assert_contains "glow version preserved" "$FAIL_KEEP" "9.9.9"

# ---------------------------------------------------------------------------
# delete
# ---------------------------------------------------------------------------

OUT=$(test_file)
H=$(new_home)
setup_clean_env "$H"
export CLI_TOOLBOX_API_BASE="file://$FIX_GLOW/api"
cli "$OUT" install glow
assert_true "glow installed before delete" test -x "$H/bin/glow"
OUT=$(test_file)
cli "$OUT" delete glow
assert_contains_re "delete glow" "$(cat "$OUT")" 'glow[[:space:]]+deleted'
assert_true "glow removed after delete" test ! -e "$H/bin/glow"

SKIP_DEL=$(
    H=$(new_home)
    export CLI_TOOLBOX_HOME="$H"
    source_libs
    _delete_release_binary glow
    printf '%s\n' "$TB_STATE"
)
assert_contains "delete uninstalled glow skipped" "$SKIP_DEL" "skipped-not-managed"

GCLOUD_DEL=$(
    H=$(new_home)
    export CLI_TOOLBOX_HOME="$H"
    export TB_OS=linux TB_ARCH=amd64
    source_libs
    http_get() { cat "$FIX_GCLOUD/dl/google/dl/cloudsdk/channels/rapid/components-2.json"; }
    download_file() { cp "$FIX_GCLOUD/assets/google-cloud-cli-502.0.0-linux-x86_64.tar.gz" "$2"; }
    install_gcloud
    _delete_gcloud
    printf 'state=%s sdk=%s\n' "$TB_STATE" "$([ -d "$H/tools/google-cloud-sdk" ] && echo yes || echo no)"
)
assert_contains "delete gcloud" "$GCLOUD_DEL" "state=deleted"
assert_contains "delete gcloud removes sdk" "$GCLOUD_DEL" "sdk=no"

OUT=$(test_file)
H=$(new_home)
setup_clean_env "$H"
cli "$OUT" install uv tccli
OUT=$(test_file)
cli "$OUT" delete tccli
assert_contains_re "delete tccli" "$(cat "$OUT")" 'tccli[[:space:]]+deleted'
assert_true "tccli removed" test ! -x "$H/.local/bin/tccli"

printf '\nTest summary: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
