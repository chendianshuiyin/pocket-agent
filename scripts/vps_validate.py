"""Private VPS validation helper. Never prints credentials or connection targets."""

import argparse
import base64
import hashlib
import json
from pathlib import Path
import shlex
import sys

import paramiko


def read_connection(path):
    lines = Path(path).read_text(encoding="utf-8-sig").splitlines()
    for index, line in enumerate(lines):
        if not line.strip().startswith("ssh "):
            continue
        words = shlex.split(line.strip())
        port = 22
        destination = None
        cursor = 1
        while cursor < len(words):
            word = words[cursor]
            if word == "-p":
                cursor += 1
                port = int(words[cursor])
            elif word.startswith("-"):
                raise ValueError("Unsupported SSH option in private configuration")
            else:
                destination = word
            cursor += 1
        if not destination or "@" not in destination:
            raise ValueError("SSH destination must include its username")
        username, hostname = destination.rsplit("@", 1)
        password = lines[index + 1].strip()
        if not password:
            raise ValueError("Missing password after SSH entry")
        return hostname, port, username, password
    raise ValueError("No SSH entry found")


class VerifyKey(paramiko.MissingHostKeyPolicy):
    def __init__(self, expected):
        self.expected = expected

    def missing_host_key(self, client, hostname, key):
        fingerprint = "SHA256:" + base64.b64encode(
            hashlib.sha256(key.asbytes()).digest()
        ).decode().rstrip("=")
        if self.expected != fingerprint:
            print(json.dumps({"hostKeyConfirmationRequired": fingerprint,
                              "algorithm": key.get_name()}))
            raise paramiko.SSHException("Host key confirmation required")


PREFLIGHT = r"""set -eu
printf 'os='; uname -s
printf 'arch='; uname -m
printf 'uid='; id -u
printf 'tmux='; command -v tmux || true
printf 'codex='; command -v codex || true
if command -v codex >/dev/null 2>&1; then codex --version; fi
printf 'auth_file_present='
if test -f "${CODEX_HOME:-$HOME/.codex}/auth.json"; then echo yes; else echo no; fi
printf 'custom_codex_home='
if test -n "${CODEX_HOME:-}"; then echo yes; else echo no; fi
printf 'runtime_available='; command -v node || true
printf 'distribution='; . /etc/os-release; printf '%s %s\n' "$ID" "$VERSION_ID"
printf 'sudo_available='; if sudo -n true 2>/dev/null; then echo yes; else echo no; fi
printf 'user_local_codex='; if test -x "$HOME/.local/bin/codex"; then echo yes; else echo no; fi
printf 'nvm_present='; if test -d "$HOME/.nvm"; then echo yes; else echo no; fi
printf 'root_codex_auth_present='; if sudo -n test -f /root/.codex/auth.json 2>/dev/null; then echo yes; else echo no; fi
"""

PREPARE = r"""set -eu
if ! command -v tmux >/dev/null 2>&1; then
  sudo -n apt-get update -qq >/dev/null 2>&1
  sudo -n env DEBIAN_FRONTEND=noninteractive apt-get install -y tmux curl ca-certificates >/dev/null 2>&1
fi
echo tmux_ready
target="$HOME/.local/share/pocket-agent/codex-0.153.4"
mkdir -p "$target" "$HOME/.local/bin"
archive=$(mktemp /tmp/pocket-agent-codex.XXXXXXXX.tar.gz)
trap 'rm -f -- "$archive"' EXIT
curl --fail --silent --show-error --location --max-time 240 --retry 2 \
  https://github.com/openai/codex/releases/download/rust-v0.153.4/codex-package-x86_64-unknown-linux-musl.tar.gz \
  --output "$archive"
printf 'a822187e1a2420c61c5926721bfbd878701ed95547c9bb0d4de4498a16ba1821  %s\n' "$archive" | sha256sum -c - >/dev/null
echo archive_checksum_verified
tar -xzf "$archive" -C "$target"
find "$target" -maxdepth 3 -type f -name 'codex*' -printf '%P\n'
"""

ACTIVATE = r"""set -eu
target="$HOME/.local/share/pocket-agent/codex-0.153.4/bin/codex"
test -x "$target"
if ! test -e "$HOME/.local/bin/codex"; then
  ln -s "$target" "$HOME/.local/bin/codex"
fi
"$HOME/.local/bin/codex" --version
"$HOME/.local/bin/codex" app-server --help
"""


def connect(args):
    host, port, user, password = read_connection(args.config)
    client = paramiko.SSHClient()
    known_hosts = Path.home() / ".ssh" / "known_hosts"
    if known_hosts.exists():
        client.load_host_keys(str(known_hosts))
    client.set_missing_host_key_policy(VerifyKey(args.fingerprint))
    client.connect(host, port=port, username=user, password=password,
                   timeout=15, auth_timeout=15, banner_timeout=15,
                   look_for_keys=False, allow_agent=False)
    return client


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--config", required=True)
    parser.add_argument("--fingerprint")
    parser.add_argument("--prepare", action="store_true")
    parser.add_argument("--activate-runtime", action="store_true")
    parser.add_argument("--schema", action="store_true")
    parser.add_argument("--health", action="store_true")
    args = parser.parse_args()
    client = None
    try:
        client = connect(args)
        if args.schema:
            command = 'mkdir -p "$HOME/.cache/pocket-agent-validation/schema-0.153.4"; "$HOME/.local/bin/codex" app-server generate-json-schema --out "$HOME/.cache/pocket-agent-validation/schema-0.153.4"'
            _, stdout, _ = client.exec_command("bash -lc " + shlex.quote(command), timeout=60)
            stdout.read()
            if stdout.channel.recv_exit_status() != 0:
                raise RuntimeError("Schema generation failed")
            sftp = client.open_sftp()
            remote = sftp.normalize(".") + "/.cache/pocket-agent-validation/schema-0.153.4"
            output = Path("artifacts/protocol-0.153.4")
            output.mkdir(parents=True, exist_ok=True)
            for name in sftp.listdir(remote):
                if name.endswith(".json") and "/" not in name and "\\" not in name:
                    sftp.get(remote + "/" + name, str(output / name))
            sftp.close()
            print(json.dumps({"schemaFiles": len(list(output.glob("*.json")))}))
            return 0
        command = PREPARE if args.prepare else ACTIVATE if args.activate_runtime else PREFLIGHT
        if args.health:
            command = 'tmux has-session -t =pocket-agent-runtime-codex-4500; printf "ready_status="; curl --max-time 3 -s -o /dev/null -w "%{http_code}\\n" http://127.0.0.1:4500/readyz; true'
        _, stdout, stderr = client.exec_command("bash -lc " + shlex.quote(command), timeout=360)
        output = stdout.read().decode(errors="replace")
        # The predefined probe contains no sensitive reads. Do not print stderr.
        print(output, end="")
        status = stdout.channel.recv_exit_status()
        print(json.dumps({"preflightExit": status}))
        return status
    except Exception as error:
        # Exception strings may contain IPs or user-controlled remote text.
        print(json.dumps({"errorType": type(error).__name__}))
        return 1
    finally:
        if client:
            client.close()


if __name__ == "__main__":
    sys.exit(main())
