#!/usr/bin/env bash
# =============================================================================
# Adversarial Corpus Test Runner
# =============================================================================
#
# Tests the Claude hook against every command in adversarial-corpus.txt.
# Verifies that BLOCK commands are denied, ALLOW commands pass, and
# PASS commands are ignored entirely.
#
# Usage: ./tests/run-corpus.sh
# =============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORPUS="$SCRIPT_DIR/adversarial-corpus.txt"
HOOKS=(
    "claude|/opt/package-verify/claude-hook.sh|Bash|hookSpecificOutput.permissionDecision"
    "codex|/opt/package-verify/codex-hook.sh|Bash|hookSpecificOutput.permissionDecision"
    "gemini|/opt/package-verify/gemini-hook.sh|run_shell_command|decision"
)
VERIFY="/opt/package-verify/verify-package.sh"
POLICY="/opt/package-verify/policy.conf"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

if [[ ! -x "/opt/package-verify/claude-hook.sh" ]]; then
    echo "ERROR: Hooks not found — run install.sh first" >&2
    exit 1
fi

# Save and set strict policy for testing
policy_bak=$(mktemp)
cp "$POLICY" "$policy_bak"
sudo bash -c "cat > $POLICY" << 'POL'
ALLOWLIST="/opt/package-verify/package-allowlist.txt"
MAX_AGE_HOURS=48
SKIP_RECENCY=1
SKIP_CONTENT=1
STRICT=1
FAIL_CLOSED=1
POL

pass=0
fail=0
skip=0
total=0

while IFS='|' read -r expected command; do
    # Skip comments and blank lines
    [[ -z "$expected" || "$expected" == \#* ]] && continue
    expected=$(echo "$expected" | tr -d ' ')
    total=$((total + 1))

    # Run against ALL hooks — if any hook disagrees with expected result, it's a failure
    all_hooks_agree=1
    for hook_entry in "${HOOKS[@]}"; do
        IFS='|' read -r hook_name hook_path tool_name deny_field <<< "$hook_entry"
        [[ ! -x "$hook_path" ]] && continue

        hook_out=$(jq -n --arg tn "$tool_name" --arg cmd "$command" \
            '{"tool_name":$tn,"tool_input":{"command":$cmd}}' | \
            "$hook_path" 2>/dev/null)

        is_denied=0
        if echo "$hook_out" | jq -e ".$deny_field == \"deny\"" &>/dev/null 2>&1; then
            is_denied=1
        fi

        case "$expected" in
            BLOCK)
                if [[ "$is_denied" != "1" ]]; then
                    echo -e "  ${RED}FAIL${NC}  BLOCK  [$hook_name]  $command"
                    fail=$((fail + 1))
                    all_hooks_agree=0
                    break
                fi ;;
            ALLOW|PASS)
                if [[ "$is_denied" != "0" ]]; then
                    echo -e "  ${RED}FAIL${NC}  $expected  [$hook_name]  $command  (was blocked!)"
                    fail=$((fail + 1))
                    all_hooks_agree=0
                    break
                fi ;;
        esac
    done

    if [[ "$all_hooks_agree" == "1" ]]; then
        case "$expected" in
            BLOCK) echo -e "  ${GREEN}PASS${NC}  BLOCK  $command"; pass=$((pass + 1)) ;;
            ALLOW) echo -e "  ${GREEN}PASS${NC}  ALLOW  $command"; pass=$((pass + 1)) ;;
            PASS)  echo -e "  ${GREEN}PASS${NC}  PASS   $command"; pass=$((pass + 1)) ;;
        esac
    fi
done < "$CORPUS"

# Restore policy
sudo cp "$policy_bak" "$POLICY"
rm -f "$policy_bak"

echo ""
echo "Results: $total tested, $pass passed, $fail failed, $skip skipped"
if [[ "$fail" -gt 0 ]]; then
    echo -e "${RED}FAILED${NC}"
    exit 1
else
    echo -e "${GREEN}ALL PASSED${NC}"
    exit 0
fi
