#!/usr/bin/env bash
# tests/test.sh — offline test suite for cli-toolbox (uv-tool / apt provider model)
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
TOOL_STATE="\${CLOUD_TOOLBOX_HOME:-\$HOME}/.mock-uv-tool-state"
TOOL_BIN="\${UV_TOOL_BIN_DIR:-\$HOME/.local/bin}"
case "\$1" in
  tool)
    case "\$2" in
      list)
        [ -f "\$TOOL_STATE/tccli" ] && { echo "tccli v3.1.165.1"; echo "- tccli"; }
        ;;
      install)
        mkdir -p "\$TOOL_BIN" "\$(dirname "\$TOOL_STATE")"
        printf '%s\n' '#!/bin/sh' 'echo 3.1.165.1' > "\$TOOL_BIN/tccli"
        chmod +x "\$TOOL_BIN/tccli"
        touch "\$TOOL_STATE/tccli"
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

make_cloud_cli_fixture() {
    local base="$1"
    mkdir -p "$base/aws-cli/bin" "$base/g-cli/bin" "$base/tc-cli/bin"
    make_bin "$base/aws-cli/bin/awst" 'echo wrapper'
    make_bin "$base/g-cli/bin/gcloudt" 'echo wrapper'
    make_bin "$base/tc-cli/bin/tcclit" 'echo wrapper'
}

FIX_GLOW=$(test_tmp); make_glow_fixture "$FIX_GLOW" 3.0.0
FIX_COSCLI=$(test_tmp); make_coscli_fixture "$FIX_COSCLI" 1.0.9
FIX_UV_REL=$(test_tmp); make_uv_release_fixture "$FIX_UV_REL" 0.12.12
FIX_UV_INST=$(test_tmp); make_uv_installer_fixture "$FIX_UV_INST" 0.12.12
FIX_PYPI=$(test_tmp); make_pypi_fixture "$FIX_PYPI" tccli 3.1.165.1
FIX_AWS=$(test_tmp); make_aws_fixture "$FIX_AWS" 2.36.42
FIX_CLOUD=$(test_tmp); make_cloud_cli_fixture "$FIX_CLOUD"

new_home() { test_tmp; }

setup_clean_env() {
    local H="$1"
    export CLOUD_TOOLBOX_HOME="$H"
    export CLOUD_TOOLBOX_API_BASE="file://$FIX_UV_REL/api"
    export CLOUD_TOOLBOX_PYPI_BASE="file://$FIX_PYPI/pypi"
    export CLOUD_TOOLBOX_UV_INSTALL_URL="file://$FIX_UV_INST/install.sh"
    export UV_TOOL_BIN_DIR="$H/.local/bin"
    export CLOUD_CLI_REPO="$FIX_CLOUD"
    mkdir -p "$H/bin" "$H/.local/bin"
    export PATH="$H/bin:$H/.local/bin:$PATH"
    unset GITHUB_TOKEN CLOUD_TOOLBOX_CURL
}

# Mock apt layer for offline tests (injected via env functions in subshell tests).
mock_apt_state() {
    local root="$1"
    mkdir -p "$root/var/lib/dpkg" "$root/usr/bin"
    printf '' >"$root/state.tsv"
}

# ---------------------------------------------------------------------------
# unit: version_gt / extract / atomic
# ---------------------------------------------------------------------------

VG_OUT=$(
    # shellcheck source=lib/common.sh
    . "$TBROOT/lib/common.sh"
    version_gt 2.1.0 2.0.9 && echo ok-gt
    version_gt 1.0.0-beta 1.0.0; echo rc=$?
)
assert_contains "version_gt basic" "$VG_OUT" "ok-gt"
assert_not_contains "version_gt prerelease no integer error" "$VG_OUT" "integer expression expected"

# ---------------------------------------------------------------------------
# list: pipx absent, PROVIDER column, az requires-root/missing
# ---------------------------------------------------------------------------

OUT=$(test_file)
H=$(new_home)
setup_clean_env "$H"
cli "$OUT" list
assert_not_contains "list: pipx not shown" "$(cat "$OUT")" "pipx"
assert_contains "list: PROVIDER header" "$(cat "$OUT")" "PROVIDER"
assert_contains "list: tccli provider uv-tool policy" "$(cat "$OUT")" "tccli"
assert_contains "list: az row present" "$(cat "$OUT")" "az"

OUT=$(test_file)
AZ_OUT=$(
    export CLOUD_TOOLBOX_HOME="$H"
    # shellcheck source=lib/common.sh
    . "$TBROOT/lib/common.sh"
    # shellcheck source=lib/providers.sh
    . "$TBROOT/lib/providers.sh"
    # shellcheck source=lib/installers.sh
    . "$TBROOT/lib/installers.sh"
    has_apt() { return 0; }
    can_sudo() { return 1; }
    apt_installed_version() { [ "$1" = "azure-cli" ] && return 0; printf '%s' ""; }
    apt_candidate_version() { printf '%s' "2.77.0"; }
    inspect_cli az
    printf '%s %s %s\n' "$TB_LIST_STATUS" "$TB_LIST_PROVIDER" "$TB_LIST_STATE"
)
assert_contains "az without sudo: requires-root" "$AZ_OUT" "requires-root"
assert_contains "az without sudo: official-package" "$AZ_OUT" "official-package"

AZ_SYS=$(
    export CLOUD_TOOLBOX_HOME="$H"
    # shellcheck source=lib/common.sh
    . "$TBROOT/lib/common.sh"
    # shellcheck source=lib/providers.sh
    . "$TBROOT/lib/providers.sh"
    # shellcheck source=lib/installers.sh
    . "$TBROOT/lib/installers.sh"
    has_apt() { return 0; }
    can_sudo() { return 0; }
    apt_installed_version() { [ "$1" = "azure-cli" ] && printf '%s' "2.76.0"; }
    apt_candidate_version() { printf '%s' "2.76.0"; }
    command() {
        if [ "$1" = "-v" ] && [ "$2" = "az" ]; then printf '%s\n' "/usr/bin/az"; return 0; fi
        builtin command "$@"
    }
    _parse_version() { [ "$1" = "az" ] && printf '%s' "2.76.0"; }
    inspect_cli az
    printf '%s %s\n' "$TB_LIST_STATUS" "$TB_LIST_PROVIDER"
)
assert_contains "az installed: system status" "$AZ_SYS" "system"

# ---------------------------------------------------------------------------
# install uv + tccli via uv tool; idempotent re-run
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
assert_true "command -v tccli" command -v tccli
assert_contains "tccli path under UV_TOOL_BIN_DIR" "$(command -v tccli)" "$H/.local/bin/tccli"

OUT=$(test_file)
cli "$OUT" install tccli
assert_contains_re "tccli unchanged" "$(cat "$OUT")" 'tccli[[:space:]]+unchanged'

# ---------------------------------------------------------------------------
# migration-available when system tccli exists elsewhere
# ---------------------------------------------------------------------------

MIG=$(
    H=$(new_home)
    SYSBIN=$(test_tmp)
    make_bin "$SYSBIN/tccli" 'echo 9.9.9'
    export CLOUD_TOOLBOX_HOME="$H"
    export UV_TOOL_BIN_DIR="$H/.local/bin"
    PATH="$H/bin:$H/.local/bin:$SYSBIN:$PATH"
    # shellcheck source=lib/common.sh
    . "$TBROOT/lib/common.sh"
    # shellcheck source=lib/providers.sh
    . "$TBROOT/lib/providers.sh"
    # shellcheck source=lib/installers.sh
    . "$TBROOT/lib/installers.sh"
    uv_tool_list_packages() { return 0; }
    uv_tool_executable_path() { return 1; }
    inspect_cli tccli
    printf '%s\n' "$TB_LIST_STATE"
)
assert_contains "tccli migration-available" "$MIG" "migration-available"

# ---------------------------------------------------------------------------
# glow / coscli release-binary still work
# ---------------------------------------------------------------------------

OUT=$(test_file)
H=$(new_home)
setup_clean_env "$H"
export CLOUD_TOOLBOX_API_BASE="file://$FIX_GLOW/api"
cli "$OUT" install glow
assert_contains_re "glow install" "$(cat "$OUT")" 'glow[[:space:]]+installed'

OUT=$(test_file)
H=$(new_home)
setup_clean_env "$H"
export CLOUD_TOOLBOX_API_BASE="file://$FIX_COSCLI/api"
cli "$OUT" install coscli
assert_contains_re "coscli install" "$(cat "$OUT")" 'coscli[[:space:]]+installed'

# ---------------------------------------------------------------------------
# aws official installer (function-level)
# ---------------------------------------------------------------------------

AWS_OUT=$(
    H=$(new_home)
    export CLOUD_TOOLBOX_HOME="$H"
    # shellcheck source=lib/common.sh
    . "$TBROOT/lib/common.sh"
    # shellcheck source=lib/providers.sh
    . "$TBROOT/lib/providers.sh"
    # shellcheck source=lib/installers.sh
    . "$TBROOT/lib/installers.sh"
    http_get() { [ "$1" = "https://awscli.amazonaws.com/v2/version.txt" ] && cat "$FIX_AWS/version.txt"; return 1; }
    download_file() { cp "$FIX_AWS/awscli.zip" "$2"; }
    install_aws
    printf 'state=%s ver=%s\n' "$TB_STATE" "$(get_installed_version aws)"
)
assert_contains "aws installs" "$AWS_OUT" "state=installed"
assert_contains "aws version" "$AWS_OUT" "ver=2.36.42"

# ---------------------------------------------------------------------------
# wrappers from CLOUD_CLI_REPO
# ---------------------------------------------------------------------------

OUT=$(test_file)
H=$(new_home)
setup_clean_env "$H"
make_bin "$H/bin/aws" 'echo aws-cli/2.0.0'
make_bin "$H/bin/gcloud" 'echo Google Cloud SDK 1.0.0'
make_bin "$H/.local/bin/tccli" 'echo 3.0.0'
export PATH="$H/bin:$H/.local/bin:$PATH"
cli "$OUT" install awst gcloudt tcclit
assert_contains_re "awst wrapper" "$(cat "$OUT")" 'awst[[:space:]]+installed'
assert_contains_re "gcloudt wrapper" "$(cat "$OUT")" 'gcloudt[[:space:]]+installed'
assert_contains_re "tcclit wrapper" "$(cat "$OUT")" 'tcclit[[:space:]]+installed'
assert_true "awst symlink" test -L "$H/bin/awst"

# ---------------------------------------------------------------------------
# system CLI not removed: installing glow keeps external gh
# ---------------------------------------------------------------------------

OUT=$(test_file)
H=$(new_home)
SYS=$(test_tmp)
make_bin "$SYS/gh" 'echo gh version 9.9.9'
setup_clean_env "$H"
export PATH="$SYS:$PATH"
export CLOUD_TOOLBOX_API_BASE="file://$FIX_GLOW/api"
cli "$OUT" install glow
assert_contains "system gh still runs" "$("$SYS/gh" --version)" "9.9.9"
assert_true "system gh still exists" test -x "$SYS/gh"

# ---------------------------------------------------------------------------
# list after install shows managed + provider
# ---------------------------------------------------------------------------

OUT=$(test_file)
H=$(new_home)
setup_clean_env "$H"
cli "$OUT" install uv tccli
OUT=$(test_file)
cli "$OUT" list tccli uv
assert_contains_re "list tccli managed" "$(cat "$OUT")" 'tccli[[:space:]]+managed'
assert_contains "list tccli uv-tool provider" "$(cat "$OUT")" "uv-tool"
assert_contains "list uv official-installer" "$(cat "$OUT")" "official-installer"

# ---------------------------------------------------------------------------
# help / executable
# ---------------------------------------------------------------------------

assert_true "cli-toolbox.sh executable" test -x "$TBROOT/cli-toolbox.sh"
OUT=$(test_file)
H=$(new_home)
setup_clean_env "$H"
cli "$OUT" help
assert_contains "help shows standard set" "$(cat "$OUT")" "tccli"

printf '\nTest summary: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
