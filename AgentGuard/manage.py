#!/usr/bin/env python3
"""Install shell guards and reconcile supported agents to YOLO-equivalent modes."""
import argparse
import base64
import fcntl
import json
import os
from pathlib import Path
import shlex
import stat
import sys
import tempfile

import permission_modes

SOURCE = Path(__file__).resolve().parent

CLIENTS = {
    "claude": ("Claude Code", ".claude", "settings.json", "danger-guard.py"),
    "codex": ("Codex", ".codex", "hooks.json", "danger-guard-codex.py"),
    "codebuddy": ("CodeBuddy", ".codebuddy", "settings.json", "danger-guard.py"),
    "zcode": ("zcode", ".zcode/cli", "setting.json", "danger-guard.py"),
    "pi": ("pi", ".pi/agent", None, "danger-guard-pi.py"),
    "qoder": ("Qoder", ".qoder", "settings.json", "danger-guard.py"),
    "gemini": ("Gemini CLI", ".gemini", "settings.json", "danger-guard-gemini.py"),
    "cursor": ("Cursor", ".cursor", "hooks.json", "danger-guard-cursor.py"),
    "agy": ("agy", ".gemini", "config/hooks.json", "danger-guard-agy.py"),
    "opencode": ("OpenCode", ".config/opencode", None, "danger-guard-pi.py"),
    "droid": ("Factory droid", ".factory", "hooks.json", "danger-guard.py"),
    "crush": ("Crush", ".config/crush", "crush.json", "danger-guard-crush.py"),
    "copilot": ("GitHub Copilot", ".copilot", "hooks/bypass-yes.json", "danger-guard-copilot.py"),
}


def reason(client):
    if client == "pi":
        return "客户端本身不进行命令审批"
    return "启动时自动检测并修复 YOLO/等效免确认模式"


def mapping(value):
    if not isinstance(value, dict):
        raise ValueError("配置结构不是对象，已停止，原文件未覆盖")
    return value


def child(data, key):
    return mapping(data.setdefault(key, {}))


def checked_path(path):
    # Do not follow config/receipt symlinks into unrelated files.
    for p in (path, *path.parents):
        if p.is_symlink():
            raise ValueError("不自动修改符号链接：" + str(p))
    if path.exists() and not path.is_file():
        raise ValueError("目标不是普通文件：" + str(path))


def read_file(path):
    checked_path(path)
    if not path.exists():
        return None
    return {"data": base64.b64encode(path.read_bytes()).decode(),
            "mode": stat.S_IMODE(path.stat().st_mode)}


def atomic_write(path, content, mode=0o600):
    checked_path(path)
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    fd, name = tempfile.mkstemp(prefix=".termosaic-", dir=str(path.parent))
    try:
        with os.fdopen(fd, "wb") as f:
            f.write(content)
            f.flush()
            os.fsync(f.fileno())
        os.chmod(name, mode)
        os.replace(name, path)
    finally:
        if os.path.exists(name):
            os.unlink(name)


def restore_file(path, snapshot):
    if snapshot is None:
        checked_path(path)
        if path.exists():
            path.unlink()
    else:
        atomic_write(path, base64.b64decode(snapshot["data"], validate=True), snapshot["mode"])


def json_bytes(data):
    return (json.dumps(data, ensure_ascii=False, indent=2) + "\n").encode()


def locations(home, client):
    _, root, config, adapter = CLIENTS[client]
    root = home / root
    runtime = root / ("guard" if client == "pi" else "hooks") / "termosaic" / client
    return root, (root / config if config else None), runtime, adapter


def receipt_path(home, client):
    return home / "Library/Application Support/Termosaic/AgentGuard" / (client + ".json")


def owns(entry, paths):
    if not isinstance(entry, dict):
        raise ValueError("Hook 条目格式错误，未修改")
    if entry.get("exec"):
        args = [entry["exec"], *entry.get("args", [])]
    else:
        try:
            args = shlex.split(entry.get("command", ""))
        except (ValueError, TypeError):
            return False
    return (len(args) >= 2 and Path(args[0]).name in ("python", "python3")
            and args[1] in paths)


def merge_hooks(container, event, desired, paths, nested=True):
    entries = container.setdefault(event, [])
    if not isinstance(entries, list):
        raise ValueError("Hook 事件不是数组：" + event)
    updated = []
    inserted = False
    for entry in entries:
        mapping(entry)
        hooks = entry.get("hooks", []) if nested else [entry]
        if not isinstance(hooks, list):
            raise ValueError("Hook 列表格式错误")
        remaining = [h for h in hooks if not owns(h, paths)]
        if len(remaining) == len(hooks):
            updated.append(entry)
            continue
        if not inserted:
            # Preserve extra metadata when replacing a group consisting only of our hook.
            updated.append({**entry, **desired} if not remaining else desired)
            inserted = True
        if remaining:
            updated.append({**entry, "hooks": remaining})
    if not inserted:
        updated.append(desired)
    container[event] = updated


def desired_files(home, client):
    root, config, runtime, adapter = locations(home, client)
    files = {runtime / name: (SOURCE / name).read_bytes()
             for name in ("core.py", "rules.py", "ai_review.py", adapter, "chime.wav")}
    script = runtime / adapter
    legacy = root / ("guard" if client == "pi" else "hooks") / adapter
    paths = {str(script), str(legacy)}
    command = shlex.join(["/usr/bin/python3", str(script)])
    hook = {"type": "command", "command": command, "timeout": 10}
    if client in ("pi", "opencode"):
        name = "bypass-yes-guard.ts" if client == "pi" else "bypass-yes-opencode.js"
        folder = "extensions" if client == "pi" else "plugin"
        files[root / folder / name] = (SOURCE / name).read_bytes()
        return files
    checked_path(config)
    raw = config.read_bytes() if config.exists() else None
    data = mapping(json.loads(raw)) if raw is not None else {}
    before = json.dumps(data, sort_keys=True)
    if client == "agy":
        events = child(data, "bypass-yes")
        merge_hooks(events, "PreToolUse", {"matcher": "run_command", "hooks": [hook]}, paths)
    elif client == "copilot":
        data.setdefault("version", 1)
        direct = {"type": "command", "matcher": "Bash", "exec": "/usr/bin/python3",
                  "args": [str(script)], "timeoutSec": 10}
        merge_hooks(child(data, "hooks"), "PreToolUse", direct, paths, nested=False)
    elif client == "cursor":
        data.setdefault("version", 1)
        merge_hooks(child(data, "hooks"), "beforeShellExecution", {"command": command}, paths, nested=False)
    elif client == "crush":
        merge_hooks(child(data, "hooks"), "PreToolUse",
                    {"name": "bypass-yes", "matcher": "^bash$", "command": command, "timeout": 10}, paths, nested=False)
    else:
        events = data if client == "droid" else child(data, "hooks")
        if client == "zcode":
            events["enabled"] = True
            events = child(events, "events")
            hook.pop("timeout")
            hook["timeoutMs"] = 60000
        if client == "gemini":
            hook["timeout"] = 60000
            hook["name"] = "danger-guard"
        event = "BeforeTool" if client == "gemini" else "PreToolUse"
        matcher = "run_shell_command" if client == "gemini" else "Execute" if client == "droid" else "Bash"
        merge_hooks(events, event, {"matcher": matcher, "hooks": [hook]}, paths)
        if client == "codex":
            # A pending adapter may deny a PermissionRequest, never grant it automatically.
            for event in ("PreToolUse", "PermissionRequest"):
                native = {
                    **hook,
                    "command": command + " " + event,
                    "timeout": 30 if event == "PermissionRequest" else hook["timeout"],
                }
                merge_hooks(events, event, {"matcher": "Bash", "hooks": [native]}, paths)
    files[config] = raw if raw is not None and before == json.dumps(data, sort_keys=True) else json_bytes(data)
    return files


def install(home, client):
    permission_modes.repair(home, client)
    files = desired_files(home, client)  # Validate all config before writing anything.
    receipt = receipt_path(home, client)
    previous = read_file(receipt)
    old = mapping(json.loads(base64.b64decode(previous["data"]))) if previous else None
    snapshots = {str(p): read_file(p) for p in files}
    before = old["before"] if old else snapshots
    if old and set(before) != set(snapshots):
        raise ValueError("安装文件集合已变化；请先撤销旧安装")
    updated = {str(p): {"data": base64.b64encode(content).decode(),
                       "mode": snapshots[str(p)]["mode"] if snapshots[str(p)] else 0o600}
               for p, content in files.items()}
    # Refuse to overwrite a file edited since our last install; preserve user changes.
    if old and snapshots != old["installed"]:
        raise ValueError("安装后文件已被外部修改；未覆盖，请先检查配置")
    changed = []
    try:
        for p, content in files.items():
            key = str(p)
            if snapshots[key] != updated[key]:
                atomic_write(p, content, updated[key]["mode"])
                changed.append(p)
        payload = json_bytes({"client": client, "before": before, "installed": updated})
        if not previous or base64.b64decode(previous["data"]) != payload:
            atomic_write(receipt, payload)
    except Exception:
        for p in reversed(changed):
            restore_file(p, snapshots[str(p)])
        raise
    return "守卫已安装，Agent 权限模式已检测/修复；重启客户端，Codex 需在 /hooks 检查并信任。"


def uninstall(home, client):
    path = receipt_path(home, client)
    snapshot = read_file(path)
    if not snapshot:
        raise ValueError("没有 TermYes 安装记录；未删除任何旧 Hook")
    record = mapping(json.loads(base64.b64decode(snapshot["data"])))
    # Receipts are not authority to write arbitrary paths.
    allowed = set(map(str, desired_files(home, client)))
    if (record.get("client") != client or set(record["before"]) != allowed
            or set(record["installed"]) != allowed):
        raise ValueError("安装记录与客户端路径不一致")
    for name, installed in record["installed"].items():
        if read_file(Path(name)) != installed:
            raise ValueError("文件已有后续改动，未自动恢复：" + name)
    restored = []
    try:
        for name, original in record["before"].items():
            restore_file(Path(name), original)
            restored.append(name)
        path.unlink()
    except Exception:
        for name in restored:
            restore_file(Path(name), record["installed"][name])
        raise
    return "已恢复守卫安装前文件；YOLO/等效权限模式保持不变。"


def status(home):
    result = []
    for client, (name, _, _, _) in CLIENTS.items():
        receipt = receipt_path(home, client)
        installed = receipt.is_file() and not receipt.is_symlink()
        result.append({
            "id": client,
            "name": name,
            "installed": installed,
            "approvalReason": reason(client),
            **permission_modes.inspect(home, client),
        })
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "action",
        choices=("status", "install", "uninstall", "reconcile", "enable-yolo"),
    )
    parser.add_argument("client", nargs="?", choices=CLIENTS)
    parser.add_argument("--home", type=Path, default=Path.home(), help="User root; tests use a temporary home")
    args = parser.parse_args()
    if not args.home.is_absolute():
        parser.error("--home must be absolute")
    if args.action == "status":
        print(json.dumps(status(args.home), ensure_ascii=False)); return
    if args.action != "reconcile" and not args.client:
        parser.error("client required")
    if args.action == "enable-yolo":
        if not args.client:
            parser.error("client required")
        permission_modes.repair(args.home, args.client)
        print(json.dumps(status(args.home), ensure_ascii=False))
        return
    if args.action == "reconcile":
        results = permission_modes.reconcile(
            args.home,
            [args.client] if args.client else None,
        )
        failures = [item for item in results if item["detected"] and not item["permissionReady"]]
        print(json.dumps(status(args.home), ensure_ascii=False))
        if failures:
            sys.exit(1)
        return
    # ponytail: one local install lock; configuration mutations are rare and short.
    lock = receipt_path(args.home, args.client).parent / ".install.lock"
    checked_path(lock)
    lock.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    fd = os.open(lock, os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, "r+") as locked:
        try:
            fcntl.flock(locked, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise ValueError("另一个安装或恢复操作正在运行，请稍后再试")
        message = install(args.home, args.client) if args.action == "install" else uninstall(args.home, args.client)
        print(message)


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        print("操作未完成：" + str(error), file=sys.stderr)
        sys.exit(1)
