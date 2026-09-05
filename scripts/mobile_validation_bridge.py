"""Opt-in local test fixture. Secrets are never embedded in source or APKs.

The default mode requires explicit permission to temporarily use local Codex
login data. Pass --without-codex-auth to validate signed-out behavior without
reading or uploading local Codex credentials.
"""

import argparse
import base64
import hashlib
from http.server import BaseHTTPRequestHandler, HTTPServer
import json
import os
from pathlib import Path
import re
import secrets
import shlex
import threading

from vps_validate import connect, read_connection


RUNTIME_SESSION = "pocket-agent-runtime-codex-4500"
VALIDATION_LEAF = "/.local/share/pocket-agent/validation-20260905"
WITHOUT_AUTH_MODE = "without-codex-auth"
AUTHORIZED_AUTH_MODE = "authorized-local-codex-auth"


class FixtureCleanupIncomplete(RuntimeError):
    """A test-only remote artifact may require cleanup-only recovery."""


def checked(client, command):
    _, stdout, _ = client.exec_command(command, timeout=45)
    output = stdout.read().decode()
    if stdout.channel.recv_exit_status() != 0:
        raise RuntimeError("Remote validation operation failed")
    return output.strip()


def validation_mode(args):
    return WITHOUT_AUTH_MODE if args.without_codex_auth else AUTHORIZED_AUTH_MODE


def runtime_argv(args, remote_home, codex_home):
    command = ["env"]
    if args.without_codex_auth:
        command.extend(["-u", "OPENAI_API_KEY", "-u", "CODEX_ACCESS_TOKEN"])
    command.extend([
        "CODEX_HOME=" + codex_home,
        remote_home + "/.local/bin/codex",
        "app-server",
        "--listen",
        "ws://127.0.0.1:4500",
    ])
    return command


def remove_if_present(sftp, path):
    try:
        sftp.remove(path)
    except FileNotFoundError:
        pass


def require_missing(sftp, path):
    try:
        sftp.stat(path)
    except FileNotFoundError:
        return
    raise RuntimeError("Isolated authentication file still exists")


def configure_codex_auth(args, sftp, codex_home):
    remote_auth = codex_home + "/auth.json"
    if args.without_codex_auth:
        remove_if_present(sftp, remote_auth)
        require_missing(sftp, remote_auth)
        config_path = codex_home + "/config.toml"
        with sftp.open(config_path, "w") as file:
            file.write('cli_auth_credentials_store = "file"\n')
        sftp.chmod(config_path, 0o600)
        return None

    auth_path = Path(
        os.environ.get("CODEX_HOME", str(Path.home() / ".codex"))
    ) / "auth.json"
    auth = json.loads(auth_path.read_text(encoding="utf-8-sig"))
    if auth.get("auth_mode") != "chatgpt" or not auth.get("tokens"):
        raise RuntimeError("Expected an existing ChatGPT Codex login")
    write_attempted = False
    try:
        write_attempted = True
        with sftp.open(remote_auth, "w") as file:
            file.write(json.dumps(auth))
        sftp.chmod(remote_auth, 0o600)
    except Exception:
        if write_attempted:
            try:
                remove_if_present(sftp, remote_auth)
                require_missing(sftp, remote_auth)
            except Exception as cleanup_error:
                raise FixtureCleanupIncomplete(
                    "Isolated credential cleanup is incomplete; run --cleanup-only"
                ) from cleanup_error
        raise
    return remote_auth


def standard_auth_cleanup_homes(args, remote_home, codex_home):
    if args.without_codex_auth:
        return []
    return [codex_home, remote_home + "/.codex"]


def cleanup_codex_auth(args, client, sftp, remote_home, codex_home):
    if args.without_codex_auth:
        isolated_auth = codex_home + "/auth.json"
        remove_if_present(sftp, isolated_auth)
        require_missing(sftp, isolated_auth)
        return

    # This destructive logout is limited to the explicitly authorized mode.
    for auth_home in standard_auth_cleanup_homes(args, remote_home, codex_home):
        command = (
            "env CODEX_HOME="
            + shlex.quote(auth_home)
            + " "
            + shlex.quote(remote_home + "/.local/bin/codex")
            + " logout >/dev/null 2>&1 || true"
        )
        checked(client, command)
        auth_path = auth_home + "/auth.json"
        remove_if_present(sftp, auth_path)
        require_missing(sftp, auth_path)
    checked(
        client,
        "sudo -n sh -c 'if test -f /root/.codex/auth.json; "
        "then rm -f -- /root/.codex/auth.json; fi; "
        "test ! -f /root/.codex/auth.json'",
    )


def setup(args):
    client = connect(args)
    remote_auth = None
    sftp = None
    runtime_started = False
    try:
        sftp = client.open_sftp()
        remote_home = sftp.normalize(".")
        validation_root = remote_home + VALIDATION_LEAF
        codex_home = validation_root + "/codex-home"
        cwd = validation_root + "/workspace"
        checked(client, "umask 077; mkdir -p " + shlex.quote(codex_home) + " " + shlex.quote(cwd))
        # Refuse to replace an unrelated or already-running remote service.
        checked(client, "! tmux has-session -t =" + RUNTIME_SESSION + " 2>/dev/null")
        remote_auth = configure_codex_auth(args, sftp, codex_home)
        sftp.chmod(codex_home, 0o700)
        command = shlex.join(runtime_argv(args, remote_home, codex_home))
        checked(client, "tmux new-session -d -s " + RUNTIME_SESSION + " " + shlex.quote(command))
        runtime_started = True
        key = client.get_transport().get_remote_server_key()
        host, port, username, password = read_connection(args.config)
        fixture = {
            "id": "validation-vps", "name": "验证服务器", "host": host,
            "port": port, "username": username, "password": password,
            "hostKeyType": key.get_name(),
            "hostKeyFingerprint": "SHA256:" + base64.b64encode(hashlib.sha256(key.asbytes()).digest()).decode().rstrip("="),
            "remoteCodexPort": 4500, "cwd": cwd,
        }
        return fixture, codex_home
    except Exception as error:
        cleanup_failures = []
        if runtime_started:
            try:
                checked(
                    client,
                    "if tmux has-session -t =" + RUNTIME_SESSION
                    + " 2>/dev/null; then tmux kill-session -t ="
                    + RUNTIME_SESSION + "; fi",
                )
            except Exception:
                cleanup_failures.append("runtime")
        if remote_auth and sftp:
            try:
                remove_if_present(sftp, remote_auth)
                require_missing(sftp, remote_auth)
            except Exception:
                cleanup_failures.append("credential")
        if cleanup_failures:
            raise FixtureCleanupIncomplete(
                "Isolated fixture cleanup is incomplete; run --cleanup-only"
            ) from error
        raise
    finally:
        try:
            if sftp:
                try:
                    sftp.close()
                except Exception:
                    pass
        finally:
            # A transport close error must not hide setup cleanup or its result.
            try:
                client.close()
            except Exception:
                pass


def cleanup(args, codex_home):
    client = connect(args)
    try:
        sftp = client.open_sftp()
        remote_home = sftp.normalize(".")
        expected = remote_home + VALIDATION_LEAF + "/codex-home"
        if codex_home != expected:
            raise RuntimeError("Unexpected cleanup target")
        _, status_out, _ = client.exec_command("tmux has-session -t =" + RUNTIME_SESSION + " 2>/dev/null")
        status_out.read()
        if status_out.channel.recv_exit_status() == 0:
            start_command = checked(client, "tmux display-message -p -t =" + RUNTIME_SESSION + " '#{pane_start_command}'")
            expected_command = runtime_argv(args, remote_home, codex_home)
            if shlex.split(start_command) != expected_command:
                raise RuntimeError("Refusing to stop a runtime not owned by this validation")
            checked(client, "tmux kill-session -t =" + RUNTIME_SESSION)
        sessions = checked(client, "tmux list-sessions -F '#{session_name}' 2>/dev/null || true")
        removed_terminals = 0
        for name in sessions.splitlines():
            if re.fullmatch(r"pocket-agent-term-validation-[0-9]+", name):
                checked(client, "tmux kill-session -t " + shlex.quote("=" + name))
                removed_terminals += 1
        cleanup_codex_auth(args, client, sftp, remote_home, codex_home)
        sftp.close()
        result = {
            "mode": validation_mode(args),
            "runtimeStopped": True,
            "temporaryTerminalsRemoved": removed_terminals,
        }
        if not args.without_codex_auth:
            result["remoteCredentialCleanup"] = "verified"
        print(json.dumps(result), flush=True)
    finally:
        client.close()


def finalize_fixture(args, codex_home, defines):
    try:
        if codex_home:
            cleanup(args, codex_home)
    except Exception:
        raise FixtureCleanupIncomplete(
            "Fixture cleanup is incomplete; run --cleanup-only"
        ) from None
    finally:
        defines.unlink(missing_ok=True)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--config", required=True)
    parser.add_argument("--fingerprint")
    parser.add_argument("--port", type=int, default=18089)
    parser.add_argument("--cleanup-only", action="store_true")
    parser.add_argument("--without-codex-auth", action="store_true")
    args = parser.parse_args()
    if args.cleanup_only:
        client = connect(args)
        sftp = client.open_sftp()
        codex_home = sftp.normalize(".") + VALIDATION_LEAF + "/codex-home"
        sftp.close()
        client.close()
        cleanup(args, codex_home)
        return
    fixture = None
    codex_home = None
    defines = Path("artifacts/validation-defines.json")
    try:
        fixture, codex_home = setup(args)
        token = secrets.token_urlsafe(32)
        defines.write_text(json.dumps({"POCKET_FIXTURE_TOKEN": token, "POCKET_FIXTURE_PORT": str(args.port)}), encoding="utf-8")

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *_):
                pass

            def authorized(self):
                return self.headers.get("Authorization") == "Bearer " + token and not self.headers.get("Origin")

            def do_GET(self):
                if self.path != "/config" or not self.authorized():
                    self.send_error(404)
                    return
                payload = json.dumps(fixture).encode()
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Cache-Control", "no-store")
                self.send_header("Content-Length", str(len(payload)))
                self.end_headers()
                self.wfile.write(payload)

            def do_POST(self):
                if self.path != "/finish" or not self.authorized():
                    self.send_error(404)
                    return
                self.send_response(204)
                self.end_headers()
                threading.Thread(target=self.server.shutdown, daemon=True).start()

        with HTTPServer(("127.0.0.1", args.port), Handler) as server:
            print(json.dumps({"fixtureReady": True, "port": args.port,
                              "mode": validation_mode(args)}), flush=True)
            server.serve_forever()
    except Exception as error:
        result = {"errorType": type(error).__name__}
        if isinstance(error, FixtureCleanupIncomplete):
            result.update({
                "cleanup": "incomplete",
                "recovery": "run --cleanup-only",
            })
        print(json.dumps(result), flush=True)
        raise SystemExit(1) from None
    finally:
        finalize_fixture(args, codex_home, defines)


if __name__ == "__main__":
    main()
