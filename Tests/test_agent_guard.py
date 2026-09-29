#!/usr/bin/env python3
"""Local classification/protocol/migration checks; never run the command strings or an agent."""
import fcntl
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "AgentGuard"
sys.path.insert(0, str(SOURCE))
import core
import manage

ENV = dict(
    os.environ,
    PYTHONDONTWRITEBYTECODE="1",
    DANGER_GUARD_SILENT="1",
    DANGER_GUARD_ASK="0",
    TERMOSAIC_AI_REVIEW_DISABLE="1",
)
checks = 0


def check(condition, message):
    global checks
    assert condition, message
    checks += 1


def payload(client, command="git reset --hard HEAD"):
    if client == "agy":
        return {"toolCall": {"name": "run_command", "args": {"CommandLine": command, "Cwd": str(ROOT)}}}
    if client in ("pi", "opencode", "cursor"):
        return {"command": command, "cwd": str(ROOT)}
    name = "bash" if client == "crush" else "run_shell_command" if client == "gemini" else "Execute" if client == "droid" else "Bash"
    return {"tool_name": name, "tool_input": {"command": command}, "cwd": str(ROOT)}


def hook(client, data, source=SOURCE, event=None):
    adapter = manage.CLIENTS[client][3]
    result = subprocess.run([sys.executable, "-B", str(source / adapter)] + ([event] if event else []),
                            input=data if isinstance(data, str) else json.dumps(data), text=True,
                            capture_output=True, env=ENV, timeout=5)
    check(result.returncode == 0, client + " protocol process: " + result.stderr)
    return json.loads(result.stdout) if result.stdout.strip() else None


def denied(output):
    if not output:
        return False
    specific = output.get("hookSpecificOutput", {})
    return (output.get("decision") == "deny" or output.get("permission") == "deny"
            or output.get("permissionDecision") == "deny" or output.get("level") == "block"
            or specific.get("permissionDecision") == "deny"
            or specific.get("decision", {}).get("behavior") == "deny")


# A safe nested deletion must never mask a warning elsewhere in the command.
for command in (
    "bash -c 'rm -rf ~/repo' && bash -c 'rm -rf /tmp/termosaic-example'",
    "bash -c 'rm -rf /tmp/termosaic-example' && bash -c 'rm -rf ~/repo'",
    "rm -rf $UNSET_DIR; bash -c 'rm -rf /tmp/termosaic-example'",
    "bash -c 'rm -rf /tmp/termosaic-example'; rm -rf $UNSET_DIR",
    "bash -c 'rm -rf /tmp/termosaic-example'; eval 'rm -rf $UNSET_DIR'",
):
    check(core.classify(command, str(ROOT))[0] == "block", "mixed wrapper command must deny")
for command in (
    "bash -c 'rm -rf /tmp/termosaic-example'",
    "bash -c 'rm -rf /tmp/termosaic-example'; bash -c 'rm -rf /tmp/termosaic-example2'",
    """/bin/zsh -c '. /tmp/snapshot && eval "rm -rf node_modules"'""",
):
    check(core.classify(command, str(ROOT))[0] == "safe", "safe wrappers retain normal behavior")

for client in manage.CLIENTS:
    for command in ("git reset --hard HEAD", "rm -rf /", "npm publish", 'echo "unterminated'):
        check(denied(hook(client, payload(client, command))), client + " must deny " + command)
    for invalid in ("{bad-json", "[]", "null", "{}", payload(client, "")):
        check(denied(hook(client, invalid)), client + " invalid payload must deny")
    safe = hook(client, payload(client, "git status"))
    check(safe is None or safe.get("level") == "safe", client + " must not auto-approve a native permission")
    with tempfile.TemporaryDirectory(prefix="termosaic-missing-core-") as tmp:
        target = Path(tmp)
        shutil.copy2(SOURCE / manage.CLIENTS[client][3], target)
        check(denied(hook(client, payload(client), source=target)), client + " missing core must deny")

check(denied(hook("codex", "bad-json", event="PermissionRequest")), "Codex error channel")
check(hook("codex", payload("codex", "git status"), event="PermissionRequest") is None, "Unverified Codex must not grant permission")
check(core.classify("git reset --hard HEAD", str(ROOT), bypass=False)[0] == "block", "Bypass flag cannot weaken policy")
check(core.classify("git reset --hard HEAD", str(ROOT), bypass=True)[0] == "block", "YOLO still blocks")
check(denied(hook("codex", payload("codex", ["sh", "-c", "rm -rf /"]))), "argv quoting retains shell payload")

for client in manage.CLIENTS:
    with tempfile.TemporaryDirectory(prefix="termosaic-install-") as tmp:
        home = Path(tmp).resolve() / "home with spaces"
        home.mkdir()
        root, config, runtime, adapter = manage.locations(home, client)
        originals = {}
        # Keep a real unrelated hook and an unrelated permission setting in every JSON config.
        if config:
            config.parent.mkdir(parents=True, exist_ok=True)
            config.write_text(json.dumps({"custom": {"keep": "untouched"}, "permissions": {"defaultMode": "default"}}))
            originals[config] = config.read_bytes()
        if client in ("pi", "opencode"):
            name = "bypass-yes-guard.ts" if client == "pi" else "bypass-yes-opencode.js"
            old = root / ("extensions" if client == "pi" else "plugin") / name
            old.parent.mkdir(parents=True, exist_ok=True)
            old.write_text("// existing bypass-yes plugin\n")
            originals[old] = old.read_bytes()
        manage.install(home, client)
        first = {p: p.read_bytes() for p in home.rglob("*") if p.is_file()}
        check((runtime / adapter).is_file(), client + " copied standalone adapter")
        check(denied(hook(client, payload(client), source=runtime)), client + " installed standalone adapter denies")
        check(manage.receipt_path(home, client).stat().st_mode & 0o777 == 0o600, client + " private backup mode")
        if config:
            value = json.loads(config.read_bytes())
            check(value["custom"]["keep"] == "untouched", client + " preserves config")
            check(value["permissions"]["defaultMode"] == "default", client + " no YOLO setting")
        manage.install(home, client)
        check(first == {p: p.read_bytes() for p in home.rglob("*") if p.is_file()}, client + " idempotent bytes and receipt")
        result = subprocess.run([sys.executable, "-B", str(SOURCE / "manage.py"), "enable-yolo", client, "--home", str(home)], capture_output=True, env=ENV)
        check(result.returncode != 0, client + " capability gate cannot be bypassed")
        check(first == {p: p.read_bytes() for p in home.rglob("*") if p.is_file()}, client + " rejected YOLO writes nothing")
        (runtime / "rules.py").write_text("# external edit\n")
        try:
            manage.uninstall(home, client)
        except ValueError:
            pass
        else:
            raise AssertionError(client + " must not overwrite user edits during restore")
        check((runtime / "rules.py").read_text() == "# external edit\n", client + " protects edits")
        (runtime / "rules.py").write_bytes(first[runtime / "rules.py"])
        manage.uninstall(home, client)
        remaining = {p: p.read_bytes() for p in home.rglob("*") if p.is_file()}
        check(remaining == originals, client + " exact restore without deleting unrelated files")

# Mixed legacy group: replacing our old hook must retain the user's other subhook.
with tempfile.TemporaryDirectory(prefix="termosaic-merge-") as tmp:
    home = Path(tmp).resolve()
    root, config, runtime, adapter = manage.locations(home, "claude")
    root.mkdir()
    other = {"type": "command", "command": "echo my-own-audit"}
    config.write_text(json.dumps({"hooks": {"PreToolUse": [{"matcher": "Bash", "hooks": [
        {"type": "command", "command": "/usr/bin/python3 " + str(root / "hooks" / adapter)}, other]}]}}))
    original = config.read_bytes()
    manage.install(home, "claude")
    groups = json.loads(config.read_bytes())["hooks"]["PreToolUse"]
    check(any(other in g["hooks"] for g in groups), "mixed custom hook preserved")
    manage.uninstall(home, "claude")
    check(config.read_bytes() == original, "original config bytes restored")
    config.write_text("{broken")
    try:
        manage.install(home, "claude")
    except ValueError:
        pass
    else:
        raise AssertionError("Invalid config must fail before installing")
    check(not runtime.exists() or not any(runtime.iterdir()), "invalid config created no runtime files")
    check(config.read_text() == "{broken", "invalid config never replaced")
    config.unlink()
    outside = home / "untouched.json"
    outside.write_text("{}")
    config.symlink_to(outside)
    try:
        manage.install(home, "claude")
    except ValueError:
        pass
    else:
        raise AssertionError("Symlink config must not be overwritten")
    check(outside.read_text() == "{}", "symlink target untouched")

# A mid-transaction write failure restores every already-written file.
with tempfile.TemporaryDirectory(prefix="termosaic-rollback-") as tmp:
    home = Path(tmp).resolve()
    real_write = manage.atomic_write
    calls = 0
    def fail_once(path, content, mode=0o600):
        global calls
        calls += 1
        if calls == 3:
            raise OSError("simulated write failure")
        return real_write(path, content, mode)
    manage.atomic_write = fail_once
    try:
        try:
            manage.install(home, "claude")
        except OSError:
            pass
        else:
            raise AssertionError("Expected write failure")
    finally:
        manage.atomic_write = real_write
    check(not any(p.is_file() for p in home.rglob("*")), "failed installation rolled back")

# Receipt shape and concurrent CLI mutation must not permit arbitrary file writes.
with tempfile.TemporaryDirectory(prefix="termosaic-lock-") as tmp:
    home = Path(tmp).resolve()
    lock = manage.receipt_path(home, "claude").parent / ".install.lock"
    lock.parent.mkdir(parents=True)
    with lock.open("w") as locked:
        fcntl.flock(locked, fcntl.LOCK_EX | fcntl.LOCK_NB)
        result = subprocess.run([sys.executable, "-B", str(SOURCE / "manage.py"), "install", "claude", "--home", str(home)],
                                capture_output=True, env=ENV, timeout=5)
        check(result.returncode != 0, "concurrent CLI install rejected")
        check(not (home / ".claude").exists(), "locked installer wrote no config/runtime")

with tempfile.TemporaryDirectory(prefix="termosaic-forged-receipt-") as tmp:
    home = Path(tmp).resolve()
    manage.install(home, "claude")
    receipt = manage.receipt_path(home, "claude")
    record = json.loads(receipt.read_bytes())
    outside = home / "unrelated"
    outside.write_text("keep me")
    record["before"][str(outside)] = None
    record["installed"][str(outside)] = manage.read_file(outside)
    receipt.write_text(json.dumps(record))
    try:
        manage.uninstall(home, "claude")
    except ValueError:
        pass
    else:
        raise AssertionError("Forged extra restore target must be rejected")
    check(outside.read_text() == "keep me", "receipt cannot add unrelated restore targets")

bad_permission = {**payload("codex", ""), "hook_event_name": "PermissionRequest"}
check(hook("codex", bad_permission)["hookSpecificOutput"]["hookEventName"] == "PermissionRequest",
      "stdin-only Codex error retains permission channel")
with tempfile.TemporaryDirectory(prefix="termosaic-event-error-") as tmp:
    target = Path(tmp)
    shutil.copy2(SOURCE / "danger-guard-codex.py", target)
    output = hook("codex", {**payload("codex"), "hook_event_name": "PermissionRequest"}, source=target)
    check(output["hookSpecificOutput"]["decision"]["behavior"] == "deny", "missing core retains permission channel")

print(f"Agent guard checks passed: {checks}; 13 adapters; real client/YOLO validation NOT performed.")
