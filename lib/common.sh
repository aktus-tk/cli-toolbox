# shellcheck shell=bash
# lib/common.sh — shared helpers for cli-toolbox
#
# All functions are overridable (tests may source this file and redefine them).
# Everything user-visible goes to stderr; stdout is reserved for machine
# readable result lines and table output.

if [ -z "${CLI_TOOLBOX_HOME:-}" ]; then
    CLI_TOOLBOX_HOME="${HOME:-}/.cli-toolbox"
fi
export CLI_TOOLBOX_HOME

# Keep a list of temp dirs created with make_tempdir; removed on exit.
__TB_TEMPDIRS=()

# ---------------------------------------------------------------------------
# logging
# ---------------------------------------------------------------------------

log_info() { printf 'info: %s\n' "$*" >&2; }
log_warn() { printf 'warn: %s\n' "$*" >&2; }
log_error() { printf 'error: %s\n' "$*" >&2; }

die() {
    log_error "$*"
    exit 1
}

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

cmd_exists() {
    command -v "$1" >/dev/null 2>&1
}

# ---------------------------------------------------------------------------
# platform detection
# ---------------------------------------------------------------------------

# Sets TB_OS (linux|darwin) and TB_ARCH (amd64|arm64). Exports them.
# Returns non-zero on unsupported OS/arch.
detect_platform() {
    if [ -n "${TB_OS:-}" ] && [ -n "${TB_ARCH:-}" ]; then
        export TB_OS TB_ARCH
        return 0
    fi
    local os arch
    os=$(uname -s 2>/dev/null)
    arch=$(uname -m 2>/dev/null)
    case "$os" in
        Linux) TB_OS=linux ;;
        Darwin) TB_OS=darwin ;;
        *)
            TB_OS=""
            log_error "unsupported OS: ${os:-unknown}"
            return 1
            ;;
    esac
    case "$arch" in
        x86_64 | amd64) TB_ARCH=amd64 ;;
        aarch64 | arm64) TB_ARCH=arm64 ;;
        *)
            TB_ARCH=""
            log_error "unsupported architecture: ${arch:-unknown}"
            return 1
            ;;
    esac
    export TB_OS TB_ARCH
    return 0
}

# ---------------------------------------------------------------------------
# version helpers
# ---------------------------------------------------------------------------

normalize_version() {
    printf '%s\n' "${1#v}"
}

# _numeric_segment <segment>: leading digits of a version segment (0 if none),
# so prerelease suffixes like "1.0.0-beta" compare numerically and never
# trigger "integer expression expected" in version_gt.
_numeric_segment() {
    local seg="$1" n
    n=${seg%%[!0-9]*}
    [ -n "$n" ] || n=0
    printf '%s' "$n"
}

# version_gt <a> <b>: true (0) if a is greater than b. Dotted numeric compare;
# non-numeric segment suffixes are ignored numerically (1.0.0-beta == 1.0.0).
version_gt() {
    local a="$1" b="$2"
    a=$(normalize_version "$a")
    b=$(normalize_version "$b")
    [ "$a" = "$b" ] && return 1
    local -a A=() B=()
    IFS=. read -r -a A <<< "$a"
    IFS=. read -r -a B <<< "$b"
    local i=0 av=0 bv=0
    while [ "$i" -lt "${#A[@]}" ] || [ "$i" -lt "${#B[@]}" ]; do
        av=0
        bv=0
        if [ "$i" -lt "${#A[@]}" ]; then av=$(_numeric_segment "${A[$i]}"); fi
        if [ "$i" -lt "${#B[@]}" ]; then bv=$(_numeric_segment "${B[$i]}"); fi
        if [ "$av" -gt "$bv" ]; then return 0; fi
        if [ "$av" -lt "$bv" ]; then return 1; fi
        i=$((i + 1))
    done
    return 1
}

# _parse_version <cli> <path>: run the binary at path and extract the version.
_parse_version() {
    local cli="$1" path="$2" out=""
    case "$cli" in
        gh)
            out=$("$path" --version 2>/dev/null | sed -n 's/.*gh version \([0-9][^ ]*\).*/\1/p' | head -1)
            ;;
        glow)
            out=$("$path" --version 2>/dev/null | sed -n 's/.*glow version \([0-9][^ ]*\).*/\1/p' | head -1)
            if [ -z "$out" ]; then
                out=$("$path" --version 2>/dev/null | grep -i 'glow version' | head -1 \
                    | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' \
                    | sed 's/^glow[[:space:]][[:space:]]*version[[:space:]][[:space:]]*//')
            fi
            ;;
        coscli)
            out=$("$path" --version 2>/dev/null | sed -n 's/.*coscli version v\?\([0-9][^ ]*\).*/\1/p' | head -1)
            ;;
        rg)
            out=$("$path" --version 2>/dev/null | sed -n 's/^ripgrep \([0-9][^ ]*\).*/\1/p' | head -1)
            ;;
        mlr)
            out=$("$path" --version 2>/dev/null | sed -n 's/^mlr \([0-9][^ ]*\).*/\1/p' | head -1)
            ;;
        opencode)
            out=$("$path" --version 2>/dev/null | sed -n 's/^opencode version \([0-9][^ ]*\).*/\1/p' | head -1)
            if [ -z "$out" ]; then
                out=$("$path" --version 2>/dev/null | sed -n 's/^\([0-9][^ ]*\).*/\1/p' | head -1)
            fi
            ;;
        agent)
            out=$("$path" --version 2>/dev/null | sed -n 's/^agent version \([0-9][^ ]*\).*/\1/p' | head -1)
            if [ -z "$out" ]; then
                out=$("$path" --version 2>/dev/null | sed -n '1s/^[[:space:]]*\([0-9][0-9A-Za-z._-]*\).*/\1/p')
            fi
            ;;
        codebuddy)
            out=$("$path" --version 2>/dev/null | sed -n 's/^codebuddy version \([0-9][^ ]*\).*/\1/p' | head -1)
            if [ -z "$out" ]; then
                out=$("$path" --version 2>/dev/null | sed -n 's/^\([0-9][^ ]*\).*/\1/p' | head -1)
            fi
            ;;
        claude)
            out=$("$path" --version 2>/dev/null | sed -n 's/^claude version \([0-9][^ ]*\).*/\1/p' | head -1)
            if [ -z "$out" ]; then
                out=$("$path" --version 2>/dev/null | sed -n 's/^\([0-9][^ ]*\).*/\1/p' | head -1)
            fi
            ;;
        codex)
            out=$("$path" --version 2>/dev/null | sed -n 's/^codex version \([0-9][^ ]*\).*/\1/p' | head -1)
            if [ -z "$out" ]; then
                out=$("$path" --version 2>/dev/null | sed -n 's/^\([0-9][^ ]*\).*/\1/p' | head -1)
            fi
            ;;
        agy)
            out=$("$path" --version 2>/dev/null | sed -n 's/^\([0-9][^ ]*\).*/\1/p' | head -1)
            ;;
        kubectl)
            out=$("$path" version --client 2>/dev/null \
                | sed -n 's/.*Client Version: v\?\([0-9][^ ]*\).*/\1/p' | head -1)
            ;;
        helm)
            out=$("$path" version --short 2>/dev/null | sed -n 's/^v\?\([0-9][^ ]*\).*/\1/p' | head -1)
            if [ -z "$out" ]; then
                out=$("$path" version 2>/dev/null \
                    | sed -n 's/.*Version:"\([^"]*\)".*/\1/p' | head -1)
                out=$(normalize_version "$out")
            fi
            ;;
        oci)
            out=$("$path" --version 2>/dev/null | sed -n 's/^\([0-9][^ ]*\).*/\1/p' | head -1)
            ;;
        uv)
            out=$("$path" --version 2>/dev/null | sed -n 's/.*uv \([0-9][^ ]*\).*/\1/p' | head -1)
            ;;
        tccli)
            out=$("$path" --version 2>/dev/null | head -1 | tr -d '[:space:]')
            ;;
        aws)
            out=$("$path" --version 2>&1 | sed -n 's/.*aws-cli\/\([0-9][^ ]*\).*/\1/p' | head -1)
            ;;
        gcloud)
            out=$("$path" version 2>/dev/null | sed -n 's/.*Google Cloud SDK \([0-9][^ ]*\).*/\1/p' | head -1)
            ;;
        az)
            out=$("$path" version 2>/dev/null | sed -n 's/.*azure-cli \([0-9][^ ]*\).*/\1/p' | head -1)
            ;;
        terraform)
            out=$("$path" version 2>/dev/null | sed -n 's/^Terraform v\([0-9][^ ]*\).*/\1/p' | head -1)
            ;;
        awst | gcloudt | tcclit)
            out="wrapper"
            ;;
    esac
    out=$(normalize_version "$out")
    printf '%s\n' "$out"
}

# ---------------------------------------------------------------------------
# download helpers (curl; overridable via CLI_TOOLBOX_CURL)
# ---------------------------------------------------------------------------

http_get() {
    local url="$1"
    "${CLI_TOOLBOX_CURL:-curl}" -fsSL --retry 3 --connect-timeout 10 "$url" 2>/dev/null
}

download_file() {
    local url="$1" dest="$2"
    "${CLI_TOOLBOX_CURL:-curl}" -fL --retry 3 --connect-timeout 10 -o "$dest" "$url" 2>/dev/null
}

# ---------------------------------------------------------------------------
# GitHub API helpers (no jq required; tolerant grep/sed parsing)
# ---------------------------------------------------------------------------

# Fetch the latest release JSON for owner/repo. Returns non-zero on failure
# with an actionable error. GitHub rate limits are detected via the HTTP
# status (403/429) or the "API rate limit exceeded" body and reported with a
# clear hint about GITHUB_TOKEN (its value is never printed). Works for both
# https:// and file:// URLs (file:// reports http_code 000, which is ignored).
github_release_json() {
    local repo="$1"
    local url="${CLI_TOOLBOX_API_BASE:-https://api.github.com}/repos/${repo}/releases/latest"
    local body code rc
    if [ -n "${GITHUB_TOKEN:-}" ]; then
        body=$("${CLI_TOOLBOX_CURL:-curl}" -sSL -H "Authorization: Bearer ${GITHUB_TOKEN}" \
            --connect-timeout 10 --retry 2 -w $'\n%{http_code}' "$url" 2>/dev/null)
        rc=$?
    else
        body=$("${CLI_TOOLBOX_CURL:-curl}" -sSL --connect-timeout 10 --retry 2 \
            -w $'\n%{http_code}' "$url" 2>/dev/null)
        rc=$?
    fi
    code=$(printf '%s\n' "$body" | tail -1)
    case "$code" in
        [0-9][0-9][0-9])
            # curl -w '%{http_code}' appends a bare 3-digit status line; drop it.
            body=$(printf '%s\n' "$body" | sed '$d')
            ;;
        *)
            # No status line appended (e.g. a mock curl): the whole output is body.
            code=""
            ;;
    esac
    if [ "$rc" -ne 0 ] || [ -z "$body" ]; then
        log_error "failed to fetch latest release for ${repo} (curl exit ${rc})"
        return 1
    fi
    if [ "$code" = "403" ] || [ "$code" = "429" ] \
        || printf '%s\n' "$body" | grep -qi 'API rate limit exceeded'; then
        log_error "GitHub API rate limit exceeded for ${repo}. Try again later, or set GITHUB_TOKEN to raise the limit (the token value is never printed)."
        return 1
    fi
    printf '%s\n' "$body"
    return 0
}

# github_version_from_json <body>: echo tag_name with leading v stripped.
github_version_from_json() {
    local body="$1" ver
    ver=$(printf '%s\n' "$body" \
        | grep -o '"tag_name"[[:space:]]*:[[:space:]]*"[^"]*"' \
        | head -1 \
        | sed 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/')
    ver=$(normalize_version "$ver")
    if [ -z "$ver" ]; then
        log_error "could not parse tag_name from release JSON"
        return 1
    fi
    printf '%s\n' "$ver"
    return 0
}

# get_latest_stable_version_github <owner/repo>
get_latest_stable_version_github() {
    local repo="$1" body
    body=$(github_release_json "$repo") || return 1
    github_version_from_json "$body"
}

# github_asset_url <owner/repo> <tag> <asset-name> <body>
# Uses browser_download_url from the release JSON when present (this is what
# makes file:// fixtures work in tests); falls back to the canonical
# https://github.com/<repo>/releases/download/<tag>/<name> URL.
github_asset_url() {
    local repo="$1" tag="$2" name="$3" body="$4" url=""
    if [ -n "$body" ]; then
        url=$(printf '%s\n' "$body" \
            | grep -o '"[^"]*"[[:space:]]*:[[:space:]]*"[^"]*"' \
            | awk -v want="$name" '
                /"name"[[:space:]]*:[[:space:]]*"/ {
                    k = $0
                    sub(/^.*"name"[[:space:]]*:[[:space:]]*"/, "", k)
                    sub(/"[[:space:]]*$/, "", k)
                    if (k == want) { seen = 1; next }
                }
                seen && /"browser_download_url"[[:space:]]*:[[:space:]]*"/ {
                    sub(/^.*"browser_download_url"[[:space:]]*:[[:space:]]*"/, "", $0)
                    sub(/"[[:space:]]*$/, "", $0)
                    print
                    exit
                }
            ')
    fi
    if [ -z "$url" ]; then
        url="https://github.com/${repo}/releases/download/${tag}/${name}"
    fi
    printf '%s\n' "$url"
    return 0
}

# ---------------------------------------------------------------------------
# PyPI helpers
# ---------------------------------------------------------------------------

# pypi_version_from_body <body>: echo info.version
pypi_version_from_body() {
    local body="$1" segment ver
    segment=${body#*\"info\"}
    segment=${segment%%\"last_serial\"*}
    ver=$(printf '%s' "$segment" \
        | grep -o '"version"[[:space:]]*:[[:space:]]*"[^"]*"' \
        | head -1 \
        | sed 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/')
    ver=$(normalize_version "$ver")
    if [ -z "$ver" ]; then
        log_error "could not parse version from PyPI JSON"
        return 1
    fi
    printf '%s\n' "$ver"
    return 0
}

# get_latest_version_pypi <pkg>
get_latest_version_pypi() {
    local pkg="$1" body
    body=$(http_get "${CLI_TOOLBOX_PYPI_BASE:-https://pypi.org}/pypi/${pkg}/json") || return 1
    pypi_version_from_body "$body"
}

# pypi_wheel_info <body> <pkg> <ver>: echo "URL<TAB>SHA256" for the wheel of
# the exact version, preferring py3-none-any wheels (tccli may ship
# py2.py3-none-any). Uses python3 — the python CLIs already require it, so a
# missing python3 is a clear error here. This deliberately replaces brittle
# grep/sed parsing of the (potentially multi-MB) PyPI JSON, which previously
# grabbed the first "url"/"sha256" in the whole document.
pypi_wheel_info() {
    local body="$1" pkg="$2" ver="$3" out
    if ! cmd_exists python3; then
        log_error "pypi_wheel_info: python3 is required to parse PyPI metadata (for ${pkg})"
        return 1
    fi
    out=$(printf '%s\n' "$body" | python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
except Exception as exc:
    sys.stderr.write("invalid PyPI JSON: %s\n" % exc)
    sys.exit(1)
pkg, ver = sys.argv[1], sys.argv[2]
files = data.get("urls") or []
if not files:
    files = (data.get("releases") or {}).get(ver, [])
wheels = [f for f in files
          if f.get("filename", "").startswith(pkg + "-" + ver + "-")
          and f.get("filename", "").endswith(".whl")]
if not wheels:
    sys.stderr.write("no wheel found for %s %s\n" % (pkg, ver))
    sys.exit(1)
pick = next((w for w in wheels if "py3-none-any" in w.get("filename", "")), wheels[0])
url = pick.get("url", "")
sha = (pick.get("digests") or {}).get("sha256", "")
if not url or not sha:
    sys.stderr.write("wheel %s is missing url or sha256 digest\n" % pick.get("filename", ""))
    sys.exit(1)
print("%s\t%s" % (url, sha))
' "$pkg" "$ver" 2>/dev/null) || return 1
    printf '%s\n' "$out"
    return 0
}

# pypi_wheel_url <body> <pkg> <ver>: echo download url of the matching wheel
pypi_wheel_url() {
    local body="$1" pkg="$2" ver="$3" info
    info=$(pypi_wheel_info "$body" "$pkg" "$ver") || return 1
    printf '%s\n' "$info" | cut -f1
}

# pypi_wheel_sha <body> <pkg> <ver>: echo sha256 digest of the matching wheel
pypi_wheel_sha() {
    local body="$1" pkg="$2" ver="$3" info
    info=$(pypi_wheel_info "$body" "$pkg" "$ver") || return 1
    printf '%s\n' "$info" | cut -f2
}

# ---------------------------------------------------------------------------
# checksum helpers
# ---------------------------------------------------------------------------

verify_sha256() {
    local file="$1" expected="$2" actual=""
    if [ ! -f "$file" ]; then
        log_error "verify_sha256: file not found: $file"
        return 1
    fi
    if cmd_exists sha256sum; then
        actual=$(sha256sum "$file" | awk '{print $1}')
    elif cmd_exists shasum; then
        actual=$(shasum -a 256 "$file" | awk '{print $1}')
    else
        log_error "verify_sha256: neither sha256sum nor shasum is available"
        return 1
    fi
    if [ "$actual" != "$expected" ]; then
        log_error "sha256 mismatch for $(basename "$file") (expected ${expected}, got ${actual})"
        return 1
    fi
    return 0
}

# checksum_for <checksum-text> <filename>: extract hash for filename
# Accepts "<hash>  <filename>" style lines (any whitespace).
checksum_for() {
    local text="$1" fname="$2" hash=""
    hash=$(printf '%s\n' "$text" | awk -v f="$fname" '$2 == f { print $1; exit }')
    if [ -z "$hash" ]; then
        log_error "checksum entry not found for '$fname'"
        return 1
    fi
    printf '%s\n' "$hash"
    return 0
}

# ---------------------------------------------------------------------------
# archive extraction (path-traversal safe)
# ---------------------------------------------------------------------------

# _archive_entries_safe <entries>: returns non-zero if any entry is unsafe
# (absolute path, drive-letter colon, ".." component, or empty component).
_archive_entries_safe() {
    local entries="$1" entry comp rest
    while IFS= read -r entry; do
        [ -z "$entry" ] && continue
        case "$entry" in
            /* | *:*) return 1 ;;
        esac
        rest="$entry"
        while [ -n "$rest" ]; do
            comp="${rest%%/*}"
            case "$comp" in
                "" | "..") return 1 ;;
            esac
            if [ "$rest" = "${rest#*/}" ]; then
                rest=""
            else
                rest="${rest#*/}"
            fi
        done
    done <<< "$entries"
    return 0
}

# extract_archive <archive> <destdir>: tar.gz/tgz or zip; creates destdir.
extract_archive() {
    local archive="$1" destdir="$2" entries
    if [ ! -f "$archive" ]; then
        log_error "extract_archive: archive not found: $archive"
        return 1
    fi
    mkdir -p "$destdir" || return 1
    case "$archive" in
        *.zip)
            if ! cmd_exists unzip; then
                log_error "extract_archive: unzip is required to extract $archive"
                return 1
            fi
            entries=$(unzip -Z1 "$archive" 2>/dev/null) || {
                log_error "extract_archive: cannot read zip: $archive"
                return 1
            }
            if ! _archive_entries_safe "$entries"; then
                log_error "extract_archive: unsafe entries (path traversal) rejected in $archive"
                return 1
            fi
            unzip -q "$archive" -d "$destdir" >/dev/null 2>&1 || {
                log_error "extract_archive: unzip failed: $archive"
                return 1
            }
            ;;
        *.tar.gz | *.tgz)
            if ! cmd_exists tar; then
                log_error "extract_archive: tar is required to extract $archive"
                return 1
            fi
            entries=$(tar -tzf "$archive" 2>/dev/null) || {
                log_error "extract_archive: cannot read tar: $archive"
                return 1
            }
            if ! _archive_entries_safe "$entries"; then
                log_error "extract_archive: unsafe entries (path traversal) rejected in $archive"
                return 1
            fi
            tar -xzf "$archive" -C "$destdir" --no-same-owner --no-same-permissions >/dev/null 2>&1 || {
                log_error "extract_archive: tar extraction failed: $archive"
                return 1
            }
            ;;
        *)
            log_error "extract_archive: unsupported archive type: $archive"
            return 1
            ;;
    esac
    return 0
}

# ---------------------------------------------------------------------------
# atomic placement
# ---------------------------------------------------------------------------

# atomic_install <srcfile> <destfile>: copy to a mktemp file inside the dest
# dir (same filesystem, so the final mv is atomic), chmod +x, then mv -f.
# The old dest is preserved on any failure; never a half-written dest.
atomic_install() {
    local src="$1" dest="$2"
    local dir name tmp
    dir=$(dirname "$dest")
    name=$(basename "$dest")
    mkdir -p "$dir" || return 1
    tmp=$(mktemp "$dir/.${name}.tmp.XXXXXX") || {
        log_error "atomic_install: cannot create temp file in $dir"
        return 1
    }
    if ! cp "$src" "$tmp"; then
        rm -f "$tmp"
        log_error "atomic_install: copy failed for $dest"
        return 1
    fi
    chmod +x "$tmp"
    if ! mv -f "$tmp" "$dest"; then
        rm -f "$tmp"
        log_error "atomic_install: move failed for $dest"
        return 1
    fi
    return 0
}

# atomic_symlink <target> <link>: create/replace symlink atomically.
atomic_symlink() {
    local target="$1" link="$2"
    local dir name tmp
    dir=$(dirname "$link")
    name=$(basename "$link")
    mkdir -p "$dir" || return 1
    tmp="$dir/.${name}.tmp.$$"
    if ! ln -s "$target" "$tmp"; then
        rm -f "$tmp"
        log_error "atomic_symlink: failed to create symlink for $link"
        return 1
    fi
    if ! mv -f "$tmp" "$link"; then
        rm -f "$tmp"
        log_error "atomic_symlink: failed to place symlink $link"
        return 1
    fi
    return 0
}

# ---------------------------------------------------------------------------
# paths and managed detection
# ---------------------------------------------------------------------------

# resolve_real_path <path>: canonical path without GNU readlink -f (macOS-safe).
resolve_real_path() {
    local path="$1" next dir base
    [ -n "$path" ] || return 1
    case "$path" in
        /*) ;;
        *) path="$(pwd)/$path" ;;
    esac
    dir=$(dirname "$path")
    base=$(basename "$path")
    dir=$(cd "$dir" 2>/dev/null && pwd -P) || return 1
    path="$dir/$base"
    while [ -L "$path" ]; do
        next=$(readlink "$path") || return 1
        case "$next" in
            /*) path="$next" ;;
            *) path="$(dirname "$path")/$next" ;;
        esac
        dir=$(dirname "$path")
        base=$(basename "$path")
        dir=$(cd "$dir" 2>/dev/null && pwd -P) || return 1
        path="$dir/$base"
    done
    printf '%s\n' "$path"
}

# find_file_limited <root> <maxdepth> <filename>: first matching file path.
find_file_limited() {
    local root="$1" max="$2" name="$3"
    _find_file_at_depth() {
        local dir="$1" d="$2" entry
        if [ "$d" -gt "$max" ]; then
            return 1
        fi
        for entry in "$dir"/*; do
            [ -e "$entry" ] || continue
            if [ -f "$entry" ] && [ "$(basename "$entry")" = "$name" ]; then
                printf '%s\n' "$entry"
                return 0
            fi
            if [ -d "$entry" ] && [ "$d" -lt "$max" ]; then
                if _find_file_at_depth "$entry" $((d + 1)); then
                    return 0
                fi
            fi
        done
        return 1
    }
    _find_file_at_depth "$root" 0
}

# resolve_path <cli>: first match of the CLI name on the current PATH.
resolve_path() {
    local cli="$1"
    command -v "$cli" 2>/dev/null
}

# is_managed <path>: true if path is inside $CLI_TOOLBOX_HOME.
is_managed() {
    case "$1" in
        "$CLI_TOOLBOX_HOME"/*) return 0 ;;
        *) return 1 ;;
    esac
}

# detect_broken_symlinks: list basenames of broken symlinks in bin (one per line).
detect_broken_symlinks() {
    local bin="$CLI_TOOLBOX_HOME/bin" l
    [ -d "$bin" ] || return 0
    for l in "$bin"/*; do
        [ -L "$l" ] || continue
        if [ ! -e "$l" ]; then
            printf '%s\n' "$(basename "$l")"
        fi
    done
    return 0
}

# ---------------------------------------------------------------------------
# temp dirs and cleanup
# ---------------------------------------------------------------------------

# make_tempdir: mktemp -d registered for automatic cleanup. Must be called in
# the CURRENT shell (never inside $(...) — a command substitution would run it
# in a subshell and lose the registration). Sets the global TB_TMPDIR.
make_tempdir() {
    local d
    d=$(mktemp -d "${TMPDIR:-/tmp}/cli-toolbox.XXXXXX") || return 1
    __TB_TEMPDIRS+=("$d")
    # shellcheck disable=SC2034  # read by installers.sh after sourcing
    TB_TMPDIR="$d"
    return 0
}

cleanup() {
    local i d
    for i in "${!__TB_TEMPDIRS[@]}"; do
        d="${__TB_TEMPDIRS[$i]}"
        if [ -n "$d" ] && [ -d "$d" ]; then
            rm -rf "$d"
        fi
    done
    __TB_TEMPDIRS=()
}

trap cleanup EXIT INT TERM

# ---------------------------------------------------------------------------
# secret presence helpers (doctor: presence only, never values)
# ---------------------------------------------------------------------------

# env_present <VARNAME>: true if the named environment variable is set/non-empty.
env_present() {
    local v="$1"
    [ -n "${!v:-}" ]
}

# path_present <path>: true if the path exists (file, dir, or symlink).
path_present() {
    [ -e "$1" ] || [ -L "$1" ]
}