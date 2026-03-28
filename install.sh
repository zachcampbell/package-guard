#!/usr/bin/env bash
# =============================================================================
# Supply Chain Security — Install Script
# =============================================================================
#
# Installs package verification hooks for Claude Code, Codex CLI, and Gemini CLI.
# Merges into existing config without clobbering other hooks or settings.
#
# Usage:
#   ./install.sh              # Install everything (interactive)
#   ./install.sh --all        # Install everything (no prompts)
#   ./install.sh --claude     # Claude Code hook only
#   ./install.sh --codex      # Codex CLI hook only
#   ./install.sh --gemini     # Gemini CLI hook only
#   ./install.sh --pip        # pip wrapper only
#   ./install.sh --uninstall  # Remove everything
#
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Detect --user mode early so paths are set before anything runs
USER_MODE=0
for _arg in "$@"; do [[ "$_arg" == "--user" ]] && USER_MODE=1; done

if [[ "$USER_MODE" == "1" ]]; then
    INSTALL_DIR="$HOME/.local/share/package-verify"
    BIN_DIR="$HOME/.local/bin"
    SUDO=""
    MODE_LABEL="user"
else
    INSTALL_DIR="/opt/package-verify"
    BIN_DIR="/usr/local/bin"
    SUDO="sudo"
    MODE_LABEL="system"
fi

ALLOWLIST_PATH="$INSTALL_DIR/package-allowlist.txt"

# Config file locations
CLAUDE_SETTINGS="$HOME/.claude/settings.json"
CODEX_CONFIG="$HOME/.codex/config.toml"
CODEX_HOOKS="$HOME/.codex/hooks.json"
GEMINI_SETTINGS="$HOME/.gemini/settings.json"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

info()  { echo -e "${BLUE}[INFO]${NC} $*"; }
ok()    { echo -e "${GREEN}[OK]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
err()   { echo -e "${RED}[ERROR]${NC} $*"; }

# ── Prerequisites ────────────────────────────────────────────────────────────

check_prereqs() {
    local missing=()
    for cmd in jq python3 curl; do
        if ! command -v "$cmd" &>/dev/null; then
            missing+=("$cmd")
        fi
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        err "Missing required tools: ${missing[*]}"
        echo "Install them first:"
        echo "  Debian/Ubuntu: sudo apt install ${missing[*]}"
        echo "  macOS:         brew install ${missing[*]}"
        exit 1
    fi
}

# ── Backup helper ────────────────────────────────────────────────────────────

backup_file() {
    local f="$1"
    if [[ -f "$f" ]]; then
        local bak="${f}.pre-pkgverify.bak"
        if [[ ! -f "$bak" ]]; then
            cp "$f" "$bak"
            info "Backed up $f → $bak"
        fi
    fi
}

# ── Install shared scripts ──────────────────────────────────────────────────

install_shared() {
    info "Installing shared scripts to $INSTALL_DIR/"

    $SUDO mkdir -p "$INSTALL_DIR"
    $SUDO cp "$SCRIPT_DIR/shared/verify-package.sh" "$INSTALL_DIR/"
    $SUDO cp "$SCRIPT_DIR/shared/pip-wrapper.sh" "$INSTALL_DIR/"
    $SUDO cp "$SCRIPT_DIR/shared/python-wrapper.sh" "$INSTALL_DIR/"
    $SUDO cp "$SCRIPT_DIR/shared/integrity-check.sh" "$INSTALL_DIR/"
    # Policy config — only install if not already present (admin may have customized)
    if [[ ! -f "$INSTALL_DIR/policy.conf" ]]; then
        $SUDO cp "$SCRIPT_DIR/shared/policy.conf" "$INSTALL_DIR/"
        $SUDO chmod 644 "$INSTALL_DIR/policy.conf"
    fi
    $SUDO cp "$SCRIPT_DIR/claude/claude-hook.sh" "$INSTALL_DIR/"
    $SUDO cp "$SCRIPT_DIR/codex/codex-hook.sh" "$INSTALL_DIR/"
    $SUDO cp "$SCRIPT_DIR/gemini/gemini-hook.sh" "$INSTALL_DIR/"
    $SUDO chmod +x "$INSTALL_DIR"/*.sh

    # Rewrite hardcoded /opt/package-verify paths if installing to a different location
    if [[ "$INSTALL_DIR" != "/opt/package-verify" ]]; then
        for f in "$INSTALL_DIR"/*.sh "$INSTALL_DIR"/*.conf; do
            [[ -f "$f" ]] || continue
            $SUDO sed -i "s|/opt/package-verify|$INSTALL_DIR|g" "$f"
        done
        info "Rewrote paths in scripts for $MODE_LABEL-mode install"
    fi

    ok "Scripts installed to $INSTALL_DIR/"

    # Allowlist — root-owned, fixed path
    if [[ ! -f "$ALLOWLIST_PATH" ]]; then
        $SUDO cp "$SCRIPT_DIR/shared/example-allowlist.txt" "$ALLOWLIST_PATH"
        $SUDO chmod 644 "$ALLOWLIST_PATH"
        ok "Allowlist created at $ALLOWLIST_PATH"
    else
        ok "Allowlist already exists at $ALLOWLIST_PATH (not overwritten)"
    fi

    # Environment variables — system mode uses /etc/profile.d, user mode uses ~/.bashrc
    if [[ "$USER_MODE" == "0" ]]; then
        local profile_script="/etc/profile.d/package-verify.sh"
        if [[ ! -f "$profile_script" ]]; then
            echo "export PACKAGE_VERIFY_SCRIPT=$INSTALL_DIR/verify-package.sh" | $SUDO tee "$profile_script" > /dev/null
            echo "export PACKAGE_ALLOWLIST=$INSTALL_DIR/package-allowlist.txt" | $SUDO tee -a "$profile_script" > /dev/null
            ok "Environment variables set in $profile_script"
            warn "Run 'source $profile_script' or start a new shell to pick up env vars"
        fi
    else
        # User mode — add to ~/.bashrc if not already there
        if ! grep -qF "package-verify" "$HOME/.bashrc" 2>/dev/null; then
            cat >> "$HOME/.bashrc" << RCEOF

# Package verification (supply chain security)
export PACKAGE_VERIFY_SCRIPT="$INSTALL_DIR/verify-package.sh"
export PACKAGE_ALLOWLIST="$INSTALL_DIR/package-allowlist.txt"
export PATH="$BIN_DIR:\$PATH"
RCEOF
            ok "Environment variables added to ~/.bashrc"
            warn "Run 'source ~/.bashrc' or start a new shell to pick up env vars"
        fi
    fi
}

# ── Claude Code ──────────────────────────────────────────────────────────────

install_claude() {
    info "Configuring Claude Code hook..."

    if [[ ! -f "$CLAUDE_SETTINGS" ]]; then
        warn "Claude settings not found at $CLAUDE_SETTINGS — skipping"
        return
    fi

    backup_file "$CLAUDE_SETTINGS"

    # Check if our hook is already installed
    if jq -e '.hooks.PreToolUse[]? | select(.hooks[]?.command == "$INSTALL_DIR/claude-hook.sh")' "$CLAUDE_SETTINGS" &>/dev/null; then
        ok "Claude hook already installed"
        return
    fi

    # Build the new hook entry
    local new_hook='{"matcher":"Bash","hooks":[{"type":"command","command":"$INSTALL_DIR/claude-hook.sh","timeout":30}]}'

    # Append to existing PreToolUse array (or create it)
    local tmp
    tmp=$(mktemp)
    if jq -e '.hooks.PreToolUse' "$CLAUDE_SETTINGS" &>/dev/null; then
        # PreToolUse array exists — append
        jq --argjson hook "$new_hook" '.hooks.PreToolUse += [$hook]' "$CLAUDE_SETTINGS" > "$tmp"
    elif jq -e '.hooks' "$CLAUDE_SETTINGS" &>/dev/null; then
        # hooks object exists but no PreToolUse — add it
        jq --argjson hook "$new_hook" '.hooks.PreToolUse = [$hook]' "$CLAUDE_SETTINGS" > "$tmp"
    else
        # No hooks at all — create the whole structure
        jq --argjson hook "$new_hook" '.hooks = {"PreToolUse": [$hook]}' "$CLAUDE_SETTINGS" > "$tmp"
    fi

    mv "$tmp" "$CLAUDE_SETTINGS"
    ok "Claude Code hook added to $CLAUDE_SETTINGS"
}

# ── Codex CLI ────────────────────────────────────────────────────────────────

install_codex() {
    info "Configuring Codex CLI hook..."

    if [[ ! -d "$HOME/.codex" ]]; then
        warn "Codex directory not found at ~/.codex — skipping"
        return
    fi

    # Enable hooks feature in config.toml
    if [[ -f "$CODEX_CONFIG" ]]; then
        backup_file "$CODEX_CONFIG"
        if ! grep -q "codex_hooks" "$CODEX_CONFIG" 2>/dev/null; then
            # Add feature flag — append to [features] section or create it
            if grep -q '^\[features\]' "$CODEX_CONFIG" 2>/dev/null; then
                # [features] section exists — add under it
                sed -i '/^\[features\]/a codex_hooks = true' "$CODEX_CONFIG"
            else
                # No [features] section — append it
                printf '\n[features]\ncodex_hooks = true\n' >> "$CODEX_CONFIG"
            fi
            ok "Enabled codex_hooks feature in $CODEX_CONFIG"
        else
            ok "codex_hooks already enabled in config.toml"
        fi
    else
        warn "Codex config.toml not found — creating minimal config"
        printf '[features]\ncodex_hooks = true\n' > "$CODEX_CONFIG"
    fi

    # Create or update hooks.json
    if [[ -f "$CODEX_HOOKS" ]]; then
        backup_file "$CODEX_HOOKS"
        # Check if our hook is already there
        if jq -e '.hooks.PreToolUse[]? | select(.hooks[]?.command == "$INSTALL_DIR/codex-hook.sh")' "$CODEX_HOOKS" &>/dev/null; then
            ok "Codex hook already installed"
            return
        fi

        local new_hook='{"matcher":"Bash","hooks":[{"type":"command","command":"$INSTALL_DIR/codex-hook.sh","timeout":30}]}'
        local tmp
        tmp=$(mktemp)
        if jq -e '.hooks.PreToolUse' "$CODEX_HOOKS" &>/dev/null; then
            jq --argjson hook "$new_hook" '.hooks.PreToolUse += [$hook]' "$CODEX_HOOKS" > "$tmp"
        elif jq -e '.hooks' "$CODEX_HOOKS" &>/dev/null; then
            jq --argjson hook "$new_hook" '.hooks.PreToolUse = [$hook]' "$CODEX_HOOKS" > "$tmp"
        else
            jq --argjson hook "$new_hook" '. + {"hooks": {"PreToolUse": [$hook]}}' "$CODEX_HOOKS" > "$tmp"
        fi
        mv "$tmp" "$CODEX_HOOKS"
    else
        # Create fresh hooks.json
        cat > "$CODEX_HOOKS" << HOOKEOF
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          {
            "type": "command",
            "command": "$INSTALL_DIR/codex-hook.sh",
            "timeout": 30
          }
        ]
      }
    ]
  }
}
HOOKEOF
    fi

    ok "Codex CLI hook configured at $CODEX_HOOKS"
}

# ── Gemini CLI ───────────────────────────────────────────────────────────────

install_gemini() {
    info "Configuring Gemini CLI hook..."

    if [[ ! -d "$HOME/.gemini" ]]; then
        warn "Gemini directory not found at ~/.gemini — skipping"
        return
    fi

    if [[ -f "$GEMINI_SETTINGS" ]]; then
        backup_file "$GEMINI_SETTINGS"

        # Check if our hook is already installed
        if jq -e '.hooks.BeforeTool[]? | select(.hooks[]?.command == "$INSTALL_DIR/gemini-hook.sh")' "$GEMINI_SETTINGS" &>/dev/null; then
            ok "Gemini hook already installed"
            return
        fi

        local new_hook='{"matcher":"run_shell_command","hooks":[{"type":"command","command":"$INSTALL_DIR/gemini-hook.sh","timeout":30}]}'
        local tmp
        tmp=$(mktemp)
        if jq -e '.hooks.BeforeTool' "$GEMINI_SETTINGS" &>/dev/null; then
            jq --argjson hook "$new_hook" '.hooks.BeforeTool += [$hook]' "$GEMINI_SETTINGS" > "$tmp"
        elif jq -e '.hooks' "$GEMINI_SETTINGS" &>/dev/null; then
            jq --argjson hook "$new_hook" '.hooks.BeforeTool = [$hook]' "$GEMINI_SETTINGS" > "$tmp"
        else
            jq --argjson hook "$new_hook" '. + {"hooks": {"BeforeTool": [$hook]}}' "$GEMINI_SETTINGS" > "$tmp"
        fi
        mv "$tmp" "$GEMINI_SETTINGS"
    else
        cat > "$GEMINI_SETTINGS" << HOOKEOF
{
  "hooks": {
    "BeforeTool": [
      {
        "matcher": "run_shell_command",
        "hooks": [
          {
            "type": "command",
            "command": "$INSTALL_DIR/gemini-hook.sh",
            "timeout": 30
          }
        ]
      }
    ]
  }
}
HOOKEOF
    fi

    ok "Gemini CLI hook configured at $GEMINI_SETTINGS"
}

# ── pip wrapper ──────────────────────────────────────────────────────────────

install_pip_wrapper() {
    info "Installing pip wrapper..."

    # Check if wrapper is already installed
    local pip_path
    pip_path=$(which pip 2>/dev/null || true)

    if [[ "$pip_path" == "$BIN_DIR/pip" ]]; then
        if head -1 "$pip_path" 2>/dev/null | grep -q "package-verify"; then
            ok "pip wrapper already installed at $BIN_DIR/pip"
            return
        fi
    fi

    mkdir -p "$BIN_DIR" 2>/dev/null || true
    $SUDO cp "$INSTALL_DIR/pip-wrapper.sh" "$BIN_DIR/pip"
    $SUDO chmod +x "$BIN_DIR/pip"
    ok "pip wrapper installed at $BIN_DIR/pip"

    # Verify it shadows the real pip
    local new_pip
    new_pip=$(which pip 2>/dev/null || true)
    if [[ "$new_pip" == "$BIN_DIR/pip" ]]; then
        ok "pip wrapper is first in PATH"
    else
        warn "pip wrapper at $BIN_DIR/pip is NOT first in PATH (found: $new_pip)"
        warn "You may need to adjust PATH or create an alias"
    fi
}

# ── python3 wrapper ──────────────────────────────────────────────────────────

install_python_wrapper() {
    info "Installing python3 wrapper..."

    # Check if wrapper is already installed
    if [[ -f $BIN_DIR/python3 ]]; then
        if head -5 $BIN_DIR/python3 2>/dev/null | grep -q "python-wrapper\|package-verify\|venv"; then
            ok "python3 wrapper already installed at $BIN_DIR/python3"
            return
        fi
    fi

    # Verify real python3 exists at /usr/bin/python3
    if [[ ! -x /usr/bin/python3 ]]; then
        warn "Real python3 not found at /usr/bin/python3 — skipping wrapper"
        return
    fi

    mkdir -p "$BIN_DIR" 2>/dev/null || true
    $SUDO cp "$INSTALL_DIR/python-wrapper.sh" "$BIN_DIR/python3"
    $SUDO chmod +x "$BIN_DIR/python3"
    ok "python3 wrapper installed at $BIN_DIR/python3"
    info "New venvs will automatically get pip verification injected"
}

# ── Integrity monitoring ─────────────────────────────────────────────────────

install_integrity() {
    info "Setting up integrity monitoring..."

    # Generate initial manifest
    $SUDO "$INSTALL_DIR/integrity-check.sh" --generate 2>/dev/null
    ok "Integrity manifest generated"

    # Add cron job (idempotent — user mode uses user crontab, system mode uses root)
    local cron_cmd="*/15 * * * * $INSTALL_DIR/integrity-check.sh --watch"
    if [[ "$USER_MODE" == "1" ]]; then
        if crontab -l 2>/dev/null | grep -qF "integrity-check.sh"; then
            ok "Integrity cron already installed"
        else
            (crontab -l 2>/dev/null; echo "$cron_cmd") | crontab -
            ok "Integrity cron installed (user crontab, every 15 minutes)"
        fi
    else
        if $SUDO crontab -l 2>/dev/null | grep -qF "integrity-check.sh"; then
            ok "Integrity cron already installed"
        else
            ($SUDO crontab -l 2>/dev/null; echo "$cron_cmd") | $SUDO crontab -
            ok "Integrity cron installed (root crontab, every 15 minutes)"
        fi
    fi
}

# ── Uninstall ────────────────────────────────────────────────────────────────

uninstall() {
    info "Uninstalling package verification..."

    # Remove scripts
    if [[ -d "$INSTALL_DIR" ]]; then
        $SUDO rm -rf "$INSTALL_DIR"
        ok "Removed $INSTALL_DIR"
    fi

    # Remove pip wrapper (if it's ours)
    if [[ -f $BIN_DIR/pip ]]; then
        if head -5 $BIN_DIR/pip 2>/dev/null | grep -q "package-verify\|pip wrapper"; then
            $SUDO rm $BIN_DIR/pip
            ok "Removed pip wrapper from $BIN_DIR/pip"
        fi
    fi

    # Remove python3 wrapper (if it's ours)
    if [[ -f $BIN_DIR/python3 ]]; then
        if head -5 $BIN_DIR/python3 2>/dev/null | grep -q "python-wrapper\|package-verify\|injects pip"; then
            $SUDO rm $BIN_DIR/python3
            ok "Removed python3 wrapper from $BIN_DIR/python3"
        fi
    fi

    # Remove integrity cron
    if [[ "$USER_MODE" == "1" ]]; then
        if crontab -l 2>/dev/null | grep -qF "integrity-check.sh"; then
            crontab -l 2>/dev/null | grep -vF "integrity-check.sh" | crontab -
            ok "Removed integrity monitoring cron (user)"
        fi
    else
        if $SUDO crontab -l 2>/dev/null | grep -qF "integrity-check.sh"; then
            $SUDO crontab -l 2>/dev/null | grep -vF "integrity-check.sh" | $SUDO crontab -
            ok "Removed integrity monitoring cron (root)"
        fi
    fi

    # Remove env profile
    if [[ "$USER_MODE" == "1" ]]; then
        if grep -qF "package-verify" "$HOME/.bashrc" 2>/dev/null; then
            sed -i '/# Package verification (supply chain security)/,/^$/d' "$HOME/.bashrc"
            sed -i '/PACKAGE_VERIFY_SCRIPT/d; /package-verify/d' "$HOME/.bashrc"
            ok "Removed package-verify lines from ~/.bashrc"
        fi
    else
        if [[ -f /etc/profile.d/package-verify.sh ]]; then
            $SUDO rm /etc/profile.d/package-verify.sh
            ok "Removed /etc/profile.d/package-verify.sh"
        fi
    fi

    # Restore Claude settings
    if [[ -f "$CLAUDE_SETTINGS" ]]; then
        local tmp
        tmp=$(mktemp)
        if jq -e '.hooks.PreToolUse' "$CLAUDE_SETTINGS" &>/dev/null; then
            jq '.hooks.PreToolUse = [.hooks.PreToolUse[] | select(.hooks[]?.command != "$INSTALL_DIR/claude-hook.sh")]' "$CLAUDE_SETTINGS" > "$tmp"
            mv "$tmp" "$CLAUDE_SETTINGS"
            ok "Removed Claude hook from $CLAUDE_SETTINGS"
        fi
    fi

    # Restore Codex hooks
    if [[ -f "$CODEX_HOOKS" ]]; then
        local tmp
        tmp=$(mktemp)
        if jq -e '.hooks.PreToolUse' "$CODEX_HOOKS" &>/dev/null; then
            jq '.hooks.PreToolUse = [.hooks.PreToolUse[] | select(.hooks[]?.command != "$INSTALL_DIR/codex-hook.sh")]' "$CODEX_HOOKS" > "$tmp"
            mv "$tmp" "$CODEX_HOOKS"
            ok "Removed Codex hook from $CODEX_HOOKS"
        fi
    fi

    # Remove codex_hooks feature flag
    if [[ -f "$CODEX_CONFIG" ]]; then
        sed -i '/codex_hooks = true/d' "$CODEX_CONFIG" 2>/dev/null
        ok "Removed codex_hooks feature flag from $CODEX_CONFIG"
    fi

    # Restore Gemini settings
    if [[ -f "$GEMINI_SETTINGS" ]]; then
        local tmp
        tmp=$(mktemp)
        if jq -e '.hooks.BeforeTool' "$GEMINI_SETTINGS" &>/dev/null; then
            jq '.hooks.BeforeTool = [.hooks.BeforeTool[] | select(.hooks[]?.command != "$INSTALL_DIR/gemini-hook.sh")]' "$GEMINI_SETTINGS" > "$tmp"
            mv "$tmp" "$GEMINI_SETTINGS"
            ok "Removed Gemini hook from $GEMINI_SETTINGS"
        fi
    fi

    # Note: allowlist is NOT removed (user data)
    info "Allowlist at $ALLOWLIST_PATH was NOT removed (user data)"
    info "Backup files (.pre-pkgverify.bak) were NOT removed"

    ok "Uninstall complete"
}

# ── Test ─────────────────────────────────────────────────────────────────────

run_test() {
    info "Running quick verification test..."
    echo ""

    local verify="$INSTALL_DIR/verify-package.sh"
    if [[ ! -x "$verify" ]]; then
        err "verify-package.sh not found at $verify — run install first"
        return 1
    fi

    local pass=0
    local fail=0

    # Tests use a temporary strict policy config
    local policy="$INSTALL_DIR/policy.conf"
    local policy_bak="$INSTALL_DIR/policy.conf.test-bak"
    $SUDO cp "$policy" "$policy_bak" 2>/dev/null || true

    # Test 1: allowlisted package (skip network checks)
    echo -n "  Allowlisted package (requests)... "
    $SUDO bash -c "cat > $policy" << POL
ALLOWLIST="$INSTALL_DIR/package-allowlist.txt"
MAX_AGE_HOURS=48
SKIP_RECENCY=1
SKIP_CONTENT=1
STRICT=0
POL
    if "$verify" pip requests 2.32.3 &>/dev/null; then
        echo -e "${GREEN}PASS${NC}"; pass=$((pass + 1))
    else
        echo -e "${RED}FAIL${NC}"; fail=$((fail + 1))
    fi

    # Test 2: unknown package in strict mode
    echo -n "  Unknown package, strict mode... "
    $SUDO bash -c "cat > $policy" << POL
ALLOWLIST="$INSTALL_DIR/package-allowlist.txt"
MAX_AGE_HOURS=48
SKIP_RECENCY=1
SKIP_CONTENT=1
STRICT=1
POL
    if ! "$verify" pip totally-fake-pkg 2>/dev/null; then
        echo -e "${GREEN}PASS (blocked)${NC}"; pass=$((pass + 1))
    else
        echo -e "${RED}FAIL (should have blocked)${NC}"; fail=$((fail + 1))
    fi

    # Test 3: Claude hook deny (strict mode still active)
    echo -n "  Claude hook deny (unknown pkg)... "
    local hook_out
    hook_out=$(echo '{"tool_name":"Bash","tool_input":{"command":"pip install evil-pkg"}}' | \
        "$INSTALL_DIR/claude-hook.sh" 2>/dev/null)
    if echo "$hook_out" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' &>/dev/null; then
        echo -e "${GREEN}PASS${NC}"; pass=$((pass + 1))
    else
        echo -e "${RED}FAIL${NC}"; fail=$((fail + 1))
    fi

    # Test 4: Claude hook allow (non-strict, allowlisted)
    echo -n "  Claude hook allow (clean pkg)... "
    $SUDO bash -c "cat > $policy" << POL
ALLOWLIST="$INSTALL_DIR/package-allowlist.txt"
MAX_AGE_HOURS=48
SKIP_RECENCY=1
SKIP_CONTENT=1
STRICT=0
POL
    hook_out=$(echo '{"tool_name":"Bash","tool_input":{"command":"pip install requests==2.32.3"}}' | \
        "$INSTALL_DIR/claude-hook.sh" 2>/dev/null)
    if [[ -z "$hook_out" ]]; then
        echo -e "${GREEN}PASS${NC}"; pass=$((pass + 1))
    else
        echo -e "${RED}FAIL (unexpected output)${NC}"; fail=$((fail + 1))
    fi

    # Test 5: non-install passthrough
    echo -n "  Hook passthrough (ls -la)... "
    hook_out=$(echo '{"tool_name":"Bash","tool_input":{"command":"ls -la"}}' | \
        "$INSTALL_DIR/claude-hook.sh" 2>/dev/null)
    if [[ -z "$hook_out" ]]; then
        echo -e "${GREEN}PASS${NC}"; pass=$((pass + 1))
    else
        echo -e "${RED}FAIL${NC}"; fail=$((fail + 1))
    fi

    # Test 6: env var bypass attempt (should NOT work)
    echo -n "  Env var bypass blocked... "
    $SUDO bash -c "cat > $policy" << POL
ALLOWLIST="$INSTALL_DIR/package-allowlist.txt"
STRICT=1
SKIP_RECENCY=1
SKIP_CONTENT=1
POL
    # Try to bypass by setting STRICT=0 via env — should still block
    if ! STRICT=0 "$verify" pip totally-fake-pkg 2>/dev/null; then
        echo -e "${GREEN}PASS (env bypass blocked)${NC}"; pass=$((pass + 1))
    else
        echo -e "${RED}FAIL (env bypass succeeded!)${NC}"; fail=$((fail + 1))
    fi

    # Test 7: pip install -r blocked
    echo -n "  Blocked: pip install -r... "
    if ! "$INSTALL_DIR/pip-wrapper.sh" install -r requirements.txt 2>/dev/null; then
        echo -e "${GREEN}PASS (blocked)${NC}"; pass=$((pass + 1))
    else
        echo -e "${RED}FAIL${NC}"; fail=$((fail + 1))
    fi

    # Test 8: local wheel blocked
    echo -n "  Blocked: local wheel... "
    if ! "$INSTALL_DIR/pip-wrapper.sh" install ./pkg.whl 2>/dev/null; then
        echo -e "${GREEN}PASS (blocked)${NC}"; pass=$((pass + 1))
    else
        echo -e "${RED}FAIL${NC}"; fail=$((fail + 1))
    fi

    # Test 9: git+https VCS blocked
    echo -n "  Blocked: VCS install... "
    if ! "$INSTALL_DIR/pip-wrapper.sh" install git+https://github.com/x/y 2>/dev/null; then
        echo -e "${GREEN}PASS (blocked)${NC}"; pass=$((pass + 1))
    else
        echo -e "${RED}FAIL${NC}"; fail=$((fail + 1))
    fi

    # Test 10: venv python -m pip install blocked (wrapper layer, no hooks)
    echo -n "  Blocked: venv python -m pip... "
    local test_venv="/tmp/pkgverify-test-venv"
    rm -rf "$test_venv"
    /usr/bin/python3 -m venv "$test_venv" 2>/dev/null  # use real python to create plain venv
    # Now inject our wrapper manually (same as python3 wrapper does)
    if [[ -f "$test_venv/bin/python" || -L "$test_venv/bin/python" ]]; then
        local venv_real
        venv_real=$(readlink -f "$test_venv/bin/python")
        rm -f "$test_venv/bin/python"
        cat > "$test_venv/bin/python" << TVWRAP
#!/usr/bin/env bash
REAL_PYTHON="$venv_real"
VERIFY="$INSTALL_DIR/verify-package.sh"
if [[ "\${1:-}" == "-m" && "\${2:-}" == "pip" && "\${3:-}" == "install" ]]; then
    for arg in "\${@:4}"; do
        [[ "\$arg" == -* || -z "\$arg" ]] && continue
        pkg="\$arg"; ver=""
        [[ "\$pkg" == *"=="* ]] && { ver="\${pkg#*==}"; pkg="\${pkg%%==*}"; }
        "\$VERIFY" pip "\$pkg" "\$ver" 2>&1 || { echo "BLOCKED" >&2; exit 1; }
    done
fi
exec "\$REAL_PYTHON" "\$@"
TVWRAP
        chmod +x "$test_venv/bin/python"
    fi
    if ! "$test_venv/bin/python" -m pip install totally-fake-pkg 2>/dev/null; then
        echo -e "${GREEN}PASS (blocked)${NC}"; pass=$((pass + 1))
    else
        echo -e "${RED}FAIL${NC}"; fail=$((fail + 1))
    fi
    rm -rf "$test_venv"

    # Restore original policy
    if [[ -f "$policy_bak" ]]; then
        $SUDO mv "$policy_bak" "$policy"
    fi

    echo ""
    echo -e "  Results: ${GREEN}$pass passed${NC}, ${RED}$fail failed${NC}"
    [[ "$fail" -eq 0 ]] && ok "All tests passed" || err "$fail test(s) failed"
    return "$fail"
}

# ── Main ─────────────────────────────────────────────────────────────────────

main() {
    echo ""
    echo "╔══════════════════════════════════════════════════════╗"
    echo "║  Supply Chain Security — Package Verification Setup  ║"
    echo "╚══════════════════════════════════════════════════════╝"
    [[ "$USER_MODE" == "1" ]] && echo "  Mode: user (~/.local/)" || echo "  Mode: system (/opt/)"
    echo ""

    check_prereqs

    case "${1:-}" in
        --all)
            install_shared
            echo ""
            install_claude
            install_codex
            install_gemini
            echo ""
            install_pip_wrapper
            install_python_wrapper
            echo ""
            install_integrity
            echo ""
            run_test
            ;;
        --claude)
            install_shared
            install_claude
            ;;
        --codex)
            install_shared
            install_codex
            ;;
        --gemini)
            install_shared
            install_gemini
            ;;
        --pip)
            install_shared
            install_pip_wrapper
            install_python_wrapper
            ;;
        --test)
            run_test
            ;;
        --uninstall)
            uninstall
            ;;
        --user)
            # --user is handled by path detection at top of script
            # Just run --all with user-mode paths already set
            install_shared
            echo ""
            install_claude
            install_codex
            install_gemini
            echo ""
            install_pip_wrapper
            install_python_wrapper
            echo ""
            install_integrity
            echo ""
            run_test
            ;;
        --help|-h)
            echo "Usage: $0 [option]"
            echo ""
            echo "Options:"
            echo "  --all        Install everything system-wide (requires sudo)"
            echo "  --user       Install everything in ~/.local (no sudo needed)"
            echo "  --claude     Install shared scripts + Claude Code hook"
            echo "  --codex      Install shared scripts + Codex CLI hook"
            echo "  --gemini     Install shared scripts + Gemini CLI hook"
            echo "  --pip        Install shared scripts + pip wrapper + python3 wrapper"
            echo "  --test       Run verification tests"
            echo "  --uninstall  Remove everything (preserves allowlist and backups)"
            echo "  --help       Show this help"
            echo ""
            echo "System mode (--all):  /opt/package-verify/ + /usr/local/bin/ (requires sudo)"
            echo "User mode (--user):   ~/.local/share/package-verify/ + ~/.local/bin/ (no sudo)"
            ;;
        "")
            # Interactive mode
            install_shared
            echo ""

            local do_claude=n do_codex=n do_gemini=n do_pip=n
            [[ -f "$CLAUDE_SETTINGS" ]] && do_claude=y
            [[ -d "$HOME/.codex" ]] && do_codex=y
            [[ -d "$HOME/.gemini" ]] && do_gemini=y

            echo "Detected AI tools:"
            [[ "$do_claude" == "y" ]] && echo "  - Claude Code ($CLAUDE_SETTINGS)"
            [[ "$do_codex" == "y" ]] && echo "  - Codex CLI ($HOME/.codex/)"
            [[ "$do_gemini" == "y" ]] && echo "  - Gemini CLI ($HOME/.gemini/)"
            echo ""

            read -rp "Install Claude Code hook? [Y/n] " ans
            [[ "${ans:-y}" =~ ^[Yy] ]] && install_claude
            echo ""

            read -rp "Install Codex CLI hook? [Y/n] " ans
            [[ "${ans:-y}" =~ ^[Yy] ]] && install_codex
            echo ""

            read -rp "Install Gemini CLI hook? [Y/n] " ans
            [[ "${ans:-y}" =~ ^[Yy] ]] && install_gemini
            echo ""

            read -rp "Install pip wrapper (universal)? [Y/n] " ans
            [[ "${ans:-y}" =~ ^[Yy] ]] && install_pip_wrapper
            echo ""

            read -rp "Install python3 wrapper (venv protection)? [Y/n] " ans
            [[ "${ans:-y}" =~ ^[Yy] ]] && install_python_wrapper
            echo ""

            read -rp "Enable integrity monitoring (cron)? [Y/n] " ans
            [[ "${ans:-y}" =~ ^[Yy] ]] && install_integrity
            echo ""

            read -rp "Run tests? [Y/n] " ans
            [[ "${ans:-y}" =~ ^[Yy] ]] && run_test
            ;;
        *)
            err "Unknown option: $1"
            echo "Run '$0 --help' for usage"
            exit 1
            ;;
    esac

    echo ""
    ok "Done."
}

main "$@"
