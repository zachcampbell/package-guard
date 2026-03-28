#!/usr/bin/env bash
# =============================================================================
# Codex CLI PreToolUse Hook — Package Install Verification
# =============================================================================
#
# Intercepts Bash tool calls that contain package install commands.
# Parses the package name and version, runs the shared verify-package.sh,
# and returns a structured allow/deny decision to Codex.
#
# Codex hooks are experimental and Bash-only. The deny JSON format is
# compatible with Claude Code hooks — same script logic, different config.
#
# Install:
#   1. Enable hooks in Codex: features.codex_hooks = true
#   2. Place this file and the shared verify-package.sh at /opt/package-verify/
#   3. Copy hooks.json to ~/.codex/ or the project's .codex/ directory
#
# Differences from Claude Code hook:
#   - Codex hooks only fire for Bash tool (not Edit, Write, etc.)
#   - "allow" and "ask" decisions are parsed but not supported — they fail open
#   - Only "deny" reliably blocks execution
#   - Multiple matching hooks run concurrently (not serialized)
#
# =============================================================================

set -uo pipefail

# HARDCODED — not overridable via environment to prevent bypass
VERIFY_SCRIPT="/opt/package-verify/verify-package.sh"

# Read hook input from stdin (same format as Claude Code)
INPUT=$(cat)
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty')

[[ -z "$COMMAND" ]] && exit 0

# ── Detect package install commands ──────────────────────────────────────────

ECOSYSTEM=""
PACKAGES=()

# pip install — matches all invocation styles
if echo "$COMMAND" | grep -qE 'pip3?\s+install\b|python[0-9.]* -m pip install\b'; then
    ECOSYSTEM="pip"
    raw_args=""
    raw_args=$(echo "$COMMAND" | sed -n 's/.*pip[3]\{0,1\} install //p' | sed 's/[;&|].*//')
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
            if [[ "$token" == *"/"* || "$token" == *.whl || "$token" == *.tar.gz || "$token" == git+* || "$token" == "." || "$token" == ".." ]]; then
                PACKAGES+=("BLOCKED:local-path"); continue
            fi
            PACKAGES+=("$token")
        done < <(echo "$raw_args" | tr ' ' '\n')
    fi
fi

# npm install
if echo "$COMMAND" | grep -qE '\bnpm\s+install\b|\bnpm\s+i\b'; then
    ECOSYSTEM="npm"
    while IFS= read -r token; do
        [[ "$token" == -* ]] && continue
        [[ "$token" == "install" || "$token" == "i" || "$token" == "npm" ]] && continue
        [[ -z "$token" ]] && continue
        PACKAGES+=("$token")
    done < <(echo "$COMMAND" | sed -n 's/.*npm \(install\|i\) //p' | tr ' ' '\n')
fi

# cargo add
if echo "$COMMAND" | grep -qE '\bcargo\s+add\b'; then
    ECOSYSTEM="cargo"
    while IFS= read -r token; do
        [[ "$token" == -* ]] && continue
        [[ "$token" == "cargo" || "$token" == "add" ]] && continue
        [[ -z "$token" ]] && continue
        PACKAGES+=("$token")
    done < <(echo "$COMMAND" | sed -n 's/.*cargo add //p' | tr ' ' '\n')
fi

# Not a package install — allow
[[ -z "$ECOSYSTEM" ]] && exit 0
[[ ${#PACKAGES[@]} -eq 0 ]] && exit 0

# ── Verify each package ─────────────────────────────────────────────────────

BLOCKED=()
REASONS=()

for pkg_spec in "${PACKAGES[@]}"; do
    if [[ "$pkg_spec" == BLOCKED:* ]]; then
        BLOCKED+=("${pkg_spec#BLOCKED:}")
        REASONS+=("BLOCK: This install method requires administrator approval.")
        continue
    fi

    local_pkg=""
    local_ver=""

    if [[ "$pkg_spec" == *"=="* ]]; then
        local_pkg="${pkg_spec%%==*}"
        local_ver="${pkg_spec#*==}"
    elif [[ "$pkg_spec" == *">="* ]]; then
        local_pkg="${pkg_spec%%>=*}"
        local_ver=""
    elif [[ "$pkg_spec" == *"@"* ]]; then
        local_pkg="${pkg_spec%%@*}"
        local_ver="${pkg_spec#*@}"
    else
        local_pkg="$pkg_spec"
        local_ver=""
    fi

    [[ -z "$local_pkg" ]] && continue

    local_output=""
    if [[ -x "$VERIFY_SCRIPT" ]]; then
        local_output=$("$VERIFY_SCRIPT" "$ECOSYSTEM" "$local_pkg" "$local_ver" 2>&1) || {
            BLOCKED+=("$local_pkg")
            local_reason=$(echo "$local_output" | grep "^BLOCK:" | head -1)
            REASONS+=("${local_reason:-Verification failed for $local_pkg}")
        }
    else
        echo "WARN: verify-package.sh not found at $VERIFY_SCRIPT" >&2
        exit 0
    fi
done

# ── Return decision ──────────────────────────────────────────────────────────

if [[ ${#BLOCKED[@]} -gt 0 ]]; then
    REASON_TEXT="Package verification failed:\n"
    for i in "${!BLOCKED[@]}"; do
        REASON_TEXT+="  - ${BLOCKED[$i]}: ${REASONS[$i]}\n"
    done
    REASON_TEXT+="\nThis package must be approved by an administrator before installation. Do not attempt to bypass this check."

    # Codex supports the same deny format as Claude Code
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

exit 0
