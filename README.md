# Pocket Agent

Pocket Agent is an Android-first web control plane for Codex. The browser talks
to a small gateway, which can run `codex app-server` on the gateway machine or
connect to a server over SSH, start Codex there, and keep the port-forward alive.
It is intentionally a remote work surface rather than a clone of the Codex UI.

```text
Android / desktop browser
        | HTTPS + WSS
        v
Rust + Axum gateway
        | local loopback WebSocket
        | or managed SSH + loopback port-forward
        v
codex app-server (local or remote server)
        |
        v
projects, Git, tests, shell, files, MCP
```

The Rust service owns the network boundary and static assets. It does not
translate Codex JSON-RPC; the TypeScript client speaks the native app-server
protocol and preserves unknown inbound fields for forward compatibility.

## What works

- Initialize/initialized handshake and version-specific protocol handling
- Model and reasoning-effort selection
- Thread list, history, new thread, resume, reconnect, steer, and interrupt
- Key/agent-based SSH connection, remote app-server startup, and tunnel lifecycle
- Slash command palette, including native `/compact` and `/review`
- Remote `skills/list`, `skills/changed` refresh, explicit Skill input, and Skill call rendering
- Streaming agent messages, reasoning, plans, commands, file changes, and diff
- Command/file approval with accept, accept-for-session, decline, and cancel
- Full `item/tool/requestUserInput` UI, including Other and secret answers
- Host file browser, browser upload, and image attachment
- Terminal through stable `command/exec`, with PTY streaming where supported
- Apps/connectors and MCP status panels
- Raw activity view for unknown notifications and item types
- Installable PWA layout designed for an Android viewport

## Prerequisites

- A current Codex CLI installed and signed in
- An OpenSSH client on the gateway machine; SSH mode also requires key/agent
  access and a signed-in Codex CLI on the remote server
- Rust 1.86 or later
- Node.js 24 or a compatible current LTS release

The implementation in this repository is verified against
`codex-cli 0.144.0`. See
[protocol compatibility](docs/PROTOCOL_COMPATIBILITY.md) before upgrading
Codex. The latest local verification evidence is in
[the validation record](docs/VALIDATION.md).

## Build and run

Install and build the PWA:

```powershell
npm --prefix frontend ci
npm --prefix frontend run build
```

Create a high-entropy gateway token for the current PowerShell session:

```powershell
$env:POCKET_AGENT_TOKEN = [Convert]::ToHexString(
    [Security.Cryptography.RandomNumberGenerator]::GetBytes(32)
).ToLowerInvariant()
```

Start Pocket Agent from the repository root:

```powershell
cargo run -p pocket-agent-gateway
```

Open `http://127.0.0.1:8787`, enter the same token in Settings, and connect.
The browser sends the token in `Sec-WebSocket-Protocol`, so it does not appear
in the WebSocket URL or normal URL access logs. Bearer, `X-Pocket-Agent-Token`,
and query-token authentication remain available for non-browser or legacy
clients; avoid the query form unless the proxy is configured to redact it.
By default the gateway starts:

```text
codex app-server --listen ws://127.0.0.1:8765
```

To work on another server, select **SSH 服务器** in Settings and enter an SSH
Host alias or `user@host`. Pocket Agent uses the gateway machine's existing
SSH agent, identity file, and `~/.ssh/config`; the browser never receives the
private key. The remote app-server binds to `127.0.0.1` and its port does not
need to be opened in the server firewall. See [SSH remote control](docs/SSH.md).

If app-server is already managed elsewhere:

```powershell
$env:POCKET_AGENT_AUTO_START_CODEX = 'false'
$env:POCKET_AGENT_CODEX_URL = 'ws://127.0.0.1:4500'
cargo run -p pocket-agent-gateway
```

For frontend-only development, run `npm --prefix frontend run dev` and set the
UI endpoint to `ws://127.0.0.1:8787/ws`.

## Configuration

| Environment variable | Default | Purpose |
| --- | --- | --- |
| `POCKET_AGENT_TOKEN` | required | Token used to authenticate `/ws` |
| `POCKET_AGENT_BIND_ADDR` | `127.0.0.1:8787` | Gateway listener |
| `POCKET_AGENT_ALLOW_REMOTE` | `false` | Explicitly allow a non-loopback listener |
| `POCKET_AGENT_CODEX_URL` | `ws://127.0.0.1:8765` | Loopback app-server endpoint |
| `POCKET_AGENT_AUTO_START_CODEX` | `true` | Start app-server when unavailable |
| `POCKET_AGENT_CODEX_BIN` | `codex` | Codex executable path |
| `POCKET_AGENT_CODEX_START_TIMEOUT_MS` | `10000` | Startup readiness timeout |
| `POCKET_AGENT_SSH_BIN` | `ssh` | OpenSSH client executable |
| `POCKET_AGENT_SSH_START_TIMEOUT_MS` | `20000` | SSH plus remote Codex readiness timeout |
| `POCKET_AGENT_SSH_REMOTE_PORT` | `4500` | Default remote loopback app-server port |
| `POCKET_AGENT_FRONTEND_DIR` | `frontend/dist` | Built PWA directory |

The gateway deliberately rejects non-loopback app-server targets. SSH mode
still forwards into a gateway-local loopback port. For remote phone access,
place Pocket Agent itself behind a TLS reverse proxy or VPN. Do not expose
plain `ws://` to the internet.

## Validation

```powershell
cargo fmt --all --check
cargo check --workspace --all-targets --locked
cargo test --workspace --all-targets --locked
cargo clippy --workspace --all-targets --locked -- -D warnings

npm --prefix frontend run typecheck
npm --prefix frontend test
npm --prefix frontend run build
npm --prefix frontend audit --audit-level=high
```

The schema regeneration scripts can check the local CLI after an upgrade:

```powershell
.\scripts\generate-schema.ps1 -OutDir .\artifacts\app-server-schema
```

## Security and current boundaries

The token grants access to shell, filesystem, configuration, and MCP operations
on the app-server host. Treat it like an SSH credential. Use a random token,
WSS, a trusted reverse proxy or private tunnel, and a device you control. The
subprotocol value is an encoding, not encryption, so reverse-proxy header logs
must also redact `Sec-WebSocket-Protocol`.

Conversation state is restored after a phone network switch by creating a new
connection, repeating `initialize -> initialized`, then reading and resuming the
active thread. A pending approval or PTY process belongs to the old upstream
connection and may be cancelled when that connection drops; the persisted
thread and completed items still recover.

Codex app-server WebSocket transport remains experimental. Regenerate the
bindings and rerun the full test suite whenever the installed Codex version
changes.

On Windows, app-server currently rejects streaming `command/exec` inside its
safe sandbox. Pocket Agent therefore uses buffered execution for `read-only`
and `workspace-write`; Unix and explicitly selected `danger-full-access` keep
the interactive PTY path.
