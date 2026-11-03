#!/usr/bin/env python3
"""Offline update checks: fake installations and mocked vendor responses only."""
from contextlib import ExitStack
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "AgentGuard"))
import agent_updates as updates


class AgentUpdateTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.home = Path(self.temporary.name).resolve()
        self.home_patch = patch.object(updates, "HOME", self.home)
        self.home_patch.start()
        self.addCleanup(self.home_patch.stop)

    def npm_fixture(self, client="codex", name="@openai/codex", prefix=None):
        prefix = prefix or self.home / "npm"
        root = prefix / "lib/node_modules" / name
        root.mkdir(parents=True)
        (root / "package.json").write_text(json.dumps({"name": name, "version": "1.0.0"}))
        binary = root / "cli.js"
        binary.write_text("#!/usr/bin/env node\n")
        binary.chmod(0o755)
        (prefix / "bin").mkdir(parents=True)
        entry = prefix / "bin" / client
        entry.symlink_to(binary)
        npm = prefix / "bin/npm"
        npm.write_text("#!/bin/sh\n")
        npm.chmod(0o755)
        return prefix, binary, entry

    def check(self, client="codex", current="1.0.0", latest="1.1.0", check_only=True, **extra):
        with ExitStack() as stack:
            stack.enter_context(patch.object(updates, "cli_command", return_value=["/fake/" + client]))
            stack.enter_context(patch.object(updates, "current_version", return_value=current))
            stack.enter_context(patch.object(updates, "npm_installation", return_value=None))
            stack.enter_context(patch.object(updates, "latest_version", return_value=(latest, "https://official.example/latest")))
            stack.enter_context(patch.object(updates, "update_command", return_value=(["/fake/updater"], "")))
            for name, value in extra.items():
                stack.enter_context(patch.object(updates, name, **value))
            return updates.check_client(client, check_only)

    def test_version_formats_and_multiline_zcode_distribution(self):
        samples = {"codex-cli 0.163.0": "0.163.0", "2.1.304 (Claude Code)": "2.1.304",
                   "opencode v2.1.0": "2.1.0", "1.4.3\n": "1.4.3",
                   "zcode-app-cli 3.14.4-30\nzcode-runtime 0.16.9": "3.14.4-30"}
        for text, expected in samples.items():
            self.assertEqual(updates.version_from_output(text), expected)
        with self.assertRaises(ValueError):
            updates.version_from_output("authentication failed")

    def test_run_timeout_terminates_parent_and_spawned_downloader(self):
        pids = self.home / "processes.json"
        child_code = "import time; time.sleep(30)"
        parent_code = (
            "import json,os,pathlib,subprocess,sys,time; "
            "child=subprocess.Popen([sys.executable,'-c',sys.argv[2]]); "
            "pathlib.Path(sys.argv[1]).write_text(json.dumps([os.getpid(),child.pid])); "
            "child.wait()"
        )
        started = time.monotonic()
        processes = []
        try:
            ok, detail = updates.run([sys.executable, "-c", parent_code, str(pids), child_code], timeout=0.5)
            self.assertFalse(ok)
            self.assertIn("超时", detail)
            self.assertLess(time.monotonic() - started, 5)
            self.assertTrue(pids.is_file(), "fake updater must actually spawn the child before timeout")
            processes = json.loads(pids.read_text())
            for pid in processes:
                deadline = time.monotonic() + 3
                while True:
                    status = subprocess.run(["/bin/ps", "-o", "stat=", "-p", str(pid)],
                                            capture_output=True, text=True, timeout=2).stdout.strip()
                    # Some CI PID 1 implementations delay reaping killed orphan zombies.
                    if not status or status.startswith("Z"):
                        break
                    if time.monotonic() >= deadline:
                        self.fail("timed-out updater left a live process: {} {}".format(pid, status))
                    time.sleep(0.05)
        finally:
            if not processes and pids.is_file():
                processes = json.loads(pids.read_text())
            for pid in processes:
                try:
                    os.kill(pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass

    def test_run_preserves_arguments_output_and_exit_status(self):
        argument = "literal ; shell substitution $(false)"
        ok, output = updates.run([sys.executable, "-c", "import sys; print(sys.argv[1]); print('error',file=sys.stderr); sys.exit(4)", argument], timeout=2)
        self.assertFalse(ok)
        self.assertIn(argument, output)
        self.assertIn("error", output)

    def test_semver_prerelease_and_numeric_builds(self):
        versions = ["1.0.0-alpha.2", "1.0.0-alpha.10", "1.0.0-beta", "1.0.0", "1.0.1", "1.1.0", "2.0.0"]
        self.assertEqual(sorted(reversed(versions), key=updates.version_key), versions)
        self.assertLess(updates.version_key("3.14.4-9"), updates.version_key("3.14.4-30"))
        self.assertEqual(updates.version_key("1.0.0+one"), updates.version_key("1.0.0+two"))

    def test_same_version_never_runs_update(self):
        with patch.object(updates, "run") as run:
            item = self.check(current="1.0.0", latest="1.0.0", check_only=False)
        self.assertEqual(item["status"], "upToDate")
        self.assertTrue(item["ok"])
        self.assertFalse(item["changed"])
        run.assert_not_called()

    def test_higher_local_version_never_downgrades(self):
        with patch.object(updates, "run") as run:
            item = self.check(current="2.1.0", latest="1.19.3", check_only=False)
        self.assertEqual(item["status"], "ahead")
        run.assert_not_called()

    def test_check_only_does_not_execute_or_update_plugins(self):
        with patch.object(updates, "run") as run, patch.object(updates, "update_plugins") as plugins:
            item = self.check()
        self.assertEqual(item["status"], "updateAvailable")
        self.assertFalse(item["changed"])
        run.assert_not_called()
        plugins.assert_not_called()

    def test_success_requires_reading_the_new_version(self):
        with patch.object(updates, "run", return_value=(True, "success")):
            item = self.check(check_only=False, current_version={"side_effect": ["1.0.0", "1.1.0"]})
        self.assertEqual(item["status"], "updated")
        self.assertEqual(item["currentVersion"], "1.1.0")
        self.assertTrue(item["changed"])
        self.assertIn("1.0.0 → 1.1.0", item["detail"])

    def test_success_output_with_unchanged_binary_is_failure(self):
        with patch.object(updates, "run", return_value=(True, "Updated successfully")):
            item = self.check(check_only=False)
        self.assertEqual(item["status"], "failed")
        self.assertFalse(item["ok"])
        self.assertFalse(item["changed"])
        self.assertIn("实际版本仍为", item["detail"])

    def test_nonzero_updater_is_failure_even_with_success_text(self):
        with patch.object(updates, "run", return_value=(False, "success but network failed")):
            item = self.check(check_only=False)
        self.assertEqual(item["status"], "failed")
        self.assertIn("network failed", item["detail"])

    def test_network_failure_retains_current_version_and_source(self):
        item = self.check(latest_version={"side_effect": OSError("network unreachable")})
        self.assertEqual(item["status"], "failed")
        self.assertEqual(item["currentVersion"], "1.0.0")
        self.assertEqual(item["latestVersion"], "")
        self.assertEqual(item["source"], updates.REGISTRY + "/@openai%2fcodex/latest")
        self.assertIn("network unreachable", item["detail"])

    def test_unparseable_current_version_is_not_latest(self):
        item = self.check(current_version={"side_effect": ValueError("invalid version output")})
        self.assertEqual(item["status"], "failed")
        self.assertFalse(item["ok"])

    def test_every_detected_client_has_a_cli_result_even_without_cli(self):
        with patch.object(updates.permission_modes, "is_detected", return_value=True), \
                patch.object(updates, "cli_command", return_value=None), \
                patch.object(updates, "update_plugins") as plugins:
            report = updates.build_report(check_only=True)
        self.assertEqual(len(report["items"]), len(updates.permission_modes.COMMANDS))
        self.assertTrue(all(i["status"] == "unsupported" for i in report["items"]))
        for item in report["items"]:
            self.assertTrue({"client", "target", "command", "ok", "changed", "detail", "currentVersion", "latestVersion", "status", "source"}.issubset(item))
        plugins.assert_not_called()
        json.dumps(report)

    def test_npm_installation_follows_simple_launcher_and_same_prefix(self):
        prefix, binary, entry = self.npm_fixture()
        launcher = self.home / "codex"
        launcher.write_text('#!/bin/sh\n# personal launcher\nexec "' + str(entry) + '" "$@"\n')
        installation = updates.npm_installation("codex", [str(launcher)])
        self.assertEqual(installation, {"name": "@openai/codex", "prefix": prefix})
        command, error = updates.update_command("codex", [str(launcher)], installation, "1.1.0")
        self.assertEqual(error, "")
        self.assertEqual(command[:6], [str(prefix / "bin/npm"), "install", "--global", "--prefix", str(prefix), "--registry"])
        self.assertEqual(command[-1], "@openai/codex@1.1.0")
        self.assertNotIn("--force", command)
        self.assertEqual(binary.read_text(), "#!/usr/bin/env node\n")

    def test_unknown_package_is_not_given_a_trusted_npm_update(self):
        _, _, entry = self.npm_fixture(name="@untrusted/codex")
        self.assertIsNone(updates.npm_installation("codex", [str(entry)]))
        command, _ = updates.update_command("codex", [str(entry)], None, "1.1.0")
        self.assertEqual(command, [])

    def test_npm_cannot_overwrite_yolo_wrapper(self):
        prefix, binary, entry = self.npm_fixture()
        entry.unlink()
        entry.write_text("#!/bin/sh\n# Managed by TermYes\nexec actual --auto \"$@\"\n")
        before = entry.read_bytes()
        command, reason = updates.update_command("codex", [str(binary)], {"name": "@openai/codex", "prefix": prefix}, "1.1.0")
        self.assertEqual(command, [])
        self.assertIn("wrapper", reason)
        self.assertEqual(entry.read_bytes(), before)

    def test_native_updater_does_not_switch_installation_method(self):
        command, reason = updates.update_command("claude", ["/opt/homebrew/bin/claude"], None, "1.1.0")
        self.assertEqual(command, [])
        self.assertIn("安装来源无法确认", reason)

    def test_native_qoder_uses_verified_update_command(self):
        binary = self.home / ".qoder/bin/qodercli/qodercli-1.0.0"
        binary.parent.mkdir(parents=True)
        binary.touch()
        command, reason = updates.update_command("qoder", [str(binary)], None, "1.1.0")
        self.assertEqual(command, [str(binary), "update"])
        self.assertEqual(reason, "")

    def test_pi_npm_preserves_ignore_scripts_official_install_option(self):
        prefix, binary, _ = self.npm_fixture(client="pi", name="@earendil-works/pi-coding-agent")
        command, _ = updates.update_command("pi", [str(binary)], {"name": "@earendil-works/pi-coding-agent", "prefix": prefix}, "1.1.0")
        self.assertIn("--ignore-scripts", command)

    def test_third_party_zcode_source_is_explicit(self):
        item = self.check(client="zcode", npm_installation={"return_value": {"name": "zcode-app-cli", "prefix": self.home}})
        self.assertEqual(item["sourceLabel"], "当前发行（第三方）")

    def test_authoritative_npm_identity_and_version_are_validated(self):
        installation = {"name": "@openai/codex", "prefix": self.home}
        with patch.object(updates, "fetch_text", return_value=json.dumps({"name": "wrong-package", "version": "9.0.0"})):
            with self.assertRaisesRegex(ValueError, "身份不匹配"):
                updates.latest_version("codex", installation)
        with patch.object(updates, "fetch_text", return_value='<html>temporarily unavailable</html>'):
            with self.assertRaises(ValueError):
                updates.latest_version("codex", installation)

    def test_native_manifest_versions(self):
        for client, payload in (("qoder", '{"latest":"1.1.75"}'), ("agy", '{"version":"1.4.3"}')):
            with patch.object(updates, "fetch_text", return_value=payload):
                latest, source = updates.latest_version(client, None)
            self.assertTrue(latest)
            self.assertTrue(source.startswith("https://"))

    def test_claude_stable_channel_is_preserved(self):
        settings = self.home / ".claude/settings.json"
        settings.parent.mkdir()
        settings.write_text('{"autoUpdatesChannel":"stable"}')
        with patch.object(updates, "fetch_text", return_value="2.1.304") as fetch:
            latest, source = updates.latest_version("claude", None)
        self.assertEqual(latest, "2.1.304")
        self.assertTrue(source.endswith("/stable"))
        fetch.assert_called_once_with(source)

    def test_opencode_two_uses_its_separate_official_channel(self):
        payload = {"version": "2.1.1", "active": True, "metadata": {"package": "@opencode/cli"}}
        with patch.object(updates, "fetch_text", return_value=json.dumps(payload)) as fetch:
            latest, source = updates.latest_version("opencode", None, "2.1.0")
        self.assertEqual(latest, "2.1.1")
        self.assertEqual(source, "https://opencode.ai/update/api/latest/cli/npm")
        fetch.assert_called_once_with(source)
        self.assertEqual(updates.version_source("opencode", None, "1.19.0"), updates.REGISTRY + "/opencode-ai/latest")

    def test_opencode_two_rejects_inactive_or_unexpected_distribution(self):
        for payload in ({"version": "2.1.1", "active": False, "metadata": {"package": "@opencode/cli"}},
                        {"version": "2.1.1", "active": True, "metadata": {"package": "not-the-official-cli"}}):
            with patch.object(updates, "fetch_text", return_value=json.dumps(payload)):
                with self.assertRaisesRegex(ValueError, "有效发行包"):
                    updates.latest_version("opencode", None, "2.1.0")

    def test_unsupported_plugin_commands_are_not_executed(self):
        with patch.object(updates, "cli_command", return_value=["/fake/codex"]), \
                patch.object(updates, "supported_command", return_value=False), \
                patch.object(updates, "run") as run:
            self.assertEqual(updates.update_plugins("codex"), [])
        run.assert_not_called()

    def test_pi_extensions_use_official_command_without_updating_self(self):
        with patch.object(updates, "cli_command", return_value=["/fake/pi"]), \
                patch.object(updates, "supported_command", return_value=True) as supported, \
                patch.object(updates, "run", return_value=(True, "Updated packages")) as run:
            items = updates.update_plugins("pi")
        supported.assert_called_once_with(["/fake/pi"], ["update", "--extensions"])
        run.assert_called_once_with(["/fake/pi", "update", "--extensions", "--no-approve"])
        self.assertEqual(len(items), 1)
        self.assertTrue(items[0]["ok"])
        self.assertFalse(items[0]["changed"], "A generic success message does not prove a version changed")
        self.assertEqual(items[0]["detail"], "Updated packages")

    def test_pi_extension_update_failure_is_reported(self):
        with patch.object(updates, "cli_command", return_value=["/fake/pi"]), \
                patch.object(updates, "supported_command", return_value=True), \
                patch.object(updates, "run", return_value=(False, "registry unreachable")):
            items = updates.update_plugins("pi")
        self.assertEqual(len(items), 1)
        self.assertFalse(items[0]["ok"])
        self.assertFalse(items[0]["changed"])
        self.assertIn("registry unreachable", items[0]["detail"])

    def test_unsupported_pi_extension_command_is_not_executed(self):
        with patch.object(updates, "cli_command", return_value=["/fake/pi"]), \
                patch.object(updates, "supported_command", return_value=False) as supported, \
                patch.object(updates, "run") as run:
            self.assertEqual(updates.update_plugins("pi"), [])
        supported.assert_called_once_with(["/fake/pi"], ["update", "--extensions"])
        run.assert_not_called()

    def test_pi_extensions_are_updated_even_when_cli_is_current(self):
        item = {"client": "pi", "target": "CLI", "ok": True, "changed": False, "status": "upToDate"}
        with patch.object(updates.permission_modes, "is_detected", side_effect=lambda home, client: client == "pi"), \
                patch.object(updates, "check_client", return_value=item), \
                patch.object(updates, "apply_update") as apply_update, \
                patch.object(updates, "cli_command", return_value=["/fake/pi"]), \
                patch.object(updates, "supported_command", return_value=True), \
                patch.object(updates, "run", return_value=(True, "Already up to date")) as run:
            report = updates.build_report()
        apply_update.assert_called_once_with(item)
        run.assert_called_once_with(["/fake/pi", "update", "--extensions", "--no-approve"])
        self.assertEqual(len(report["items"]), 2)
        self.assertTrue(all(entry["ok"] and not entry["changed"] for entry in report["items"]))

    def test_plugin_update_success_text_does_not_claim_version_changed(self):
        self.assertFalse(updates.changed_from_output("Marketplace updated successfully"))
        self.assertFalse(updates.changed_from_output("Already up to date"))
        self.assertTrue(updates.changed_from_output("plugin 1.0.0 -> 1.1.0"))

    def test_plugin_ids_cannot_be_options(self):
        self.assertEqual(updates.plugin_ids_from_output("plugin@marketplace\n--flag\n/tmp/path@remote\n"), ["plugin@marketplace"])


if __name__ == "__main__":
    unittest.main()
