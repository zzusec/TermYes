#!/usr/bin/env python3
"""Codex token repair must never authorize a dangerous command or reshape argv."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

HOOK = Path(__file__).resolve().parents[1] / "AgentGuard/danger-guard-codex.py"
TOKEN = "<｜deepseek_image｜>"


class CodexTokenGuardTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="termyes-token-test-")
        self.addCleanup(temporary.cleanup)
        self.home = Path(temporary.name).resolve()
        self.environment = dict(os.environ, HOME=str(self.home), DANGER_GUARD_SILENT="1",
                                TOXIC_GUARD_LOG=str(self.home / "token.log"), PYTHONDONTWRITEBYTECODE="1")
        self.environment.pop("TOXIC_GUARD_DISABLE", None)

    def hook(self, command, event="PreToolUse", extra=None):
        payload = {"tool_name": "shell", "cwd": str(self.home),
                   "tool_input": {"command": command, **(extra or {})}}
        result = subprocess.run([sys.executable, "-I", "-B", str(HOOK), event],
                                input=json.dumps(payload), capture_output=True, text=True,
                                env=self.environment, timeout=5)
        self.assertEqual(result.returncode, 0, result.stderr)
        return json.loads(result.stdout)["hookSpecificOutput"] if result.stdout.strip() else None

    def test_toxic_token_does_not_bypass_pretooluse_policy(self):
        result = self.hook('git reset --hard HEAD; printf "%s\\n" "' + TOKEN + '"')
        self.assertEqual(result["permissionDecision"], "deny")
        self.assertNotIn("updatedInput", result)

    def test_toxic_token_does_not_bypass_permissionrequest_policy(self):
        result = self.hook('git reset --hard HEAD; printf "%s\\n" "' + TOKEN + '"', "PermissionRequest")
        self.assertEqual(result["decision"]["behavior"], "deny")

    def test_danger_in_shell_argv_is_also_blocked(self):
        result = self.hook(["/bin/zsh", "-lc", 'git reset --hard HEAD; printf %s "' + TOKEN + '"'])
        self.assertEqual(result["permissionDecision"], "deny")

    def test_safe_rewrite_preserves_other_tool_parameters(self):
        result = self.hook('printf %s "' + TOKEN + '"', extra={"timeout_ms": 2500, "workdir": str(self.home)})
        self.assertEqual(result["permissionDecision"], "allow")
        self.assertEqual(result["updatedInput"], {
            "command": 'printf %s "<deepseek_image>"',
            "timeout_ms": 2500, "workdir": str(self.home),
        })

    def test_safe_rewrite_preserves_argv_shape(self):
        result = self.hook(["/usr/bin/printf", "%s", TOKEN])
        self.assertEqual(result["updatedInput"]["command"], ["/usr/bin/printf", "%s", "<deepseek_image>"])

    def test_unmodified_safe_command_stays_silent(self):
        self.assertIsNone(self.hook("git status"))


if __name__ == "__main__":
    unittest.main()
