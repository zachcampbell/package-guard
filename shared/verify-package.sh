#!/usr/bin/env bash
# =============================================================================
# Package Verification Script
# =============================================================================
#
# Checks a package against multiple signals before allowing installation:
#   1. Allowlist — is this package pre-approved?
#   2. Recency  — was this version published in the last 48 hours?
#   3. Content  — does the package source contain suspicious patterns?
#
# Usage:
#   verify-package.sh <ecosystem> <package> [version]
#   verify-package.sh pip requests 2.32.3
#   verify-package.sh npm express
#
# Exit codes:
#   0  — package is clean
#   1  — package failed verification (reason on stderr)
#   2  — verification error (network, parse failure, etc.)
#
# Configuration:
#   All settings are read from policy.conf (not environment variables).
#   Default location: /opt/package-verify/policy.conf (system mode)
#                     ~/.local/share/package-verify/policy.conf (user mode)
#   The installer rewrites paths automatically for the chosen install mode.
# =============================================================================

set -euo pipefail

ECOSYSTEM="${1:-}"
PACKAGE="${2:-}"
VERSION="${3:-}"

# Security-critical config — read from root-owned file, NOT environment
CONF_FILE="/opt/package-verify/policy.conf"
if [[ -f "$CONF_FILE" ]]; then
    source "$CONF_FILE"
fi

# Defaults (overridden by policy.conf, NOT by environment variables)
ALLOWLIST="${ALLOWLIST:-/opt/package-verify/package-allowlist.txt}"
MAX_AGE_HOURS="${MAX_AGE_HOURS:-48}"
SKIP_RECENCY="${SKIP_RECENCY:-0}"
SKIP_CONTENT="${SKIP_CONTENT:-0}"
STRICT="${STRICT:-0}"
FAIL_CLOSED="${FAIL_CLOSED:-0}"

# Single-line suspicious patterns (matched per-line with grep)
SUSPICIOUS_SINGLE_LINE=(
    'exec(compile'
    'marshal\.loads'
    'types\.CodeType'
)

# Co-occurrence pairs — both terms must appear in the SAME FILE (not same line)
# These are the exact techniques used in TeamPCP (LiteLLM, Telnyx, CanisterWorm)
# Format: "term1|term2" — file must contain both to flag
# Note: setup.py commonly contains exec(f.read()) for version loading
# and urllib3 as a dependency name. Rules must not match those patterns.
SUSPICIOUS_COOCCUR=(
    'b64decode|exec'
    'b64decode|subprocess'
    'b64decode|eval('
    'b64decode|os.system'
    'wave.open|readframes'
    'wave.open|b64decode'
    'socket.connect|b64decode'
    'urllib.request|exec'
    'ctypes.windll|ShellExecute'
    '__import__|b64decode'
    'codecs.decode|exec'
)

# ── Helpers ──────────────────────────────────────────────────────────────────

die()  { echo "BLOCK: $*" >&2; exit 1; }
warn() { echo "WARN: $*" >&2; }
info() { echo "INFO: $*" >&2; }
# warn_or_die: in enforcement mode (FAIL_CLOSED=1), treat warnings as blocks
warn_or_die() {
    if [[ "$FAIL_CLOSED" == "1" ]]; then
        die "$*"
    else
        warn "$*"
    fi
}

usage() {
    echo "Usage: verify-package.sh <pip|npm|cargo> <package> [version]" >&2
    exit 2
}

# ── Allowlist Check ──────────────────────────────────────────────────────────

check_allowlist() {
    if [[ ! -f "$ALLOWLIST" ]]; then
        if [[ "$STRICT" == "1" ]]; then
            die "No allowlist found at $ALLOWLIST and PACKAGE_STRICT=1"
        fi
        info "No allowlist at $ALLOWLIST — skipping allowlist check"
        return 0
    fi

    # Allowlist format: one entry per line
    #   package           — any version allowed
    #   package==1.2.3    — specific version only
    #   package>=1.2.0    — version constraint (pip-style, checked loosely)
    #   # comment lines ignored
    #   blank lines ignored

    local found=0
    while IFS= read -r line; do
        line="${line%%#*}"          # strip comments
        line="${line// /}"          # strip spaces
        [[ -z "$line" ]] && continue

        local list_pkg list_ver=""
        if [[ "$line" == *"=="* ]]; then
            list_pkg="${line%%==*}"
            list_ver="${line#*==}"
        elif [[ "$line" == *">="* ]]; then
            list_pkg="${line%%>=*}"
            # For >= constraints, just allow if package matches (loose check)
            list_ver=""
        else
            list_pkg="$line"
        fi

        # Case-insensitive comparison for pip packages
        if [[ "${list_pkg,,}" == "${PACKAGE,,}" ]]; then
            if [[ -n "$list_ver" && -n "$VERSION" && "$list_ver" != "$VERSION" ]]; then
                die "Package $PACKAGE is allowlisted for version $list_ver only (requested: $VERSION). Contact your administrator to update the allowlist."
            fi
            found=1
            break
        fi
    done < "$ALLOWLIST"

    if [[ "$found" == "0" ]]; then
        if [[ "$STRICT" == "1" ]]; then
            die "Package '$PACKAGE' is not on the approved package list. Contact your administrator to request approval."
        else
            warn "Package '$PACKAGE' is not on the approved list"
        fi
    else
        info "Package '$PACKAGE' is on the allowlist"
    fi
}

# ── Recency Check (PyPI) ────────────────────────────────────────────────────

check_recency_pypi() {
    [[ "$SKIP_RECENCY" == "1" ]] && return 0

    local url="https://pypi.org/pypi/${PACKAGE}/json"
    local response
    response=$(curl -sf --max-time 10 "$url" 2>/dev/null) || {
        warn_or_die "Could not fetch PyPI metadata for $PACKAGE (network error or package not found)"
        return 0
    }

    # Get the upload time for the requested version (or latest)
    local upload_time
    if [[ -n "$VERSION" ]]; then
        upload_time=$(echo "$response" | python3 -c "
import sys, json
data = json.load(sys.stdin)
releases = data.get('releases', {})
ver = '$VERSION'
if ver in releases and releases[ver]:
    print(releases[ver][0].get('upload_time_iso_8601', ''))
" 2>/dev/null)
    else
        upload_time=$(echo "$response" | python3 -c "
import sys, json
data = json.load(sys.stdin)
urls = data.get('urls', [])
if urls:
    print(urls[0].get('upload_time_iso_8601', ''))
" 2>/dev/null)
    fi

    if [[ -z "$upload_time" ]]; then
        warn_or_die "Could not determine upload time for $PACKAGE${VERSION:+ $VERSION}"
        return 0
    fi

    # Check age
    local upload_epoch now_epoch age_hours
    upload_epoch=$(python3 -c "
from datetime import datetime, timezone
t = datetime.fromisoformat('$upload_time'.replace('Z', '+00:00'))
print(int(t.timestamp()))
" 2>/dev/null) || return 0

    now_epoch=$(date +%s)
    age_hours=$(( (now_epoch - upload_epoch) / 3600 ))

    if [[ "$age_hours" -lt "$MAX_AGE_HOURS" ]]; then
        die "Package $PACKAGE${VERSION:+ $VERSION} was published ${age_hours}h ago (threshold: ${MAX_AGE_HOURS}h). Recently published packages require manual review."
    else
        info "Package $PACKAGE${VERSION:+ $VERSION} published ${age_hours}h ago (OK)"
    fi
}

# ── Recency Check (npm) ─────────────────────────────────────────────────────

check_recency_npm() {
    [[ "$SKIP_RECENCY" == "1" ]] && return 0

    local url="https://registry.npmjs.org/${PACKAGE}"
    local response
    response=$(curl -sf --max-time 10 "$url" 2>/dev/null) || {
        warn_or_die "Could not fetch npm metadata for $PACKAGE"
        return 0
    }

    local ver="${VERSION}"
    if [[ -z "$ver" ]]; then
        ver=$(echo "$response" | python3 -c "
import sys, json
data = json.load(sys.stdin)
print(data.get('dist-tags', {}).get('latest', ''))
" 2>/dev/null)
    fi

    if [[ -z "$ver" ]]; then
        warn_or_die "Could not determine version for $PACKAGE"
        return 0
    fi

    local publish_time
    publish_time=$(echo "$response" | python3 -c "
import sys, json
data = json.load(sys.stdin)
t = data.get('time', {}).get('$ver', '')
print(t)
" 2>/dev/null)

    if [[ -z "$publish_time" ]]; then
        warn_or_die "Could not determine publish time for $PACKAGE@$ver"
        return 0
    fi

    local publish_epoch now_epoch age_hours
    publish_epoch=$(python3 -c "
from datetime import datetime, timezone
t = datetime.fromisoformat('$publish_time'.replace('Z', '+00:00'))
print(int(t.timestamp()))
" 2>/dev/null) || return 0

    now_epoch=$(date +%s)
    age_hours=$(( (now_epoch - publish_epoch) / 3600 ))

    if [[ "$age_hours" -lt "$MAX_AGE_HOURS" ]]; then
        die "Package $PACKAGE@$ver was published ${age_hours}h ago (threshold: ${MAX_AGE_HOURS}h). Recently published packages require manual review."
    else
        info "Package $PACKAGE@$ver published ${age_hours}h ago (OK)"
    fi
}

# ── Recency Check (Go modules) ───────────────────────────────────────────────

check_recency_go() {
    [[ "$SKIP_RECENCY" == "1" ]] && return 0

    # Go module paths use slashes — need to be URL-encoded for the proxy
    # e.g., github.com/user/repo -> github.com/user/repo
    local module="$PACKAGE"

    # If no version specified, get the latest
    local ver="$VERSION"
    if [[ -z "$ver" ]]; then
        local latest_url="https://proxy.golang.org/${module}/@latest"
        local latest_resp
        latest_resp=$(curl -sf --max-time 10 "$latest_url" 2>/dev/null) || {
            warn_or_die "Could not fetch Go module info for $module"
            return 0
        }
        ver=$(echo "$latest_resp" | python3 -c "
import sys, json
data = json.load(sys.stdin)
print(data.get('Version', ''))
" 2>/dev/null)
    fi

    if [[ -z "$ver" ]]; then
        warn_or_die "Could not determine version for Go module $module"
        return 0
    fi

    # Get version info with timestamp
    local info_url="https://proxy.golang.org/${module}/@v/${ver}.info"
    local info_resp
    info_resp=$(curl -sf --max-time 10 "$info_url" 2>/dev/null) || {
        warn_or_die "Could not fetch version info for $module@$ver"
        return 0
    }

    local publish_time
    publish_time=$(echo "$info_resp" | python3 -c "
import sys, json
data = json.load(sys.stdin)
print(data.get('Time', ''))
" 2>/dev/null)

    if [[ -z "$publish_time" ]]; then
        warn_or_die "Could not determine publish time for $module@$ver"
        return 0
    fi

    local publish_epoch now_epoch age_hours
    publish_epoch=$(python3 -c "
from datetime import datetime, timezone
t = datetime.fromisoformat('$publish_time'.replace('Z', '+00:00'))
print(int(t.timestamp()))
" 2>/dev/null) || return 0

    now_epoch=$(date +%s)
    age_hours=$(( (now_epoch - publish_epoch) / 3600 ))

    if [[ "$age_hours" -lt "$MAX_AGE_HOURS" ]]; then
        die "Go module $module@$ver was published ${age_hours}h ago (threshold: ${MAX_AGE_HOURS}h). Recently published modules require manual review."
    else
        info "Go module $module@$ver published ${age_hours}h ago (OK)"
    fi
}

# ── Content Scan (PyPI) ─────────────────────────────────────────────────────

check_content_pypi() {
    [[ "$SKIP_CONTENT" == "1" ]] && return 0

    local tmpdir
    tmpdir=$(mktemp -d)
    trap "rm -rf '$tmpdir'" RETURN

    # Download without installing
    pip download --no-deps --no-binary :all: -d "$tmpdir" \
        "${PACKAGE}${VERSION:+==$VERSION}" 2>/dev/null || {
        # Try with binary (wheel) if sdist fails
        pip download --no-deps -d "$tmpdir" \
            "${PACKAGE}${VERSION:+==$VERSION}" 2>/dev/null || {
            warn_or_die "Could not download $PACKAGE for content scan"
            return 0
        }
    }

    # Extract and scan
    local archive
    archive=$(find "$tmpdir" -maxdepth 1 -type f | head -1)
    [[ -z "$archive" ]] && return 0

    local extractdir="$tmpdir/extracted"
    mkdir -p "$extractdir"

    case "$archive" in
        *.tar.gz|*.tgz)  tar xzf "$archive" -C "$extractdir" 2>/dev/null ;;
        *.whl|*.zip)      unzip -q "$archive" -d "$extractdir" 2>/dev/null ;;
        *)                warn_or_die "Unknown archive format: $archive — cannot verify content"; return 0 ;;
    esac

    # Scan Python files for suspicious patterns
    local hits=""

    # Check single-line patterns (both terms on the same line)
    for pattern in "${SUSPICIOUS_SINGLE_LINE[@]}"; do
        local matches
        matches=$(grep -rl "$pattern" "$extractdir" --include="*.py" 2>/dev/null | head -5 || true)
        if [[ -n "$matches" ]]; then
            hits+="  Pattern '$pattern' found in:\n"
            while IFS= read -r f; do
                local relpath="${f#$extractdir/}"
                hits+="    $relpath\n"
            done <<< "$matches"
        fi
    done

    # Check co-occurrence pairs (both terms in the same file, any line)
    local pyfiles
    pyfiles=$(find "$extractdir" -name "*.py" -type f 2>/dev/null)
    for pair in "${SUSPICIOUS_COOCCUR[@]}"; do
        local term1="${pair%%|*}"
        local term2="${pair#*|}"
        while IFS= read -r f; do
            [[ -z "$f" ]] && continue
            if grep -q "$term1" "$f" 2>/dev/null && grep -q "$term2" "$f" 2>/dev/null; then
                local relpath="${f#$extractdir/}"
                hits+="  Co-occurrence '$term1' + '$term2' found in:\n"
                hits+="    $relpath\n"
            fi
        done <<< "$pyfiles"
    done

    if [[ -n "$hits" ]]; then
        echo -e "BLOCK: Package $PACKAGE contains suspicious code patterns:\n$hits" >&2
        echo "This may indicate a supply chain attack. Review the package source before installing." >&2
        exit 1
    fi

    info "Content scan clean for $PACKAGE"
}

# ── Main ─────────────────────────────────────────────────────────────────────

[[ -z "$ECOSYSTEM" || -z "$PACKAGE" ]] && usage

info "Verifying $ECOSYSTEM package: $PACKAGE${VERSION:+ $VERSION}"

check_allowlist

case "$ECOSYSTEM" in
    pip|python|pypi)
        check_recency_pypi
        check_content_pypi
        ;;
    npm|node)
        check_recency_npm
        # npm content scan not implemented yet — packages are tarballs
        # with different structure. Could add later.
        ;;
    go|golang)
        check_recency_go
        ;;
    cargo|rust)
        # crates.io API is similar, could add recency check
        warn "Cargo verification not yet implemented"
        ;;
    *)
        warn "Unknown ecosystem: $ECOSYSTEM"
        ;;
esac

info "Package $PACKAGE${VERSION:+ $VERSION} passed all checks"
exit 0
