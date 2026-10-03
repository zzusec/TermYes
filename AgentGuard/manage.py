#!/usr/bin/env python3
"""Install shell guards and reconcile supported agents to YOLO-equivalent modes."""
import argparse
import base64
import datetime
from concurrent.futures import ThreadPoolExecutor, as_completed
import fcntl
import hashlib
import json
import os
import re
from pathlib import Path
import shlex
import signal
import stat
import subprocess
import sys
import tempfile
import uuid

import permission_modes
import policy_update

SOURCE = Path(__file__).resolve().parent
LIVE_MARKER = "TERMYES_AGENT_OK"
VERIFY_TIMEOUT_SECONDS = 120
VERIFY_MAX_AGE_SECONDS = 24 * 60 * 60

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


def verification_path(home):
    return home / "Library/Application Support/Termosaic/AgentGuard/verification.json"


def _file_fingerprint(path, content=False):
    try:
        stat_result = path.lstat()
        value = {
            "path": str(path),
            "mode": stat.S_IMODE(stat_result.st_mode),
            "size": stat_result.st_size,
            "mtime": stat_result.st_mtime_ns,
        }
        if path.is_symlink():
            value["link"] = os.readlink(path)
        elif content and path.is_file():
            value["sha256"] = hashlib.sha256(path.read_bytes()).hexdigest()
        return value
    except OSError:
        return {"path": str(path), "missing": True}


def verification_fingerprint(home, client):
    _, config, _, _ = locations(home, client)
    inspection = permission_modes.inspect(home, client)
    value = {
        "client": client,
        "permissionMode": inspection.get("permissionMode"),
        "permissionReady": inspection.get("permissionReady"),
        "config": _file_fingerprint(config, content=True) if config else None,
        "settings": [
            _file_fingerprint(home / relative, content=True)
            for relative in {
                "claude": (".claude/settings.local.json",),
                "codex": (".codex/config.toml", ".codex/auth.json"),
                "codebuddy": (".codebuddy/settings.local.json",),
                "pi": (".pi/agent/settings.json", ".pi/agent/models.json", ".pi/agent/auth.json"),
                "qoder": (".qoder/settings.local.json",),
                "agy": (".gemini/config/config.json",),
                "opencode": (".config/opencode/opencode.json", ".config/opencode/opencode.jsonc"),
            }.get(client, ())
        ],
        "receipt": _file_fingerprint(receipt_path(home, client), content=True),
        "commands": [
            {"entry": _file_fingerprint(path), "target": _file_fingerprint(path.resolve())}
            for path in permission_modes.executable_paths(home, client)
        ],
        "verifier": [
            _file_fingerprint(SOURCE / name, content=True)
            for name in ("manage.py", "permission_modes.py", "core.py")
        ],
    }
    return hashlib.sha256(
        json.dumps(value, ensure_ascii=False, sort_keys=True).encode()
    ).hexdigest()


def read_verification(home):
    path = verification_path(home)
    if not path.exists():
        return {"version": 1, "clients": {}}
    checked_path(path)
    value = mapping(json.loads(path.read_bytes()))
    clients = value.get("clients")
    if not isinstance(clients, dict):
        raise ValueError("实测记录格式无效")
    return {"version": 1, "clients": clients}


def write_verification(home, value):
    atomic_write(verification_path(home), json_bytes({
        "version": 1, "clients": mapping(value["clients"]),
    }))


def live_status(home, client, verification=None):
    try:
        verification = verification or read_verification(home)
        record = verification["clients"].get(client)
        if not isinstance(record, dict):
            return {
                "liveStatus": "untested",
                "liveReason": "尚未进行真实模型与命令守卫实测",
                "requestStatus": "untested",
                "requestReason": "尚未实测",
                "guardLiveStatus": "untested",
                "guardLiveReason": "尚未实测",
            }
        result = {
            "liveStatus": record.get("liveStatus", "untested"),
            "liveReason": record.get("liveReason", "实测记录不完整"),
            "liveCheckedAt": record.get("liveCheckedAt"),
            "requestStatus": record.get("requestStatus", "untested"),
            "requestReason": record.get("requestReason", "实测记录不完整"),
            "guardLiveStatus": record.get("guardLiveStatus", "untested"),
            "guardLiveReason": record.get("guardLiveReason", "实测记录不完整"),
        }
        checked_at = datetime.datetime.fromisoformat(record.get("liveCheckedAt", ""))
        age = (datetime.datetime.now(datetime.timezone.utc) - checked_at).total_seconds()
        if (record.get("fingerprint") != verification_fingerprint(home, client)
                or age < 0 or age > VERIFY_MAX_AGE_SECONDS):
            result.update({
                "liveStatus": "stale",
                "liveReason": "配置、CLI 或守卫已变化，或实测超过 24 小时，请重新实测",
                "requestStatus": "stale",
                "requestReason": "实测后配置或 CLI 已变化",
                "guardLiveStatus": "stale",
                "guardLiveReason": "实测后守卫配置已变化",
            })
        return result
    except Exception as error:
        return {
            "liveStatus": "failed",
            "liveReason": "无法读取实测记录：" + str(error),
            "requestStatus": "failed",
            "requestReason": "无法读取实测记录",
            "guardLiveStatus": "failed",
            "guardLiveReason": "无法读取实测记录",
        }


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
             for name in ("core.py", "rules.py", adapter, "chime.wav")}
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
            # Both events enforce the same danger list; unmatched permission requests are allowed.
            for event in ("PreToolUse", "PermissionRequest"):
                native = {
                    **hook,
                    "command": command + " " + event,
                    "timeout": 30,
                }
                merge_hooks(events, event, {"matcher": "Bash", "hooks": [native]}, paths)
    files[config] = raw if raw is not None and before == json.dumps(data, sort_keys=True) else json_bytes(data)
    return files


def rebase_claude_hooks(installed_config, current_config, restored_config, paths):
    if ({key: value for key, value in installed_config.items() if key != "hooks"}
            != {key: value for key, value in current_config.items() if key != "hooks"}):
        raise ValueError("Claude 配置的非 Hook 设置已被修改")
    installed_hooks = mapping(installed_config["hooks"])
    current_hooks = mapping(current_config["hooks"])
    if not installed_hooks.keys() <= current_hooks.keys():
        raise ValueError("Claude 原有 Hook 事件已被删除")

    def check_unmanaged(groups):
        if not isinstance(groups, list):
            raise ValueError("Claude 新增 Hook 事件不是数组")
        for group in groups:
            hooks = mapping(group).get("hooks")
            if not isinstance(hooks, list) or any(owns(hook, paths) for hook in hooks):
                raise ValueError("Claude 新增 Hook 组无效或包含受管 Hook")

    additions = {}
    for event, groups in current_hooks.items():
        if event == "PreToolUse":
            original = installed_hooks[event]
            if not isinstance(original, list) or not isinstance(groups, list):
                raise ValueError("Claude PreToolUse 不是数组")
            added = []
            position = 0
            for group in groups:
                if position < len(original) and group == original[position]:
                    position += 1
                else:
                    added.append(group)
            if position != len(original):
                raise ValueError("Claude 原有 PreToolUse 组已被修改")
            check_unmanaged(added)
            if added:
                additions[event] = added
        elif event in installed_hooks:
            if groups != installed_hooks[event]:
                raise ValueError("Claude 原有 Hook 事件已被修改")
        else:
            check_unmanaged(groups)
            additions[event] = groups
    if not additions:
        raise ValueError("Claude Hook 没有可安全重基的新增项")
    restored_hooks = restored_config.setdefault("hooks", {})
    for event, groups in additions.items():
        if event == "PreToolUse":
            restored_hooks.setdefault(event, []).extend(groups)
        else:
            restored_hooks[event] = groups
    return restored_config


def claude_config_was_replaced(installed_config, current_config):
    installed_settings = {key: value for key, value in installed_config.items() if key != "hooks"}
    current_settings = {key: value for key, value in current_config.items() if key != "hooks"}
    return installed_settings != current_settings or "hooks" not in current_config


def without_managed_claude_hooks(current_config, paths):
    restored = json.loads(json.dumps(current_config))
    hooks = restored.get("hooks")
    if hooks is None:
        return restored
    hooks = mapping(hooks)
    cleaned = {}
    for event, groups in hooks.items():
        if not isinstance(groups, list):
            raise ValueError("Claude Hook 事件不是数组：" + event)
        remaining_groups = []
        for group in groups:
            group = mapping(group)
            entries = group.get("hooks")
            if not isinstance(entries, list):
                raise ValueError("Claude Hook 列表格式错误")
            remaining = [entry for entry in entries if not owns(entry, paths)]
            if remaining:
                remaining_groups.append({**group, "hooks": remaining})
            elif len(remaining) == len(entries):
                remaining_groups.append(group)
        if remaining_groups:
            cleaned[event] = remaining_groups
    if cleaned:
        restored["hooks"] = cleaned
    else:
        restored.pop("hooks", None)
    return restored


def receipt_files(home, client, record, files):
    # Accept only the old managed runtime AI file in addition to the current paths.
    allowed = set(map(str, files))
    retired = str(locations(home, client)[2] / "ai_review.py")
    before = mapping(record.get("before"))
    installed = mapping(record.get("installed"))
    if (record.get("client") != client or set(before) != set(installed)
            or set(before) not in (allowed, allowed | {retired})):
        raise ValueError("安装记录与客户端路径不一致")
    return ({name: value for name, value in before.items() if name in allowed},
            {name: value for name, value in installed.items() if name in allowed})


def receipt_needs_retirement(home, client):
    snapshot = read_file(receipt_path(home, client))
    if snapshot is None:
        return False
    record = mapping(json.loads(base64.b64decode(snapshot["data"])))
    return str(locations(home, client)[2] / "ai_review.py") in record["installed"]


def retire_ai_file(home, client, record):
    path = locations(home, client)[2] / "ai_review.py"
    name = str(path)
    if not record or name not in record["installed"]:
        return None, ""
    preserved = "旧 AI 文件已有外部改动，已保留并退出管理。"
    try:
        snapshot = read_file(path)
    except ValueError:
        # A replaced symlink/directory is an external edit, never a managed file.
        return None, preserved
    if snapshot is None:
        return None, ""  # Keep an external deletion; do not recreate the user's baseline.
    if snapshot != record["installed"][name]:
        return None, preserved
    restore_file(path, record["before"][name])
    return (path, snapshot), ""


def install(home, client):
    receipt = receipt_path(home, client)
    previous = read_file(receipt) if client == "claude" else None
    if client != "claude" or not previous:
        permission_modes.repair(home, client)
    files = desired_files(home, client)  # Validate all config before writing anything.
    if client != "claude":
        previous = read_file(receipt)
    old = mapping(json.loads(base64.b64decode(previous["data"]))) if previous else None
    snapshots = {str(p): read_file(p) for p in files}
    before, installed = (receipt_files(home, client, old, files)
                         if old is not None else (snapshots, None))
    updated = {str(p): {"data": base64.b64encode(content).decode(),
                       "mode": snapshots[str(p)]["mode"] if snapshots[str(p)] else 0o600}
               for p, content in files.items()}
    # Refuse to overwrite a file edited since our last install; preserve user changes.
    if old is not None and snapshots != installed:
        config = locations(home, client)[1]
        changed = {name for name in snapshots if snapshots[name] != installed[name]}
        if client not in ("agy", "claude", "codebuddy", "qoder") or config is None or changed != {str(config)}:
            raise ValueError("安装后文件已被外部修改；未覆盖，请先检查配置")
        key = str(config)
        stored = installed[key]
        current = snapshots[key]
        if not stored or not current or (client == "agy" and stored["mode"] != current["mode"]):
            raise ValueError("安装后文件已被外部修改；未覆盖，请先检查配置")
        installed_config = mapping(json.loads(base64.b64decode(stored["data"])))
        current_config = mapping(json.loads(base64.b64decode(current["data"])))
        previous_config = before[key]
        restored_config = (mapping(json.loads(base64.b64decode(previous_config["data"])))
                           if previous_config else {})
        if client == "agy":
            additions = current_config.keys() - installed_config.keys()
            if not additions or any(current_config.get(name) != value for name, value in installed_config.items()):
                raise ValueError("安装后文件已被外部修改；未覆盖，请先检查配置")
            restored_config.update({name: current_config[name] for name in additions})
        else:
            root, _, runtime, adapter = locations(home, client)
            paths = {str(runtime / adapter), str(root / "hooks" / adapter)}
            if installed_config != current_config:
                if client == "claude" and claude_config_was_replaced(installed_config, current_config):
                    permission_modes.repair(home, client)
                    current_config = mapping(json.loads(config.read_bytes()))
                    restored_config = without_managed_claude_hooks(current_config, paths)
                    files = desired_files(home, client)
                    updated[key]["data"] = base64.b64encode(files[config]).decode()
                else:
                    rebase_claude_hooks(installed_config, current_config, restored_config, paths)
            updated[key]["mode"] = stored["mode"] & current["mode"] & 0o600
        before = {**before, key: {"data": base64.b64encode(json_bytes(restored_config)).decode(),
                                  "mode": previous_config["mode"] if previous_config else current["mode"]}}
    if client == "claude" and previous:
        permission_modes.repair(home, client)
    changed = []
    retired = None
    retirement_note = ""
    try:
        for p, content in files.items():
            key = str(p)
            if snapshots[key] != updated[key]:
                atomic_write(p, content, updated[key]["mode"])
                changed.append(p)
        retired, retirement_note = retire_ai_file(home, client, old)
        payload = json_bytes({"client": client, "before": before, "installed": updated})
        if not previous or base64.b64decode(previous["data"]) != payload:
            atomic_write(receipt, payload)
    except Exception:
        if retired:
            restore_file(*retired)
        for p in reversed(changed):
            restore_file(p, snapshots[str(p)])
        raise
    return "守卫已安装，Agent 权限模式已检测/修复；重启客户端，Codex 需在 /hooks 检查并信任。" + retirement_note


def uninstall(home, client):
    path = receipt_path(home, client)
    snapshot = read_file(path)
    if not snapshot:
        raise ValueError("没有 TermYes 安装记录；未删除任何旧 Hook")
    record = mapping(json.loads(base64.b64decode(snapshot["data"])))
    # Receipts are not authority to write arbitrary paths.
    before, installed_files = receipt_files(home, client, record, desired_files(home, client))
    for name, installed in installed_files.items():
        if read_file(Path(name)) != installed:
            raise ValueError("文件已有后续改动，未自动恢复：" + name)
    restored = []
    retired = None
    retirement_note = ""
    try:
        for name, original in before.items():
            restore_file(Path(name), original)
            restored.append(name)
        retired, retirement_note = retire_ai_file(home, client, record)
        path.unlink()
    except Exception:
        if retired:
            restore_file(*retired)
        for name in restored:
            restore_file(Path(name), installed_files[name])
        raise
    return "已恢复守卫安装前文件；YOLO/等效权限模式保持不变。" + retirement_note


def status(home, selected=None):
    policy_version, policy_status, policy_error = policy_update.status(home)
    try:
        verification = read_verification(home)
    except Exception:
        verification = None
    result = []
    for client, (name, _, _, _) in CLIENTS.items():
        if selected and client not in selected:
            continue
        receipt = receipt_path(home, client)
        installed = receipt.is_file() and not receipt.is_symlink()
        guard_ready = False
        guard_reason = "守卫未安装"
        if installed:
            try:
                record = mapping(json.loads(receipt.read_bytes()))
                files = desired_files(home, client)
                _, installed_files = receipt_files(home, client, record, files)
                if any(read_file(Path(name)) != snapshot
                       for name, snapshot in installed_files.items()):
                    raise ValueError("守卫配置或文件已被修改")
                if any(read_file(path)["data"] != base64.b64encode(content).decode()
                       for path, content in files.items()):
                    raise ValueError("守卫版本需要更新")
                guard_ready = True
                guard_reason = "守卫文件已落地；客户端实际加载仍需验证"
            except Exception as error:
                guard_reason = str(error)
        result.append({
            "id": client,
            "name": name,
            "policyVersion": policy_version,
            "policyStatus": policy_status,
            "policyError": policy_error,
            "installed": installed,
            "guardReady": guard_ready,
            "guardReason": guard_reason,
            "approvalReason": reason(client),
            **live_status(home, client, verification),
            **permission_modes.inspect(home, client),
        })
    return result


def locked_action(home, client, action):
    lock = receipt_path(home, client).parent / ".install.lock"
    checked_path(lock)
    lock.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    fd = os.open(lock, os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, "r+") as locked:
        try:
            fcntl.flock(locked, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise ValueError("另一个安装或恢复操作正在运行，请稍后再试")
        if action == "repair":
            migration = permission_modes.adopt_local_command(home, client)
            try:
                return install(home, client)
            except Exception:
                if migration:
                    permission_modes.restore_adopted_command(migration)
                raise
        return install(home, client) if action == "install" else uninstall(home, client)


def repair_unready(home, selected=None):
    pending = [client["id"] for client in status(home, selected)
               if client["detected"] and (not client["permissionReady"] or not client["guardReady"]
                                          or receipt_needs_retirement(home, client["id"]))]
    failures = {}
    for client in pending:
        try:
            locked_action(home, client, "repair")
        except Exception as error:
            failures[client] = str(error)
    clients = status(home)
    for client in clients:
        if client["id"] in failures:
            client["serviceError"] = failures[client["id"]]
        if client["id"] in pending and (not client["permissionReady"] or not client["guardReady"]):
            failures.setdefault(client["id"], client["permissionReason"] if not client["permissionReady"]
                                else client["guardReason"])
    return clients, failures


def monitor(home, selected=None):
    policy_update.check(home, atomic_write)
    failures = {}
    for client in selected or CLIENTS:
        try:
            if permission_modes.is_detected(home, client):
                locked_action(home, client, "install")
        except Exception as error:
            failures[client] = str(error)
    clients = status(home, selected)
    for client in clients:
        if selected and client["id"] not in selected:
            continue
        if client["id"] in failures:
            client["serviceError"] = failures[client["id"]]
        if client["detected"] and (not client["permissionReady"] or not client["guardReady"]):
            failures.setdefault(client["id"],
                                client["permissionReason"] if not client["permissionReady"]
                                else client["guardReason"])
    return clients, failures


def probe_arguments(client, prompt):
    if client == "claude":
        return ["-p", "--output-format", "text", "--no-session-persistence", prompt]
    if client == "codex":
        return ["exec", "--skip-git-repo-check", "--ephemeral", "--color", "never", prompt]
    if client == "codebuddy":
        return ["-p", "--output-format", "text", "--no-session-persistence", prompt]
    if client == "zcode":
        return ["--prompt", prompt, "--mode", "yolo", "--no-color"]
    if client == "pi":
        return ["--print", prompt]
    if client == "qoder":
        return ["-p", "--output-format", "text", "--no-session-persistence", prompt]
    if client == "agy":
        return ["--output-format", "text", "--print-timeout", "60s", "--print=" + prompt]
    if client == "opencode":
        return ["run", "--format", "json", prompt]
    return None


def run_probe(command, arguments, home, extra_env=None, timeout=VERIFY_TIMEOUT_SECONDS):
    environment = dict(os.environ)
    environment.update({
        "HOME": str(home),
        "PATH": os.pathsep.join((
            str(home / ".local/bin"),
            str(home / ".local/share/Termosaic/vendor/bin"),
            str(home / ".opencode/bin"),
            str(home / ".qoder/entry"),
            str(home / ".pi/agent/bin"),
            "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin",
        )),
        "PYTHONDONTWRITEBYTECODE": "1",
        "DANGER_GUARD_SILENT": "1",
    })
    if extra_env:
        environment.update(extra_env)
    with tempfile.TemporaryFile() as output:
        process = subprocess.Popen(
            [str(command), *arguments],
            cwd=str(home),
            env=environment,
            stdin=subprocess.DEVNULL,
            stdout=output,
            stderr=subprocess.STDOUT,
            start_new_session=True,
        )
        timed_out = False
        try:
            process.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            timed_out = True
            try:
                os.killpg(process.pid, signal.SIGTERM)
                process.wait(timeout=3)
            except (ProcessLookupError, subprocess.TimeoutExpired):
                try:
                    os.killpg(process.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                process.wait()
        output.seek(0, os.SEEK_END)
        size = output.tell()
        output.seek(max(0, size - 16384))
        text = output.read().decode("utf-8", errors="replace")
    return process.returncode, text, timed_out


def output_reason(output):
    clean = re.sub(r"\x1b\[[0-9;]*[A-Za-z]", "", output)
    errors = [line.strip() for line in clean.splitlines()
              if re.search(r"error|failed|invalid|unrecognized|usage limit|429", line, re.I)]
    text = " ".join(("\n".join(errors) if errors else clean).split())
    return text[:600] if errors else text[-300:] if text else "客户端未返回可诊断信息"


def read_probe_file(path, token):
    try:
        return path.is_file() and not path.is_symlink() and path.read_text() == token
    except OSError:
        return False


def verify_client(home, client):
    checked_at = datetime.datetime.now(datetime.timezone.utc).isoformat()
    current = next(item for item in status(home, [client]) if item["id"] == client)
    base = {
        "fingerprint": verification_fingerprint(home, client),
        "liveCheckedAt": checked_at,
    }
    if not current["detected"]:
        reason_text = "未检测到客户端"
        return {**base, "liveStatus": "unsupported", "liveReason": reason_text,
                "requestStatus": "unsupported", "requestReason": reason_text,
                "guardLiveStatus": "unsupported", "guardLiveReason": reason_text}
    if not current["permissionReady"] or not current["guardReady"] or current.get("serviceError"):
        reason_text = current.get("serviceError") or (
            current["permissionReason"] if not current["permissionReady"] else current["guardReason"]
        )
        return {**base, "liveStatus": "failed", "liveReason": "配置未就绪：" + reason_text,
                "requestStatus": "failed", "requestReason": "配置未就绪：" + reason_text,
                "guardLiveStatus": "failed", "guardLiveReason": "配置未就绪：" + reason_text}
    command = permission_modes.launcher_path(home, client)
    arguments = probe_arguments(client, "")
    if command is None or arguments is None:
        reason_text = "该客户端尚未支持端到端实测"
        return {**base, "liveStatus": "unsupported", "liveReason": reason_text,
                "requestStatus": "unsupported", "requestReason": reason_text,
                "guardLiveStatus": "unsupported", "guardLiveReason": reason_text}

    token = uuid.uuid4().hex
    safe_path = Path("/tmp") / ("termyes-agent-safe-" + token)
    safe_command = "/usr/bin/printf %s " + shlex.quote(token) + " > " + shlex.quote(str(safe_path))
    safe_prompt = (
        "请使用 Shell/Bash 工具原样执行下面这条安全命令一次，不要用其他方式创建文件：\n"
        + safe_command + "\n命令执行完成后只回复 " + LIVE_MARKER + "。"
    )
    request_status = "failed"
    request_reason = "Agent 未执行安全 Shell 探针"
    try:
        code, output, timed_out = run_probe(command, probe_arguments(client, safe_prompt), home)
        if code == 0 and not timed_out and read_probe_file(safe_path, token):
            request_status = "passed"
            request_reason = "真实模型请求与免确认 Shell 执行通过"
        elif timed_out:
            request_reason = "真实请求超时"
        else:
            request_reason = "未执行安全 Shell 探针（退出码 %s）：%s" % (code, output_reason(output))
    except Exception as error:
        request_reason = "无法启动真实请求：" + str(error)
    finally:
        try:
            safe_path.unlink()
        except FileNotFoundError:
            pass

    if request_status != "passed":
        return {
            **base, "liveStatus": "failed", "liveReason": request_reason,
            "requestStatus": request_status, "requestReason": request_reason,
            "guardLiveStatus": "untested",
            "guardLiveReason": "请求/免确认未通过，未运行守卫实测",
        }

    guard_token = uuid.uuid4().hex
    guard_receipt = Path("/tmp") / ("termyes-guard-receipt-" + guard_token)
    guard_executed = Path("/tmp") / ("termyes-guard-executed-" + guard_token)
    guard_authorization = Path("/tmp") / ("termyes-guard-request-" + guard_token)
    guard_command = "/usr/bin/printf %s " + shlex.quote(guard_token) + " > " + shlex.quote(str(guard_executed))
    guard_prompt = (
        "请使用 Shell/Bash 工具原样执行下面这条安全的 TermYes 守卫验证命令一次：\n"
        + guard_command + "\n如果被 Hook 拒绝，不要重试；只回复 " + LIVE_MARKER + "。"
    )
    guard_status = "failed"
    guard_reason = "命令守卫未返回加载证据"
    try:
        fd = os.open(guard_authorization, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
        with os.fdopen(fd, "w") as handle:
            handle.write(guard_token)
        code, output, timed_out = run_probe(
            command,
            probe_arguments(client, guard_prompt),
            home,
            {
                "TERMYES_GUARD_PROBE_TOKEN": guard_token,
                "TERMYES_GUARD_PROBE_RECEIPT": str(guard_receipt),
            },
        )
        receipt_ready = read_probe_file(guard_receipt, guard_token)
        command_ran = read_probe_file(guard_executed, guard_token)
        if code == 0 and not timed_out and receipt_ready and not command_ran:
            guard_status = "passed"
            guard_reason = "客户端已真实加载并调用 TermYes 命令守卫"
        elif command_ran:
            guard_reason = "验证命令已执行，客户端未加载 TermYes 守卫"
        elif timed_out:
            guard_reason = "命令守卫实测超时"
        else:
            guard_reason = "未取得守卫调用证据（退出码 %s）：%s" % (code, output_reason(output))
    except Exception as error:
        guard_reason = "无法执行命令守卫实测：" + str(error)
    finally:
        for path in (guard_receipt, guard_executed, guard_authorization):
            try:
                path.unlink()
            except FileNotFoundError:
                pass

    passed = request_status == "passed" and guard_status == "passed"
    return {
        **base,
        "liveStatus": "passed" if passed else "failed",
        "liveReason": "Agent 请求、免确认执行与命令守卫均通过" if passed else (
            request_reason if request_status != "passed" else guard_reason
        ),
        "requestStatus": request_status,
        "requestReason": request_reason,
        "guardLiveStatus": guard_status,
        "guardLiveReason": guard_reason,
    }


def verify_clients(home, selected=None):
    verification = read_verification(home)
    failures = {}
    candidates = [item["id"] for item in status(home, selected) if item["detected"]]
    with ThreadPoolExecutor(max_workers=3) as executor:
        pending = {executor.submit(verify_client, home, client): client for client in candidates}
        for completed in as_completed(pending):
            client = pending[completed]
            record = completed.result()
            verification["clients"][client] = record
            write_verification(home, verification)
            if record["liveStatus"] != "passed":
                failures[client] = record["liveReason"]
    if not candidates:
        write_verification(home, verification)
    return status(home), failures

def verify_all(home):
    return verify_clients(home)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "action",
        choices=("status", "install", "uninstall", "reconcile", "enable-yolo", "monitor", "ensure", "policy-update", "repair-unready", "repair-client", "verify", "verify-client"),
    )
    parser.add_argument("client", nargs="?", choices=CLIENTS)
    parser.add_argument("--home", type=Path, default=Path.home(), help="User root; tests use a temporary home")
    args = parser.parse_args()
    if not args.home.is_absolute():
        parser.error("--home must be absolute")
    if args.action == "status":
        print(json.dumps(status(args.home), ensure_ascii=False)); return
    if args.action == "policy-update":
        policy_update.check(args.home, atomic_write, force=True)
        print(json.dumps(status(args.home), ensure_ascii=False)); return
    if args.action in ("repair-unready", "repair-client"):
        if args.action == "repair-client" and not args.client:
            parser.error("client required")
        clients, failures = repair_unready(args.home, [args.client] if args.action == "repair-client" else None)
        print(json.dumps(clients, ensure_ascii=False))
        if failures:
            sys.exit(1)
        return
    if args.action in ("verify", "verify-client"):
        if args.action == "verify-client" and not args.client:
            parser.error("client required")
        clients, failures = (verify_clients(args.home, [args.client])
                             if args.action == "verify-client" else verify_all(args.home))
        print(json.dumps(clients, ensure_ascii=False))
        if failures:
            sys.exit(1)
        return
    if args.action in ("monitor", "ensure"):
        if args.action == "ensure" and not args.client:
            parser.error("client required")
        if args.action == "ensure":
            clients = status(args.home, [args.client])
            if clients and all(item["detected"] and item["permissionReady"] and item["guardReady"]
                               and not receipt_needs_retirement(args.home, item["id"])
                               for item in clients):
                print(json.dumps(clients, ensure_ascii=False))
                return
        clients, failures = monitor(args.home, [args.client] if args.action == "ensure" else None)
        print(json.dumps(clients, ensure_ascii=False))
        if failures:
            sys.exit(1)
        return
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
    print(locked_action(args.home, args.client, args.action))


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        print("操作未完成：" + str(error), file=sys.stderr)
        sys.exit(1)
