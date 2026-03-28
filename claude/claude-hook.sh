#!/usr/bin/env bash
# =============================================================================
# Claude Code PreToolUse Hook — Package Install Verification
# =============================================================================
#
# Intercepts Bash tool calls that contain package install commands.
# Parses the package name and version, runs verify-package.sh, and returns
# a structured allow/deny decision to Claude.
#
# Install:
#   1. Deploy shared scripts to /opt/package-verify/:
#        cp ../shared/verify-package.sh /opt/package-verify/
#        cp claude-hook.sh /opt/package-verify/
#
#   2. Add to ~/.claude/settings.json or .claude/settings.json:
#
#   {
#     "hooks": {
#       "PreToolUse": [
#         {
#           "matcher": "Bash",
#           "hooks": [
#             {
#               "type": "command",
#               "command": "/opt/package-verify/claude-hook.sh",
#               "timeout": 30
#             }
#           ]
#         }
#       ]
#     }
#   }
#
# =============================================================================

set -uo pipefail

# HARDCODED — not overridable via environment to prevent bypass
VERIFY_SCRIPT="/opt/package-verify/verify-package.sh"

# Read hook input from stdin
INPUT=$(cat)
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty')

# If no command, allow immediately
[[ -z "$COMMAND" ]] && exit 0

# Strip quoted strings so we don't match package names inside commit messages,
# echo statements, heredocs, etc. Only match actual commands being executed.
COMMAND_STRIPPED=$(echo "$COMMAND" | sed "s/'[^']*'//g; s/\"[^\"]*\"//g")

# ── Detect package install commands ──────────────────────────────────────────

ECOSYSTEM=""
PACKAGES=()

# pip install — matches all invocation styles including:
#   pip install X, pip3 install X, python -m pip install X,
#   .venv/bin/pip install X, /path/to/pip install X,
#   ENV=val pip install X, cd /tmp && pip install X
if echo "$COMMAND_STRIPPED" | grep -qE 'pip3?\s+install\b|python[0-9.]* -m pip install\b'; then
    ECOSYSTEM="pip"

    # Extract everything after "pip install" (or "pip3 install"), stop at shell operators
    raw_args=""
    raw_args=$(echo "$COMMAND" | sed -n 's/.*pip[3]\{0,1\} install //p' | sed 's/[;&|].*//')

    # Block dangerous install modes at the hook level
    if echo "$raw_args" | grep -qE '(\s|^)(-r|--requirement)\b'; then
        PACKAGES+=("BLOCKED:-r")
    elif echo "$raw_args" | grep -qE '(\s|^)(-e|--editable)\b'; then
        PACKAGES+=("BLOCKED:-e")
    elif echo "$raw_args" | grep -qE '(\s|^)(-i|--index-url|-f|--find-links|--extra-index-url)\b'; then
        PACKAGES+=("BLOCKED:custom-source")
    else
        while IFS= read -r token; do
            [[ "$token" == -* ]] && continue
            [[ "$token" == "install" ]] && continue
            [[ -z "$token" ]] && continue
            # Block local paths, wheels, VCS at hook level
            if [[ "$token" == *"/"* || "$token" == *.whl || "$token" == *.tar.gz || "$token" == git+* || "$token" == "." || "$token" == ".." ]]; then
                PACKAGES+=("BLOCKED:local-path")
                continue
            fi
            PACKAGES+=("$token")
        done < <(echo "$raw_args" | tr ' ' '\n')
    fi
fi

# npm install <packages>
if echo "$COMMAND_STRIPPED" | grep -qE '\bnpm\s+install\b|\bnpm\s+i\b'; then
    ECOSYSTEM="npm"
    while IFS= read -r token; do
        [[ "$token" == -* ]] && continue
        [[ "$token" == "install" || "$token" == "i" || "$token" == "npm" ]] && continue
        [[ -z "$token" ]] && continue
        # Skip if no packages specified (bare npm install = install from package.json)
        PACKAGES+=("$token")
    done < <(echo "$COMMAND" | sed -n 's/.*npm \(install\|i\) //p' | tr ' ' '\n')
fi

# npx <package> — downloads and runs without installing
if echo "$COMMAND_STRIPPED" | grep -qE '\bnpx\s+'; then
    ECOSYSTEM="npm"
    while IFS= read -r token; do
        [[ "$token" == -* ]] && continue
        [[ "$token" == "npx" ]] && continue
        [[ -z "$token" ]] && continue
        PACKAGES+=("$token")
        break  # npx only runs the first package
    done < <(echo "$COMMAND" | sed -n 's/.*npx //p' | sed 's/[;&|].*//' | tr ' ' '\n')
fi

# yarn add / pnpm add / bun add
if echo "$COMMAND_STRIPPED" | grep -qE '\b(yarn|pnpm|bun)\s+add\b'; then
    ECOSYSTEM="npm"
    while IFS= read -r token; do
        [[ "$token" == -* ]] && continue
        [[ "$token" == "add" || "$token" == "yarn" || "$token" == "pnpm" || "$token" == "bun" ]] && continue
        [[ -z "$token" ]] && continue
        PACKAGES+=("$token")
    done < <(echo "$COMMAND" | sed -n 's/.*\(yarn\|pnpm\|bun\) add //p' | sed 's/[;&|].*//' | tr ' ' '\n')
fi

# cargo add / cargo install
if echo "$COMMAND_STRIPPED" | grep -qE '\bcargo\s+(add|install)\b'; then
    ECOSYSTEM="cargo"
    while IFS= read -r token; do
        [[ "$token" == -* ]] && continue
        [[ "$token" == "cargo" || "$token" == "add" || "$token" == "install" ]] && continue
        [[ -z "$token" ]] && continue
        PACKAGES+=("$token")
    done < <(echo "$COMMAND" | sed -n 's/.*cargo \(add\|install\) //p' | sed 's/[;&|].*//' | tr ' ' '\n')
fi

# go get / go install
if echo "$COMMAND_STRIPPED" | grep -qE '\bgo\s+(get|install)\b'; then
    ECOSYSTEM="go"
    while IFS= read -r token; do
        [[ "$token" == -* ]] && continue
        [[ "$token" == "go" || "$token" == "get" || "$token" == "install" ]] && continue
        [[ -z "$token" ]] && continue
        # Go modules look like github.com/user/repo or golang.org/x/pkg
        # Strip @version suffix for the package name, keep version separate
        local_pkg="$token"
        local_ver=""
        if [[ "$token" == *"@"* ]]; then
            local_pkg="${token%%@*}"
            local_ver="${token#*@}"
        fi
        PACKAGES+=("$local_pkg${local_ver:+@$local_ver}")
        break  # go get/install typically takes one module
    done < <(echo "$COMMAND" | sed -n 's/.*go \(get\|install\) //p' | sed 's/[;&|].*//' | tr ' ' '\n')
fi

# Not a package install command — allow
[[ -z "$ECOSYSTEM" ]] && exit 0

# No packages extracted (e.g., bare "npm install" from lockfile) — allow
[[ ${#PACKAGES[@]} -eq 0 ]] && exit 0

# ── Verify each package ─────────────────────────────────────────────────────

BLOCKED=()
REASONS=()

for pkg_spec in "${PACKAGES[@]}"; do
    # Handle blocked install modes (detected in parsing above)
    if [[ "$pkg_spec" == BLOCKED:* ]]; then
        BLOCKED+=("${pkg_spec#BLOCKED:}")
        REASONS+=("BLOCK: This install method requires administrator approval.")
        continue
    fi

    # Split package==version or package>=version
    local_pkg=""
    local_ver=""

    if [[ "$pkg_spec" == *"=="* ]]; then
        local_pkg="${pkg_spec%%==*}"
        local_ver="${pkg_spec#*==}"
    elif [[ "$pkg_spec" == *">="* ]]; then
        local_pkg="${pkg_spec%%>=*}"
        local_ver=""
    elif [[ "$pkg_spec" == *"@"* ]]; then
        # npm style: package@version
        local_pkg="${pkg_spec%%@*}"
        local_ver="${pkg_spec#*@}"
    else
        local_pkg="$pkg_spec"
        local_ver=""
    fi

    # Skip empty package names
    [[ -z "$local_pkg" ]] && continue

    # Run verification
    local_output=""
    if [[ -x "$VERIFY_SCRIPT" ]]; then
        local_output=$("$VERIFY_SCRIPT" "$ECOSYSTEM" "$local_pkg" "$local_ver" 2>&1) || {
            BLOCKED+=("$local_pkg")
            # Extract the BLOCK reason
            local_reason=$(echo "$local_output" | grep "^BLOCK:" | head -1)
            REASONS+=("${local_reason:-Verification failed for $local_pkg}")
        }
    else
        # No verify script — just log
        echo "WARN: verify-package.sh not found at $VERIFY_SCRIPT" >&2
        exit 0
    fi
done

# ── Return decision ──────────────────────────────────────────────────────────

if [[ ${#BLOCKED[@]} -gt 0 ]]; then
    # Build reason string
    REASON_TEXT="Package verification failed:\n"
    for i in "${!BLOCKED[@]}"; do
        REASON_TEXT+="  - ${BLOCKED[$i]}: ${REASONS[$i]}\n"
    done
    REASON_TEXT+="\nThis package must be approved by an administrator before installation. Do not attempt to bypass this check."

    # Return structured deny to Claude
    jq -n \
        --arg reason "$(echo -e "$REASON_TEXT")" \
        '{
            "hookSpecificOutput": {
                "hookEventName": "PreToolUse",
                "permissionDecision": "deny",
                "permissionDecisionReason": $reason
            }
        }'
    exit 0
fi

# All packages passed — allow
exit 0
