#!/usr/bin/env bash
# =============================================================================
# Deployment Integrity Check
# =============================================================================
#
# Verifies that installed scripts, hooks, and config haven't been tampered with.
# Compares SHA256 checksums of deployed files against a manifest.
#
# Usage:
#   integrity-check.sh --generate    # Generate manifest from current install
#   integrity-check.sh --verify      # Verify install against manifest
#   integrity-check.sh --watch       # Run as cron job (verify + alert)
#
# Install as cron:
#   echo '*/15 * * * * /opt/package-verify/integrity-check.sh --watch' | sudo crontab -
#
# =============================================================================

set -uo pipefail

INSTALL_DIR="/opt/package-verify"
MANIFEST="$INSTALL_DIR/.integrity-manifest"
ALERT_LOG="/var/log/package-verify-integrity.log"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Files to monitor
MONITORED_FILES=(
    "$INSTALL_DIR/verify-package.sh"
    "$INSTALL_DIR/pip-wrapper.sh"
    "$INSTALL_DIR/python-wrapper.sh"
    "$INSTALL_DIR/claude-hook.sh"
    "$INSTALL_DIR/codex-hook.sh"
    "$INSTALL_DIR/gemini-hook.sh"
    "$INSTALL_DIR/policy.conf"
    "$INSTALL_DIR/package-allowlist.txt"
    "/usr/local/bin/pip"
    "/usr/local/bin/python3"
)

# Also check hook configs (may not all exist)
HOOK_CONFIGS=(
    "$HOME/.claude/settings.json"
    "$HOME/.codex/hooks.json"
    "$HOME/.gemini/settings.json"
)

generate_manifest() {
    echo "# Package verification integrity manifest" > "$MANIFEST"
    echo "# Generated: $(date -u '+%Y-%m-%d %H:%M:%S UTC')" >> "$MANIFEST"
    echo "" >> "$MANIFEST"

    for f in "${MONITORED_FILES[@]}" "${HOOK_CONFIGS[@]}"; do
        if [[ -f "$f" ]]; then
            sha=$(sha256sum "$f" | awk '{print $1}')
            echo "$sha  $f" >> "$MANIFEST"
        fi
    done

    chmod 600 "$MANIFEST"
    echo "Manifest generated: $MANIFEST ($(wc -l < "$MANIFEST") entries)"
}

verify_manifest() {
    if [[ ! -f "$MANIFEST" ]]; then
        echo -e "${RED}No manifest found.${NC} Run with --generate first." >&2
        return 1
    fi

    local failures=0
    local checked=0
    local missing=0

    while IFS='  ' read -r expected_hash filepath; do
        [[ -z "$expected_hash" || "$expected_hash" == \#* ]] && continue
        checked=$((checked + 1))

        if [[ ! -f "$filepath" ]]; then
            echo -e "  ${RED}MISSING${NC}  $filepath"
            failures=$((failures + 1))
            missing=$((missing + 1))
            continue
        fi

        actual_hash=$(sha256sum "$filepath" | awk '{print $1}')
        if [[ "$actual_hash" != "$expected_hash" ]]; then
            echo -e "  ${RED}MODIFIED${NC} $filepath"
            echo "    expected: $expected_hash"
            echo "    actual:   $actual_hash"
            failures=$((failures + 1))
        else
            echo -e "  ${GREEN}OK${NC}       $filepath"
        fi
    done < "$MANIFEST"

    echo ""
    echo "Checked $checked files: $((checked - failures)) OK, $failures issues ($missing missing)"

    if [[ "$failures" -gt 0 ]]; then
        echo -e "${RED}INTEGRITY CHECK FAILED${NC}"
        return 1
    else
        echo -e "${GREEN}ALL FILES INTACT${NC}"
        return 0
    fi
}

watch_mode() {
    # Silent unless something is wrong — suitable for cron
    if [[ ! -f "$MANIFEST" ]]; then
        return 0  # no manifest, nothing to check
    fi

    local failures=""
    while IFS='  ' read -r expected_hash filepath; do
        [[ -z "$expected_hash" || "$expected_hash" == \#* ]] && continue

        if [[ ! -f "$filepath" ]]; then
            failures+="MISSING: $filepath\n"
            continue
        fi

        actual_hash=$(sha256sum "$filepath" | awk '{print $1}')
        if [[ "$actual_hash" != "$expected_hash" ]]; then
            failures+="MODIFIED: $filepath (expected=$expected_hash actual=$actual_hash)\n"
        fi
    done < "$MANIFEST"

    if [[ -n "$failures" ]]; then
        local timestamp
        timestamp=$(date -u '+%Y-%m-%d %H:%M:%S UTC')
        local alert="[$timestamp] INTEGRITY ALERT:\n$failures"

        # Log to file
        echo -e "$alert" >> "$ALERT_LOG" 2>/dev/null

        # Also write to syslog if available
        logger -t package-verify "INTEGRITY ALERT: tampered files detected" 2>/dev/null || true

        # Print to stderr (visible in cron mail)
        echo -e "$alert" >&2
        return 1
    fi

    return 0
}

case "${1:-}" in
    --generate)
        generate_manifest
        ;;
    --verify)
        verify_manifest
        ;;
    --watch)
        watch_mode
        ;;
    *)
        echo "Usage: $0 --generate | --verify | --watch"
        echo ""
        echo "  --generate   Create manifest from current install"
        echo "  --verify     Check install against manifest (interactive)"
        echo "  --watch      Silent check for cron (alerts only on failure)"
        exit 1
        ;;
esac
