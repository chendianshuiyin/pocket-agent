# Pocket Agent

Pocket Agent is an Android-first web control plane for Codex and remote servers.
The browser talks to a small gateway, which can run `codex app-server`, manage a
remote app-server over SSH, and open independent interactive SSH terminals. It
is intentionally a remote work surface rather than a clone of the Codex UI.

```text
Android / desktop browser
        | HTTPS + WSS
        v
Rust + Axum gateway
        |                              |
        | /ws                          | /terminal/ws
        | local WebSocket or           | native PTY + ssh -tt
        | managed SSH port-forward     |
        v                              v
codex app-server                 remote login shell
(local or remote)                       |
        |                               | run codex directly
        +---------------+---------------+
                        v
              projects, Git, tests, files, MCP
```

The Rust service owns the network boundary and static assets. It does not
translate Codex JSON-RPC; the TypeScript client speaks the native app-server
protocol and preserves unknown inbound fields for forward compatibility.

## What works

- Initialize/initialized handshake and version-specific protocol handling
- Model and reasoning-effort selection
- Thread list, history, new thread, resume, reconnect, steer, and interrupt
- Key/agent-based SSH connection, remote app-server startup, and tunnel lifecycle
- Direct key/agent-based SSH terminal sessions, independent of app-server readiness
- Native PTY input, resize, process exit, ANSI color, and full-screen TUI rendering
- Up to eight named SSH sessions with per-session working directory and command history
- Slash command palette, including native `/compact` and `/review`
- Remote `skills/list`, `skills/changed` refresh, explicit Skill input, and Skill call rendering
- Streaming agent messages, reasoning, plans, commands, file changes, and diff
- Command/file approval with accept, accept-for-session, decline, and cancel
- Full `item/tool/requestUserInput` UI, including Other and secret answers
- Host file browser, browser upload, and image attachment
- Apps/connectors and MCP status panels
- Raw activity view for unknown notifications and item types
- Installable PWA layout designed for an Android viewport

## Prerequisites

- A current Codex CLI installed and signed in for Codex task management
- An OpenSSH client on the gateway machine and key/agent access for SSH mode
- A remote Codex installation only when starting Codex on that server; the
  direct SSH terminal itself only requires shell access
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
Host alias or `user@host`. Open **Terminal** to create a direct remote shell,
then run `codex` exactly as you would after a normal SSH login. The terminal is
available even when managed remote app-server startup fails. Pocket Agent uses
the gateway machine's existing SSH agent, identity file, and `~/.ssh/config`;
the browser never receives the private key. See
[SSH remote control](docs/SSH.md).

The optional managed Codex path starts remote app-server and forwards its
loopback WebSocket to `/ws`. That forwarded port stays private and does not need
to be opened in the server firewall.

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

The token grants access to direct SSH terminals as well as shell, filesystem,
configuration, and MCP operations on the app-server host. Treat it like an SSH
credential. Use a random token, WSS, a trusted reverse proxy or private tunnel,
and a device you control. The subprotocol value is an encoding, not encryption,
so reverse-proxy header logs must also redact `Sec-WebSocket-Protocol`.

Terminal output and live process handles are kept in memory and are not restored
after a page reload. Only session names, working directories, and command history
are persisted in browser storage.

Conversation state is restored after a phone network switch by creating a new
connection, repeating `initialize -> initialized`, then reading and resuming the
active thread. A pending approval belongs to the old upstream connection and may
be cancelled when that connection drops; the persisted thread and completed
items still recover. Direct SSH terminal sessions use separate WebSockets and do
not depend on the app-server connection, but each terminal closes if its own
socket, SSH process, or gateway stops.

Codex app-server WebSocket transport remains experimental. Regenerate the
bindings and rerun the full test suite whenever the installed Codex version
changes. The direct SSH terminal does not use app-server `command/exec`.
