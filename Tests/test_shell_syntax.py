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

    def test_executable_arguments_are_not_masked_as_data(self):
        self.assert_level([
            "rm '-rf' ~",
            "'rm' -rf /etc",
            "git reset '--hard' HEAD",
            "git 'reset' --hard HEAD",
            'dd if=/dev/zero of="/dev/disk2"',
            "chmod '-R' 777 '/etc'",
        ], "block")
        self.assert_level([
            "printf '%s\\n' 'rm -rf ~'",
            "printf '%s\\n' 'git reset --hard HEAD'",
            "printf '%s\\n' 'dd if=/dev/zero of=/dev/disk2'",
            "git commit -m 'reset --hard reboot'",
            "grep 'reboot' notes.txt",
        ], "safe")

    def test_shell_options_and_nested_data(self):
        self.assert_level([
            "bash -lc 'git reset --hard HEAD'",
            "/bin/zsh -ilc 'git reset --hard HEAD'",
            "sudo bash -lc 'git reset --hard HEAD'",
            "eval 'git reset --hard HEAD'",
        ], "block")
        self.assert_level([
            "printf '%s\\n' 'bash -lc \"git reset --hard HEAD\"'",
            "printf '%s\\n' 'bash -c \"git reset --hard HEAD\"'",
            "bash -lc 'printf %s \"git reset --hard HEAD\"'",
            "bash -lc 'rm -rf /tmp/termyes-safe'",
        ], "safe")

    def test_executable_substitutions_not_literal_examples(self):
        self.assert_level([
            'printf "%s\\n" "$(git reset --hard HEAD)"',
            'printf "%s\\n" "`git reset --hard HEAD`"',
            'printf %s $(git reset --hard HEAD)',
            'printf %s "$(rm -rf /etc)"',
        ], "block")
        self.assert_level([
            "printf '%s\\n' '$(git reset --hard HEAD)'",
            r'printf "%s\n" "\$(git reset --hard HEAD)"',
            'printf "%s\\n" "$(printf %s \'reboot\')"',
        ], "safe")

    def test_heredoc_shell_executes_quoted_body_but_cat_does_not(self):
        self.assert_level([
            "bash <<'EOF'\ngit reset --hard HEAD\nEOF",
            "sudo /bin/zsh <<'EOF'\nrm -rf /etc\nEOF",
        ], "block")
        self.assert_level([
            "cat <<'EOF'\ngit reset --hard HEAD\nEOF",
            "bash <<'EOF'\nprintf '%s\\n' 'git reset --hard HEAD'\nEOF",
            "bash <<'EOF'\nrm -rf /tmp/termyes-safe\nEOF",
        ], "safe")

    def test_safe_rm_cannot_mask_wrapped_danger(self):
        self.assert_level([
            "rm -rf /tmp/termyes-safe; bash -c 'rm -rf /etc'",
            "rm -rf /tmp/termyes-safe; sudo rm -rf /etc/guard-victim",
            "rm -rf /tmp/termyes-safe; /bin/rm -rf /etc/guard-victim",
            "rm -rf /tmp/termyes-safe; env X=1 rm -rf /etc",
        ], "block")
        self.assert_level([
            "rm -rf /tmp/termyes-a; bash -c 'rm -rf /tmp/termyes-b'",
            "rm -rf /tmp/termyes-a; sudo rm -rf /tmp/termyes-b",
        ], "safe")

    def test_unparsed_compound_deletion_keeps_conservative_protection(self):
        self.assert_level([
            "(rm -rf /etc)",
            "{ rm -rf /etc; }",
            "if true; then rm -rf /etc; fi",
            'for target in /etc; do rm -rf "$target"; done',
            "rm -rf /tmp/termyes-safe; (rm -rf /etc)",
        ], "block")

    def test_cd_affects_later_relative_deletion(self):
        self.assert_level([
            "cd /; rm -rf etc",
            "cd / && rm -rf etc",
            "cd /etc; rm -rf guard-victim",
            "cd \"$UNKNOWN\"; rm -rf relative",
            "env --chdir=/ rm -rf etc",
            "sudo --chdir=/ rm -rf etc",
        ], "block")
        self.assert_level([
            "cd /tmp && rm -rf /tmp/termyes-safe",
            "cd /tmp; rm -rf termyes-safe",
        ], "safe")

    def test_command_environment_does_not_replace_shell_variable(self):
        self.assert_level([
            'D=/etc; D=/tmp/termyes-safe true; rm -rf "$D"',
            'D=/etc; D=/tmp/termyes-safe rm -rf "$D"',
        ], "block")
        self.assert_level([
            'D=/tmp/termyes-safe; rm -rf "$D"',
            'export D=/tmp/termyes-safe; rm -rf "$D"',
            'D=/tmp/termyes-safe; D=/etc true; rm -rf "$D"',
        ], "safe")

    def test_home_operand_uses_home_policy_even_when_unknown_is_allowed(self):
        policy = {**rules.BUNDLED_POLICY, "rm": {**rules.BUNDLED_POLICY["rm"], "block": ["home"], "warn": []}}
        with mock.patch.object(rules, "active_policy", return_value=(policy, None)):
            self.assert_level(['rm -rf "$HOME"', 'rm -rf ${HOME}', 'rm -rf ~'], "block")
            self.assert_level(['rm -rf "$UNSET"'], "safe")

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
