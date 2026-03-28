#!/usr/bin/env bash
# =============================================================================
# python3 wrapper — injects pip verification into new venvs
# =============================================================================
#
# Wraps python3 to intercept `python3 -m venv` and `python3 -m pip install`.
#
# When a venv is created, this wrapper:
#   1. Lets the real python3 create the venv normally
#   2. Replaces the venv's pip with our verification wrapper
#
# When `python3 -m pip install` is called directly, this wrapper:
#   1. Extracts package names and runs verification
#   2. Blocks if verification fails
#   3. Passes through to real python3 if clean
#
# Installed by install.sh to:
#   System mode: /usr/local/bin/python3
#   User mode:   ~/.local/bin/python3
#
# The installer rewrites hardcoded paths automatically for each mode.
#
# =============================================================================

set -uo pipefail

# HARDCODED — not overridable via environment to prevent bypass
VERIFY_SCRIPT="/opt/package-verify/verify-package.sh"
WRAPPER_PIP="/opt/package-verify/pip-wrapper.sh"

# Find the real python3 (skip this script)
_realpath() { python3.real -c "import os; print(os.path.realpath('$1'))" 2>/dev/null || readlink -f "$1" 2>/dev/null || echo "$1"; }

SELF="$(_realpath "${BASH_SOURCE[0]}" 2>/dev/null || echo "${BASH_SOURCE[0]}")"
REAL_PYTHON=""

# Look for the real python3 binary, skipping ourselves
for candidate in /usr/bin/python3 /usr/local/bin/python3.real /usr/bin/python3.12 /usr/bin/python3.11 /usr/bin/python3.13; do
    if [[ -x "$candidate" ]]; then
        candidate_real="$(_realpath "$candidate" 2>/dev/null || echo "$candidate")"
        if [[ "$candidate_real" != "$SELF" && "$candidate" != "$SELF" ]]; then
            REAL_PYTHON="$candidate"
            break
        fi
    fi
done

if [[ -z "$REAL_PYTHON" ]]; then
    # Fallback: search PATH, skipping /usr/local/bin
    REAL_PYTHON=$(PATH="/usr/bin:/usr/sbin:$PATH" type -p python3 2>/dev/null || echo "")
    if [[ -z "$REAL_PYTHON" || "$(_realpath "$REAL_PYTHON")" == "$SELF" ]]; then
        echo "ERROR: python3 wrapper could not find real python3 binary" >&2
        exit 1
    fi
fi

# ── Intercept: python3 -m venv ───────────────────────────────────────────────

if [[ "${1:-}" == "-m" && "${2:-}" == "venv" ]]; then
    # Let the real python create the venv first
    "$REAL_PYTHON" "$@"
    rc=$?
    [[ $rc -ne 0 ]] && exit $rc

    # Find the venv path (last non-flag argument)
    venv_path=""
    for arg in "${@:3}"; do
        [[ "$arg" != -* ]] && venv_path="$arg"
    done

    # Inject our pip wrapper into the venv
    if [[ -n "$venv_path" && -f "$venv_path/bin/pip" && -x "$WRAPPER_PIP" ]]; then
        # Save the real venv pip — hidden name, but must stay executable
        # for passthrough commands (pip list, freeze, show, etc.)
        # The name is deliberately obscure to prevent AI agents from guessing it.
        real_venv_pip="$venv_path/bin/.pv-$(head -c 8 /dev/urandom | xxd -p)-delegate"
        mv "$venv_path/bin/pip" "$real_venv_pip"
        chmod 755 "$real_venv_pip"
        cp "$WRAPPER_PIP" "$venv_path/bin/pip"
        chmod +x "$venv_path/bin/pip"

        # Do the same for pip3 if it exists
        if [[ -f "$venv_path/bin/pip3" ]]; then
            # Just replace pip3 with our wrapper — no need to keep the original
            # since .pv-*-delegate handles the real pip calls
            rm -f "$venv_path/bin/pip3"
            cp "$WRAPPER_PIP" "$venv_path/bin/pip3"
            chmod +x "$venv_path/bin/pip3"
        fi

        # Create a hidden config so the wrapper knows where the real pip is
        # Paths are hardcoded — not overridable via environment
        cat > "$venv_path/bin/.pip-wrapper.conf" << CONF
REAL_PIP="$real_venv_pip"
CONF
        chmod 644 "$venv_path/bin/.pip-wrapper.conf"

        # Note: we do NOT wrap the venv's python binary. Doing so breaks venv
        # isolation (the delegate pip's shebang points to venv/bin/python, and
        # replacing it with a wrapper that execs the system python loses the
        # venv's sys.prefix). The venv's pip IS wrapped, and the system python3
        # wrapper + hooks cover the python -m pip install path.
    fi

    exit 0
fi

# ── Intercept: python3 -m pip install ────────────────────────────────────────

if [[ "${1:-}" == "-m" && "${2:-}" == "pip" && "${3:-}" == "install" ]]; then
    # Run verification on the packages before passing to real python
    if [[ -x "$VERIFY_SCRIPT" ]]; then
        PACKAGES=()
        SKIP_NEXT=0
        for arg in "${@:4}"; do
            if [[ "$SKIP_NEXT" == "1" ]]; then SKIP_NEXT=0; continue; fi
            case "$arg" in
                -r|--requirement|-e|--editable|-i|--index-url|-f|--find-links|--extra-index-url)
                    echo "BLOCKED: This install method requires administrator approval." >&2; exit 1 ;;
                -c|--constraint|-t|--target|--prefix|--src|--root)
                    SKIP_NEXT=1; continue ;;
                -*) continue ;;
            esac
            [[ "$arg" == *".txt"* || "$arg" == *".cfg"* || "$arg" == *".toml"* ]] && continue
            [[ -z "$arg" ]] && continue
            PACKAGES+=("$arg")
        done

        for pkg_spec in "${PACKAGES[@]}"; do
            pkg="" ver=""
            if [[ "$pkg_spec" == *"=="* ]]; then
                pkg="${pkg_spec%%==*}"; ver="${pkg_spec#*==}"
            elif [[ "$pkg_spec" == *">="* ]]; then
                pkg="${pkg_spec%%>=*}"
            else
                pkg="$pkg_spec"
            fi
            [[ -z "$pkg" ]] && continue

            if ! "$VERIFY_SCRIPT" pip "$pkg" "$ver" 2>&1; then
                echo "" >&2
                echo "=== PACKAGE BLOCKED ===" >&2
                echo "Package '$pkg_spec' failed verification." >&2
                echo "=======================" >&2
                exit 1
            fi
        done
    fi
fi

# ── Pass through to real python3 ─────────────────────────────────────────────

exec "$REAL_PYTHON" "$@"
