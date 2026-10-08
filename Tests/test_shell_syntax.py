#!/usr/bin/env python3
"""Shell syntax regressions: classify text only, never execute shell commands."""

import importlib.util
import os
from pathlib import Path
import sys
import unittest
from unittest import mock


ROOT = Path(__file__).resolve().parents[1]
GUARD = Path(os.environ.get("TERMYES_SHELL_SYNTAX_DIR", ROOT / "AgentGuard"))


def load_module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


rules = load_module("shell_syntax_rules", GUARD / "rules.py")
with mock.patch.dict(sys.modules, {"rules": rules}):
    core = load_module("shell_syntax_core", GUARD / "core.py")


class ShellSyntaxTests(unittest.TestCase):
    def setUp(self):
        # Use only bundled policy and disable the private probe receipt mechanism.
        for patch in (
            mock.patch.object(rules, "active_policy", return_value=(rules.BUNDLED_POLICY, None)),
            mock.patch.object(core, "_guard_probe", return_value=False),
            mock.patch.object(core.subprocess, "Popen", side_effect=AssertionError("no process launch")),
            mock.patch.object(core.subprocess, "run", side_effect=AssertionError("no process launch")),
        ):
            patch.start()
            self.addCleanup(patch.stop)

    def assert_level(self, commands, expected):
        for command in commands:
            with self.subTest(command=command):
                self.assertEqual(core.classify(command, str(ROOT))[0], expected)

    def test_apostrophes_and_unclosed_syntax_in_comments_are_data(self):
        self.assert_level([
            "printf '%s\\n' ok # user's comment",
            'printf ok # unmatched " $( `',
        ], "safe")

    def test_reboot_in_comments_is_not_executable(self):
        self.assert_level([
            "printf ok # reboot",
            "# reboot; user's comment\nprintf ok",
            "printf ok;# reboot",
            "bash -c 'printf ok # reboot'",
            "bash -c $'printf ok # reboot'",
        ], "safe")

    def test_ansi_c_escaped_quotes_do_not_expose_data(self):
        self.assert_level([
            r"printf '%s\n' $'can\'t'",
            r"printf '%s\n' $'can\'t reboot'",
            r"printf '%s\n' $'backslash\\' # reboot",
        ], "safe")

    def test_ansi_c_quote_inside_command_substitution(self):
        self.assert_level([
            r'''printf %s "$(printf %s $'can\'t')"''',
        ], "safe")

    def test_hash_inside_words_quotes_and_escapes_is_not_a_comment(self):
        self.assert_level([
            "printf '%s\\n' 'user#reboot'",
            'printf "%s\\n" "user#reboot"',
            r"printf foo\#bar # reboot",
        ], "safe")
        self.assert_level([
            "printf foo#bar; reboot",
            r"printf \#bar; reboot",
            "printf ''#bar; reboot",
        ], "block")

    def test_real_danger_remains_blocked(self):
        self.assert_level([
            "reboot # user's comment",
            "printf ok # user's comment\nreboot",
            r"printf %s $'can\'t'; reboot",
            "printf '%s\\n' '# comment'; reboot",
            "bash -c 'printf ok # comment\nreboot'",
            r"bash -c $'printf ok # comment\nreboot'",
            r'''bash -c $'printf "%s" "can\'t"; reboot' ''',
            r"eval $'re\x62oot'",
        ], "block")

    def test_comment_mask_preserves_offsets_and_newlines(self):
        command = "printf ok # user's reboot comment\nprintf next"
        masked = core.strip_shell_comments(command)
        self.assertEqual(len(masked), len(command))
        self.assertEqual(masked.index("\n"), command.index("\n"))
        self.assertTrue(masked.endswith("\nprintf next"))

    def test_unclosed_quotes_and_substitutions_remain_blocked(self):
        self.assert_level([
            "printf 'unterminated",
            'printf "unterminated',
            "printf $'unterminated",
            r"printf $'escaped\'",
            "printf $(printf 'unterminated)",
            "printf $'unclosed # comment",
        ], "block")


if __name__ == "__main__":
    unittest.main()
