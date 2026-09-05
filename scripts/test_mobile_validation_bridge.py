import io
import json
from pathlib import Path
import shlex
import sys
import tempfile
from types import ModuleType, SimpleNamespace
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parent))
if "vps_validate" not in sys.modules:
    vps_validate = ModuleType("vps_validate")
    vps_validate.connect = None
    vps_validate.read_connection = None
    sys.modules["vps_validate"] = vps_validate

import mobile_validation_bridge as bridge


class MemoryFile:
    def __init__(self, sftp, path):
        self.sftp = sftp
        self.path = path
        self.buffer = io.StringIO()

    def __enter__(self):
        return self

    def __exit__(self, *_):
        self.sftp.files[self.path] = self.buffer.getvalue()

    def write(self, value):
        if self.path == self.sftp.partial_write_failure:
            self.buffer.write(value[:12])
            raise RuntimeError("synthetic partial write failure")
        return self.buffer.write(value)


class FakeSftp:
    def __init__(
        self,
        *,
        chmod_failure=None,
        partial_write_failure=None,
        remote_home="/home/validation",
    ):
        self.files = {}
        self.permissions = {}
        self.chmod_failure = chmod_failure
        self.partial_write_failure = partial_write_failure
        self.remote_home = remote_home
        self.closed = False

    def open(self, path, mode):
        if mode != "w":
            raise AssertionError("Tests only support writes")
        return MemoryFile(self, path)

    def chmod(self, path, mode):
        if path == self.chmod_failure:
            raise RuntimeError("synthetic chmod failure")
        self.permissions[path] = mode

    def remove(self, path):
        if path not in self.files:
            raise FileNotFoundError(path)
        del self.files[path]

    def stat(self, path):
        if path not in self.files:
            raise FileNotFoundError(path)
        return object()

    def normalize(self, path):
        if path != ".":
            raise AssertionError("Unexpected normalize target")
        return self.remote_home

    def close(self):
        self.closed = True


class FakeKey:
    def get_name(self):
        return "ssh-ed25519"

    def asbytes(self):
        return b"fake-public-key"


class FakeTransport:
    def get_remote_server_key(self):
        return FakeKey()


class FakeClient:
    def __init__(self, sftp):
        self.sftp = sftp
        self.closed = False

    def open_sftp(self):
        return self.sftp

    def get_transport(self):
        return FakeTransport()

    def close(self):
        self.closed = True


class WithoutCodexAuthTest(unittest.TestCase):
    def setUp(self):
        self.args = SimpleNamespace(without_codex_auth=True)
        self.remote_home = "/home/validation"
        self.codex_home = self.remote_home + bridge.VALIDATION_LEAF + "/codex-home"

    def test_configuration_never_reads_local_auth_and_removes_stale_auth(self):
        sftp = FakeSftp()
        remote_auth = self.codex_home + "/auth.json"
        config_path = self.codex_home + "/config.toml"
        sftp.files[remote_auth] = "stale-secret"

        with patch.object(
            bridge.Path,
            "read_text",
            side_effect=AssertionError("Local auth must not be read"),
        ):
            uploaded = bridge.configure_codex_auth(
                self.args, sftp, self.codex_home
            )

        self.assertIsNone(uploaded)
        self.assertNotIn(remote_auth, sftp.files)
        self.assertEqual(
            sftp.files[config_path],
            'cli_auth_credentials_store = "file"\n',
        )
        self.assertEqual(sftp.permissions[config_path], 0o600)

    def test_runtime_unsets_supported_environment_credentials(self):
        command = bridge.runtime_argv(
            self.args, self.remote_home, self.codex_home
        )

        self.assertEqual(command[:5], [
            "env",
            "-u",
            "OPENAI_API_KEY",
            "-u",
            "CODEX_API_KEY",
        ])
        for variable in (
            "OPENAI_API_KEY",
            "CODEX_API_KEY",
            "CODEX_ACCESS_TOKEN",
            "OPENAI_ACCESS_TOKEN",
            "CHATGPT_ACCESS_TOKEN",
        ):
            self.assertIn(variable, command)
        self.assertEqual(
            command[-6:],
            [
                "--listen",
                "ws://127.0.0.1:4500",
                "--ws-auth",
                "capability-token",
                "--ws-token-file",
                self.remote_home + bridge.TRANSPORT_TOKEN_LEAF,
            ],
        )

    def test_transport_token_paths_do_not_overlap_isolated_account_auth(self):
        validation_root = self.remote_home + bridge.VALIDATION_LEAF
        token_file, owner_file = bridge.transport_paths(
            self.remote_home, validation_root
        )

        self.assertEqual(
            token_file,
            "/home/validation/.pocket-agent/app-server-4500.token",
        )
        self.assertEqual(
            owner_file,
            validation_root + "/transport-token-4500.sha256",
        )
        self.assertFalse(token_file.startswith(self.codex_home))

    def test_validation_directories_are_checked_before_chmod(self):
        commands = []
        with patch.object(
            bridge,
            "checked",
            side_effect=lambda _client, command: commands.append(command) or "",
        ):
            paths = bridge.ensure_validation_directories(
                object(), self.remote_home
            )

        self.assertEqual(
            paths,
            (
                self.remote_home + bridge.VALIDATION_LEAF,
                self.codex_home,
                self.remote_home + bridge.VALIDATION_LEAF + "/workspace",
            ),
        )
        self.assertNotIn("mkdir -p", commands[0])
        self.assertLess(commands[0].find("test -L"), commands[0].find("chmod 700"))

    def test_transport_token_is_generated_remotely_and_validated(self):
        validation_root = self.remote_home + bridge.VALIDATION_LEAF
        commands = []

        with patch.object(
            bridge,
            "checked",
            side_effect=lambda _client, command: commands.append(command)
            or "a" * 64,
        ):
            token = bridge.create_fixture_transport_token(
                object(), self.remote_home, validation_root
            )

        self.assertEqual(token, "a" * 64)
        self.assertEqual(len(commands), 1)
        self.assertNotIn("a" * 64, commands[0])
        self.assertIn("sha256sum", commands[0])
        self.assertLess(
            commands[0].find("trap cleanup_partial"),
            commands[0].find('mktemp "$token_file.fixture.XXXXXX"'),
        )
        self.assertLess(
            commands[0].find("token_created=1"),
            commands[0].find('ln -- "$token_temp" "$token_file"'),
        )

    def test_transport_cleanup_checks_owner_hash_before_removal(self):
        validation_root = self.remote_home + bridge.VALIDATION_LEAF
        commands = []

        with patch.object(
            bridge,
            "checked",
            side_effect=lambda _client, command: commands.append(command)
            or "removed",
        ):
            bridge.cleanup_fixture_transport_token(
                object(), self.remote_home, validation_root
            )

        self.assertEqual(len(commands), 1)
        self.assertIn("actual_hash", commands[0])
        self.assertIn("owner_hash", commands[0])
        self.assertNotIn("rm -rf", commands[0])

    def test_transport_cleanup_recovers_owner_only_but_rejects_token_only(self):
        validation_root = self.remote_home + bridge.VALIDATION_LEAF
        with patch.object(bridge, "checked", return_value="owner-removed"):
            self.assertEqual(
                bridge.cleanup_fixture_transport_token(
                    object(), self.remote_home, validation_root
                ),
                "owner-removed",
            )
        with patch.object(bridge, "checked", return_value="token-without-owner"):
            with self.assertRaisesRegex(
                bridge.FixtureCleanupIncomplete,
                "was not removed and requires manual inspection",
            ):
                bridge.cleanup_fixture_transport_token(
                    object(), self.remote_home, validation_root
                )

    def test_runtime_ownership_rejects_empty_pane_list(self):
        with patch.object(bridge, "checked", return_value=""):
            with self.assertRaisesRegex(RuntimeError, "exactly one validated pane"):
                bridge.require_owned_runtime(
                    self.args,
                    object(),
                    self.remote_home,
                    self.codex_home,
                )

    def test_runtime_ownership_rejects_multiple_panes(self):
        commands = []

        def fake_checked(_client, command):
            commands.append(command)
            return "%0\n%1"

        with patch.object(bridge, "checked", side_effect=fake_checked):
            with self.assertRaisesRegex(RuntimeError, "exactly one validated pane"):
                bridge.require_owned_runtime(
                    self.args,
                    object(),
                    self.remote_home,
                    self.codex_home,
                )

        self.assertEqual(len(commands), 1)

    def test_runtime_ownership_accepts_single_layer_command(self):
        expected = bridge.runtime_argv(
            self.args,
            self.remote_home,
            self.codex_home,
        )
        responses = iter(["%7", shlex.join(expected)])

        with patch.object(
            bridge,
            "checked",
            side_effect=lambda *_: next(responses),
        ):
            bridge.require_owned_runtime(
                self.args,
                object(),
                self.remote_home,
                self.codex_home,
            )

    def test_runtime_ownership_accepts_double_quoted_command(self):
        expected = bridge.runtime_argv(
            self.args,
            self.remote_home,
            self.codex_home,
        )
        responses = iter(["%12", shlex.quote(shlex.join(expected))])

        with patch.object(
            bridge,
            "checked",
            side_effect=lambda *_: next(responses),
        ):
            bridge.require_owned_runtime(
                self.args,
                object(),
                self.remote_home,
                self.codex_home,
            )

    def test_runtime_ownership_rejects_wrong_codex_home(self):
        wrong = bridge.runtime_argv(
            self.args,
            self.remote_home,
            self.codex_home + "-other",
        )
        responses = iter(["%2", shlex.join(wrong)])

        with patch.object(
            bridge,
            "checked",
            side_effect=lambda *_: next(responses),
        ):
            with self.assertRaisesRegex(RuntimeError, "not owned"):
                bridge.require_owned_runtime(
                    self.args,
                    object(),
                    self.remote_home,
                    self.codex_home,
                )

    def test_runtime_ownership_rejects_wrong_mode(self):
        authorized_args = SimpleNamespace(without_codex_auth=False)
        wrong_mode = bridge.runtime_argv(
            authorized_args,
            self.remote_home,
            self.codex_home,
        )
        responses = iter(["%5", shlex.quote(shlex.join(wrong_mode))])

        with patch.object(
            bridge,
            "checked",
            side_effect=lambda *_: next(responses),
        ):
            with self.assertRaisesRegex(RuntimeError, "not owned"):
                bridge.require_owned_runtime(
                    self.args,
                    object(),
                    self.remote_home,
                    self.codex_home,
                )

    def test_cleanup_excludes_standard_remote_auth_homes(self):
        sftp = FakeSftp()
        isolated_auth = self.codex_home + "/auth.json"
        sftp.files[isolated_auth] = "stale-secret"
        with patch.object(
            bridge,
            "checked",
            side_effect=AssertionError("Standard auth must not be changed"),
        ):
            bridge.cleanup_codex_auth(
                self.args,
                object(),
                sftp,
                self.remote_home,
                self.codex_home,
            )

        self.assertNotIn(isolated_auth, sftp.files)
        self.assertEqual(
            bridge.standard_auth_cleanup_homes(
                self.args, self.remote_home, self.codex_home
            ),
            [],
        )

    def test_default_mode_keeps_authorized_auth_behavior(self):
        args = SimpleNamespace(without_codex_auth=False)
        command = bridge.runtime_argv(args, self.remote_home, self.codex_home)

        self.assertNotIn("-u", command)
        self.assertEqual(
            bridge.standard_auth_cleanup_homes(
                args, self.remote_home, self.codex_home
            ),
            [self.codex_home, self.remote_home + "/.codex"],
        )

    def test_uploaded_auth_is_removed_when_chmod_fails(self):
        args = SimpleNamespace(without_codex_auth=False)
        remote_auth = self.codex_home + "/auth.json"
        sftp = FakeSftp(chmod_failure=remote_auth)
        local_auth = json.dumps({"auth_mode": "chatgpt", "tokens": {"test": True}})

        with patch.object(bridge.Path, "read_text", return_value=local_auth):
            with self.assertRaisesRegex(RuntimeError, "synthetic chmod failure"):
                bridge.configure_codex_auth(args, sftp, self.codex_home)

        self.assertNotIn(remote_auth, sftp.files)

    def test_partially_written_auth_is_removed_when_write_fails(self):
        args = SimpleNamespace(without_codex_auth=False)
        remote_auth = self.codex_home + "/auth.json"
        sftp = FakeSftp(partial_write_failure=remote_auth)
        local_auth = json.dumps({"auth_mode": "chatgpt", "tokens": {"test": True}})

        with patch.object(bridge.Path, "read_text", return_value=local_auth):
            with self.assertRaisesRegex(RuntimeError, "partial write failure"):
                bridge.configure_codex_auth(args, sftp, self.codex_home)

        self.assertNotIn(remote_auth, sftp.files)

    def test_setup_failure_after_runtime_start_cleans_owned_artifacts(self):
        args = SimpleNamespace(
            without_codex_auth=False,
            config="unused-test-config",
        )
        sftp = FakeSftp(remote_home=self.remote_home)
        client = FakeClient(sftp)
        remote_auth = self.codex_home + "/auth.json"
        commands = []

        def fake_checked(_client, command):
            commands.append(command)
            if "actual_hash" in command:
                return "removed"
            return ""

        local_auth = json.dumps({"auth_mode": "chatgpt", "tokens": {"test": True}})
        with patch.object(bridge, "connect", return_value=client), patch.object(
            bridge, "checked", side_effect=fake_checked
        ), patch.object(
            bridge,
            "create_fixture_transport_token",
            return_value="a" * 64,
        ), patch.object(
            bridge,
            "read_connection",
            side_effect=RuntimeError("synthetic fixture failure"),
        ), patch.object(bridge.Path, "read_text", return_value=local_auth):
            with self.assertRaisesRegex(RuntimeError, "synthetic fixture failure"):
                bridge.setup(args)

        runtime_command = shlex.join(
            bridge.runtime_argv(args, self.remote_home, self.codex_home)
        )
        self.assertIn(
            "tmux new-session -d -s " + bridge.RUNTIME_SESSION
            + " " + shlex.quote(runtime_command),
            commands,
        )
        self.assertIn(
            "if tmux has-session -t =" + bridge.RUNTIME_SESSION
            + " 2>/dev/null; then tmux kill-session -t ="
            + bridge.RUNTIME_SESSION + "; fi",
            commands,
        )
        self.assertNotIn(remote_auth, sftp.files)
        self.assertTrue(sftp.closed)
        self.assertTrue(client.closed)

    def test_setup_does_not_kill_a_preexisting_runtime(self):
        args = SimpleNamespace(
            without_codex_auth=True,
            config="unused-test-config",
        )
        sftp = FakeSftp(remote_home=self.remote_home)
        client = FakeClient(sftp)
        commands = []

        def fake_checked(_client, command):
            commands.append(command)
            if command.startswith("! tmux has-session"):
                raise RuntimeError("synthetic existing runtime")
            return ""

        with patch.object(bridge, "connect", return_value=client), patch.object(
            bridge,
            "checked",
            side_effect=fake_checked,
        ):
            with self.assertRaisesRegex(RuntimeError, "synthetic existing runtime"):
                bridge.setup(args)

        self.assertFalse(any("tmux kill-session" in item for item in commands))
        self.assertFalse(any("tmux new-session" in item for item in commands))
        self.assertTrue(sftp.closed)
        self.assertTrue(client.closed)

    def test_uncertain_transport_creation_requires_cleanup_only(self):
        args = SimpleNamespace(
            without_codex_auth=True,
            config="unused-test-config",
        )
        sftp = FakeSftp(remote_home=self.remote_home)
        client = FakeClient(sftp)

        with patch.object(bridge, "connect", return_value=client), patch.object(
            bridge, "checked", return_value=""
        ), patch.object(
            bridge,
            "create_fixture_transport_token",
            side_effect=RuntimeError("uncertain remote result"),
        ), patch.object(
            bridge,
            "cleanup_fixture_transport_token",
            return_value=None,
        ):
            with self.assertRaises(bridge.FixtureCleanupIncomplete) as caught:
                bridge.setup(args)

        self.assertEqual(
            str(caught.exception),
            "Isolated fixture cleanup is incomplete; run --cleanup-only",
        )

    def test_setup_cleanup_failure_reports_redacted_recovery(self):
        args = SimpleNamespace(
            without_codex_auth=False,
            config="unused-test-config",
        )
        sftp = FakeSftp(remote_home=self.remote_home)
        client = FakeClient(sftp)

        def fake_checked(_client, command):
            if command.startswith("if tmux has-session"):
                raise RuntimeError("sensitive synthetic remote detail")
            return ""

        local_auth = json.dumps({"auth_mode": "chatgpt", "tokens": {"test": True}})
        with patch.object(bridge, "connect", return_value=client), patch.object(
            bridge,
            "checked",
            side_effect=fake_checked,
        ), patch.object(
            bridge,
            "create_fixture_transport_token",
            return_value="a" * 64,
        ), patch.object(
            bridge,
            "read_connection",
            side_effect=RuntimeError("synthetic fixture failure"),
        ), patch.object(bridge.Path, "read_text", return_value=local_auth):
            with self.assertRaises(bridge.FixtureCleanupIncomplete) as caught:
                bridge.setup(args)

        self.assertEqual(
            str(caught.exception),
            "Isolated fixture cleanup is incomplete; run --cleanup-only",
        )
        self.assertNotIn("sensitive", str(caught.exception))
        self.assertNotIn(self.codex_home + "/auth.json", sftp.files)

    def test_cleanup_failure_still_removes_local_defines(self):
        args = SimpleNamespace(without_codex_auth=True)
        with tempfile.TemporaryDirectory() as directory:
            defines = Path(directory) / "validation-defines.json"
            defines.write_text("test-only", encoding="utf-8")

            with patch.object(
                bridge,
                "cleanup",
                side_effect=RuntimeError("synthetic cleanup failure"),
            ):
                with self.assertRaisesRegex(
                    bridge.FixtureCleanupIncomplete,
                    "run --cleanup-only",
                ):
                    bridge.finalize_fixture(args, "/isolated/codex-home", defines)

            self.assertFalse(defines.exists())


if __name__ == "__main__":
    unittest.main()
