# SSH remote control

Pocket Agent provides two independent SSH paths:

1. **Direct terminal**: `/terminal/ws` allocates a native PTY on the gateway and
   runs `ssh -tt`. The browser renders the remote shell with xterm.js and sends
   keystrokes and resize events back to that PTY. It does not require app-server
   to be running.
2. **Managed Codex**: `/api/ssh/connect` starts `codex app-server` remotely and
   forwards its loopback WebSocket to the gateway. The browser's task UI keeps
   using `/ws`.

The browser never connects to the SSH port directly and never receives the
private key. Both paths use the OpenSSH client, agent, config, and identity files
available to the account running the gateway.

## Server prerequisites

1. Verify key or agent login from the machine running Pocket Agent:

   ```powershell
   ssh my-server
   ```

2. If Codex will run there, install and sign in to Codex on the remote server.
3. For managed task mode, confirm `codex` is available to a non-interactive SSH
   command:

   ```powershell
   ssh my-server codex --version
   ```

If the last command cannot find Codex, enter its absolute remote path in the
**远端 Codex executable** field. Do not use `~` in that field; use an absolute
path so it does not depend on shell expansion.

Password prompts are intentionally disabled with `BatchMode=yes`. Use an SSH
agent, a configured identity in `~/.ssh/config`, or an identity-file path on
the gateway machine. Pocket Agent never accepts or stores a private-key body.

## Connect from the web UI

Open **连接与运行设置**, select **SSH 服务器**, and set:

- **SSH Target**: a `Host` alias or `user@host`.
- **SSH Port**: optional; leave empty to use OpenSSH config or port 22.
- **Identity file**: optional path on the gateway machine.
- **Remote app-server Port**: an unused remote loopback port, default 4500.
- **远端 Codex executable**: `codex` or an absolute remote path.
- **服务器工作目录**: an absolute path on the remote server.

After entering a target, **Terminal** can open immediately, even if the managed
remote Codex connection reports an error. Create a session and click connect,
then work in the shell normally:

```text
ssh -tt <target>
remote$ cd /path/to/project
remote$ codex
```

Each terminal tab owns an independent SSH process. Keyboard input, control keys,
ANSI output, terminal resize, full-screen TUI applications, exit status, and
manual termination are relayed over `/terminal/ws`. Closing the terminal socket,
disconnecting SSH mode, or stopping the gateway terminates the corresponding
PTY process. Live terminal output is not persisted across page reloads.

Separately, saving the managed Codex settings calls the authenticated control
API. The gateway runs an argument-safe equivalent of:

```text
ssh -T -L 127.0.0.1:<local>:127.0.0.1:<remote> <target> \
  "codex app-server --listen ws://127.0.0.1:<remote>"
```

The implementation also enables `ExitOnForwardFailure`, keepalives, and a
connection timeout. The remote port remains loopback-only. Switching back to
**本机** stops the managed SSH process, closes direct SSH terminals, and returns
`/ws` to the local upstream. Gateway shutdown stops both SSH paths and any
locally managed app-server.

## Troubleshooting

- **Permission denied / publickey**: make `ssh <target>` work from the gateway
  account first. Browser credentials cannot answer an SSH password prompt.
- **codex: not found**: set the absolute remote executable path.
- **Terminal connects but managed Codex does not**: use the terminal first to
  verify `codex --version`, sign-in state, executable path, and working directory.
- **Remote Codex did not become ready**: choose an unused remote port and check
  that the remote Codex CLI is current and signed in.
- **Connection drops**: check `ServerAliveInterval`-compatible proxy/firewall
  settings and reconnect from Pocket Agent. The persisted Codex thread can be
  resumed after a new upstream connection.
- **Phone cannot open Pocket Agent**: this is gateway reachability, not the SSH
  tunnel. Publish the gateway through HTTPS/WSS or a trusted VPN; never expose
  app-server's plain WebSocket port.

## Control API

All SSH routes require the same gateway token as `/ws`. HTTP control calls accept
a Bearer token or `X-Pocket-Agent-Token`; the browser terminal sends the encoded
token in `Sec-WebSocket-Protocol`:

- `POST /api/ssh/connect`
- `POST /api/ssh/disconnect`
- `GET /api/ssh/status`
- `GET /terminal/ws` (WebSocket upgrade and PTY protocol)

The production browser clients do not place the token in the URL. A query-token
form remains available for non-browser or legacy WebSocket clients and should be
avoided unless access logs redact it.
