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
import textwrap
import time
import unittest
from unittest.mock import ANY, patch

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
        self.env_patch = patch.dict(os.environ, {"HOME": str(self.home)})
        self.env_patch.start()
        self.addCleanup(self.env_patch.stop)

    def npm_fixture(self, client="codex", name="@openai/codex", prefix=None):
        prefix = prefix or self.home / "npm"
        root = prefix / "lib/node_modules" / name
        root.mkdir(parents=True)
        (root / "package.json").write_text(json.dumps({"name": name, "version": "1.0.0"}))
        binary = root / "cli.js"
        binary.write_text("#!/usr/bin/env node\n")
        binary.chmod(0o755)
        (prefix / "bin").mkdir(parents=True, exist_ok=True)
        entry = prefix / "bin" / client
        entry.symlink_to(binary)
        npm = prefix / "bin/npm"
        npm.write_text("#!/bin/sh\n")
        npm.chmod(0o755)
        return prefix, binary, entry

    def runnable_npm_fixture(self, client="codex", name="@openai/codex"):
        prefix, binary, entry = self.npm_fixture(client, name)
        version = self.home / (client + ".version")
        version.write_text("1.0.0")
        binary.write_text("#!" + sys.executable + " -I\n" +
                          "from pathlib import Path\nprint(Path(" + repr(str(version)) + ").read_text())\n")
        (prefix / "bin/npm").write_text("#!" + sys.executable + " -I\n" + textwrap.dedent('''\
            import json, os, sys, time
            from pathlib import Path
            home = Path(os.environ["HOME"])
            active = home / "npm-active"
            try:
                fd = os.open(active, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
                os.close(fd)
            except FileExistsError:
                (home / "overlap").touch()
            worker = os.environ.get("TEST_WORKER", "single")
            (home / ("started-" + worker)).write_text(str(os.getpid()))
            with (home / "installs.jsonl").open("a") as log:
                log.write(json.dumps(sys.argv[1:]) + "\\n")
            deadline = time.monotonic() + 10
            while os.environ.get("TEST_HOLD") == "1" and not (home / ("release-" + worker)).exists():
                if time.monotonic() > deadline:
                    raise TimeoutError("fake installer release timed out")
                time.sleep(0.01)
            package, version = sys.argv[-1].rsplit("@", 1)
            client = {"@openai/codex": "codex", "@google/gemini-cli": "gemini"}[package]
            (home / (client + ".version")).write_text(version)
            active.unlink(missing_ok=True)
            (home / ("done-" + worker)).touch()
        '''))
        return prefix, binary, entry

    def start_report(self, worker, client="codex", hold=False):
        code = textwrap.dedent('''\
            import json, sys
            from pathlib import Path
            sys.path.insert(0, sys.argv[1])
            import agent_updates as updates
            home = updates.HOME
            client = sys.argv[2]
            updates.permission_modes._search_dirs = lambda _: [home / "npm/bin"]
            updates.permission_modes.is_detected = lambda _, value: value == client
            updates.latest_version = lambda value, install, current: ("2.0.0", updates.version_source(value, install, current))
            updates.update_plugins = lambda _: []
            print(json.dumps(updates.build_report()))
        ''')
        process = subprocess.Popen([sys.executable, "-I", "-B", "-c", code,
                                    str(Path(updates.__file__).parent), client],
                                   env=dict(os.environ, TEST_WORKER=worker, TEST_HOLD="1" if hold else "0"),
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, cwd=str(self.home))
        self.addCleanup(self.stop_process, process)
        return process

    @staticmethod
    def stop_process(process):
        if process.poll() is None:
            process.kill()
        process.communicate(timeout=5)

    def wait_for_file(self, path):
        deadline = time.monotonic() + 5
        while not path.exists():
            if time.monotonic() > deadline:
                self.fail("test subprocess did not create " + str(path))
            time.sleep(0.01)

    def read_report(self, process):
        stdout, stderr = process.communicate(timeout=5)
        self.assertEqual(process.returncode, 0, stderr)
        return json.loads(stdout)

    def check(self, client="codex", current="1.0.0", latest="1.1.0", check_only=True, **extra):
        with ExitStack() as stack:
            stack.enter_context(patch.object(updates, "cli_command", return_value=["/fake/" + client]))
            stack.enter_context(patch.object(updates, "current_version", return_value=current))
            stack.enter_context(patch.object(updates, "npm_installation", return_value=None))
            stack.enter_context(patch.object(updates, "latest_version", side_effect=lambda client, installation, current: (latest, updates.version_source(client, installation, current))))
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

    def test_apply_rechecks_current_version_before_installing_stale_plan(self):
        prefix, _, _ = self.runnable_npm_fixture()
        with patch.object(updates.permission_modes, "_search_dirs", return_value=[prefix / "bin"]), \
                patch.object(updates, "latest_version", side_effect=lambda client, install, current: ("2.0.0", updates.version_source(client, install, current))):
            plan = updates.check_client("codex", check_only=True)
            self.assertEqual(plan["status"], "updateAvailable")
            for version, status in (("2.0.0", "upToDate"), ("3.0.0", "ahead")):
                with self.subTest(version=version):
                    item = dict(plan)
                    (self.home / "codex.version").write_text(version)
                    updates.apply_update(item)
                    self.assertEqual(item["status"], status)
                    self.assertEqual(item["currentVersion"], version)
                    self.assertTrue(item["ok"])
                    self.assertFalse(item["changed"])
                    self.assertFalse((self.home / "installs.jsonl").exists())
                    self.assertEqual((self.home / "codex.version").read_text(), version)

    def test_apply_rejects_installation_prefix_change_since_check(self):
        prefix, _, entry = self.npm_fixture()
        replacement_prefix, _, replacement = self.npm_fixture(prefix=self.home / "other-npm")
        with patch.object(updates, "cli_command", return_value=[str(entry)]), \
                patch.object(updates, "current_version", return_value="1.0.0"), \
                patch.object(updates, "latest_version", side_effect=lambda client, install, current: ("2.0.0", updates.version_source(client, install, current))):
            item = updates.check_client("codex", check_only=True)
            self.assertIn(str(prefix), item["command"])
            with patch.object(updates, "cli_command", return_value=[str(replacement)]), patch.object(updates, "run") as run:
                updates.apply_update(item)
        self.assertEqual(item["status"], "failed")
        self.assertIn("安装来源已变化", item["detail"])
        self.assertNotIn(str(replacement_prefix), item["command"])
        run.assert_not_called()

    def test_apply_rejects_release_source_change_since_check(self):
        item = self.check(client="pi", npm_installation={"return_value": {"name": "@mariozechner/pi-coding-agent", "prefix": self.home}})
        with patch.object(updates, "cli_command", return_value=["/fake/pi"]), \
                patch.object(updates, "current_version", return_value="1.0.0"), \
                patch.object(updates, "npm_installation", return_value={"name": "@earendil-works/pi-coding-agent", "prefix": self.home}), \
                patch.object(updates, "run") as run:
            updates.apply_update(item)
        self.assertEqual(item["status"], "failed")
        self.assertIn("发行源已变化", item["detail"])
        run.assert_not_called()

    def test_apply_cannot_update_when_version_recheck_fails(self):
        item = self.check()
        with patch.object(updates, "cli_command", return_value=["/fake/codex"]), \
                patch.object(updates, "current_version", side_effect=ValueError("version read failed")), \
                patch.object(updates, "run") as run:
            updates.apply_update(item)
        self.assertEqual(item["status"], "failed")
        self.assertFalse(item["changed"])
        self.assertIn("version read failed", item["detail"])
        run.assert_not_called()

    def test_separate_report_processes_never_overlap_shared_prefix_installs(self):
        self.runnable_npm_fixture()
        self.runnable_npm_fixture("gemini", "@google/gemini-cli")
        first = self.start_report("first", hold=True)
        self.addCleanup((self.home / "release-first").touch)
        self.wait_for_file(self.home / "started-first")
        second = self.read_report(self.start_report("second", client="gemini"))
        self.assertEqual(second["items"][0]["status"], "failed")
        self.assertIn("另一个", second["items"][0]["detail"])
        self.assertFalse((self.home / "started-second").exists())
        (self.home / "release-first").touch()
        self.assertEqual(self.read_report(first)["items"][0]["status"], "updated")
        third = self.read_report(self.start_report("third", client="gemini"))
        self.assertEqual(third["items"][0]["status"], "updated")
        self.assertFalse((self.home / "overlap").exists())
        self.assertEqual(len((self.home / "installs.jsonl").read_text().splitlines()), 2)

    def test_orphaned_installer_keeps_lock_until_it_exits(self):
        self.runnable_npm_fixture()
        first = self.start_report("orphan", hold=True)
        self.addCleanup((self.home / "release-orphan").touch)
        self.wait_for_file(self.home / "started-orphan")
        first.kill()
        first.wait(timeout=5)
        blocked = self.read_report(self.start_report("blocked"))
        self.assertEqual(blocked["items"][0]["status"], "failed")
        self.assertIn("另一个", blocked["items"][0]["detail"])
        self.assertFalse((self.home / "started-blocked").exists())
        (self.home / "release-orphan").touch()
        self.wait_for_file(self.home / "done-orphan")
        first.communicate(timeout=5)
        recovered = self.read_report(self.start_report("recovered"))
        self.assertEqual(recovered["items"][0]["status"], "upToDate")
        self.assertFalse((self.home / "overlap").exists())
        self.assertEqual(len((self.home / "installs.jsonl").read_text().splitlines()), 1)

    def test_lock_failure_is_visible_and_other_checks_still_run(self):
        detected = {"codex", "gemini"}
        def checked(client, check_only):
            return dict(client=client, target="CLI", ok=True, changed=False,
                        command="/fake/updater", status="updateAvailable", latestVersion="2.0.0", currentVersion="1.0.0")
        with patch.object(updates.permission_modes, "is_detected", side_effect=lambda _, client: client in detected), \
                patch.object(updates, "check_client", side_effect=checked) as check, \
                patch.object(updates, "update_lock", side_effect=OSError("lock unavailable")), \
                patch.object(updates, "run") as run:
            report = updates.build_report()
        self.assertEqual(check.call_count, 2)
        self.assertEqual({item["client"] for item in report["items"]}, detected)
        self.assertTrue(all(item["status"] == "failed" and "lock unavailable" in item["detail"] for item in report["items"]))
        run.assert_not_called()

    def test_plugin_lock_contention_does_not_prevent_cli_checks(self):
        item = dict(client="pi", target="CLI", ok=True, changed=False, status="upToDate")
        with updates.update_lock(), \
                patch.object(updates.permission_modes, "is_detected", side_effect=lambda _, client: client == "pi"), \
                patch.object(updates, "check_client", return_value=item) as check, \
                patch.object(updates, "run") as run:
            report = updates.build_report()
            check_only_report = updates.build_report(check_only=True)
        self.assertEqual(check.call_count, 2)
        self.assertEqual(report["items"][0]["status"], "upToDate")
        self.assertFalse(report["items"][1]["ok"])
        self.assertIn("另一个", report["items"][1]["detail"])
        self.assertEqual(check_only_report["items"], [item])
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
            item = self.check(check_only=False, current_version={"side_effect": ["1.0.0", "1.0.0", "1.1.0"]})
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

    def test_explicit_unknown_plugin_command_is_unsupported(self):
        for output in ("error: unknown command 'update'", "unrecognized subcommand 'extensions'", "command 'plugin' not found"):
            with self.subTest(output=output), patch.object(updates, "run", return_value=(False, output)):
                self.assertFalse(updates.supported_command(["/fake/pi"], ["update", "--extensions"]))

    def test_plugin_probe_failures_are_reported_and_other_checks_continue(self):
        for output in ("Fatal error: extension module not found", "超时（30 秒），已终止升级进程组"):
            with self.subTest(output=output):
                def checked(client, check_only):
                    return dict(client=client, target="CLI", ok=True, changed=False, status="upToDate")
                with patch.object(updates.permission_modes, "is_detected", side_effect=lambda _, client: client in ("pi", "zcode")), \
                        patch.object(updates, "check_client", side_effect=checked) as check, \
                        patch.object(updates, "cli_command", side_effect=lambda client: ["/fake/" + client]), \
                        patch.object(updates, "run", side_effect=lambda args, **kwargs: (False, output) if args[0] == "/fake/pi" else (False, "unknown command 'plugins'")) as run:
                    report = updates.build_report()
                self.assertEqual(check.call_count, 2)
                failures = [item for item in report["items"] if not item["ok"]]
                self.assertEqual(len(failures), 1)
                self.assertEqual(failures[0]["client"], "pi")
                self.assertIn(output, failures[0]["detail"])
                self.assertIn("插件命令探测失败", failures[0]["detail"])
                self.assertIn("失败或暂不支持 1 项", report["message"])
                self.assertTrue(all(call.args[0][-1] == "--help" for call in run.call_args_list))

    def test_later_plugin_probe_failure_preserves_earlier_result(self):
        with patch.object(updates, "cli_command", return_value=["/fake/zcode"]), \
                patch.object(updates, "run", side_effect=[(True, "Usage: plugins marketplace update"),
                                                        (True, "plugin 1.0.0 -> 1.1.0"),
                                                        (False, "Fatal error: extension failed")]):
            items = updates.update_plugins("zcode")
        self.assertEqual(len(items), 2)
        self.assertTrue(items[0]["ok"] and items[0]["changed"])
        self.assertFalse(items[1]["ok"])
        self.assertIn("Fatal error: extension failed", items[1]["detail"])

    def test_pi_extensions_use_official_command_without_updating_self(self):
        with patch.object(updates, "cli_command", return_value=["/fake/pi"]), \
                patch.object(updates, "supported_command", return_value=True) as supported, \
                patch.object(updates, "run", return_value=(True, "Updated packages")) as run:
            items = updates.update_plugins("pi")
        supported.assert_called_once_with(["/fake/pi"], ["update", "--extensions"])
        run.assert_called_once_with(["/fake/pi", "update", "--extensions", "--no-approve"], lock_fd=ANY)
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
        run.assert_called_once_with(["/fake/pi", "update", "--extensions", "--no-approve"], lock_fd=ANY)
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
