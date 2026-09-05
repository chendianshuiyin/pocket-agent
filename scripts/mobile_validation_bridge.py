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
RUNTIME_PORT = 4500
TRANSPORT_TOKEN_LEAF = "/.pocket-agent/app-server-4500.token"
TRANSPORT_OWNER_NAME = "transport-token-4500.sha256"
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


def transport_paths(remote_home, validation_root):
    return (
        remote_home + TRANSPORT_TOKEN_LEAF,
        validation_root + "/" + TRANSPORT_OWNER_NAME,
    )


def ensure_validation_directories(client, remote_home):
    local_root = remote_home + "/.local"
    share_root = local_root + "/share"
    pocket_root = share_root + "/pocket-agent"
    validation_root = remote_home + VALIDATION_LEAF
    codex_home = validation_root + "/codex-home"
    cwd = validation_root + "/workspace"
    directories = (
        remote_home,
        local_root,
        share_root,
        pocket_root,
        validation_root,
        codex_home,
        cwd,
    )
    assignments = "\n".join(
        "dir_{}={}".format(index, shlex.quote(path))
        for index, path in enumerate(directories)
    )
    directory_arguments = " ".join(
        '"$dir_{}"'.format(index) for index in range(len(directories))
    )
    strict_arguments = " ".join(
        '"$dir_{}"'.format(index)
        for index in range(len(directories) - 3, len(directories))
    )
    script = """set -eu
{assignments}
uid="$(id -u)"
for directory in {directory_arguments}; do
  if test -L "$directory" || {{ test -e "$directory" && ! test -d "$directory"; }}; then
    exit 73
  fi
  if test -e "$directory"; then
    test "$(stat -c '%u' -- "$directory")" = "$uid" || exit 73
  else
    mkdir -m 700 -- "$directory"
  fi
done
for directory in {directory_arguments}; do
  test ! -L "$directory" && test -d "$directory" || exit 73
  test "$(stat -c '%u' -- "$directory")" = "$uid" || exit 73
done
chmod 700 -- {strict_arguments}
for directory in {strict_arguments}; do
  test "$(stat -c '%a' -- "$directory")" = 700 || exit 73
done
""".format(
        assignments=assignments,
        directory_arguments=directory_arguments,
        strict_arguments=strict_arguments,
    )
    checked(client, "sh -lc " + shlex.quote(script))
    return validation_root, codex_home, cwd


def require_transport_slot_available(client, remote_home, validation_root):
    token_file, owner_file = transport_paths(remote_home, validation_root)
    script = """set -eu
token_file={token_file}
owner_file={owner_file}
! test -e "$token_file" && ! test -L "$token_file"
! test -e "$owner_file" && ! test -L "$owner_file"
""".format(
        token_file=shlex.quote(token_file),
        owner_file=shlex.quote(owner_file),
    )
    checked(client, "sh -lc " + shlex.quote(script))


def create_fixture_transport_token(client, remote_home, validation_root):
    token_file, owner_file = transport_paths(remote_home, validation_root)
    token_dir = remote_home + "/.pocket-agent"
    script = r"""set -eu
token_dir={token_dir}
token_file={token_file}
validation_root={validation_root}
owner_file={owner_file}
uid="$(id -u)"
for command in mktemp od sha256sum stat; do
  command -v "$command" >/dev/null 2>&1 || exit 69
done
if test -L "$token_dir" || {{ test -e "$token_dir" && ! test -d "$token_dir"; }}; then
  exit 73
fi
if ! test -e "$token_dir"; then
  if ! mkdir -m 700 -- "$token_dir" 2>/dev/null; then
    test -d "$token_dir" || exit 73
  fi
fi
for directory in "$token_dir" "$validation_root"; do
  test ! -L "$directory" && test -d "$directory" || exit 73
  test "$(stat -c '%u' -- "$directory")" = "$uid" || exit 73
  test "$(stat -c '%a' -- "$directory")" = 700 || exit 73
done
! test -e "$token_file" && ! test -L "$token_file" || exit 75
! test -e "$owner_file" && ! test -L "$owner_file" || exit 75
token_temp=''
owner_temp=''
token_temp_identity=''
owner_temp_identity=''
token_created=0
owner_created=0
token_identity=''
owner_identity=''
cleanup_partial() {{
  if test -n "$token_temp" && test -n "$token_temp_identity" &&
     test -f "$token_temp" && test ! -L "$token_temp" &&
     test "$(stat -c '%d:%i' -- "$token_temp")" = "$token_temp_identity"; then
    case "$token_temp" in "$token_file.fixture."??????) rm -f -- "$token_temp";; esac
  fi
  if test -n "$owner_temp" && test -n "$owner_temp_identity" &&
     test -f "$owner_temp" && test ! -L "$owner_temp" &&
     test "$(stat -c '%d:%i' -- "$owner_temp")" = "$owner_temp_identity"; then
    case "$owner_temp" in "$owner_file.tmp."??????) rm -f -- "$owner_temp";; esac
  fi
  if test "$owner_created" = 1 && test -f "$owner_file" && test ! -L "$owner_file" &&
     test "$(stat -c '%d:%i' -- "$owner_file")" = "$owner_identity"; then
    rm -f -- "$owner_file"
  fi
  if test "$token_created" = 1 && test -f "$token_file" && test ! -L "$token_file" &&
     test "$(stat -c '%d:%i' -- "$token_file")" = "$token_identity"; then
    rm -f -- "$token_file"
  fi
}}
trap cleanup_partial EXIT HUP INT TERM
token_temp="$(umask 077; mktemp "$token_file.fixture.XXXXXX")"
token_temp_identity="$(stat -c '%d:%i' -- "$token_temp")"
owner_temp="$(umask 077; mktemp "$owner_file.tmp.XXXXXX")"
owner_temp_identity="$(stat -c '%d:%i' -- "$owner_temp")"
token="$(od -An -N32 -tx1 /dev/urandom | tr -d ' \n')"
case "$token" in *[!a-f0-9]*|'') exit 74;; esac
test "${{#token}}" = 64 || exit 74
printf '%s\n' "$token" > "$token_temp"
chmod 600 -- "$token_temp"
token_hash="$(printf '%s' "$token" | sha256sum | awk '{{print $1}}')"
printf '%s\n' "$token_hash" > "$owner_temp"
chmod 600 -- "$owner_temp"
token_created=1
token_identity="$(stat -c '%d:%i' -- "$token_temp")"
ln -- "$token_temp" "$token_file"
owner_created=1
owner_identity="$(stat -c '%d:%i' -- "$owner_temp")"
ln -- "$owner_temp" "$owner_file"
rm -f -- "$token_temp" "$owner_temp"
test "$(stat -c '%a' -- "$token_file")" = 600 || exit 74
test "$(stat -c '%h' -- "$token_file")" = 1 || exit 74
test "$(stat -c '%a' -- "$owner_file")" = 600 || exit 74
test "$(stat -c '%h' -- "$owner_file")" = 1 || exit 74
trap - EXIT HUP INT TERM
printf '%s' "$token"
""".format(
        token_dir=shlex.quote(token_dir),
        token_file=shlex.quote(token_file),
        validation_root=shlex.quote(validation_root),
        owner_file=shlex.quote(owner_file),
    )
    token = checked(client, "sh -lc " + shlex.quote(script))
    if not re.fullmatch(r"[a-f0-9]{64}", token):
        raise RuntimeError("Remote transport token creation failed")
    return token


def cleanup_fixture_transport_token(client, remote_home, validation_root):
    token_file, owner_file = transport_paths(remote_home, validation_root)
    token_dir = remote_home + "/.pocket-agent"
    script = r"""set -eu
token_dir={token_dir}
token_file={token_file}
validation_root={validation_root}
owner_file={owner_file}
uid="$(id -u)"
if ! test -e "$token_file" && ! test -L "$token_file" &&
   ! test -e "$owner_file" && ! test -L "$owner_file"; then
  printf absent
  exit 0
fi
if {{ test -e "$token_file" || test -L "$token_file"; }} &&
   ! test -e "$owner_file" && ! test -L "$owner_file"; then
  printf token-without-owner
  exit 0
fi
if ! test -e "$token_file" && ! test -L "$token_file" &&
   {{ test -e "$owner_file" || test -L "$owner_file"; }}; then
  test ! -L "$validation_root" && test -d "$validation_root" || exit 73
  test "$(stat -c '%u' -- "$validation_root")" = "$uid" || exit 73
  test "$(stat -c '%a' -- "$validation_root")" = 700 || exit 73
  test ! -L "$owner_file" && test -f "$owner_file" || exit 74
  test "$(stat -c '%u' -- "$owner_file")" = "$uid" || exit 74
  test "$(stat -c '%a' -- "$owner_file")" = 600 || exit 74
  test "$(stat -c '%h' -- "$owner_file")" = 1 || exit 74
  rm -f -- "$owner_file"
  test ! -e "$owner_file" && ! test -L "$owner_file" || exit 75
  printf owner-removed
  exit 0
fi
for directory in "$token_dir" "$validation_root"; do
  test ! -L "$directory" && test -d "$directory" || exit 73
  test "$(stat -c '%u' -- "$directory")" = "$uid" || exit 73
  test "$(stat -c '%a' -- "$directory")" = 700 || exit 73
done
for file in "$token_file" "$owner_file"; do
  test ! -L "$file" && test -f "$file" || exit 74
  test "$(stat -c '%u' -- "$file")" = "$uid" || exit 74
  test "$(stat -c '%a' -- "$file")" = 600 || exit 74
  test "$(stat -c '%h' -- "$file")" = 1 || exit 74
done
token="$(cat -- "$token_file")"
owner_hash="$(cat -- "$owner_file")"
case "$token" in *[!a-f0-9]*|'') exit 74;; esac
case "$owner_hash" in *[!a-f0-9]*|'') exit 74;; esac
test "${{#token}}" = 64 && test "${{#owner_hash}}" = 64 || exit 74
actual_hash="$(printf '%s' "$token" | sha256sum | awk '{{print $1}}')"
test "$actual_hash" = "$owner_hash" || exit 75
rm -f -- "$token_file"
test ! -e "$token_file" && ! test -L "$token_file" || exit 75
rm -f -- "$owner_file"
test ! -e "$owner_file" && ! test -L "$owner_file" || exit 75
printf removed
""".format(
        token_dir=shlex.quote(token_dir),
        token_file=shlex.quote(token_file),
        validation_root=shlex.quote(validation_root),
        owner_file=shlex.quote(owner_file),
    )
    outcome = checked(client, "sh -lc " + shlex.quote(script))
    if outcome == "token-without-owner":
        raise FixtureCleanupIncomplete(
            "Remote app-server token has no fixture owner marker; "
            "it was not removed and requires manual inspection"
        )
    if outcome not in {"absent", "owner-removed", "removed"}:
        raise RuntimeError("Unexpected transport token cleanup result")
    return outcome


def runtime_argv(args, remote_home, codex_home):
    command = ["env"]
    if args.without_codex_auth:
        for variable in (
            "OPENAI_API_KEY",
            "CODEX_API_KEY",
            "CODEX_ACCESS_TOKEN",
            "OPENAI_ACCESS_TOKEN",
            "CHATGPT_ACCESS_TOKEN",
        ):
            command.extend(["-u", variable])
    command.extend([
        "CODEX_HOME=" + codex_home,
        remote_home + "/.local/bin/codex",
        "app-server",
        "--listen",
        "ws://127.0.0.1:4500",
        "--ws-auth",
        "capability-token",
        "--ws-token-file",
        remote_home + TRANSPORT_TOKEN_LEAF,
    ])
    return command


def require_owned_runtime(args, client, remote_home, codex_home):
    pane_output = checked(
        client,
        "tmux list-panes -s -t =" + RUNTIME_SESSION + " -F '#{pane_id}'",
    )
    pane_ids = pane_output.splitlines() if pane_output else []
    if len(pane_ids) != 1 or not re.fullmatch(r"%[0-9]+", pane_ids[0]):
        raise RuntimeError(
            "Refusing to stop a runtime without exactly one validated pane"
        )

    start_command = checked(
        client,
        "tmux display-message -p -t "
        + shlex.quote(pane_ids[0])
        + " '#{pane_start_command}'",
    )
    actual_argv = shlex.split(start_command)
    if len(actual_argv) == 1:
        actual_argv = shlex.split(actual_argv[0])
    if actual_argv != runtime_argv(args, remote_home, codex_home):
        raise RuntimeError(
            "Refusing to stop a runtime not owned by this validation"
        )


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
    transport_token_attempted = False
    transport_token_confirmed = False
    try:
        sftp = client.open_sftp()
        remote_home = sftp.normalize(".")
        validation_root, codex_home, cwd = ensure_validation_directories(
            client, remote_home
        )
        # Refuse to replace an unrelated or already-running remote service.
        checked(client, "! tmux has-session -t =" + RUNTIME_SESSION + " 2>/dev/null")
        require_transport_slot_available(client, remote_home, validation_root)
        transport_token_attempted = True
        create_fixture_transport_token(client, remote_home, validation_root)
        transport_token_confirmed = True
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
            "remoteCodexPort": RUNTIME_PORT, "cwd": cwd,
        }
        return fixture, codex_home
    except Exception as error:
        cleanup_failures = []
        runtime_stopped = not runtime_started
        if runtime_started:
            try:
                checked(
                    client,
                    "if tmux has-session -t =" + RUNTIME_SESSION
                    + " 2>/dev/null; then tmux kill-session -t ="
                    + RUNTIME_SESSION + "; fi",
                )
                runtime_stopped = True
            except Exception:
                cleanup_failures.append("runtime")
        if remote_auth and sftp:
            try:
                remove_if_present(sftp, remote_auth)
                require_missing(sftp, remote_auth)
            except Exception:
                cleanup_failures.append("credential")
        if transport_token_attempted and runtime_stopped:
            try:
                cleanup_fixture_transport_token(
                    client, remote_home, validation_root
                )
            except Exception:
                cleanup_failures.append("transport-token")
        elif transport_token_attempted:
            cleanup_failures.append("transport-token")
        if transport_token_attempted and not transport_token_confirmed:
            cleanup_failures.append("transport-token-uncertain")
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
            require_owned_runtime(args, client, remote_home, codex_home)
            checked(client, "tmux kill-session -t =" + RUNTIME_SESSION)
        sessions = checked(client, "tmux list-sessions -F '#{session_name}' 2>/dev/null || true")
        removed_terminals = 0
        for name in sessions.splitlines():
            if re.fullmatch(r"pocket-agent-term-validation-[0-9]+", name):
                checked(client, "tmux kill-session -t " + shlex.quote("=" + name))
                removed_terminals += 1
        try:
            cleanup_codex_auth(args, client, sftp, remote_home, codex_home)
        finally:
            transport_cleanup = cleanup_fixture_transport_token(
                client, remote_home, remote_home + VALIDATION_LEAF
            )
        sftp.close()
        result = {
            "mode": validation_mode(args),
            "runtimeStopped": True,
            "transportTokenRemoved": transport_cleanup
            in {"absent", "owner-removed", "removed"},
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
