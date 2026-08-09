# Pocket Agent

Pocket Agent is an Android-first PWA client for `codex app-server`. It gives a
phone a focused Codex interface without exposing app-server directly to the
public network.

```text
Android / desktop browser
        | HTTPS + WSS
        v
Rust + Axum gateway
        | loopback WebSocket, raw frames
        v
codex app-server
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
| `POCKET_AGENT_FRONTEND_DIR` | `frontend/dist` | Built PWA directory |

The gateway deliberately rejects non-loopback app-server targets. For remote
phone access, keep Pocket Agent on loopback and place it behind a TLS reverse
proxy, VPN, or SSH tunnel. Do not expose plain `ws://` to the internet.

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
