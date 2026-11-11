#!/usr/bin/env python3
"""Versioned danger-list updates use mock responses, never execute shell commands."""
from concurrent.futures import ThreadPoolExecutor, TimeoutError
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import threading
from unittest import mock

SOURCE = Path(__file__).resolve().parents[1] / "AgentGuard"
sys.path.insert(0, str(SOURCE))
import core
import manage
import policy_update
import rules


def encoded(version, block=None, warn=None, rm=None):
    return json.dumps({"version": version, "block": block if block is not None else rules.BLOCK,
                       "warn": warn if warn is not None else rules.WARN,
                       "rm": rm if rm is not None else rules.BUNDLED_POLICY["rm"]}, ensure_ascii=False).encode()


def codex_decision(home, command):
    payload = {"tool_name": "Bash", "tool_input": {"command": command}, "cwd": str(home)}
    result = subprocess.run([sys.executable, "-B", str(SOURCE / "danger-guard-codex.py"), "PermissionRequest"],
                            input=json.dumps(payload), capture_output=True, text=True, timeout=5,
                            env={**os.environ, "HOME": str(home), "DANGER_GUARD_SILENT": "1"})
    assert result.returncode == 0, result.stderr
    return json.loads(result.stdout)["hookSpecificOutput"]["decision"]["behavior"]


initial = rules.validate_policy((SOURCE / "danger-policy.json").read_bytes())
assert initial == rules.BUNDLED_POLICY
base = rules.BUILTIN_VERSION

with tempfile.TemporaryDirectory(prefix="termyes-policy-") as temp:
    home = Path(temp).resolve()
    with mock.patch.dict(os.environ, {"HOME": str(home)}):
        assert core.classify("shutdown", str(home))[0] == "block"
        assert core.classify("echo hello", str(home))[0] == "safe"
        version, message, failed = policy_update.check(
            home, manage.atomic_write, now=10000, fetch=lambda: encoded(base + 1, [[r"\bmkfs\b", "disk"]], []))
        assert version == base + 1 and not failed, message
        assert core.classify("shutdown", str(home))[0] == "safe"
        assert core.classify("mkfs", str(home))[0] == "block"
        assert core.classify("rm -rf /", str(home))[0] == "block"
        assert codex_decision(home, "shutdown") == "allow"
        assert codex_decision(home, "mkfs") == "deny"

        def should_not_fetch():
            raise AssertionError("same interval should not fetch")

        policy_update.check(home, manage.atomic_write, now=10001, fetch=should_not_fetch)
        policy_update.check(home, manage.atomic_write, now=17200, fetch=lambda: encoded(base))
        assert policy_update.status(home)[0] == base + 1
        assert core.classify("shutdown", str(home))[0] == "safe"
        policy_update.check(home, manage.atomic_write, now=24400, fetch=lambda: encoded(base + 1))
        assert policy_update.status(home)[0] == base + 1

        invalid = [encoded(base + 2, [["(", "bad regex"]], []), encoded(base + 2, [], []),
                   encoded(True), b"{" * (rules.MAX_POLICY_BYTES + 1),
                   json.dumps({"version": 3, "block": [], "warn": [], "code": "x"}).encode()]
        for value in invalid:
            version, message, failed = policy_update.check(home, manage.atomic_write, force=True,
                                                            fetch=lambda value=value: value)
            assert version == base + 1 and failed, message
            assert core.classify("mkfs", str(home))[0] == "block"

        def offline():
            raise OSError("offline")

        version, message, failed = policy_update.check(home, manage.atomic_write, force=True, fetch=offline)
        assert version == base + 1 and failed and "offline" in message
        version, message, failed = policy_update.check(
            home, manage.atomic_write, force=True,
            fetch=lambda: encoded(base + 2, [[r"\bmkfs\b", "disk"]], [[r"\bshutdown\b", "shutdown"]]))
        assert version == base + 2 and not failed, message
        assert core.classify("shutdown", str(home))[0] == "block"
        assert core.classify("echo hello", str(home))[0] == "safe"

        rules.policy_path(home).write_text("broken")
        version, message, failed = policy_update.status(home)
        assert version == base and failed and "本地缓存无效" in message
        assert core.classify("shutdown", str(home))[0] == "block"
        version, message, failed = policy_update.check(
            home, manage.atomic_write, force=True, fetch=lambda: encoded(base + 3, [[r"\bmkfs\b", "disk"]], []))
        assert version == base + 3 and not failed, message
        assert core.classify("shutdown", str(home))[0] == "safe"

        # The current JSON, including rm rules, is the only decision source.
        rm = {**rules.BUNDLED_POLICY["rm"], "block": [], "warn": []}
        policy_update.check(home, manage.atomic_write, force=True,
                            fetch=lambda: encoded(base + 4, [[r"\bmkfs\b", "disk"]], [], rm))
        assert core.classify("rm -rf /", str(home))[0] == "safe"
        assert core.classify("rm -rf $UNKNOWN", str(home))[0] == "safe"
        assert core.classify("git reset --hard", str(home))[0] == "safe"
        assert core.classify("mkfs", str(home))[0] == "block"
        rm["block"] = ["root"]
        policy_update.check(home, manage.atomic_write, force=True,
                            fetch=lambda: encoded(base + 5, [[r"\bmkfs\b", "disk"]], [], rm))
        assert core.classify("rm -rf /", str(home))[0] == "block"
        assert core.classify("rm -rf /tmp/smNps", str(home))[0] == "safe"
        assert core.classify("rm -rf cache*", str(home))[0] == "safe"
        assert core.classify("rm -rf ./cache*", str(home))[0] == "safe"
        assert codex_decision(home, "rm -rf /tmp/smNps") == "allow"
        assert codex_decision(home, "rm -rf /") == "deny"
        for rm_change in ({"block": ["not-a-category"]}, {"temporaryRoots": ["/"]},
                          {"warn": ["root"]}, {"warnReason": ""}):
            try:
                rules.validate_policy(encoded(base + 6, rm={**rm, **rm_change}))
            except ValueError:
                pass
            else:
                raise AssertionError("invalid rm rule accepted")

def test_concurrent_policy_updates_cannot_downgrade():
    with tempfile.TemporaryDirectory(prefix="termyes-policy-concurrent-") as temp:
        home = Path(temp).resolve()
        older_ready = threading.Event()
        newer_started = threading.Event()
        release_older = threading.Event()
        older_version = rules.BUILTIN_VERSION + 1
        newer_version = older_version + 1

        def paused_write(path, content, mode=0o600):
            if path == rules.policy_path(home) and json.loads(content)["version"] == older_version:
                older_ready.set()
                assert release_older.wait(5), "older update was not released"
            manage.atomic_write(path, content, mode)

        def update_newer():
            newer_started.set()
            return policy_update.check(home, paused_write, force=True, fetch=lambda: encoded(newer_version))

        with mock.patch.dict(os.environ, {"HOME": str(home)}), ThreadPoolExecutor(max_workers=2) as pool:
            older = pool.submit(policy_update.check, home, paused_write,
                                force=True, fetch=lambda: encoded(older_version))
            try:
                assert older_ready.wait(5), "older update never reached its write"
                newer = pool.submit(update_newer)
                assert newer_started.wait(5), "newer update never started"
                try:
                    newer.result(timeout=0.2)
                except TimeoutError:
                    pass  # A serialized update waits until the old writer commits.
            finally:
                release_older.set()
            older.result(timeout=5)
            result = newer.result(timeout=5)
        assert result[0] == newer_version and not result[2], result
        assert rules.active_policy(home)[0]["version"] == newer_version, "concurrent older write downgraded policy"
        assert json.loads(rules.policy_path(home).read_bytes())["version"] == newer_version


test_concurrent_policy_updates_cannot_downgrade()
print("danger policy updates: pass")
