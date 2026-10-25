#!/usr/bin/env python3
"""Per-agent review pause checks; only temporary homes and inert fake CLIs."""
import contextlib
import datetime
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "AgentGuard"
sys.path.insert(0, str(SOURCE))
import core
import manage
import permission_modes

DEFAULT_PAYLOAD = object()


def payload(client, command="git reset --hard HEAD"):
    if client == "agy":
        return {"toolCall": {"name": "run_command", "args": {"CommandLine": command, "Cwd": str(ROOT)}}}
    if client in ("pi", "opencode", "cursor"):
        return {"command": command, "cwd": str(ROOT)}
    name = "bash" if client == "crush" else "run_shell_command" if client == "gemini" else "Execute" if client == "droid" else "Bash"
    return {"tool_name": name, "tool_input": {"command": command}, "cwd": str(ROOT)}


def denied(output):
    output = output or {}
    specific = output.get("hookSpecificOutput", {})
    return (output.get("decision") == "deny" or output.get("permission") == "deny"
            or output.get("permissionDecision") == "deny" or output.get("level") == "block"
            or specific.get("permissionDecision") == "deny"
            or specific.get("decision", {}).get("behavior") == "deny")


class GuardPauseTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="termyes-pause-test-")
        self.addCleanup(self.temp.cleanup)
        self.home = Path(self.temp.name).resolve() / "home with spaces"
        self.tools = self.home / ".opencode/bin"
        self.tools.mkdir(parents=True)
        for names in permission_modes.COMMANDS.values():
            for name in names:
                cli = self.tools / name
                cli.write_text("#!/bin/sh\nprintf 'fake model reply\\n'\n")
                cli.chmod(0o755)
        self.env = {**os.environ, "HOME": str(self.home), "PATH": str(self.tools) + ":/usr/bin:/bin",
                    "PYTHONDONTWRITEBYTECODE": "1", "DANGER_GUARD_SILENT": "1", "DANGER_GUARD_ASK": "0"}
        patch = mock.patch.dict(os.environ, self.env)
        patch.start()
        self.addCleanup(patch.stop)

    def state(self, client="claude"):
        return manage.status(self.home, [client])[0]

    def hook(self, client, data=DEFAULT_PAYLOAD, event=None):
        _, _, runtime, adapter = manage.locations(self.home, client)
        result = subprocess.run([sys.executable, "-B", str(runtime / adapter)] + ([event] if event else []),
                                input=json.dumps(payload(client) if data is DEFAULT_PAYLOAD else data), text=True,
                                capture_output=True, env=self.env, timeout=5)
        self.assertEqual(result.returncode, 0, result.stderr)
        return json.loads(result.stdout) if result.stdout.strip() else None

    def cli(self, action, client="claude", *arguments):
        return subprocess.run([sys.executable, "-B", str(SOURCE / "manage.py"), action, client,
                               "--home", str(self.home), *arguments], env=self.env,
                              capture_output=True, text=True, timeout=10)

    def expire(self, client):
        past = datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(seconds=1)
        manage.atomic_write(core.guard_pause_path(self.home, client), manage.json_bytes({
            "client": client, "expiresAt": past.strftime("%Y-%m-%dT%H:%M:%SZ"),
        }))

    def test_all_installed_adapters_pause_and_expire_without_app_or_monitor(self):
        for client in manage.CLIENTS:
            with self.subTest(client=client):
                manage.install(self.home, client)
                self.assertTrue(denied(self.hook(client)))
                files = {path: manage.read_file(path) for path in manage.desired_files(self.home, client)}
                receipt = manage.receipt_path(self.home, client).read_bytes()
                manage.pause_client(self.home, client, 15)
                state = self.state(client)
                self.assertTrue(state["guardConfigured"])
                self.assertFalse(state["guardReady"])
                self.assertTrue(state["guardPaused"])
                self.assertIsNone(state["guardPauseError"])
                self.assertRegex(state["guardPausedUntil"], r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$")
                self.assertEqual(core.guard_pause_path(self.home, client).stat().st_mode & 0o777, 0o600)
                self.assertEqual(state["liveStatus"], "paused")
                for command in ("git reset --hard HEAD", "rm -rf /", "npm publish"):
                    self.assertFalse(denied(self.hook(client, payload(client, command))))
                for invalid in ([], None, {}, payload(client, ""), payload(client, 'echo "unterminated')):
                    self.assertTrue(denied(self.hook(client, invalid)))
                self.assertEqual(files, {path: manage.read_file(path) for path in files})
                self.assertEqual(receipt, manage.receipt_path(self.home, client).read_bytes())
                self.assertTrue(permission_modes.inspect(self.home, client)["permissionReady"])
                self.expire(client)
                self.assertTrue(denied(self.hook(client)))
                self.assertFalse(self.state(client)["guardPaused"])
                self.assertIsNone(self.state(client)["guardPausedUntil"])
                self.assertIsNone(self.state(client)["guardPauseError"])
                self.assertTrue(self.state(client)["guardReady"])

    def test_runtime_identity_is_per_client_not_home_or_hook_payload(self):
        for client in ("claude", "codebuddy", "droid", "pi", "opencode"):
            manage.install(self.home, client)
        manage.pause_client(self.home, "codebuddy")
        for client in ("claude", "codebuddy", "droid", "pi", "opencode"):
            data = {**payload(client), "client": "codebuddy", "guardPaused": True}
            self.assertEqual(denied(self.hook(client, data)), client != "codebuddy")
        self.assertEqual(core.classify("rm -rf /", str(ROOT))[0], "block")

    def test_resume_early_and_codex_permission_event(self):
        manage.install(self.home, "codex")
        manage.pause_client(self.home, "codex", 60)
        output = self.hook("codex", event="PermissionRequest")
        self.assertEqual(output["hookSpecificOutput"]["decision"]["behavior"], "allow")
        manage.resume_client(self.home, "codex")
        self.assertTrue(denied(self.hook("codex", event="PermissionRequest")))
        self.assertFalse(core.guard_pause_path(self.home, "codex").exists())
        manage.resume_client(self.home, "codex")

    def test_cli_default_sixty_minutes_and_explicit_fifteen(self):
        manage.install(self.home, "claude")
        for arguments, minutes in (((), 60), (("--minutes", "15"), 15)):
            start = datetime.datetime.now(datetime.timezone.utc)
            result = self.cli("pause-client", "claude", *arguments)
            self.assertEqual(result.returncode, 0, result.stderr)
            state = next(item for item in json.loads(result.stdout) if item["id"] == "claude")
            self.assertTrue(state["guardPaused"])
            expires = datetime.datetime.fromisoformat(state["guardPausedUntil"].replace("Z", "+00:00"))
            self.assertAlmostEqual((expires - start).total_seconds(), minutes * 60, delta=3)
            self.assertEqual(core.guard_paused_until(self.home, "claude", now=expires - datetime.timedelta(seconds=1)),
                             state["guardPausedUntil"])
            self.assertIsNone(core.guard_paused_until(self.home, "claude", now=expires))
        for minutes in ("0", "-1", "1440"):
            self.assertNotEqual(self.cli("pause-client", "claude", "--minutes", minutes).returncode, 0)
        self.assertEqual(self.cli("resume-client").returncode, 0)
        self.assertFalse(self.state()["guardPaused"])

    def test_ensure_monitor_and_repair_keep_pause_but_validate_configuration(self):
        manage.install(self.home, "claude")
        manage.pause_client(self.home, "claude")
        snapshot = core.guard_pause_path(self.home, "claude").read_bytes()
        self.assertEqual(self.cli("ensure").returncode, 0)
        with mock.patch.object(manage.policy_update, "check"):
            clients, failures = manage.monitor(self.home, ["claude"])
        self.assertFalse(failures)
        self.assertTrue(clients[0]["guardPaused"])
        with mock.patch.object(manage, "locked_action", side_effect=AssertionError("Unexpected repair")):
            _, failures = manage.repair_unready(self.home, ["claude"])
        self.assertFalse(failures)
        self.assertEqual(core.guard_pause_path(self.home, "claude").read_bytes(), snapshot)
        runtime = manage.locations(self.home, "claude")[2]
        (runtime / "rules.py").write_text("# external edit\n")
        self.assertNotEqual(self.cli("ensure").returncode, 0)
        self.assertFalse(self.state()["guardConfigured"])
        self.assertTrue(self.state()["guardPaused"])

    def test_paused_client_never_verifies_passed_and_expiry_stales_record(self):
        manage.install(self.home, "claude")
        manage.pause_client(self.home, "claude")
        with mock.patch.object(manage, "run_probe", side_effect=AssertionError("Must not call a model")):
            clients, failures = manage.verify_clients(self.home, ["claude"])
        self.assertFalse(failures)
        self.assertEqual(next(item for item in clients if item["id"] == "claude")["guardLiveStatus"], "paused")
        record = manage.read_verification(self.home)["clients"]["claude"]
        self.assertEqual(record["liveStatus"], "paused")
        self.expire("claude")
        self.assertEqual(self.state()["liveStatus"], "stale")

    def test_invalid_private_state_fails_closed_and_can_be_explicitly_resumed(self):
        manage.install(self.home, "claude")
        path = core.guard_pause_path(self.home, "claude")
        for content in (b"{broken", b"[]", b'{"client":"codex","expiresAt":"2099-01-01T00:00:00Z"}',
                        b'{"client":"claude","expiresAt":"2099-01-01T00:00:00"}'):
            manage.atomic_write(path, content)
            self.assertTrue(denied(self.hook("claude", payload("claude", "git status"))))
            self.assertFalse(self.state()["guardConfigured"])
            self.assertFalse(self.state()["guardPaused"])
            self.assertTrue(self.state()["guardPauseError"])
            manage.resume_client(self.home, "claude")
            self.assertIsNone(self.state()["guardPauseError"])
        manage.pause_client(self.home, "claude")
        path.chmod(0o644)
        self.assertTrue(denied(self.hook("claude", payload("claude", "git status"))))
        self.assertTrue(self.state()["guardPauseError"])
        manage.resume_client(self.home, "claude")
        os.mkfifo(path, 0o600)
        self.assertTrue(denied(self.hook("claude", payload("claude", "git status"))))
        self.assertFalse(self.state()["guardConfigured"])
        self.assertTrue(self.state()["guardPauseError"])
        path.unlink()
        outside = self.home / "unrelated.json"
        outside.write_text('{"client":"claude","expiresAt":"2099-01-01T00:00:00Z"}')
        path.symlink_to(outside)
        self.assertTrue(denied(self.hook("claude")))
        self.assertTrue(self.state()["guardPauseError"])
        with self.assertRaises(ValueError):
            manage.pause_client(self.home, "claude")
        original = outside.read_bytes()
        result = self.cli("resume-client")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(path.is_symlink())
        self.assertFalse(path.exists())
        self.assertEqual(outside.read_bytes(), original)
        self.assertIsNone(self.state()["guardPauseError"])
        path.symlink_to(self.home / "missing.json")
        manage.resume_client(self.home, "claude")
        self.assertFalse(path.is_symlink())

        relocated = self.home / "relocated-pauses"
        path.parent.rename(relocated)
        path.parent.symlink_to(relocated, target_is_directory=True)
        (relocated / path.name).write_bytes(original)
        with self.assertRaises(ValueError):
            manage.resume_client(self.home, "claude")
        self.assertEqual((relocated / path.name).read_bytes(), original)

    def test_pause_requires_valid_installed_guard(self):
        with self.assertRaises(ValueError):
            manage.pause_client(self.home, "claude")
        self.assertFalse(core.guard_pause_path(self.home, "claude").exists())
        failed = self.cli("pause-client")
        self.assertNotEqual(failed.returncode, 0)
        state = next(item for item in json.loads(failed.stdout) if item["id"] == "claude")
        self.assertTrue(state["serviceError"])
        self.assertFalse(state["guardPaused"])

    def test_pause_state_survives_reinstall(self):
        manage.install(self.home, "claude")
        manage.pause_client(self.home, "claude")
        manage.install(self.home, "claude")
        self.assertTrue(self.state()["guardPaused"], "Reinstalling the guard must not clear a pause record")


if __name__ == "__main__":
    unittest.main()
