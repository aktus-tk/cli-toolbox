#!/usr/bin/env bash
# tests/test.sh — offline test suite for cli-toolbox
#
# Run: bash tests/test.sh
#
# Guarantees:
#   * fully offline (file:// fixtures + mock curl; no real network)
#   * never touches the real $HOME (each test uses its own temp
#     CLOUD_TOOLBOX_HOME)
#
# Mockability hooks exercised here:
#   CLOUD_TOOLBOX_API_BASE  -> file:// fixture with fake releases/latest JSON
#   CLOUD_TOOLBOX_PYPI_BASE -> file:// fixture with fake PyPI JSON + wheel
#   CLOUD_TOOLBOX_CURL      -> mock curl scripts (HTTP-error scenarios)
#   sourcing lib/*.sh and overriding functions (extract_archive, aws/gcloud)

set -u

TESTDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TBROOT="$(dirname "$TESTDIR")"

PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); printf 'PASS: %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL: %s\n' "$1"; }

# ---------------------------------------------------------------------------
# temp tracking: everything the suite creates under /tmp is registered here
# and removed on EXIT/INT/TERM, so a full run leaves no leftovers. The
# registry is a FILE because most call sites use command substitution
# (e.g. OUT=$(test_file)), which would discard an in-memory array append.
# ---------------------------------------------------------------------------

__TEST_REG=$(mktemp)

test_tmp() { # mktemp -d registered for cleanup
    local d
    d=$(mktemp -d) || return 1
    printf '%s\n' "$d" >>"$__TEST_REG"
    printf '%s\n' "$d"
}

test_file() { # mktemp file registered for cleanup
    local f
    f=$(mktemp) || return 1
    printf '%s\n' "$f" >>"$__TEST_REG"
    printf '%s\n' "$f"
}

test_cleanup() {
    local p
    if [ -f "$__TEST_REG" ]; then
        while IFS= read -r p; do
            [ -n "$p" ] && rm -rf -- "$p"
        done <"$__TEST_REG"
        rm -f -- "$__TEST_REG"
    fi
}

trap test_cleanup EXIT INT TERM

# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------

# cli <outfile> <args...>: run the real binary with the current exported env.
cli() {
    local out="$1"
    shift
    "$TBROOT/cli-toolbox" "$@" >"$out" 2>&1
    CLI_RC=$?
}

assert_contains() {
    local desc="$1" hay="$2" needle="$3"
    if printf '%s' "$hay" | grep -qF -- "$needle"; then
        pass "$desc"
    else
        fail "$desc (missing: $needle)"
    fi
}

assert_contains_re() {
    local desc="$1" hay="$2" regex="$3"
    if printf '%s' "$hay" | grep -qE -- "$regex"; then
        pass "$desc"
    else
        fail "$desc (regex not matched: $regex)"
    fi
}

assert_not_contains() {
    local desc="$1" hay="$2" needle="$3"
    if printf '%s' "$hay" | grep -qF -- "$needle"; then
        fail "$desc (found forbidden: $needle)"
    else
        pass "$desc"
    fi
}

assert_true() {
    local desc="$1"
    shift
    if "$@" >/dev/null 2>&1; then
        pass "$desc"
    else
        fail "$desc"
    fi
}

# ---------------------------------------------------------------------------
# fixture builders (file:// based; no network)
# ---------------------------------------------------------------------------

make_tarball() { # <srcdir> <tarball> <relname...>
    local srcdir="$1" tarball="$2"
    shift 2
    tar -C "$srcdir" -czf "$tarball" "$@"
}

make_bin() { # <path> <body...>
    local path="$1"
    shift
    printf '#!/bin/sh\n%s\n' "$*" >"$path"
    chmod +x "$path"
}

# make_wheel <out.whl> <pkg> <ver>: self-contained py3-none-any wheel with a
# console script <pkg> that prints <ver>.
make_wheel() {
    local out="$1" pkg="$2" ver="$3"
    local wdir
    wdir=$(test_tmp)
    mkdir -p "$wdir/${pkg}-${ver}.dist-info" "$wdir/$pkg"
    printf 'Wheel-Version: 1.0\nGenerator: cli-toolbox-test\nRoot-Is-Purelib: true\nTag: py3-none-any\n' \
        >"$wdir/${pkg}-${ver}.dist-info/WHEEL"
    printf 'Metadata-Version: 2.1\nName: %s\nVersion: %s\n' "$pkg" "$ver" \
        >"$wdir/${pkg}-${ver}.dist-info/METADATA"
    printf '[console_scripts]\n%s = %s.cli:main\n' "$pkg" "$pkg" \
        >"$wdir/${pkg}-${ver}.dist-info/entry_points.txt"
    printf 'def main():\n    print("%s")\n' "$ver" >"$wdir/$pkg/cli.py"
    : >"$wdir/$pkg/__init__.py"
    python3 - "$wdir" "$out" "${pkg}-${ver}" <<'PY'
import sys, zipfile, os, hashlib, base64
src, dst, dist = sys.argv[1], sys.argv[2], sys.argv[3]
lines = []
for root, dirs, files in os.walk(src):
    for f in files:
        p = os.path.join(root, f)
        arc = os.path.relpath(p, src)
        b64 = base64.urlsafe_b64encode(hashlib.sha256(open(p, 'rb').read()).digest()).rstrip(b'=').decode()
        lines.append(f"{arc},sha256={b64},{os.path.getsize(p)}")
lines.append(f"{dist}.dist-info/RECORD,,")
with open(os.path.join(src, f"{dist}.dist-info", "RECORD"), "w") as fh:
    fh.write("\n".join(lines) + "\n")
with zipfile.ZipFile(dst, 'w', zipfile.ZIP_DEFLATED) as z:
    for root, dirs, files in os.walk(src):
        for f in files:
            p = os.path.join(root, f)
            z.write(p, os.path.relpath(p, src))
PY
}

# make_gh_fixture <base> <ver>
make_gh_fixture() {
    local base="$1" ver="$2"
    local root="$base/assets/root"
    mkdir -p "$root/gh_${ver}_linux_amd64/bin"
    make_bin "$root/gh_${ver}_linux_amd64/bin/gh" "echo \"gh version ${ver} (test)\""
    make_tarball "$root" "$base/assets/gh_${ver}_linux_amd64.tar.gz" "gh_${ver}_linux_amd64"
    local hash
    hash=$(sha256sum "$base/assets/gh_${ver}_linux_amd64.tar.gz" | awk '{print $1}')
    printf '%s  %s\n' "$hash" "gh_${ver}_linux_amd64.tar.gz" >"$base/assets/gh_${ver}_checksums.txt"
    mkdir -p "$base/api/repos/cli/cli/releases"
    cat >"$base/api/repos/cli/cli/releases/latest" <<EOF
{"tag_name": "v${ver}", "name": "GitHub CLI ${ver}", "assets": [
 {"name": "gh_${ver}_linux_amd64.tar.gz", "browser_download_url": "file://$base/assets/gh_${ver}_linux_amd64.tar.gz"},
 {"name": "gh_${ver}_checksums.txt", "browser_download_url": "file://$base/assets/gh_${ver}_checksums.txt"}]}
EOF
}

# make_glow_fixture <base> <ver>: mirrors the REAL release layout where the
# binary is nested in a version-named top dir: glow_<V>_Linux_x86_64/glow
make_glow_fixture() {
    local base="$1" ver="$2"
    local root="$base/assets/root"
    mkdir -p "$root/glow_${ver}_Linux_x86_64"
    make_bin "$root/glow_${ver}_Linux_x86_64/glow" "echo \"glow version ${ver} (abc123)\""
    make_tarball "$root" "$base/assets/glow_${ver}_Linux_x86_64.tar.gz" "glow_${ver}_Linux_x86_64"
    local hash
    hash=$(sha256sum "$base/assets/glow_${ver}_Linux_x86_64.tar.gz" | awk '{print $1}')
    printf '%s  %s\n' "$hash" "glow_${ver}_Linux_x86_64.tar.gz" >"$base/assets/checksums.txt"
    mkdir -p "$base/api/repos/charmbracelet/glow/releases"
    cat >"$base/api/repos/charmbracelet/glow/releases/latest" <<EOF
{"tag_name": "v${ver}", "name": "Glow ${ver}", "assets": [
 {"name": "glow_${ver}_Linux_x86_64.tar.gz", "browser_download_url": "file://$base/assets/glow_${ver}_Linux_x86_64.tar.gz"},
 {"name": "checksums.txt", "browser_download_url": "file://$base/assets/checksums.txt"}]}
EOF
}

# make_glow_fixture_root <base> <ver>: older layout with the binary at the
# archive root (glow), to prove both layouts are supported.
make_glow_fixture_root() {
    local base="$1" ver="$2"
    local root="$base/assets/root"
    mkdir -p "$root"
    make_bin "$root/glow" "echo \"glow version ${ver} (root-layout)\""
    make_tarball "$root" "$base/assets/glow_${ver}_Linux_x86_64.tar.gz" "glow"
    local hash
    hash=$(sha256sum "$base/assets/glow_${ver}_Linux_x86_64.tar.gz" | awk '{print $1}')
    printf '%s  %s\n' "$hash" "glow_${ver}_Linux_x86_64.tar.gz" >"$base/assets/checksums.txt"
    mkdir -p "$base/api/repos/charmbracelet/glow/releases"
    cat >"$base/api/repos/charmbracelet/glow/releases/latest" <<EOF
{"tag_name": "v${ver}", "name": "Glow ${ver}", "assets": [
 {"name": "glow_${ver}_Linux_x86_64.tar.gz", "browser_download_url": "file://$base/assets/glow_${ver}_Linux_x86_64.tar.gz"},
 {"name": "checksums.txt", "browser_download_url": "file://$base/assets/checksums.txt"}]}
EOF
}

# make_coscli_fixture <base> <ver>
make_coscli_fixture() {
    local base="$1" ver="$2"
    local root="$base/assets/root"
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

# make_uv_fixture <base> <ver> (tag has NO v prefix): mirrors the REAL release
# layout where uv+uvx are nested in a target-named top dir:
# uv-x86_64-unknown-linux-gnu/{uv,uvx}
make_uv_fixture() {
    local base="$1" ver="$2"
    local root="$base/assets/root"
    mkdir -p "$root/uv-x86_64-unknown-linux-gnu"
    make_bin "$root/uv-x86_64-unknown-linux-gnu/uv" "echo \"uv ${ver} (abcdef 2026-01-01)\""
    make_bin "$root/uv-x86_64-unknown-linux-gnu/uvx" "echo \"uvx ${ver}\""
    make_tarball "$root" "$base/assets/uv-x86_64-unknown-linux-gnu.tar.gz" "uv-x86_64-unknown-linux-gnu"
    local hash
    hash=$(sha256sum "$base/assets/uv-x86_64-unknown-linux-gnu.tar.gz" | awk '{print $1}')
    printf '%s  %s\n' "$hash" "uv-x86_64-unknown-linux-gnu.tar.gz" \
        >"$base/assets/uv-x86_64-unknown-linux-gnu.tar.gz.sha256"
    mkdir -p "$base/api/repos/astral-sh/uv/releases"
    cat >"$base/api/repos/astral-sh/uv/releases/latest" <<EOF
{"tag_name": "${ver}", "name": "uv ${ver}", "assets": [
 {"name": "uv-x86_64-unknown-linux-gnu.tar.gz", "browser_download_url": "file://$base/assets/uv-x86_64-unknown-linux-gnu.tar.gz"},
 {"name": "uv-x86_64-unknown-linux-gnu.tar.gz.sha256", "browser_download_url": "file://$base/assets/uv-x86_64-unknown-linux-gnu.tar.gz.sha256"}]}
EOF
}

# make_uv_fixture_root <base> <ver>: older layout with uv and uvx at the
# archive root, to prove both layouts are supported.
make_uv_fixture_root() {
    local base="$1" ver="$2"
    local root="$base/assets/root"
    mkdir -p "$root"
    make_bin "$root/uv" "echo \"uv ${ver} (root-layout)\""
    make_bin "$root/uvx" "echo \"uvx ${ver}\""
    make_tarball "$root" "$base/assets/uv-x86_64-unknown-linux-gnu.tar.gz" "uv" "uvx"
    local hash
    hash=$(sha256sum "$base/assets/uv-x86_64-unknown-linux-gnu.tar.gz" | awk '{print $1}')
    printf '%s  %s\n' "$hash" "uv-x86_64-unknown-linux-gnu.tar.gz" \
        >"$base/assets/uv-x86_64-unknown-linux-gnu.tar.gz.sha256"
    mkdir -p "$base/api/repos/astral-sh/uv/releases"
    cat >"$base/api/repos/astral-sh/uv/releases/latest" <<EOF
{"tag_name": "${ver}", "name": "uv ${ver}", "assets": [
 {"name": "uv-x86_64-unknown-linux-gnu.tar.gz", "browser_download_url": "file://$base/assets/uv-x86_64-unknown-linux-gnu.tar.gz"},
 {"name": "uv-x86_64-unknown-linux-gnu.tar.gz.sha256", "browser_download_url": "file://$base/assets/uv-x86_64-unknown-linux-gnu.tar.gz.sha256"}]}
EOF
}

# make_pypi_fixture <base> <pkg> <ver>
make_pypi_fixture() {
    local base="$1" pkg="$2" ver="$3"
    mkdir -p "$base/pypi/pypi/$pkg"
    make_wheel "$base/pypi/pypi/$pkg/${pkg}-${ver}-py3-none-any.whl" "$pkg" "$ver"
    local hash
    hash=$(sha256sum "$base/pypi/pypi/$pkg/${pkg}-${ver}-py3-none-any.whl" | awk '{print $1}')
    cat >"$base/pypi/pypi/$pkg/json" <<EOF
{"info": {"name": "$pkg", "version": "$ver"}, "last_serial": 1, "urls": [
 {"filename": "${pkg}-${ver}-py3-none-any.whl", "url": "file://$base/pypi/pypi/$pkg/${pkg}-${ver}-py3-none-any.whl", "digests": {"sha256": "$hash"}}]}
EOF
}

# make_aws_fixture <base> <ver>: fake official installer zip
make_aws_fixture() {
    local base="$1" ver="$2"
    local root="$base/awsroot"
    mkdir -p "$root/aws/dist"
    cat >"$root/aws/install" <<EOF
#!/bin/sh
# fake aws installer for tests
install_dir=""
bin_dir=""
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
    python3 - "$root" "$base/awscli-exe-linux-x86_64.zip" <<'PY'
import sys, zipfile, os
src, dst = sys.argv[1], sys.argv[2]
with zipfile.ZipFile(dst, 'w', zipfile.ZIP_DEFLATED) as z:
    for root, dirs, files in os.walk(src):
        for f in files:
            p = os.path.join(root, f)
            z.write(p, os.path.relpath(p, src))
PY
    printf '2.36.42\n' >"$base/version.txt"
}

# make_gcloud_fixture <base> <ver>: fake google-cloud-cli tarball + manifest
make_gcloud_fixture() {
    local base="$1" ver="$2"
    local root="$base/gcloudroot"
    mkdir -p "$root/google-cloud-sdk/bin"
    make_bin "$root/google-cloud-sdk/bin/gcloud" "echo \"Google Cloud SDK ${ver}\""
    make_tarball "$root" "$base/google-cloud-cli-${ver}-linux-x86_64.tar.gz" "google-cloud-sdk"
    cat >"$base/components-2.json" <<EOF
{"version": "${ver}", "components": [{"id": "core", "version": "${ver}"}]}
EOF
}

# ---------------------------------------------------------------------------
# mock curl scripts
# ---------------------------------------------------------------------------

make_mock_curl_fail() { # always fails
    local out="$1"
    cat >"$out" <<'EOF'
#!/bin/sh
exit 1
EOF
    chmod +x "$out"
}

make_mock_curl_download_fail() { # fails URLs containing /assets/ (i.e. downloads)
    local out="$1"
    cat >"$out" <<'EOF'
#!/bin/sh
for arg in "$@"; do
    case "$arg" in
        */assets/*) exit 1 ;;
    esac
done
exec /usr/bin/curl "$@"
EOF
    chmod +x "$out"
}

make_mock_curl_fail_cloud() { # fails AWS/Google endpoints only
    local out="$1"
    cat >"$out" <<'EOF'
#!/bin/sh
for arg in "$@"; do
    case "$arg" in
        *awscli.amazonaws.com* | *dl.google.com*) exit 1 ;;
    esac
done
exec /usr/bin/curl "$@"
EOF
    chmod +x "$out"
}

make_mock_curl_ratelimit() { # returns a GitHub rate-limit body with exit 0
    local out="$1"
    cat >"$out" <<'EOF'
#!/bin/sh
printf '%s\n' '{"message": "API rate limit exceeded for 1.2.3.4. (But here'"'"'s the good news: Authenticated requests get a higher rate limit.)"}'
exit 0
EOF
    chmod +x "$out"
}

make_mock_curl_capture() { # records all invocations, then behaves like curl
    local out="$1" capture="$2"
    cat >"$out" <<EOF
#!/bin/sh
printf '%s\n' "\$@" >> "$capture"
exec /usr/bin/curl "\$@"
EOF
    chmod +x "$out"
}

# ---------------------------------------------------------------------------
# fixtures (shared)
# ---------------------------------------------------------------------------

FIX_GH=$(test_tmp)
make_gh_fixture "$FIX_GH" 2.80.0

FIX_GH_OLD=$(test_tmp)
make_gh_fixture "$FIX_GH_OLD" 2.79.0

FIX_GH_NEW=$(test_tmp)
make_gh_fixture "$FIX_GH_NEW" 2.81.0

FIX_GH_BADSUM=$(test_tmp)
make_gh_fixture "$FIX_GH_BADSUM" 2.81.0
printf '%s  %s\n' "0000000000000000000000000000000000000000000000000000000000000000" \
    "gh_2.81.0_linux_amd64.tar.gz" >"$FIX_GH_BADSUM/assets/gh_2.81.0_checksums.txt"

FIX_GLOW=$(test_tmp)
make_glow_fixture "$FIX_GLOW" 3.0.0

FIX_GLOW_ROOT=$(test_tmp)
make_glow_fixture_root "$FIX_GLOW_ROOT" 3.0.0

FIX_COSCLI=$(test_tmp)
make_coscli_fixture "$FIX_COSCLI" 1.0.9

FIX_COSCLI_BADSUM=$(test_tmp)
make_coscli_fixture "$FIX_COSCLI_BADSUM" 1.1.0
printf '%s  %s\n' "0000000000000000000000000000000000000000000000000000000000000000" \
    "coscli-v1.1.0-linux-amd64" >"$FIX_COSCLI_BADSUM/assets/sha256sum.log"

FIX_UV=$(test_tmp)
make_uv_fixture "$FIX_UV" 0.12.12

FIX_UV_ROOT=$(test_tmp)
make_uv_fixture_root "$FIX_UV_ROOT" 0.12.12

FIX_UV_BADSUM=$(test_tmp)
make_uv_fixture "$FIX_UV_BADSUM" 0.13.0
printf '%s  %s\n' "0000000000000000000000000000000000000000000000000000000000000000" \
    "uv-x86_64-unknown-linux-gnu.tar.gz" >"$FIX_UV_BADSUM/assets/uv-x86_64-unknown-linux-gnu.tar.gz.sha256"

FIX_PYPIX=$(test_tmp)
make_pypi_fixture "$FIX_PYPIX" pipx 1.17.2

# Compact JSON (no space after colons) with TWO releases; the OLD version's
# wheel appears first in the document. The pre-fix parser grabbed the first
# "url"/"sha256" in the whole document and therefore selected the WRONG wheel;
# the fixed parser must pick the 1.17.2 wheel from the correct release.
FIX_PYPIX_COMPACT=$(test_tmp)
make_pypi_fixture_compact() {
    local base="$1" pkg="$2" ver="$3" oldver="$4"
    mkdir -p "$base/pypi/pypi/$pkg"
    make_wheel "$base/pypi/pypi/$pkg/${pkg}-${oldver}-py3-none-any.whl" "$pkg" "$oldver"
    make_wheel "$base/pypi/pypi/$pkg/${pkg}-${ver}-py3-none-any.whl" "$pkg" "$ver"
    local oldhash newhash
    oldhash=$(sha256sum "$base/pypi/pypi/$pkg/${pkg}-${oldver}-py3-none-any.whl" | awk '{print $1}')
    newhash=$(sha256sum "$base/pypi/pypi/$pkg/${pkg}-${ver}-py3-none-any.whl" | awk '{print $1}')
    cat >"$base/pypi/pypi/$pkg/json" <<EOF
{"info":{"name":"$pkg","version":"$ver"},"last_serial":2,"releases":{"$oldver":[{"filename":"${pkg}-${oldver}-py3-none-any.whl","url":"file://$base/pypi/pypi/$pkg/${pkg}-${oldver}-py3-none-any.whl","digests":{"sha256":"$oldhash"}}],"$ver":[{"filename":"${pkg}-${ver}-py3-none-any.whl","url":"file://$base/pypi/pypi/$pkg/${pkg}-${ver}-py3-none-any.whl","digests":{"sha256":"$newhash"}}]},"urls":[{"filename":"${pkg}-${ver}-py3-none-any.whl","url":"file://$base/pypi/pypi/$pkg/${pkg}-${ver}-py3-none-any.whl","digests":{"sha256":"$newhash"}}]}
EOF
}
make_pypi_fixture_compact "$FIX_PYPIX_COMPACT" pipx 1.17.2 1.17.1

FIX_TC_CLI=$(test_tmp)
make_pypi_fixture "$FIX_TC_CLI" tccli 3.1.165.1

FIX_AWS=$(test_tmp)
make_aws_fixture "$FIX_AWS" 2.36.42

FIX_GCLOUD=$(test_tmp)
make_gcloud_fixture "$FIX_GCLOUD" 584.0.0

FIX_ALL=$(test_tmp)
make_gh_fixture "$FIX_ALL" 2.80.0
make_glow_fixture "$FIX_ALL" 3.0.0
make_coscli_fixture "$FIX_ALL" 1.0.9
make_uv_fixture "$FIX_ALL" 0.12.12
make_pypi_fixture "$FIX_ALL" pipx 1.17.2
make_pypi_fixture "$FIX_ALL" tccli 3.1.165.1

MOCK_FAIL=$(test_file)
make_mock_curl_fail "$MOCK_FAIL"
MOCK_DLFAIL=$(test_file)
make_mock_curl_download_fail "$MOCK_DLFAIL"
MOCK_CLOUDFAIL=$(test_file)
make_mock_curl_fail_cloud "$MOCK_CLOUDFAIL"
MOCK_RL=$(test_file)
make_mock_curl_ratelimit "$MOCK_RL"
MOCK_CAPTURE=$(test_file)
CAPTURE_FILE=$(test_file)
make_mock_curl_capture "$MOCK_CAPTURE" "$CAPTURE_FILE"

new_home() { test_tmp; }

# ===========================================================================
# 1. first install
# ===========================================================================

OUT=$(test_file)
H=$(new_home)
export CLOUD_TOOLBOX_HOME="$H"
export CLOUD_TOOLBOX_API_BASE="file://$FIX_GH/api"
cli "$OUT" install gh
assert_contains_re "T1 first install: result line" "$(cat "$OUT")" 'gh[[:space:]]+installed[[:space:]]+2\.80\.0'
assert_contains "T1 first install: apply summary" "$(cat "$OUT")" "Apply complete: 1 installed, 0 updated, 0 unchanged, 0 failed"
assert_true "T1 first install: binary exists and runs" "$H/bin/gh" --version
assert_contains "T1 first install: version parses" "$("$H/bin/gh" --version)" "2.80.0"
assert_contains "T1 first install: url shown in log" "$(cat "$OUT")" "downloading"

# ===========================================================================
# 2. re-run same version -> unchanged
# ===========================================================================

OUT=$(test_file)
cli "$OUT" install gh
assert_contains_re "T2 unchanged: result line" "$(cat "$OUT")" 'gh[[:space:]]+unchanged[[:space:]]+2\.80\.0'
assert_contains "T2 unchanged: apply summary" "$(cat "$OUT")" "Apply complete: 0 installed, 0 updated, 1 unchanged, 0 failed"

# ===========================================================================
# 3. update from old version
# ===========================================================================

OUT=$(test_file)
H=$(new_home)
export CLOUD_TOOLBOX_HOME="$H"
export CLOUD_TOOLBOX_API_BASE="file://$FIX_GH_OLD/api"
cli "$OUT" install gh
assert_contains_re "T3 update: first install old" "$(cat "$OUT")" 'gh[[:space:]]+installed[[:space:]]+2\.79\.0'
OUT=$(test_file)
export CLOUD_TOOLBOX_API_BASE="file://$FIX_GH/api"
cli "$OUT" install gh
assert_contains_re "T3 update: updated detail" "$(cat "$OUT")" 'gh[[:space:]]+updated[[:space:]]+2\.79\.0[[:space:]]+->[[:space:]]+2\.80\.0'
assert_contains "T3 update: apply summary" "$(cat "$OUT")" "Apply complete: 0 installed, 1 updated, 0 unchanged, 0 failed"

# ===========================================================================
# 4. PATH not set -> doctor WARN (with export hint)
# ===========================================================================

OUT=$(test_file)
H=$(new_home)
export CLOUD_TOOLBOX_HOME="$H"
export CLOUD_TOOLBOX_API_BASE="file://$FIX_GH/api"
cli "$OUT" doctor
assert_contains "T4 doctor PATH WARN" "$(cat "$OUT")" "WARN PATH"
assert_contains "T4 doctor export hint" "$(cat "$OUT")" "export PATH=\"$H/bin:\$PATH\""

# ===========================================================================
# 5. unsupported OS/arch -> error
# ===========================================================================

OUT=$(test_file)
H=$(new_home)
FAKEBIN=$(test_tmp)
cat >"$FAKEBIN/uname" <<'EOF'
#!/bin/sh
case "$1" in
    -s) echo "Linux" ;;
    -m) echo "sparc64" ;;
    *) exec /usr/bin/uname "$@" ;;
esac
EOF
chmod +x "$FAKEBIN/uname"
export CLOUD_TOOLBOX_HOME="$H"
export CLOUD_TOOLBOX_API_BASE="file://$FIX_GH/api"
PATH="$FAKEBIN:$PATH" cli "$OUT" install gh
assert_contains_re "T5 unsupported arch: error state" "$(cat "$OUT")" 'gh[[:space:]]+error'
assert_contains "T5 unsupported arch: message" "$(cat "$OUT")" "unsupported"
assert_true "T5 unsupported arch: non-zero exit" test "$CLI_RC" -ne 0

# ===========================================================================
# 6. HTTP error -> error, existing binary kept
# ===========================================================================

OUT=$(test_file)
H=$(new_home)
export CLOUD_TOOLBOX_HOME="$H"
export CLOUD_TOOLBOX_API_BASE="file://$FIX_GH/api"
unset CLOUD_TOOLBOX_CURL
cli "$OUT" install gh
assert_contains_re "T6 setup: gh installed" "$(cat "$OUT")" 'gh[[:space:]]+installed[[:space:]]+2\.80\.0'
OUT=$(test_file)
export CLOUD_TOOLBOX_API_BASE="file://$FIX_GH_NEW/api"
export CLOUD_TOOLBOX_CURL="$MOCK_FAIL"
cli "$OUT" install gh
assert_contains_re "T6 http error: error state" "$(cat "$OUT")" 'gh[[:space:]]+error'
assert_contains "T6 http error: summary failed" "$(cat "$OUT")" "Apply complete: 0 installed, 0 updated, 0 unchanged, 1 failed"
assert_contains "T6 http error: existing binary kept" "$("$H/bin/gh" --version)" "2.80.0"

# ===========================================================================
# 7. checksum mismatch -> error, existing binary kept
# ===========================================================================

OUT=$(test_file)
H=$(new_home)
export CLOUD_TOOLBOX_HOME="$H"
export CLOUD_TOOLBOX_API_BASE="file://$FIX_GH/api"
unset CLOUD_TOOLBOX_CURL
cli "$OUT" install gh
assert_contains_re "T7 setup: gh installed" "$(cat "$OUT")" 'gh[[:space:]]+installed[[:space:]]+2\.80\.0'
OUT=$(test_file)
export CLOUD_TOOLBOX_API_BASE="file://$FIX_GH_BADSUM/api"
cli "$OUT" install gh
assert_contains_re "T7 checksum mismatch: error state" "$(cat "$OUT")" 'gh[[:space:]]+error'
assert_contains "T7 checksum mismatch: reason" "$(cat "$OUT")" "checksum mismatch"
assert_contains "T7 checksum mismatch: existing binary kept" "$("$H/bin/gh" --version)" "2.80.0"

# ===========================================================================
EXT_HOME=$(test_tmp)
# 8. extraction failure / path traversal rejected (function-level)
# ===========================================================================

EXT=$(test_tmp)
EXT_OUT=$(
    export CLOUD_TOOLBOX_HOME="$EXT_HOME"
    # shellcheck source=lib/common.sh
    . "$TBROOT/lib/common.sh"
    mkdir -p "$EXT/src"
    printf 'pwn' >"$EXT/src/evil.txt"
    (cd "$EXT" && tar -czf "$EXT/evil-traversal.tar.gz" --transform 's|src|../evil|' src/evil.txt)
    (cd "$EXT" && tar -czf "$EXT/abs.tar.gz" -P --transform 's|src|/evil|' src/evil.txt)
    printf 'this is not a real archive' >"$EXT/bad.tar.gz"
    python3 - "$EXT" <<'PY'
import sys, zipfile
base = sys.argv[1]
with zipfile.ZipFile(f"{base}/zip-traversal.zip", "w") as z:
    z.writestr("../evil.txt", "pwn")
PY
    mkdir -p "$EXT/out1" "$EXT/out2" "$EXT/out3" "$EXT/out4" "$EXT/out5"
    extract_archive "$EXT/evil-traversal.tar.gz" "$EXT/out1" >/dev/null 2>&1
    printf 'tar-traversal=%s\n' "$?"
    extract_archive "$EXT/abs.tar.gz" "$EXT/out2" >/dev/null 2>&1
    printf 'abs-path=%s\n' "$?"
    extract_archive "$EXT/bad.tar.gz" "$EXT/out3" >/dev/null 2>&1
    printf 'corrupt=%s\n' "$?"
    extract_archive "$EXT/zip-traversal.zip" "$EXT/out4" >/dev/null 2>&1
    printf 'zip-traversal=%s\n' "$?"
    tar -C "$FIX_GH/assets/root" -czf "$EXT/good.tar.gz" gh_2.80.0_linux_amd64
    extract_archive "$EXT/good.tar.gz" "$EXT/out5" >/dev/null 2>&1
    printf 'good=%s\n' "$?"
    [ -f "$EXT/out5/gh_2.80.0_linux_amd64/bin/gh" ] && printf 'good-file=yes\n'
)
assert_contains "T8 tar traversal rejected" "$EXT_OUT" "tar-traversal=1"
assert_contains "T8 absolute path rejected" "$EXT_OUT" "abs-path=1"
assert_contains "T8 corrupt archive fails" "$EXT_OUT" "corrupt=1"
assert_contains "T8 zip traversal rejected" "$EXT_OUT" "zip-traversal=1"
assert_contains "T8 valid archive extracts" "$EXT_OUT" "good=0"
assert_contains "T8 valid archive file present" "$EXT_OUT" "good-file=yes"

# ===========================================================================
# 9. conflict with existing system CLI (shadowing detected)
# ===========================================================================

OUT=$(test_file)
H=$(new_home)
SYSBIN=$(test_tmp)
make_bin "$SYSBIN/gh" 'echo "gh version 9.9.9 (system)"'
export CLOUD_TOOLBOX_HOME="$H"
export CLOUD_TOOLBOX_API_BASE="file://$FIX_GH/api"
unset CLOUD_TOOLBOX_CURL
cli "$OUT" install gh
assert_contains_re "T9 setup: managed gh installed" "$(cat "$OUT")" 'gh[[:space:]]+installed[[:space:]]+2\.80\.0'
OUT=$(test_file)
PATH="$SYSBIN:$PATH" cli "$OUT" doctor
assert_contains "T9 doctor: shadowing warned" "$(cat "$OUT")" "shadows the managed binary"
OUT=$(test_file)
PATH="$H/bin:$SYSBIN:$PATH" cli "$OUT" doctor
assert_not_contains "T9 doctor: no shadow when toolbox bin first" "$(cat "$OUT")" "shadows the managed binary"

# ===========================================================================
# 10. update failure keeps existing binary (download fails mid-update)
# ===========================================================================

OUT=$(test_file)
H=$(new_home)
export CLOUD_TOOLBOX_HOME="$H"
export CLOUD_TOOLBOX_API_BASE="file://$FIX_GH/api"
unset CLOUD_TOOLBOX_CURL
cli "$OUT" install gh
assert_contains_re "T10 setup: gh installed" "$(cat "$OUT")" 'gh[[:space:]]+installed[[:space:]]+2\.80\.0'
OUT=$(test_file)
export CLOUD_TOOLBOX_API_BASE="file://$FIX_GH_NEW/api"
export CLOUD_TOOLBOX_CURL="$MOCK_DLFAIL"
cli "$OUT" install gh
assert_contains_re "T10 update failure: error state" "$(cat "$OUT")" 'gh[[:space:]]+error'
assert_contains "T10 update failure: existing binary kept" "$("$H/bin/gh" --version)" "2.80.0"
assert_true "T10 update failure: exit non-zero" test "$CLI_RC" -ne 0

# ===========================================================================
# 11. secrets not printed (token only in Authorization header, never output)
# ===========================================================================

OUT=$(test_file)
H=$(new_home)
export CLOUD_TOOLBOX_HOME="$H"
export CLOUD_TOOLBOX_API_BASE="file://$FIX_GH/api"
export CLOUD_TOOLBOX_CURL="$MOCK_CAPTURE"
export GITHUB_TOKEN="super-secret-abc123"
cli "$OUT" install gh
assert_contains "T11 secrets: Authorization header sent" "$(cat "$CAPTURE_FILE")" "Authorization: Bearer super-secret-abc123"
assert_not_contains "T11 secrets: token not in install output" "$(cat "$OUT")" "super-secret-abc123"
OUT=$(test_file)
cli "$OUT" doctor
assert_not_contains "T11 secrets: token not in doctor output" "$(cat "$OUT")" "super-secret-abc123"
OUT=$(test_file)
cli "$OUT" list gh
assert_not_contains "T11 secrets: token not in list output" "$(cat "$OUT")" "super-secret-abc123"

# ===========================================================================
# 12. unknown CLI argument -> error
# ===========================================================================

OUT=$(test_file)
H=$(new_home)
export CLOUD_TOOLBOX_HOME="$H"
unset CLOUD_TOOLBOX_API_BASE CLOUD_TOOLBOX_CURL GITHUB_TOKEN
cli "$OUT" install nosuchcli
assert_contains "T12 unknown CLI: error message" "$(cat "$OUT")" "unknown CLI: nosuchcli"
assert_contains "T12 unknown CLI: lists supported" "$(cat "$OUT")" "gh glow coscli uv tccli pipx aws gcloud"
assert_true "T12 unknown CLI: exit 2" test "$CLI_RC" -eq 2

# ===========================================================================
# 13. multiple CLIs, some fail -> non-zero exit + failed summary
# ===========================================================================

OUT=$(test_file)
H=$(new_home)
export CLOUD_TOOLBOX_HOME="$H"
export CLOUD_TOOLBOX_API_BASE="file://$FIX_GH/api"
export CLOUD_TOOLBOX_PYPI_BASE="file:///nonexistent-pypi-dir"
unset CLOUD_TOOLBOX_CURL GITHUB_TOKEN
cli "$OUT" install gh pipx
assert_contains_re "T13 multi: gh installed" "$(cat "$OUT")" 'gh[[:space:]]+installed[[:space:]]+2\.80\.0'
assert_contains_re "T13 multi: pipx error" "$(cat "$OUT")" 'pipx[[:space:]]+error'
assert_contains "T13 multi: summary counts" "$(cat "$OUT")" "Apply complete: 1 installed, 0 updated, 0 unchanged, 1 failed"
assert_contains "T13 multi: failed names" "$(cat "$OUT")" "Failed: pipx"
assert_true "T13 multi: exit non-zero" test "$CLI_RC" -ne 0

# ===========================================================================
# 14. cli-toolbox itself executable and help works
# ===========================================================================

assert_true "T14 executable" test -x "$TBROOT/cli-toolbox"
OUT=$(test_file)
H=$(new_home)
export CLOUD_TOOLBOX_HOME="$H"
cli "$OUT" help
assert_contains "T14 help: usage shown" "$(cat "$OUT")" "Usage:"
assert_true "T14 help: exit 0" test "$CLI_RC" -eq 0

# ===========================================================================
# 15. pipx end-to-end (PyPI fixture, venv, wheel, console script)
# ===========================================================================

OUT=$(test_file)
H=$(new_home)
export CLOUD_TOOLBOX_HOME="$H"
export CLOUD_TOOLBOX_PYPI_BASE="file://$FIX_PYPIX/pypi"
unset CLOUD_TOOLBOX_API_BASE CLOUD_TOOLBOX_CURL GITHUB_TOKEN
cli "$OUT" install pipx
assert_contains_re "T15 pipx: installed" "$(cat "$OUT")" 'pipx[[:space:]]+installed[[:space:]]+1\.17\.2'
assert_true "T15 pipx: console script works" "$H/bin/pipx" --version
OUT=$(test_file)
cli "$OUT" install pipx
assert_contains_re "T15 pipx: re-run unchanged" "$(cat "$OUT")" 'pipx[[:space:]]+unchanged[[:space:]]+1\.17\.2'

# ===========================================================================
# 16. tccli end-to-end
# ===========================================================================

OUT=$(test_file)
H=$(new_home)
export CLOUD_TOOLBOX_HOME="$H"
export CLOUD_TOOLBOX_PYPI_BASE="file://$FIX_TC_CLI/pypi"
cli "$OUT" install tccli
assert_contains_re "T16 tccli: installed" "$(cat "$OUT")" 'tccli[[:space:]]+installed[[:space:]]+3\.1\.165\.1'
assert_true "T16 tccli: console script works" "$H/bin/tccli" --version
OUT=$(test_file)
cli "$OUT" install tccli
assert_contains_re "T16 tccli: re-run unchanged" "$(cat "$OUT")" 'tccli[[:space:]]+unchanged[[:space:]]+3\.1\.165\.1'

# ===========================================================================
# 17. uv end-to-end (no-v tag, uv+uvx both installed)
# ===========================================================================

OUT=$(test_file)
H=$(new_home)
export CLOUD_TOOLBOX_HOME="$H"
export CLOUD_TOOLBOX_API_BASE="file://$FIX_UV/api"
unset CLOUD_TOOLBOX_PYPI_BASE CLOUD_TOOLBOX_CURL GITHUB_TOKEN
cli "$OUT" install uv
assert_contains_re "T17 uv: installed" "$(cat "$OUT")" 'uv[[:space:]]+installed[[:space:]]+0\.12\.12'
assert_true "T17 uv: uv runs" "$H/bin/uv" --version
assert_true "T17 uv: uvx installed too" test -x "$H/bin/uvx"
OUT=$(test_file)
cli "$OUT" install uv
assert_contains_re "T17 uv: re-run unchanged" "$(cat "$OUT")" 'uv[[:space:]]+unchanged[[:space:]]+0\.12\.12'

# ===========================================================================
# 18. glow end-to-end
# ===========================================================================

OUT=$(test_file)
H=$(new_home)
export CLOUD_TOOLBOX_HOME="$H"
export CLOUD_TOOLBOX_API_BASE="file://$FIX_GLOW/api"
cli "$OUT" install glow
assert_contains_re "T18 glow: installed" "$(cat "$OUT")" 'glow[[:space:]]+installed[[:space:]]+3\.0\.0'
assert_true "T18 glow: binary runs" "$H/bin/glow" --version

# ===========================================================================
# 19. coscli end-to-end (raw binary + sha256sum.log)
# ===========================================================================

OUT=$(test_file)
H=$(new_home)
export CLOUD_TOOLBOX_HOME="$H"
export CLOUD_TOOLBOX_API_BASE="file://$FIX_COSCLI/api"
cli "$OUT" install coscli
assert_contains_re "T19 coscli: installed" "$(cat "$OUT")" 'coscli[[:space:]]+installed[[:space:]]+1\.0\.9'
assert_true "T19 coscli: binary runs" "$H/bin/coscli" --version

# ===========================================================================
# 20. list with network failure -> '?' and WARN, does not crash
# ===========================================================================

OUT=$(test_file)
H=$(new_home)
export CLOUD_TOOLBOX_HOME="$H"
export CLOUD_TOOLBOX_CURL="$MOCK_FAIL"
unset CLOUD_TOOLBOX_API_BASE CLOUD_TOOLBOX_PYPI_BASE GITHUB_TOKEN
cli "$OUT" list
assert_contains "T20 list network fail: shows ?" "$(cat "$OUT")" "?"
assert_contains "T20 list network fail: warns" "$(cat "$OUT")" "warn:"
assert_true "T20 list network fail: exit 0" test "$CLI_RC" -eq 0

# ===========================================================================
# 21. aws installer (function-level with overridden http_get/download_file)
# ===========================================================================
AWS_HOME=$(test_tmp)

AWS_OUT=$(
    export CLOUD_TOOLBOX_HOME="$AWS_HOME"
    # shellcheck source=lib/common.sh
    . "$TBROOT/lib/common.sh"
    # shellcheck source=lib/installers.sh
    . "$TBROOT/lib/installers.sh"
    http_get() {
        case "$1" in
            *version.txt) cat "$FIX_AWS/version.txt" ;;
            *) return 1 ;;
        esac
    }
    download_file() {
        local url="$1" dest="$2"
        case "$url" in
            *awscli-exe-linux-x86_64.zip) cp "$FIX_AWS/awscli-exe-linux-x86_64.zip" "$dest" || return 1 ;;
            *) return 1 ;;
        esac
    }
    install_aws
    printf 'STATE=%s DETAIL=%s\n' "$TB_STATE" "$TB_DETAIL"
    if [ -x "$CLOUD_TOOLBOX_HOME/bin/aws" ]; then
        printf 'VER=%s\n' "$(get_installed_version aws)"
        printf 'SYMLINK=%s\n' "$(readlink "$CLOUD_TOOLBOX_HOME/bin/aws")"
    fi
)
assert_contains "T21 aws: installs" "$AWS_OUT" "STATE=installed"
assert_contains "T21 aws: version confirmed" "$AWS_OUT" "VER=2.36.42"
assert_contains_re "T21 aws: symlink into tools" "$AWS_OUT" "SYMLINK=.*tools/aws-cli"

# ===========================================================================
# 22. gcloud installer (function-level with overridden http_get/download_file)
# ===========================================================================
GCLOUD_HOME=$(test_tmp)

GCLOUD_OUT=$(
    export CLOUD_TOOLBOX_HOME="$GCLOUD_HOME"
    # shellcheck source=lib/common.sh
    . "$TBROOT/lib/common.sh"
    # shellcheck source=lib/installers.sh
    . "$TBROOT/lib/installers.sh"
    http_get() {
        case "$1" in
            *components-2.json) cat "$FIX_GCLOUD/components-2.json" ;;
            *) return 1 ;;
        esac
    }
    download_file() {
        local url="$1" dest="$2"
        case "$url" in
            *google-cloud-cli-584.0.0-linux-x86_64.tar.gz)
                cp "$FIX_GCLOUD/google-cloud-cli-584.0.0-linux-x86_64.tar.gz" "$dest" || return 1
                ;;
            *) return 1 ;;
        esac
    }
    install_gcloud
    printf 'STATE=%s DETAIL=%s\n' "$TB_STATE" "$TB_DETAIL"
    if [ -L "$CLOUD_TOOLBOX_HOME/bin/gcloud" ]; then
        printf 'SYMLINK=%s\n' "$(readlink "$CLOUD_TOOLBOX_HOME/bin/gcloud")"
        printf 'VER=%s\n' "$(get_installed_version gcloud)"
    fi
)
assert_contains "T22 gcloud: installs" "$GCLOUD_OUT" "STATE=installed"
assert_contains "T22 gcloud: version confirmed" "$GCLOUD_OUT" "VER=584.0.0"
assert_contains_re "T22 gcloud: symlink to SDK bin" "$GCLOUD_OUT" "SYMLINK=.*tools/google-cloud-sdk/bin/gcloud"

# ===========================================================================
# 23. version_gt / normalize_version unit checks
# ===========================================================================

VG_OUT=$(
    # shellcheck source=lib/common.sh
    . "$TBROOT/lib/common.sh"
    version_gt 2.1.0 2.0.9 && echo "a-gt"
    version_gt 2.0.9 2.1.0 && echo "b-gt"
    version_gt 1.0.0 1.0.0 && echo "eq"
    version_gt v2.80.0 2.79.0 && echo "vstrip-gt"
    version_gt 2.1 2.1.0 && echo "pad-eq"
    version_gt 2.1.1 2.1 && echo "pad-gt"
    printf 'norm=%s\n' "$(normalize_version v1.2.3)"
)
assert_contains "T23 version_gt: a>b" "$VG_OUT" "a-gt"
assert_not_contains "T23 version_gt: b>a false" "$VG_OUT" "b-gt"
assert_not_contains "T23 version_gt: equal false" "$VG_OUT" "eq"
assert_contains "T23 version_gt: v-stripped" "$VG_OUT" "vstrip-gt"
assert_not_contains "T23 version_gt: padded equal false" "$VG_OUT" "pad-eq"
assert_contains "T23 version_gt: padded greater" "$VG_OUT" "pad-gt"
assert_contains "T23 normalize_version" "$VG_OUT" "norm=1.2.3"

# ===========================================================================
# 24. list normal (managed, unchanged) for installed CLIs
# ===========================================================================

OUT=$(test_file)
H=$(new_home)
export CLOUD_TOOLBOX_HOME="$H"
export CLOUD_TOOLBOX_API_BASE="file://$FIX_GH/api"
unset CLOUD_TOOLBOX_CURL CLOUD_TOOLBOX_PYPI_BASE GITHUB_TOKEN
cli "$OUT" install gh
OUT=$(test_file)
cli "$OUT" list gh
assert_contains "T24 list: header" "$(cat "$OUT")" "CLI"
assert_contains_re "T24 list: managed row" "$(cat "$OUT")" 'gh[[:space:]]+managed[[:space:]]+2\.80\.0[[:space:]]+2\.80\.0'
assert_contains "T24 list: unchanged state" "$(cat "$OUT")" "unchanged"

# ===========================================================================
# 25. unsupported CLIs reported, count as failed, exit non-zero
# ===========================================================================

OUT=$(test_file)
H=$(new_home)
export CLOUD_TOOLBOX_HOME="$H"
unset CLOUD_TOOLBOX_API_BASE CLOUD_TOOLBOX_PYPI_BASE CLOUD_TOOLBOX_CURL GITHUB_TOKEN
cli "$OUT" install az awst
assert_contains_re "T25 unsupported: az line" "$(cat "$OUT")" 'az[[:space:]]+unsupported'
assert_contains_re "T25 unsupported: awst line" "$(cat "$OUT")" 'awst[[:space:]]+unsupported'
assert_contains "T25 unsupported: az reason" "$(cat "$OUT")" "no self-contained non-root binary"
assert_contains "T25 unsupported: awst reason" "$(cat "$OUT")" "no release binaries in cloud-cli"
assert_contains "T25 unsupported: summary" "$(cat "$OUT")" "Apply complete: 0 installed, 0 updated, 0 unchanged, 2 failed"
assert_true "T25 unsupported: exit non-zero" test "$CLI_RC" -ne 0

# ===========================================================================
# 26. install with no args -> STANDARD_SET (aws/gcloud fail on mocked network)
# ===========================================================================

OUT=$(test_file)
H=$(new_home)
export CLOUD_TOOLBOX_HOME="$H"
export CLOUD_TOOLBOX_API_BASE="file://$FIX_ALL/api"
export CLOUD_TOOLBOX_PYPI_BASE="file://$FIX_ALL/pypi"
export CLOUD_TOOLBOX_CURL="$MOCK_CLOUDFAIL"
unset GITHUB_TOKEN
cli "$OUT" install
assert_contains "T26 no-args: gh listed" "$(cat "$OUT")" "gh"
assert_contains "T26 no-args: glow listed" "$(cat "$OUT")" "glow"
assert_contains "T26 no-args: coscli listed" "$(cat "$OUT")" "coscli"
assert_contains "T26 no-args: uv listed" "$(cat "$OUT")" "uv"
assert_contains "T26 no-args: tccli listed" "$(cat "$OUT")" "tccli"
assert_contains "T26 no-args: pipx listed" "$(cat "$OUT")" "pipx"
assert_contains "T26 no-args: aws listed" "$(cat "$OUT")" "aws"
assert_contains "T26 no-args: gcloud listed" "$(cat "$OUT")" "gcloud"
assert_contains "T26 no-args: summary" "$(cat "$OUT")" "Apply complete: 6 installed, 0 updated, 0 unchanged, 2 failed"
assert_contains "T26 no-args: failed names" "$(cat "$OUT")" "Failed: aws, gcloud"
assert_true "T26 no-args: exit non-zero (partial failures)" test "$CLI_RC" -ne 0
assert_true "T26 no-args: gh actually installed" test -x "$H/bin/gh"
assert_true "T26 no-args: pipx actually installed" test -x "$H/bin/pipx"

# ===========================================================================
# 27. M2: coscli bad checksum -> error, existing binary kept
# ===========================================================================

OUT=$(test_file)
H=$(new_home)
export CLOUD_TOOLBOX_HOME="$H"
export CLOUD_TOOLBOX_API_BASE="file://$FIX_COSCLI/api"
unset CLOUD_TOOLBOX_CURL CLOUD_TOOLBOX_PYPI_BASE GITHUB_TOKEN
cli "$OUT" install coscli
assert_contains_re "T27 coscli badsum: setup installed" "$(cat "$OUT")" 'coscli[[:space:]]+installed[[:space:]]+1\.0\.9'
OUT=$(test_file)
export CLOUD_TOOLBOX_API_BASE="file://$FIX_COSCLI_BADSUM/api"
cli "$OUT" install coscli
assert_contains_re "T27 coscli badsum: error state" "$(cat "$OUT")" 'coscli[[:space:]]+error'
assert_contains "T27 coscli badsum: reason" "$(cat "$OUT")" "checksum mismatch"
assert_contains "T27 coscli badsum: old binary kept" "$("$H/bin/coscli" --version)" "1.0.9"

# ===========================================================================
# 28. M3: uv bad checksum -> error, existing binary kept
# ===========================================================================

OUT=$(test_file)
H=$(new_home)
export CLOUD_TOOLBOX_HOME="$H"
export CLOUD_TOOLBOX_API_BASE="file://$FIX_UV/api"
unset CLOUD_TOOLBOX_CURL CLOUD_TOOLBOX_PYPI_BASE GITHUB_TOKEN
cli "$OUT" install uv
assert_contains_re "T28 uv badsum: setup installed" "$(cat "$OUT")" 'uv[[:space:]]+installed[[:space:]]+0\.12\.12'
OUT=$(test_file)
export CLOUD_TOOLBOX_API_BASE="file://$FIX_UV_BADSUM/api"
cli "$OUT" install uv
assert_contains_re "T28 uv badsum: error state" "$(cat "$OUT")" 'uv[[:space:]]+error'
assert_contains "T28 uv badsum: reason" "$(cat "$OUT")" "checksum mismatch"
assert_contains "T28 uv badsum: old binary kept" "$("$H/bin/uv" --version)" "0.12.12"

# ===========================================================================
# 29. M5: no temp dirs leak after an install
# ===========================================================================

BEFORE=$(ls -d /tmp/cli-toolbox.* 2>/dev/null | wc -l)
OUT=$(test_file)
H=$(new_home)
export CLOUD_TOOLBOX_HOME="$H"
export CLOUD_TOOLBOX_API_BASE="file://$FIX_GH/api"
unset CLOUD_TOOLBOX_CURL CLOUD_TOOLBOX_PYPI_BASE GITHUB_TOKEN
cli "$OUT" install gh
AFTER=$(ls -d /tmp/cli-toolbox.* 2>/dev/null | wc -l)
assert_contains_re "T29 temp dirs cleaned" "$(cat "$OUT")" 'gh[[:space:]]+installed[[:space:]]+2\.80\.0'
assert_true "T29 temp dirs: no leftovers added" test "$AFTER" -eq "$BEFORE"

# ===========================================================================
# 30. M6: fault-injection THROUGH the real atomic_install — a missing source
# makes the copy fail while a good binary sits at the destination. No
# wholesale override: the real function body (including the mktemp + mv
# sequence) is what runs, so a mutation that deletes the old dest early is
# caught by the "dest unchanged" assertion.
# ===========================================================================
M6_HOME=$(test_tmp)

M6_OUT=$(
    export CLOUD_TOOLBOX_HOME="$M6_HOME"
    # shellcheck source=lib/common.sh
    . "$TBROOT/lib/common.sh"
    mkdir -p "$CLOUD_TOOLBOX_HOME/bin"
    printf '#!/bin/sh\necho "gh version 2.80.0 (kept)"\n' >"$CLOUD_TOOLBOX_HOME/bin/gh"
    chmod +x "$CLOUD_TOOLBOX_HOME/bin/gh"
    before=$(sha256sum "$CLOUD_TOOLBOX_HOME/bin/gh" | awk '{print $1}')
    atomic_install "$CLOUD_TOOLBOX_HOME/does-not-exist" "$CLOUD_TOOLBOX_HOME/bin/gh" 2>/dev/null
    rc=$?
    after=$(sha256sum "$CLOUD_TOOLBOX_HOME/bin/gh" | awk '{print $1}')
    printf 'rc=%s\n' "$rc"
    [ "$before" = "$after" ] && printf 'same=yes\n' || printf 'same=no\n'
    [ -x "$CLOUD_TOOLBOX_HOME/bin/gh" ] && printf 'exe=yes\n' || printf 'exe=no\n'
    printf 'runs=%s\n' "$("$CLOUD_TOOLBOX_HOME/bin/gh" --version)"
)
assert_contains "T30 atomic failure: copy step fails" "$M6_OUT" "rc=1"
assert_contains "T30 atomic failure: dest byte-identical" "$M6_OUT" "same=yes"
assert_contains "T30 atomic failure: dest still executable" "$M6_OUT" "exe=yes"
assert_contains "T30 atomic failure: dest still runs" "$M6_OUT" "gh version 2.80.0 (kept)"
assert_not_contains "T30 atomic failure: no half-written tmp left" "$M6_OUT" "same=no"

# ===========================================================================
# 31. M7: installed but version parse failed -> error guard
# ===========================================================================
M7_HOME=$(test_tmp)

M7_OUT=$(
    export CLOUD_TOOLBOX_HOME="$M7_HOME"
    # shellcheck source=lib/common.sh
    . "$TBROOT/lib/common.sh"
    # shellcheck source=lib/installers.sh
    . "$TBROOT/lib/installers.sh"
    export CLOUD_TOOLBOX_API_BASE="file://$FIX_GH/api"
    _parse_version() { printf '\n'; }
    install_gh
    printf 'state=%s\n' "$TB_STATE"
    printf 'detail=%s\n' "$TB_DETAIL"
)
assert_contains "T31 parse-fail: error state" "$M7_OUT" "state=error"
assert_contains "T31 parse-fail: guard message" "$M7_OUT" "version check failed"

# ===========================================================================
# 32. M12: checksum_for picks the right entry among several
# ===========================================================================

CKFILE=$(test_file)
printf '%s  %s\n' "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" \
    "glow_3.0.0_Linux_x86_64.tar.gz" >"$CKFILE"
printf '%s  %s\n' "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" \
    "glow_3.0.0_Linux_arm64.tar.gz" >>"$CKFILE"
CK_OUT=$(
    # shellcheck source=lib/common.sh
    . "$TBROOT/lib/common.sh"
    printf 'x86=%s\n' "$(checksum_for "$(cat "$CKFILE")" glow_3.0.0_Linux_x86_64.tar.gz)"
    printf 'arm=%s\n' "$(checksum_for "$(cat "$CKFILE")" glow_3.0.0_Linux_arm64.tar.gz)"
    printf 'missing=%s\n' "$(checksum_for "$(cat "$CKFILE")" no-such-file 2>/dev/null || echo FAIL)"
)
assert_contains "T32 checksum_for multi: x86 entry" "$CK_OUT" \
    "x86=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
assert_contains "T32 checksum_for multi: arm entry" "$CK_OUT" \
    "arm=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
assert_contains "T32 checksum_for multi: missing fails" "$CK_OUT" "missing=FAIL"

# ===========================================================================
# 33. compact PyPI JSON with multiple releases -> correct wheel selected
#     (would fail with the pre-fix parser that grabbed the first url/sha256)
# ===========================================================================

OUT=$(test_file)
H=$(new_home)
export CLOUD_TOOLBOX_HOME="$H"
export CLOUD_TOOLBOX_PYPI_BASE="file://$FIX_PYPIX_COMPACT/pypi"
unset CLOUD_TOOLBOX_API_BASE CLOUD_TOOLBOX_CURL GITHUB_TOKEN
cli "$OUT" install pipx
assert_contains_re "T33 compact pypi: installed latest" "$(cat "$OUT")" 'pipx[[:space:]]+installed[[:space:]]+1\.17\.2'
assert_contains "T33 compact pypi: correct version runs" "$("$H/bin/pipx" --version)" "1.17.2"
assert_not_contains "T33 compact pypi: old wheel never used" "$(cat "$OUT")" "1.17.1"

# ===========================================================================
# 34. GitHub rate-limit body -> actionable message (never a parse error)
# ===========================================================================

OUT=$(test_file)
H=$(new_home)
export CLOUD_TOOLBOX_HOME="$H"
export CLOUD_TOOLBOX_API_BASE="file://$FIX_GH/api"
export CLOUD_TOOLBOX_CURL="$MOCK_RL"
unset CLOUD_TOOLBOX_PYPI_BASE GITHUB_TOKEN
cli "$OUT" install gh
assert_contains_re "T34 rate limit: error state" "$(cat "$OUT")" 'gh[[:space:]]+error'
assert_contains "T34 rate limit: actionable message" "$(cat "$OUT")" "rate limit"
assert_contains "T34 rate limit: GITHUB_TOKEN hint" "$(cat "$OUT")" "GITHUB_TOKEN"
assert_not_contains "T34 rate limit: not a tag parse error" "$(cat "$OUT")" "could not parse tag_name"

# ===========================================================================
# 35. version_gt must not choke on prerelease suffixes
# ===========================================================================

VGN_OUT=$(
    # shellcheck source=lib/common.sh
    . "$TBROOT/lib/common.sh"
    err=$(version_gt 1.0.0-beta 1.0.0 2>&1)
    printf 'rc=%s err=%s\n' "$?" "$err"
    version_gt 1.1.0-rc1 1.0.9 && echo "rc1-gt"
    version_gt 1.0.9 1.1.0-rc1 && echo "rc1-lt"
)
assert_not_contains "T35 prerelease: no integer error" "$VGN_OUT" "integer expression expected"
assert_contains "T35 prerelease: rc1 greater than 1.0.9" "$VGN_OUT" "rc1-gt"
assert_not_contains "T35 prerelease: rc1 not less" "$VGN_OUT" "rc1-lt"

# ===========================================================================
# 36. glow root-layout archive (binary at archive root) still works
# ===========================================================================

OUT=$(test_file)
H=$(new_home)
export CLOUD_TOOLBOX_HOME="$H"
export CLOUD_TOOLBOX_API_BASE="file://$FIX_GLOW_ROOT/api"
unset CLOUD_TOOLBOX_CURL CLOUD_TOOLBOX_PYPI_BASE GITHUB_TOKEN
cli "$OUT" install glow
assert_contains_re "T36 glow root-layout: installed" "$(cat "$OUT")" 'glow[[:space:]]+installed[[:space:]]+3\.0\.0'
assert_contains "T36 glow root-layout: binary runs" "$("$H/bin/glow" --version)" "root-layout"

# ===========================================================================
# 37. uv root-layout archive (uv+uvx at archive root) still works
# ===========================================================================

OUT=$(test_file)
H=$(new_home)
export CLOUD_TOOLBOX_HOME="$H"
export CLOUD_TOOLBOX_API_BASE="file://$FIX_UV_ROOT/api"
unset CLOUD_TOOLBOX_CURL CLOUD_TOOLBOX_PYPI_BASE GITHUB_TOKEN
cli "$OUT" install uv
assert_contains_re "T37 uv root-layout: installed" "$(cat "$OUT")" 'uv[[:space:]]+installed[[:space:]]+0\.12\.12'
assert_true "T37 uv root-layout: uv runs" "$H/bin/uv" --version
assert_true "T37 uv root-layout: uvx installed" test -x "$H/bin/uvx"

# ===========================================================================
# summary
# ===========================================================================

printf '\nTest summary: %d passed, %d failed\n' "$PASS" "$FAIL"
if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
exit 0