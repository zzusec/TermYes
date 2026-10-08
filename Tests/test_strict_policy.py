#!/usr/bin/env python3
"""Strict policy migration tests use temporary homes and fake CLIs only."""
import base64
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "AgentGuard"))
import manage
import permission_modes as modes


class StrictPolicyTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="termyes-strict-")
        self.addCleanup(temporary.cleanup)
        self.home = Path(temporary.name).resolve()
        self.bin = self.home / ".local/bin"
        self.bin.mkdir(parents=True)
        environment = mock.patch.dict(os.environ, {"HOME": str(self.home), "PATH": str(self.bin)})
        environment.start()
        self.addCleanup(environment.stop)

    def install(self, client):
        command = self.bin / modes.COMMANDS[client][0]
        command.write_text("#!/bin/sh\nexit 0\n")
        command.chmod(0o755)
        manage.install(self.home, client)
        return manage.locations(self.home, client)

    def test_legacy_canary_is_retired_while_other_hooks_and_provider_changes_survive(self):
        for client in ("codebuddy", "qoder", "codex"):
            root, config, runtime, _ = self.install(client)
            current = json.loads(config.read_bytes())
            current["model"] = "user-selected-model"
            current["hooks"]["PreToolUse"].append({"matcher": "Bash", "hooks": [
                {"command": str(root / "hooks/danger-guard-canary.sh")},
                {"command": "echo unrelated", "type": "command"},
            ]})
            config.write_bytes(manage.json_bytes(current))
            manage.install(self.home, client)
            installed = json.loads(config.read_bytes())
            self.assertEqual(installed["model"], "user-selected-model")
            commands = [h["command"] for g in installed["hooks"]["PreToolUse"] for h in g["hooks"]]
            self.assertIn("echo unrelated", commands)
            self.assertFalse(any("danger-guard-canary.sh" in c for c in commands))
            first = manage.receipt_path(self.home, client).read_bytes()
            manage.install(self.home, client)
            self.assertEqual(first, manage.receipt_path(self.home, client).read_bytes())
            manage.uninstall(self.home, client)
            restored = json.loads(config.read_bytes())
            self.assertEqual(restored["model"], "user-selected-model")
            self.assertIn("echo unrelated", json.dumps(restored))
            self.assertNotIn("danger-guard-canary.sh", json.dumps(restored))

    def test_legacy_manifest_gains_bundled_json_and_can_restore(self):
        _, _, runtime, _ = self.install("codebuddy")
        policy = runtime / "danger-policy.json"
        receipt = manage.receipt_path(self.home, "codebuddy")
        old = json.loads(receipt.read_bytes())
        old["before"].pop(str(policy))
        old["installed"].pop(str(policy))
        policy.unlink()
        receipt.write_bytes(manage.json_bytes(old))
        manage.install(self.home, "codebuddy")
        self.assertEqual(policy.read_bytes(), (manage.SOURCE / "danger-policy.json").read_bytes())
        record = json.loads(receipt.read_bytes())
        self.assertIsNone(record["before"][str(policy)])
        manage.uninstall(self.home, "codebuddy")
        self.assertFalse(policy.exists())

    def test_native_shell_denies_retire_without_touching_file_permissions(self):
        for client in ("claude", "codebuddy", "zcode"):
            _, config, _, _ = self.install(client)
            current = json.loads(config.read_bytes())
            owner = current.setdefault("permission" if client == "zcode" else "permissions", {})
            key = "disallowedTools" if client == "zcode" else "deny"
            owner[key] = ["Bash(rm -rf *)", "Edit(~/.ssh/**)"]
            config.write_bytes(manage.json_bytes(current))
            manage.install(self.home, client)
            installed = json.loads(config.read_bytes())
            self.assertEqual(installed["permission" if client == "zcode" else "permissions"][key], ["Edit(~/.ssh/**)"])
            manage.uninstall(self.home, client)
            restored = json.loads(config.read_bytes())
            self.assertNotIn("Bash(rm -rf *)", json.dumps(restored))
            self.assertIn("Edit(~/.ssh/**)", json.dumps(restored))

    def test_managed_hook_changes_are_still_rejected(self):
        _, config, _, _ = self.install("codebuddy")
        current = json.loads(config.read_bytes())
        current["model"] = "different-provider"
        current["hooks"]["PreToolUse"][0]["matcher"] = "Read"
        config.write_bytes(manage.json_bytes(current))
        before = config.read_bytes()
        with self.assertRaises(ValueError):
            manage.install(self.home, "codebuddy")
        self.assertEqual(config.read_bytes(), before)

    def test_direct_legacy_uninstall_does_not_restore_old_shell_rules(self):
        root, config, _, _ = self.install("codebuddy")
        receipt = manage.receipt_path(self.home, "codebuddy")
        record = json.loads(receipt.read_bytes())
        baseline = {"permissions": {"defaultMode": "bypassPermissions",
                                     "deny": ["Bash(sudo *)", "Edit(~/.ssh/**)"]},
                    "hooks": {"PreToolUse": [{"hooks": [
                        {"command": str(root / "hooks/danger-guard-canary.sh")},
                        {"command": "echo user-hook"},
                    ]}]}}
        record["before"][str(config)] = {
            "data": base64.b64encode(manage.json_bytes(baseline)).decode(), "mode": 0o600}
        receipt.write_bytes(manage.json_bytes(record))
        manage.uninstall(self.home, "codebuddy")
        restored = config.read_text()
        self.assertNotIn("Bash(sudo *)", restored)
        self.assertNotIn("danger-guard-canary.sh", restored)
        self.assertIn("Edit(~/.ssh/**)", restored)
        self.assertIn("echo user-hook", restored)

    def test_codebuddy_probes_get_full_bypass_with_both_probe_environments(self):
        command = self.bin / "codebuddy"
        command.write_text(
            '#!/usr/bin/python3\nimport json,os,sys\n'
            'print(json.dumps({"env":os.getenv("CODEBUDDY_IS_SANDBOX"), "args":sys.argv[1:]}))\n')
        command.chmod(0o755)
        for extra_env in (None, {"TERMYES_GUARD_PROBE_TOKEN": "test"}):
            code, output, timed_out = manage.run_probe(
                command, manage.probe_arguments("codebuddy", "test prompt"), self.home, extra_env)
            self.assertEqual(code, 0)
            self.assertFalse(timed_out)
            report = json.loads(output)
            self.assertEqual(report["env"], "1")
            self.assertIn("--dangerously-skip-permissions", report["args"])


if __name__ == "__main__":
    unittest.main()
