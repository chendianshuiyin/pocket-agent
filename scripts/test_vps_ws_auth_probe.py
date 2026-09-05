"""Pure-local tests for the VPS WebSocket auth probe."""

import contextlib
import io
import json
import unittest

import vps_ws_auth_probe


class VpsWsAuthProbeTest(unittest.TestCase):
    def test_remote_probe_is_valid_python(self):
        compile(vps_ws_auth_probe.REMOTE_PROBE, "<remote-probe>", "exec")
        for variable in (
            "OPENAI_API_KEY",
            "CODEX_API_KEY",
            "CODEX_ACCESS_TOKEN",
            "OPENAI_ACCESS_TOKEN",
            "CHATGPT_ACCESS_TOKEN",
        ):
            self.assertIn('environment.pop(auth_variable, None)', vps_ws_auth_probe.REMOTE_PROBE)
            self.assertIn('"' + variable + '"', vps_ws_auth_probe.REMOTE_PROBE)

    def test_valid_result_is_accepted(self):
        result = {
            "status": "passed",
            "version": "codex-cli 0.153.0",
            "missingStatus": 401,
            "wrongStatus": 401,
            "correctStatus": 101,
            "processStopped": True,
            "listenerStopped": True,
            "tokenRemoved": True,
            "codexHomeRemoved": True,
            "tempRemoved": True,
        }
        raw = json.dumps(result, separators=(",", ":")).encode()
        self.assertEqual(vps_ws_auth_probe.validate_remote_result(raw, 0), result)
        self.assertTrue(vps_ws_auth_probe.remote_result_passed(result, 0))

    def test_unexpected_output_is_rejected(self):
        result = {
            "status": "passed",
            "version": "codex-cli 0.153.0",
            "missingStatus": 401,
            "wrongStatus": 401,
            "correctStatus": 101,
            "processStopped": True,
            "listenerStopped": True,
            "tokenRemoved": True,
            "codexHomeRemoved": True,
            "tempRemoved": True,
            "secret": "must-not-pass",
        }
        with self.assertRaises(vps_ws_auth_probe.RemoteProbeError):
            vps_ws_auth_probe.validate_remote_result(json.dumps(result).encode(), 0)

    def test_failed_auth_or_cleanup_is_rejected(self):
        result = {
            "status": "passed",
            "version": "codex-cli 0.153.0",
            "missingStatus": 101,
            "wrongStatus": 401,
            "correctStatus": 101,
            "processStopped": True,
            "listenerStopped": True,
            "tokenRemoved": True,
            "codexHomeRemoved": True,
            "tempRemoved": True,
        }
        validated = vps_ws_auth_probe.validate_remote_result(
            json.dumps(result).encode(), 1
        )
        self.assertFalse(vps_ws_auth_probe.remote_result_passed(validated, 1))
        result["missingStatus"] = 401
        result["tempRemoved"] = False
        validated = vps_ws_auth_probe.validate_remote_result(
            json.dumps(result).encode(), 1
        )
        self.assertFalse(vps_ws_auth_probe.remote_result_passed(validated, 1))

    def test_config_is_explicit_and_fingerprint_is_optional(self):
        with contextlib.redirect_stderr(io.StringIO()):
            with self.assertRaises(SystemExit):
                vps_ws_auth_probe.build_parser().parse_args([])
        args = vps_ws_auth_probe.build_parser().parse_args(["--config", "private"])
        self.assertEqual(args.config, "private")
        self.assertIsNone(args.fingerprint)


if __name__ == "__main__":
    unittest.main()
