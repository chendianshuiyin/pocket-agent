# SSH remote control

Pocket Agent can use the gateway machine's OpenSSH client to connect to a
server, start `codex app-server` on that server, and forward its loopback
WebSocket back to the gateway. The browser continues to use the same `/ws`
endpoint; it never connects to the SSH or app-server port directly.

## Server prerequisites

1. Verify key or agent login from the machine running Pocket Agent:

   ```powershell
   ssh my-server
   ```

2. Install and sign in to Codex on the remote server.
3. Confirm `codex` is available to a non-interactive SSH command:

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

Saving the form calls the authenticated gateway control API. The gateway runs
an argument-safe equivalent of:

```text
ssh -T -L 127.0.0.1:<local>:127.0.0.1:<remote> <target> \
  "codex app-server --listen ws://127.0.0.1:<remote>"
```

The implementation also enables `ExitOnForwardFailure`, keepalives, and a
connection timeout. The remote port remains loopback-only. Switching back to
**本机** stops the managed SSH process and returns `/ws` to the local upstream.
Gateway shutdown stops both the SSH session and any locally managed app-server.

## Troubleshooting

- **Permission denied / publickey**: make `ssh <target>` work from the gateway
  account first. Browser credentials cannot answer an SSH password prompt.
- **codex: not found**: set the absolute remote executable path.
- **Remote Codex did not become ready**: choose an unused remote port and check
  that the remote Codex CLI is current and signed in.
- **Connection drops**: check `ServerAliveInterval`-compatible proxy/firewall
  settings and reconnect from Pocket Agent. The persisted Codex thread can be
  resumed after a new upstream connection.
- **Phone cannot open Pocket Agent**: this is gateway reachability, not the SSH
  tunnel. Publish the gateway through HTTPS/WSS or a trusted VPN; never expose
  app-server's plain WebSocket port.

## Control API

All SSH control routes require the same gateway token as `/ws`, sent as a
Bearer token or `X-Pocket-Agent-Token` header:

- `POST /api/ssh/connect`
- `POST /api/ssh/disconnect`
- `GET /api/ssh/status`

The browser uses the header form and does not place the token in the URL.
