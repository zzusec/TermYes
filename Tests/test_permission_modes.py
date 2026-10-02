#!/usr/bin/env python3
"""Permission-mode regressions; every executable and config lives in a temporary HOME."""

import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "AgentGuard"))
import permission_modes as modes


class PermissionModesTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="termyes-permissions-")
        self.addCleanup(self.temporary.cleanup)
        self.home = Path(self.temporary.name).resolve() / "home with spaces"
        self.home.mkdir()
        self.bin = self.home / "tools"
        self.bin.mkdir()
        # Never discover or execute the machine's installed agents.
        self.environment = mock.patch.dict(os.environ, {"HOME": str(self.home), "PATH": str(self.bin)})
        self.environment.start()
        self.addCleanup(self.environment.stop)
        self.defaults = mock.patch.object(modes, "_default_search_dirs", return_value=[self.bin], create=True)
        self.defaults.start()
        self.addCleanup(self.defaults.stop)
        self.apps = mock.patch.object(modes, "APP_PATHS", {})
        self.apps.start()
        self.addCleanup(self.apps.stop)

    def write(self, path, text, executable=False):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf-8")
        path.chmod(0o755 if executable else 0o600)
        return path

    def cli(self, name, directory=None):
        return self.write((directory or self.bin) / name,
                          '#!/bin/sh\nprintf "%s\\n" "$0" "$@"\n', True)

    def manager(self, success=True):
        return self.write(self.home / "manage.py",
                          'import pathlib, sys\n'
                          f'pathlib.Path({str(self.home / "ensure.log")!r}).write_text(" ".join(sys.argv[1:]))\n'
                          f'sys.exit({0 if success else 1})\n')

    def run_wrapper(self, name, args=(), path=None):
        env = {**os.environ, "PATH": path or str(self.bin),
               "TERMYES_MANAGE_PY": str(self.manager())}
        return subprocess.run([str(self.home / ".local/bin" / name), *args],
                              capture_output=True, text=True, env=env, timeout=5)

    def test_native_resolution_follows_path_not_fixed_install_order(self):
        local = self.cli("claude", self.home / ".local/bin")
        actual = self.cli("claude")
        self.assertEqual(modes.launcher_path(self.home, "claude"), actual)
        self.assertNotEqual(local, actual)

    def test_qoder_uses_real_qodercli_not_desktop_dispatcher(self):
        self.cli("qoder", self.home / ".qoder/entry")
        actual = self.cli("qodercli")
        self.assertEqual(modes.launcher_path(self.home, "qoder"), actual)

    def test_qoder_old_cli_name_remains_supported(self):
        actual = self.cli("qoder")
        self.assertTrue(modes.is_detected(self.home, "qoder"))
        self.assertEqual(modes.launcher_path(self.home, "qoder"), actual)

    def test_qoder_desktop_dispatcher_alone_is_not_a_cli(self):
        self.write(self.bin / "qoder", '#!/bin/bash\n# Qoder Command Dispatcher\nexit 127\n', True)
        self.assertFalse(modes.is_detected(self.home, "qoder"))
        self.assertIsNone(modes.launcher_path(self.home, "qoder"))

    def test_cursor_editor_alone_is_not_an_agent_cli(self):
        self.cli("cursor")
        with mock.patch.object(modes, "APP_PATHS", {"cursor": (str(self.home),)}):
            self.assertTrue(modes.is_detected(self.home, "cursor"))
            self.assertFalse(modes.inspect(self.home, "cursor")["permissionReady"])
            self.assertIsNone(modes.launcher_path(self.home, "cursor"))

    def test_symlink_basename_does_not_make_a_real_cli_a_managed_wrapper(self):
        binary = self.cli("agent-yolo-wrapper")
        link = self.bin / "gemini"
        link.symlink_to(binary.name)
        self.assertFalse(modes._is_managed_wrapper(link))
        self.assertEqual(modes.launcher_path(self.home, "gemini"), link)

    def test_managed_wrapper_detection_follows_target_content(self):
        wrapper = self.write(self.bin / "launcher", modes._wrapper_content(), True)
        link = self.bin / "gemini"
        link.symlink_to(wrapper.name)
        self.assertTrue(modes._is_managed_wrapper(link))
        self.assertFalse(modes.is_detected(self.home, "gemini"))

    def test_embedded_marker_in_cli_is_not_a_managed_wrapper(self):
        binary = self.write(self.bin / "gemini", '#!/bin/sh\necho "# Managed by TermYes"\n', True)
        self.assertFalse(modes._is_managed_wrapper(binary))
        self.assertTrue(modes.is_detected(self.home, "gemini"))

    def test_wrapper_without_underlying_cli_does_not_count_as_installed(self):
        modes._ensure_wrapper(self.home, "gemini")
        self.assertFalse(modes.inspect(self.home, "gemini")["detected"])
        self.assertIsNone(modes.launcher_path(self.home, "gemini"))

    def test_stale_or_nonexecutable_wrapper_is_not_ready_and_gets_repaired(self):
        self.cli("gemini")
        modes.repair(self.home, "gemini")
        wrapper = self.home / ".local/bin" / modes.WRAPPER_NAME
        self.write(wrapper, '#!/bin/zsh\n# Managed by TermYes\nexec /bin/echo "$@"\n', True)
        self.assertFalse(modes.inspect(self.home, "gemini")["permissionReady"])
        self.assertTrue(modes.repair(self.home, "gemini")["permissionReady"])
        wrapper.chmod(0o600)
        self.assertFalse(modes.inspect(self.home, "gemini")["permissionReady"])
        self.assertTrue(modes.repair(self.home, "gemini")["permissionReady"])
        self.assertTrue(os.access(wrapper, os.X_OK))

    def test_opencode_equivalent_wrapper_is_upgraded_without_dropping_auto(self):
        self.cli("opencode")
        original = self.write(self.home / ".local/bin/opencode",
                              '#!/bin/zsh\n# Managed by TermYes\nexec /bin/echo --auto "$@"\n', True)
        self.assertFalse(modes.inspect(self.home, "opencode")["permissionReady"])
        self.assertTrue(modes.repair(self.home, "opencode")["permissionReady"])
        self.assertTrue(original.is_file())
        self.assertIn("--auto", self.run_wrapper("opencode").stdout.splitlines())

    def test_opencode_run_places_auto_inside_subcommand(self):
        self.cli("opencode")
        modes.repair(self.home, "opencode")
        result = self.run_wrapper("opencode", ["run", "--format", "json", "safe prompt"])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.splitlines()[1:], ["run", "--auto", "--format", "json", "safe prompt"])

    def test_cursor_launcher_and_wrapper_use_cursor_agent_not_editor(self):
        editor = self.cli("cursor")
        actual = self.cli("cursor-agent")
        modes.repair(self.home, "cursor")
        self.assertEqual(modes.launcher_path(self.home, "cursor").name, "cursor-agent")
        result = self.run_wrapper("cursor", ["--version"])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.splitlines()[0], str(actual))
        self.assertNotIn(str(editor), result.stdout.splitlines())

    def test_vendor_path_is_consistent_with_executed_wrapper_target(self):
        self.cli("opencode")
        actual = self.cli("opencode", self.home / ".local/share/Termosaic/vendor/bin")
        modes.repair(self.home, "opencode")
        self.assertIn(actual, modes.executable_paths(self.home, "opencode"))
        result = self.run_wrapper("opencode", ["--version"])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.splitlines()[0], str(actual))

    def test_known_install_dir_is_used_when_missing_from_path(self):
        actual = self.cli("opencode", self.home / ".opencode/bin")
        with mock.patch.object(modes, "_default_search_dirs", return_value=[actual.parent]):
            modes.repair(self.home, "opencode")
            result = self.run_wrapper("opencode", ["--version"])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.splitlines()[0], str(actual))

    def test_wrapper_skips_symlinked_path_back_to_itself(self):
        actual = self.cli("gemini")
        modes.repair(self.home, "gemini")
        alias = self.home / "alias-bin"
        alias.symlink_to(self.home / ".local/bin", target_is_directory=True)
        result = self.run_wrapper("gemini", ["--version"], str(alias) + ":" + str(self.bin))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.splitlines()[0], str(actual))

    def test_symlink_targets_are_in_verification_paths(self):
        actual = self.cli("real-claude")
        link = self.bin / "claude"
        link.symlink_to(actual.name)
        self.assertIn(actual, modes.executable_paths(self.home, "claude"))

    def test_wrapper_rejects_conflicting_permission_options_without_launching(self):
        for client, args in (("opencode", ["--auto=false"]),
                             ("gemini", ["--approval-mode", "default"]),
                             ("gemini", ["--approval-mode=plan"]),
                             ("cursor", ["--yolo=false"]),
                             ("droid", ["exec", "--auto", "low"]),
                             ("droid", ["exec", "--auto=medium"]),
                             ("copilot", ["--allow-all-tools=false"])):
            with self.subTest(client=client, args=args):
                self.cli(modes.COMMANDS[client][0])
                modes.repair(self.home, client)
                result = self.run_wrapper(modes._wrapper_names(client)[0], args)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(result.stdout, "")
                self.assertIn("YOLO", result.stderr)

    def test_wrapper_preserves_delimiter_and_prompt_text(self):
        self.cli("gemini")
        modes.repair(self.home, "gemini")
        args = ["--", "--approval-mode=default", "prompt with spaces"]
        result = self.run_wrapper("gemini", args)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.splitlines()[1:], ["--yolo", *args])

    def test_wrapper_accepts_equivalent_mode_and_preserves_denials(self):
        self.cli("gemini")
        modes.repair(self.home, "gemini")
        result = self.run_wrapper("gemini", ["--approval-mode", "yolo"])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.cli("copilot")
        modes.repair(self.home, "copilot")
        result = self.run_wrapper("copilot", ["--deny-tool", "shell(rm)"])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("shell(rm)", result.stdout)
        for flag in ("--allow-all-tools",):
            self.assertIn(flag, result.stdout.splitlines())

    def test_wrapper_still_fails_closed_when_guard_fails(self):
        self.cli("gemini")
        modes.repair(self.home, "gemini")
        env = {**os.environ, "TERMYES_MANAGE_PY": str(self.manager(False))}
        result = subprocess.run([str(self.home / ".local/bin/gemini"), "--version"],
                                capture_output=True, text=True, env=env, timeout=5)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, "")

    def test_shell_loader_prevents_path_bypass_and_handles_qodercli(self):
        self.cli("gemini")
        self.cli("qodercli")
        modes.repair(self.home, "gemini")
        modes.repair(self.home, "qoder")
        # A later PATH change must not evade the guarded wrapper.
        command = 'source "$HOME/.local/bin/termyes-agent-yolo-shell"; gemini --version; qodercli --version'
        result = subprocess.run(["/bin/zsh", "-f", "-c", command], capture_output=True, text=True,
                                env={**os.environ, "TERMYES_MANAGE_PY": str(self.manager())}, timeout=5)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("--yolo", result.stdout.splitlines())
        self.assertEqual((self.home / "ensure.log").read_text(), "ensure qoder")

    def test_native_shell_rejects_permission_downgrades_and_config_overrides(self):
        self.cli("codex")
        modes.repair(self.home, "codex")
        for args in (["--ask-for-approval", "on-request"], ["--sandbox=read-only"],
                     ["-c", 'approval_policy="on-request"'],
                     ["--config=sandbox_mode='read-only'"], ["--full-auto"]):
            with self.subTest(args=args):
                command = 'source "$HOME/.local/bin/termyes-agent-yolo-shell"; codex "$@"'
                result = subprocess.run(["/bin/zsh", "-f", "-c", command, "test", *args],
                                        capture_output=True, text=True,
                                        env={**os.environ, "TERMYES_MANAGE_PY": str(self.manager())}, timeout=5)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(result.stdout, "")
                self.assertIn("YOLO", result.stderr)
        result = subprocess.run(
            ["/bin/zsh", "-f", "-c", command, "test", "-c", 'approval_policy="never"'],
            capture_output=True, text=True,
            env={**os.environ, "TERMYES_MANAGE_PY": str(self.manager())}, timeout=5)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('approval_policy="never"', result.stdout.splitlines())

    def test_zsh_path_block_moves_after_later_vendor_path_without_erasing_user_lines(self):
        rc = self.write(self.home / ".zshrc", modes.PATH_MARKER + '\nexport PATH="$HOME/.local/bin:$PATH"\n'
                        + modes.SHELL_MARKER + '\nsource "$HOME/.local/bin/termyes-agent-yolo-shell"\n'
                        + '# End TermYes Agent YOLO shell\nexport PATH="$HOME/vendor/bin:$PATH"\n')
        modes._ensure_zsh_path(self.home)
        text = rc.read_text()
        self.assertIn('export PATH="$HOME/vendor/bin:$PATH"', text)
        self.assertGreater(text.index(modes.PATH_MARKER), text.index('export PATH="$HOME/vendor/bin:$PATH"'))
        first = rc.read_bytes()
        modes._ensure_zsh_path(self.home)
        self.assertEqual(rc.read_bytes(), first)

    def test_json_repair_preserves_other_settings_and_is_idempotent(self):
        for client in ("claude", "codebuddy", "qoder", "zcode"):
            with self.subTest(client=client):
                self.cli(modes.COMMANDS[client][0])
                relative, keys, expected = modes._json_spec(client)
                config = self.home / modes.ROOTS[client] / relative
                data = {"custom": {"keep": True}, "hooks": {"PreToolUse": ["user-hook"]}}
                self.write(config, json.dumps(data))
                self.assertTrue(modes.repair(self.home, client)["permissionReady"])
                value = json.loads(config.read_text())
                self.assertEqual(value["custom"], data["custom"])
                self.assertEqual(value["hooks"], data["hooks"])
                for key in keys:
                    value = value[key]
                self.assertEqual(value, expected)
                first = config.read_bytes()
                self.assertFalse(modes.repair(self.home, client)["repaired"])
                self.assertEqual(config.read_bytes(), first)

    def test_codex_literal_quotes_are_equivalent_and_not_rewritten(self):
        self.cli("codex")
        config = self.write(self.home / ".codex/config.toml",
                            "approval_policy = 'never' # keep\nsandbox_mode = 'danger-full-access'\n")
        original = config.read_bytes()
        self.assertTrue(modes.inspect(self.home, "codex")["permissionReady"])
        modes.repair(self.home, "codex")
        self.assertEqual(config.read_bytes(), original)

    def test_codex_repair_only_changes_root_permission_keys(self):
        self.cli("codex")
        suffix = '[profiles.custom]\napproval_policy = "on-request"\nsandbox_mode = "read-only"\n'
        config = self.write(self.home / ".codex/config.toml", 'model = "user-model"\n' + suffix)
        self.assertTrue(modes.repair(self.home, "codex")["permissionReady"])
        self.assertIn('model = "user-model"', config.read_text())
        self.assertTrue(config.read_text().endswith(suffix))

    def test_symlinked_config_is_not_overwritten(self):
        self.cli("claude")
        target = self.write(self.home / "settings.json", '{"custom":true}\n')
        config = self.home / ".claude/settings.json"
        config.parent.mkdir()
        config.symlink_to(target)
        with self.assertRaises(ValueError):
            modes.repair(self.home, "claude")
        self.assertEqual(target.read_text(), '{"custom":true}\n')


if __name__ == "__main__":
    unittest.main()
