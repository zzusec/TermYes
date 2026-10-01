#!/usr/bin/env python3
"""Versioned danger-list updates use mock responses, never execute shell commands."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
from unittest import mock

SOURCE = Path(__file__).resolve().parents[1] / "AgentGuard"
sys.path.insert(0, str(SOURCE))
import core
import manage
import policy_update
import rules


def encoded(version, block=None, warn=None):
    return json.dumps({"version": version, "block": block if block is not None else rules.BLOCK,
                       "warn": warn if warn is not None else rules.WARN}, ensure_ascii=False).encode()


def codex_decision(home, command):
    payload = {"tool_name": "Bash", "tool_input": {"command": command}, "cwd": str(home)}
    result = subprocess.run([sys.executable, "-B", str(SOURCE / "danger-guard-codex.py"), "PermissionRequest"],
                            input=json.dumps(payload), capture_output=True, text=True, timeout=5,
                            env={**os.environ, "HOME": str(home), "DANGER_GUARD_SILENT": "1"})
    assert result.returncode == 0, result.stderr
    return json.loads(result.stdout)["hookSpecificOutput"]["decision"]["behavior"]


initial = rules.validate_policy((SOURCE / "danger-policy.json").read_bytes())
assert initial["version"] > rules.BUILTIN_VERSION

with tempfile.TemporaryDirectory(prefix="termyes-policy-") as temp:
    home = Path(temp).resolve()
    with mock.patch.dict(os.environ, {"HOME": str(home)}):
        assert core.classify("shutdown", str(home))[0] == "block"
        assert core.classify("echo hello", str(home))[0] == "safe"
        version, message, failed = policy_update.check(
            home, manage.atomic_write, now=10000, fetch=lambda: encoded(2, [[r"\bmkfs\b", "disk"]], []))
        assert version == 2 and not failed, message
        assert core.classify("shutdown", str(home))[0] == "safe"
        assert core.classify("mkfs", str(home))[0] == "block"
        assert core.classify("rm -rf /", str(home))[0] == "block"
        assert codex_decision(home, "shutdown") == "allow"
        assert codex_decision(home, "mkfs") == "deny"

        def should_not_fetch():
            raise AssertionError("same interval should not fetch")

        policy_update.check(home, manage.atomic_write, now=10001, fetch=should_not_fetch)
        policy_update.check(home, manage.atomic_write, now=17200, fetch=lambda: encoded(1))
        assert policy_update.status(home)[0] == 2
        assert core.classify("shutdown", str(home))[0] == "safe"
        policy_update.check(home, manage.atomic_write, now=24400, fetch=lambda: encoded(2))
        assert policy_update.status(home)[0] == 2

        invalid = [encoded(3, [["(", "bad regex"]], []), encoded(3, [], []),
                   encoded(True), b"{" * (rules.MAX_POLICY_BYTES + 1),
                   json.dumps({"version": 3, "block": [], "warn": [], "code": "x"}).encode()]
        for value in invalid:
            version, message, failed = policy_update.check(home, manage.atomic_write, force=True,
                                                            fetch=lambda value=value: value)
            assert version == 2 and failed, message
            assert core.classify("mkfs", str(home))[0] == "block"

        def offline():
            raise OSError("offline")

        version, message, failed = policy_update.check(home, manage.atomic_write, force=True, fetch=offline)
        assert version == 2 and failed and "offline" in message
        version, message, failed = policy_update.check(
            home, manage.atomic_write, force=True,
            fetch=lambda: encoded(3, [[r"\bmkfs\b", "disk"]], [[r"\bshutdown\b", "shutdown"]]))
        assert version == 3 and not failed, message
        assert core.classify("shutdown", str(home))[0] == "block"
        assert core.classify("echo hello", str(home))[0] == "safe"

        rules.policy_path(home).write_text("broken")
        version, message, failed = policy_update.status(home)
        assert version == 1 and failed and "本地缓存无效" in message
        assert core.classify("shutdown", str(home))[0] == "block"
        version, message, failed = policy_update.check(
            home, manage.atomic_write, force=True, fetch=lambda: encoded(4, [[r"\bmkfs\b", "disk"]], []))
        assert version == 4 and not failed, message
        assert core.classify("shutdown", str(home))[0] == "safe"

print("danger policy updates: pass")
