# Mobile implementation contract

Android and iOS share the Flutter application under `mobile/`. The existing web
client and gateway remain optional and are not required by the mobile app.

## Scope and ownership

- Personal, multiple Linux servers, independent SSH connections.
- SSH PTY terminals and Codex app-server tasks are separate features.
- A remote, loopback-only app-server survives phone disconnection. SSH forwards
  its WebSocket endpoint; no public app-server port is opened.
- SSH host keys require explicit first-use confirmation and pinned verification.
- Credentials belong only in OS secure storage; never preferences, source or logs.
- Remote Codex authentication is managed on the server, not copied into the app.
- iOS sources are supplied; Mac/Xcode validation is unavailable in this workspace.

## Parallel coding boundaries

Transport agent owns `lib/core/`, `lib/ssh/`, and corresponding tests. It supplies
`ServerProfile`, `ServerSecret`, `ServerRepository`, `SshConnection` and
`CodexTunnel`, plus guarded persistent remote runtime setup and tmux PTYs.

Protocol agent owns `lib/codex/` and corresponding tests. It supplies
`CodexClient.connect(Uri)`, JSON-RPC calls/events/server requests and a typed
thread/turn/skill facade. It must not depend on the SSH implementation.

UI agent owns `lib/main.dart`, `lib/ui/`, `lib/app/` and widget tests. It integrates
the published transport/protocol APIs and keeps per-server/per-thread state.

The main agent owns platform configuration, integration tests, real VPS tests,
security review, documentation, dependency changes and commits. Agents coordinate
API signatures directly before integration and do not commit or handle VPS secrets.

## Verification gates

1. Unit/widget tests and static analysis.
2. Real SSH host-key verification, PTY input/output and resize.
3. Remote app-server initialize, task creation/history, streaming, interruption,
   approval handling, and reconnect while work is running.
4. Android emulator smoke tests and APK build.
5. Remove temporary test resources and both temporary and pre-existing remote
   Codex login credentials at the user's explicit request; verify without
   exposing credential contents.

Changes are reviewed and committed by feature rather than one final bulk commit.
