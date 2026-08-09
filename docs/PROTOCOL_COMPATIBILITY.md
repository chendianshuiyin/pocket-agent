# Codex app-server compatibility

Pocket Agent currently targets `codex-cli 0.144.0`. The app-server protocol is
versioned with the CLI, so generated bindings are the source of truth when a
rolling documentation example and the installed server disagree.

Regenerate bindings after every Codex upgrade:

```powershell
.\scripts\generate-schema.ps1 -OutDir .\artifacts\app-server-schema
```

```bash
./scripts/generate-schema.sh ./artifacts/app-server-schema
```

Set `CODEX_POCKET_EXPERIMENTAL_SCHEMA=1` on Unix, or pass `-Experimental` on
PowerShell, to include the experimental surface.

## Connection lifecycle

Each new upstream WebSocket connection must perform this sequence exactly once:

```text
initialize request
  -> initialize response
initialized notification
  -> model/list, thread/list, or another request
```

Requests use `{ method, id, params }`, responses use `{ id, result }` or
`{ id, error }`, and notifications omit `id`. Server-initiated requests also
carry an `id`; the client must answer that exact request id.

Pocket Agent keeps `experimentalApi` disabled: both `app/list` and
`item/tool/requestUserInput` are part of the stable 0.144.0 surface. Unknown
inbound fields and item types remain visible, while unknown server requests
fail closed with `-32601` rather than being approved.

## Important wire-format distinctions

| Location | Correct value in 0.144.0 |
| --- | --- |
| `thread/start.sandbox` | `read-only`, `workspace-write`, or `danger-full-access` |
| `turn/start.sandboxPolicy.type` | `readOnly`, `workspaceWrite`, `dangerFullAccess`, or `externalSandbox` |
| Text input | `{ "type": "text", "text": "...", "text_elements": [] }` |
| Request user input method | `item/tool/requestUserInput` |
| File-change streaming | `item/fileChange/patchUpdated` and `turn/diff/updated` |

A real 0.144.0 WebSocket probe confirmed that
`thread/start.sandbox = "workspaceWrite"` is rejected with `-32600`; the
kebab-case `"workspace-write"` value succeeds. This intentionally differs from
some rolling documentation examples.

## Client methods used by Pocket Agent

- Discovery: `model/list`, `thread/list`, `thread/read`, `app/list`,
  `mcpServerStatus/list`, `skills/list`
- Conversation: `thread/start`, `thread/resume`, `turn/start`, `turn/steer`,
  `turn/interrupt`, `thread/compact/start`, `review/start`
- Files: `fs/readDirectory`, `fs/writeFile`
- Terminal: `command/exec`, `command/exec/write`,
  `command/exec/terminate`

`thread/list` explicitly includes `appServer` in `sourceKinds`; the server's
default filter only includes interactive CLI and VS Code sources and would hide
threads created by this client.

`thread/read` is used to load persisted turns, but it does not subscribe the
connection. Reconnect recovery therefore always follows it with
`thread/resume` before continuing the conversation.

The command palette maps `/compact` and `/review` to the stable methods above;
navigation commands remain client-side. Unknown slash-prefixed text is sent as
ordinary user input rather than being discarded.

`skills/list` is scoped to the active remote `cwd`. `skills/changed` is treated
as an invalidation signal and triggers a forced refresh. An explicit Skill turn
contains both the `$<skill-name>` marker and `{ type: "skill", name, path }`,
matching the stable 0.144.0 schema.

## Streamed state

The UI aggregates delta notifications for immediate rendering, keyed by
`(threadId, turnId, itemId)`. A later `item/completed.item` replaces that local
aggregate and is authoritative. The primary events are:

- `turn/started`, `turn/completed`, `turn/plan/updated`, `turn/diff/updated`
- `item/started`, `item/completed`
- `item/agentMessage/delta`, `item/plan/delta`
- `item/reasoning/summaryTextDelta`, `item/reasoning/textDelta`
- `item/commandExecution/outputDelta`
- `item/fileChange/patchUpdated`
- `item/mcpToolCall/progress`

`item/fileChange/outputDelta` is retained only as a legacy compatibility path;
the current server does not rely on it.

## Server requests

Pocket Agent renders explicit UI for:

- `item/commandExecution/requestApproval`
- `item/fileChange/requestApproval`
- `item/tool/requestUserInput`

Command and file approval decisions use `accept`, `acceptForSession`, `decline`,
or `cancel`. Request-user-input responses map each question id to
`{ answers: string[] }`. Secret answers are never copied into the activity log.

`serverRequest/resolved` removes a pending prompt even if it was cleared by turn
completion or interruption before the user answered.

## Images, files, and terminal

`localImage.path` is a path on the app-server host, not a browser-local file.
The mobile upload flow first writes the selected file with `fs/writeFile`
(`dataBase64`), then sends the resulting absolute path as `localImage`.

The embedded terminal uses stable `command/exec` with a client-generated,
connection-scoped `processId`. Unix and explicitly selected
`danger-full-access` use PTY mode, streamed stdout/stderr, and base64 stdin.
Because 0.144.0 rejects streaming execution inside the Windows safe sandbox,
Windows `read-only` and `workspace-write` use the buffered response while
retaining the process id for termination. `process/spawn` is not used because
it is experimental in 0.144.0.

## Security boundary

The raw app-server surface includes shell, filesystem, configuration, login,
and MCP calls. A Pocket Agent token therefore grants host-control privileges.

- app-server binds only to a loopback `ws://` address.
- The Rust gateway rejects non-loopback upstreams.
- SSH mode starts app-server on remote loopback and exposes it only through a
  gateway-local loopback forward.
- Remote browser traffic must use TLS (`https://` / `wss://`) at a reverse
  proxy or tunnel.
- Browser authentication uses a hex-encoded token in
  `Sec-WebSocket-Protocol`, not a query string. The encoding is reversible;
  proxy header logs must redact it and remote traffic must use WSS.
- Bearer, `X-Pocket-Agent-Token`, and query tokens remain compatibility paths.
  Query tokens must not appear in HTTP request logs.
- Unknown server requests are never approved automatically.

The upstream WebSocket transport remains experimental. Run the schema
generation and integration tests whenever the installed Codex CLI changes.
