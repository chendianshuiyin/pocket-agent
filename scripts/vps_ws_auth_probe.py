"""Safely probe Codex app-server WebSocket capability-token enforcement."""

import argparse
import contextlib
import io
import json
import re
import sys


REMOTE_PROBE = r'''import base64
import json
import os
import re
import secrets
import shutil
import signal
import socket
import stat
import subprocess
import sys
import tempfile
import time

PREFIX = "pocket-agent-ws-auth-"
TEMP_PARENT = "/tmp"
RESERVED_PORT = 4500


class CleanupError(Exception):
    pass


class ProbeAssertionError(Exception):
    pass


def reserve_port():
    for _ in range(10):
        probe = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        try:
            probe.bind(("127.0.0.1", 0))
            port = probe.getsockname()[1]
        finally:
            probe.close()
        if port != RESERVED_PORT:
            return port
    raise OSError("unable to reserve a non-runtime port")


def is_listening(port):
    if port is None:
        return False
    probe = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    probe.settimeout(0.2)
    try:
        return probe.connect_ex(("127.0.0.1", port)) == 0
    finally:
        probe.close()


def wait_for_listener(process, port, timeout):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if process.poll() is not None:
            raise RuntimeError("app-server exited before listening")
        if is_listening(port):
            return
        time.sleep(0.05)
    raise TimeoutError("app-server listener timeout")


def websocket_status(port, bearer_token):
    key = base64.b64encode(secrets.token_bytes(16)).decode("ascii")
    headers = [
        "GET / HTTP/1.1",
        "Host: 127.0.0.1:%d" % port,
        "Upgrade: websocket",
        "Connection: Upgrade",
        "Sec-WebSocket-Key: %s" % key,
        "Sec-WebSocket-Version: 13",
    ]
    if bearer_token is not None:
        headers.append("Authorization: Bearer %s" % bearer_token)
    request = ("\r\n".join(headers) + "\r\n\r\n").encode("ascii")

    connection = socket.create_connection(("127.0.0.1", port), timeout=3)
    connection.settimeout(3)
    try:
        connection.sendall(request)
        response = bytearray()
        while b"\r\n\r\n" not in response:
            chunk = connection.recv(4096)
            if not chunk:
                break
            response.extend(chunk)
            if len(response) > 16384:
                raise ValueError("oversized HTTP response")
    finally:
        connection.close()

    status_line = bytes(response).split(b"\r\n", 1)[0]
    match = re.fullmatch(rb"HTTP/1\.[01] ([1-5][0-9]{2})(?: .*)?", status_line)
    if match is None:
        raise ValueError("invalid HTTP status line")
    return int(match.group(1))


def stop_process_group(process):
    if process is None:
        return True

    def group_exists():
        try:
            os.killpg(process.pid, 0)
            return True
        except ProcessLookupError:
            return False
        except PermissionError:
            return True

    try:
        os.killpg(process.pid, signal.SIGTERM)
    except ProcessLookupError:
        pass
    deadline = time.monotonic() + 3
    while group_exists() and time.monotonic() < deadline:
        process.poll()
        time.sleep(0.05)
    if group_exists():
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        deadline = time.monotonic() + 3
        while group_exists() and time.monotonic() < deadline:
            process.poll()
            time.sleep(0.05)
    try:
        process.wait(timeout=0.2)
    except subprocess.TimeoutExpired:
        pass
    return not group_exists()


def safe_probe_dir(path, parent, identity):
    if path is None or parent is None or identity is None:
        return False
    absolute = os.path.abspath(path)
    resolved = os.path.realpath(path)
    if absolute != path or resolved != path:
        return False
    if os.path.dirname(resolved) != parent:
        return False
    if not os.path.basename(resolved).startswith(PREFIX):
        return False
    try:
        metadata = os.lstat(resolved)
    except FileNotFoundError:
        return False
    return (
        stat.S_ISDIR(metadata.st_mode)
        and not stat.S_ISLNK(metadata.st_mode)
        and (metadata.st_dev, metadata.st_ino) == identity
    )


def sanitized_version(codex, environment):
    completed = subprocess.run(
        [codex, "--version"],
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        text=True,
        timeout=10,
        env=environment,
        check=True,
    )
    version = completed.stdout.strip().splitlines()[0]
    if re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._+() -]{0,119}", version) is None:
        raise ValueError("unexpected version format")
    return version


def main():
    workdir = None
    workdir_identity = None
    temp_parent = None
    codex_home = None
    token_path = None
    process = None
    port = None
    result = {"status": "error"}
    error_type = None
    process_stopped = True
    listener_stopped = True
    token_removed = True
    codex_home_removed = True
    temp_removed = True

    try:
        if not os.path.isdir(TEMP_PARENT):
            raise FileNotFoundError("temporary parent is unavailable")
        temp_parent = os.path.realpath(TEMP_PARENT)
        if not os.path.isabs(temp_parent):
            raise ValueError("temporary parent is not absolute")

        workdir = tempfile.mkdtemp(prefix=PREFIX, dir=temp_parent)
        workdir = os.path.realpath(workdir)
        os.chmod(workdir, 0o700)
        metadata = os.lstat(workdir)
        workdir_identity = (metadata.st_dev, metadata.st_ino)
        if not safe_probe_dir(workdir, temp_parent, workdir_identity):
            raise CleanupError("unsafe temporary directory")
        if stat.S_IMODE(metadata.st_mode) != 0o700:
            raise PermissionError("temporary directory mode")

        codex_home = os.path.join(workdir, "codex-home")
        os.mkdir(codex_home, 0o700)
        os.chmod(codex_home, 0o700)
        if stat.S_IMODE(os.stat(codex_home).st_mode) != 0o700:
            raise PermissionError("CODEX_HOME mode")
        token_path = os.path.join(workdir, "capability-token")
        token = secrets.token_hex(32)
        descriptor = os.open(token_path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(descriptor, "w", encoding="ascii") as token_file:
            token_file.write(token + "\n")
        os.chmod(token_path, 0o600)
        if stat.S_IMODE(os.stat(token_path).st_mode) != 0o600:
            raise PermissionError("token file mode")

        codex = os.path.expanduser("~/.local/bin/codex")
        if not os.path.isfile(codex) or not os.access(codex, os.X_OK):
            raise FileNotFoundError("Codex runtime is unavailable")
        environment = os.environ.copy()
        environment["CODEX_HOME"] = codex_home
        for auth_variable in (
            "OPENAI_API_KEY",
            "CODEX_API_KEY",
            "CODEX_ACCESS_TOKEN",
            "OPENAI_ACCESS_TOKEN",
            "CHATGPT_ACCESS_TOKEN",
        ):
            environment.pop(auth_variable, None)
        version = sanitized_version(codex, environment)
        result["version"] = version

        port = reserve_port()
        process = subprocess.Popen(
            [
                codex,
                "app-server",
                "--listen",
                "ws://127.0.0.1:%d" % port,
                "--ws-auth",
                "capability-token",
                "--ws-token-file",
                token_path,
            ],
            cwd=workdir,
            env=environment,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            start_new_session=True,
        )
        wait_for_listener(process, port, 12)

        missing_status = websocket_status(port, None)
        result["missingStatus"] = missing_status
        wrong_status = websocket_status(port, secrets.token_hex(32))
        result["wrongStatus"] = wrong_status
        correct_status = websocket_status(port, token)
        result["correctStatus"] = correct_status
        if missing_status == 101 or wrong_status == 101 or correct_status != 101:
            raise ProbeAssertionError("capability-token enforcement failed")
        result["status"] = "passed"
    except Exception as error:
        error_type = type(error).__name__
        result["status"] = "failed"
    finally:
        process_stopped = stop_process_group(process)
        if port is not None:
            deadline = time.monotonic() + 3
            while is_listening(port) and time.monotonic() < deadline:
                time.sleep(0.05)
            listener_stopped = not is_listening(port)

        cleanup_boundary_safe = safe_probe_dir(
            workdir, temp_parent, workdir_identity
        )
        if cleanup_boundary_safe and process_stopped and token_path is not None:
            try:
                os.unlink(token_path)
            except FileNotFoundError:
                pass
            except OSError:
                token_removed = False
        if token_path is not None:
            token_removed = token_removed and not os.path.lexists(token_path)

        if cleanup_boundary_safe and process_stopped:
            try:
                shutil.rmtree(workdir)
            except OSError:
                temp_removed = False
        elif workdir is not None and os.path.lexists(workdir):
            temp_removed = False

        if workdir is not None:
            temp_removed = temp_removed and not os.path.lexists(workdir)
        if codex_home is not None:
            codex_home_removed = not os.path.lexists(codex_home)

    cleanup_ok = (
        process_stopped
        and listener_stopped
        and token_removed
        and codex_home_removed
        and temp_removed
    )
    result.update(
        {
            "processStopped": process_stopped,
            "listenerStopped": listener_stopped,
            "tokenRemoved": token_removed,
            "codexHomeRemoved": codex_home_removed,
            "tempRemoved": temp_removed,
        }
    )
    if not cleanup_ok:
        result["status"] = "failed"
        error_type = error_type or "CleanupError"
    if error_type is not None:
        result["errorType"] = error_type
    print(json.dumps(result, sort_keys=True, separators=(",", ":")))
    return 0 if result["status"] == "passed" and cleanup_ok else 1


if __name__ == "__main__":
    sys.exit(main())
'''


class RemoteProbeError(RuntimeError):
    """The remote probe did not produce a safe successful result."""


_VERSION_PATTERN = re.compile(r"[A-Za-z0-9][A-Za-z0-9._+() -]{0,119}")
_STATUS_KEYS = ("missingStatus", "wrongStatus", "correctStatus")
_CLEANUP_KEYS = (
    "processStopped",
    "listenerStopped",
    "tokenRemoved",
    "codexHomeRemoved",
    "tempRemoved",
)
_ALLOWED_KEYS = {
    "status",
    "version",
    "errorType",
    *_STATUS_KEYS,
    *_CLEANUP_KEYS,
}


def validate_remote_result(raw_output, remote_exit):
    """Validate remote JSON before allowing any of it onto local stdout."""
    if len(raw_output) > 4096:
        raise RemoteProbeError()
    try:
        decoded = raw_output.decode("utf-8")
        lines = decoded.splitlines()
        if len(lines) != 1:
            raise ValueError()
        result = json.loads(lines[0])
    except (UnicodeDecodeError, ValueError, json.JSONDecodeError) as error:
        raise RemoteProbeError() from error

    if not isinstance(result, dict) or set(result) - _ALLOWED_KEYS:
        raise RemoteProbeError()
    if result.get("status") not in {"passed", "failed"}:
        raise RemoteProbeError()
    if "version" in result:
        if not isinstance(result["version"], str):
            raise RemoteProbeError()
        if _VERSION_PATTERN.fullmatch(result["version"]) is None:
            raise RemoteProbeError()
    for key in _STATUS_KEYS:
        if key in result and (
            isinstance(result[key], bool)
            or not isinstance(result[key], int)
            or not 100 <= result[key] <= 599
        ):
            raise RemoteProbeError()
    if any(not isinstance(result.get(key), bool) for key in _CLEANUP_KEYS):
        raise RemoteProbeError()
    if "errorType" in result and (
        not isinstance(result["errorType"], str)
        or re.fullmatch(r"[A-Za-z][A-Za-z0-9_]{0,79}", result["errorType"])
        is None
    ):
        raise RemoteProbeError()

    if result["status"] == "passed" and (
        "version" not in result
        or "errorType" in result
        or any(key not in result for key in _STATUS_KEYS)
    ):
        raise RemoteProbeError()
    if result["status"] == "failed" and "errorType" not in result:
        raise RemoteProbeError()
    if not isinstance(remote_exit, int):
        raise RemoteProbeError()
    return result


def remote_result_passed(result, remote_exit):
    return (
        remote_exit == 0
        and result.get("status") == "passed"
        and result.get("missingStatus") != 101
        and result.get("wrongStatus") != 101
        and result.get("correctStatus") == 101
        and all(result[key] for key in _CLEANUP_KEYS)
    )


def build_parser():
    parser = argparse.ArgumentParser(
        description=(
            "Probe loopback Codex app-server WebSocket capability-token auth "
            "without logging in or starting a model request."
        )
    )
    parser.add_argument("--config", required=True)
    parser.add_argument(
        "--fingerprint",
        help="Expected SHA256 SSH host-key fingerprint for host pinning.",
    )
    return parser


def main():
    args = build_parser().parse_args()
    client = None
    try:
        from vps_validate import connect

        # vps_validate may print a proposed host key on mismatch; keep this
        # probe's stdout limited to its validated non-sensitive result schema.
        with contextlib.redirect_stdout(io.StringIO()):
            client = connect(args)
        stdin, stdout, stderr = client.exec_command("python3 -", timeout=120)
        stdin.write(REMOTE_PROBE)
        stdin.flush()
        stdin.channel.shutdown_write()
        raw_output = stdout.read()
        stderr.read()
        remote_exit = stdout.channel.recv_exit_status()
        result = validate_remote_result(raw_output, remote_exit)
        print(json.dumps(result, sort_keys=True, separators=(",", ":")))
        return 0 if remote_result_passed(result, remote_exit) else 1
    except Exception as error:
        print(json.dumps({"errorType": type(error).__name__}))
        return 1
    finally:
        if client is not None:
            client.close()


if __name__ == "__main__":
    sys.exit(main())
