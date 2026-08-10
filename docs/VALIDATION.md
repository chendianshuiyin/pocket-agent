# Validation record

Date: 2026-08-11
Host: Windows 10.0.26200, x86_64
Codex CLI: `0.144.0`

## Automated checks

The following commands passed from the repository root:

```powershell
cargo fmt --all --check
cargo check --workspace --all-targets --locked
cargo test --workspace --all-targets --locked
cargo clippy --workspace --all-targets --locked -- -D warnings

npm --prefix frontend ci
npm --prefix frontend run typecheck
npm --prefix frontend test
npm --prefix frontend run build
npm --prefix frontend audit --audit-level=high
```

Results:

- Rust: 20 tests passed (14 unit and 6 gateway); the opt-in real-Codex test is ignored by the default suite.
- Frontend: 10 test files and 35 tests passed.
- npm audit: 0 vulnerabilities.
- Vite built the production application and generated the service worker.
- The generated manifest contains 192 px and 512 px PNG icons, a maskable icon, an explicit app id, start URL, scope, and standalone display mode.

## Real Codex integration

The ignored integration test was run explicitly against the installed Codex CLI:

```powershell
cargo test --test managed_codex -- --ignored
```

It verified managed app-server startup, the real `/readyz` response, a WebSocket handshake, and process shutdown.

`scripts/probe-app-server.mjs` was also run through the authenticated Axum gateway rather than directly against app-server. It verified:

- `initialize -> initialized`
- `model/list`
- rejection of the legacy `thread/start.sandbox = "workspaceWrite"` value with `-32600`
- success of `thread/start.sandbox = "workspace-write"`
- a real app-server thread id and Windows platform response

## Browser checks

The production build was served by the Rust gateway and tested at 412 x 915
and 360 x 800 Android-style viewports against the real local app-server.

Verified paths:

- missing token shows a recoverable disconnected state
- missing credentials pause reconnect immediately and open Settings instead of
  entering an unbounded retry loop
- saving the token connects and completes initialization
- the browser authenticates with `Sec-WebSocket-Protocol` and keeps the token
  out of the WebSocket URL
- task history loads `appServer` and sub-agent sources
- selecting a task and reloading restores it with `thread/read` followed by `thread/resume`
- long task previews remain constrained to the viewport and are clickable
- the host filesystem lists the configured workspace
- Apps and MCP status load from `app/list` and `mcpServerStatus/list`
- the SSH terminal session manager renders a dedicated xterm.js canvas and exposes direct PTY controls
- the page console contains no application errors or warnings
- the 360 x 800 viewport has no horizontal overflow
- the Slash palette exposes UI commands plus native `/compact` and `/review`
- `skills/list` loads real app-server Skills, and selecting one creates both the
  `$name` marker and explicit Skill attachment
- SSH settings render and scroll correctly at the Android viewport

The browser probe exposed a very long task preview that could expand the mobile
list to its min-content width. Page and row constraints now prevent horizontal
overflow. The terminal was subsequently moved off app-server `command/exec` and
onto its own SSH PTY transport.

## Known transport boundary

The gateway intentionally creates one upstream app-server WebSocket per browser
WebSocket and forwards frames without interpreting JSON-RPC. Persisted threads
and completed items recover after reconnect. A server request owned by an
upstream connection may be cancelled if that connection is lost; the gateway
does not replay unresolved approvals across a new upstream connection.

Each direct terminal has a separate authenticated `/terminal/ws` connection and
an independent SSH PTY process. App-server reconnects do not close those
terminals. A terminal does close when its own socket, SSH process, or the gateway
stops, and terminal output is not replayed after reconnection.

Pending requests carry their source thread in the UI, including a distinct
background-task label when the user is viewing another thread. Socket
generation checks prevent late messages from a replaced connection from
resolving requests on the new connection.

## SSH validation boundary

Automated Rust coverage verifies SSH control-route and terminal-WebSocket
authentication, target/session/path validation, argument-safe command
construction, dynamic upstream selection, and managed-process shutdown
behavior. Frontend tests verify control URL derivation, subprotocol-token
transport, terminal start/input/resize serialization, stale-socket isolation,
multi-session lifecycle, bounded output, and metadata persistence.

This validation host did not have a configured external SSH target or
credentials, so no external login was attempted. The automated suite validates
the PTY protocol, SSH argument construction, transport lifecycle, and renderer,
but it does not claim a successful external server login. A deployment must
complete the key-based `ssh <target>` and, when needed,
`ssh <target> codex --version` checks in [SSH remote control](SSH.md) before
treating remote connectivity as verified.
