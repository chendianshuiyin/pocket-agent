# Validation record

Date: 2026-08-09  
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

- Rust: 16 tests passed; the opt-in real-Codex test is ignored by the default suite.
- Frontend: 7 test files and 24 tests passed.
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
- the Windows safe-sandbox terminal executes through the buffered fallback and returns stdout plus exit code
- the page console contains no application errors or warnings
- the 360 x 800 viewport has no horizontal overflow
- the Slash palette exposes UI commands plus native `/compact` and `/review`
- `skills/list` loads real app-server Skills, and selecting one creates both the
  `$name` marker and explicit Skill attachment
- SSH settings render and scroll correctly at the Android viewport

The real probe exposed two platform/browser defects that were fixed during validation:

1. Windows sandbox rejects streaming `command/exec`; safe Windows modes now use buffered execution, while Unix and explicit `danger-full-access` retain PTY streaming.
2. A very long task preview could expand the mobile list to its min-content width; the page and row constraints now prevent horizontal overflow.

## Known transport boundary

The gateway intentionally creates one upstream app-server WebSocket per browser WebSocket and forwards frames without interpreting JSON-RPC. Persisted threads and completed items recover after reconnect. A server request or PTY owned by an upstream connection may be cancelled if that upstream connection itself is lost; the gateway does not replay unresolved approvals across a new upstream connection.

Pending requests carry their source thread in the UI, including a distinct
background-task label when the user is viewing another thread. Socket
generation checks prevent late messages from a replaced connection from
resolving requests on the new connection.

## SSH validation boundary

Automated Rust coverage verifies SSH control-route authentication, target
validation, argument-safe command construction, dynamic upstream selection,
and managed-process shutdown behavior. The browser client tests verify control
URL derivation, header-token transport, request serialization, and port
validation.

This validation host did not have an SSH server or a configured remote Host
alias, so no external SSH login was attempted. A deployment must complete the
key-based `ssh <target>` and `ssh <target> codex --version` checks in
[SSH remote control](SSH.md) before treating remote connectivity as verified.
