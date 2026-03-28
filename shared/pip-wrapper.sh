#!/usr/bin/env bash
# =============================================================================
# pip wrapper — universal package verification
# =============================================================================
#
# Drop-in replacement for pip that verifies packages before installing.
# Works for any tool that calls pip — AI assistants, terminals, scripts, CI.
#
# Installed by install.sh to:
#   System mode: /usr/local/bin/pip
#   User mode:   ~/.local/bin/pip
#
# The installer rewrites hardcoded paths automatically for each mode.
#
# Only intercepts "install" subcommands. All other pip commands
# (list, freeze, show, etc.) pass through to the real pip.
# =============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Check for venv config (injected by python3 wrapper when creating venvs)
# Only reads REAL_PIP — security paths are hardcoded below
if [[ -f "$SCRIPT_DIR/.pip-wrapper.conf" ]]; then
    source "$SCRIPT_DIR/.pip-wrapper.conf"
fi

# HARDCODED — not overridable via environment to prevent bypass
VERIFY_SCRIPT="/opt/package-verify/verify-package.sh"

# Find the real pip (skip this script if it shadows pip in PATH)
if [[ -n "${REAL_PIP:-}" ]]; then
    PIP="$REAL_PIP"
else
    # Find pip, skipping this script
    # realpath isn't available on macOS by default — use python3 as portable fallback
    _realpath() { python3 -c "import os; print(os.path.realpath('$1'))" 2>/dev/null || readlink -f "$1" 2>/dev/null || echo "$1"; }
    SELF="$(_realpath "${BASH_SOURCE[0]}")"
    PIP=""
    # 'type -ap' is bash-portable; 'which -a' is Linux/macOS
    while IFS= read -r candidate; do
        candidate_real="$(_realpath "$candidate")"
        if [[ "$candidate_real" != "$SELF" ]]; then
            PIP="$candidate"
            break
        fi
    done < <(type -ap pip pip3 2>/dev/null || which -a pip pip3 2>/dev/null)

    if [[ -z "$PIP" ]]; then
        echo "ERROR: Could not find real pip binary" >&2
        exit 1
    fi
fi

# Helper: run the real pip
_run_real_pip() {
    if [[ -x "$PIP" ]]; then
        exec "$PIP" "$@"
    fi
    echo "ERROR: Cannot execute real pip at $PIP" >&2
    exit 1
}

# Pass through if not "install" subcommand
SUBCOMMAND="${1:-}"
if [[ "$SUBCOMMAND" != "install" ]]; then
    _run_real_pip "$@"
fi

# Block non-index installs (requirements files, local paths, wheels, VCS, custom indexes)
# These bypass package-name verification entirely
HAS_BLOCKED_SOURCE=0
for arg in "${@:2}"; do
    case "$arg" in
        -r|--requirement)
            echo "BLOCKED: pip install -r (requirements file) is not allowed." >&2
            echo "Read the requirements file and install packages individually: pip install pkg1 pkg2 pkg3" >&2
            HAS_BLOCKED_SOURCE=1 ;;
        -e|--editable)
            echo "BLOCKED: pip install -e (editable/VCS) requires administrator approval." >&2
            HAS_BLOCKED_SOURCE=1 ;;
        -i|--index-url|-f|--find-links|--extra-index-url)
            echo "BLOCKED: Custom package sources require administrator approval." >&2
            HAS_BLOCKED_SOURCE=1 ;;
    esac
    # Block local paths, wheels, archives, git+https
    if [[ "$arg" != -* && ("$arg" == *"/"* || "$arg" == *.whl || "$arg" == *.tar.gz || "$arg" == *.zip || "$arg" == git+* || "$arg" == "." || "$arg" == "..") ]]; then
        echo "BLOCKED: Local/VCS package installs require administrator approval." >&2
        HAS_BLOCKED_SOURCE=1
    fi
done
[[ "$HAS_BLOCKED_SOURCE" == "1" ]] && exit 1

# Parse arguments to extract package names
PACKAGES=()
SKIP_NEXT=0

for arg in "${@:2}"; do
    if [[ "$SKIP_NEXT" == "1" ]]; then
        SKIP_NEXT=0
        continue
    fi

    case "$arg" in
        -c|--constraint|-t|--target|--prefix|--src|--root|\
        --install-option|--global-option)
            SKIP_NEXT=1
            continue
            ;;
        -*)
            continue
            ;;
    esac

    [[ -z "$arg" ]] && continue
    PACKAGES+=("$arg")
done

# If no packages extracted (bare `pip install` from lockfile), pass through
if [[ ${#PACKAGES[@]} -eq 0 ]]; then
    _run_real_pip "$@"
fi

# Verify each package
FAILED=0
for pkg_spec in "${PACKAGES[@]}"; do
    pkg=""
    ver=""

    if [[ "$pkg_spec" == *"=="* ]]; then
        pkg="${pkg_spec%%==*}"
        ver="${pkg_spec#*==}"
    elif [[ "$pkg_spec" == *">="* ]]; then
        pkg="${pkg_spec%%>=*}"
    else
        pkg="$pkg_spec"
    fi

    [[ -z "$pkg" ]] && continue

    if [[ -x "$VERIFY_SCRIPT" ]]; then
        "$VERIFY_SCRIPT" pip "$pkg" "$ver" 2>&1 || {
            echo "" >&2
            echo "=== PACKAGE BLOCKED ===" >&2
            echo "Package '$pkg_spec' failed verification." >&2
            echo "Contact your administrator to request package approval." >&2
            echo "=======================" >&2
            FAILED=1
        }
    fi
done

if [[ "$FAILED" == "1" ]]; then
    exit 1
fi

# All checks passed — run the real pip
_run_real_pip "$@"
