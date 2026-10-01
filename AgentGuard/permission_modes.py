#!/usr/bin/env python3
"""Detect and repair YOLO-equivalent permission modes for supported agents."""

import json
import os
from pathlib import Path
import re
import stat
import tempfile


MANAGED_MARKER = "# Managed by TermYes"
WRAPPER_NAME = "agent-yolo-wrapper"
PATH_MARKER = "# TermYes Agent YOLO PATH v1"
SHELL_WRAPPER_NAME = "termyes-agent-yolo-shell"
SHELL_MARKER = "# TermYes Agent YOLO shell v1"

ROOTS = {
    "claude": ".claude",
    "codex": ".codex",
    "codebuddy": ".codebuddy",
    "zcode": ".zcode/cli",
    "pi": ".pi/agent",
    "qoder": ".qoder",
    "gemini": ".gemini",
    "cursor": ".cursor",
    "agy": ".gemini",
    "opencode": ".config/opencode",
    "droid": ".factory",
    "crush": ".config/crush",
    "copilot": ".copilot",
}

COMMANDS = {
    "claude": ("claude",),
    "codex": ("codex",),
    "codebuddy": ("codebuddy",),
    "zcode": ("zcode",),
    "pi": ("pi",),
    "qoder": ("qoder", "qodercli"),
    "gemini": ("gemini",),
    "cursor": ("cursor", "cursor-agent"),
    "agy": ("agy",),
    "opencode": ("opencode",),
    "droid": ("droid",),
    "crush": ("crush",),
    "copilot": ("copilot",),
}

APP_PATHS = {
    "cursor": ("/Applications/Cursor.app",),
    "agy": ("/Applications/Antigravity.app",),
    "copilot": (
        "/Applications/GitHub Copilot.app",
        "/Applications/GitHub Copilot CLI.app",
    ),
}

WRAPPER_FLAGS = {
    "gemini": ("--yolo",),
    "cursor": ("--yolo",),
    "agy": ("--dangerously-skip-permissions",),
    "opencode": ("--auto",),
    "droid": ("--auto", "high"),
    "crush": ("--yolo",),
    "copilot": ("--allow-all-tools",),
}


def _checked_path(path):
    for parent in (path, *path.parents):
        if parent.is_symlink():
            raise ValueError("不自动修改符号链接：" + str(parent))


def _atomic_write(path, content, mode=0o600):
    _checked_path(path)
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    fd, temporary = tempfile.mkstemp(prefix=".termyes-", dir=str(path.parent))
    try:
        with os.fdopen(fd, "wb") as handle:
            handle.write(content)
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(temporary, mode)
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def _search_dirs(home):
    values = [
        home / ".local/bin",
        home / ".local/share/Termosaic/vendor/bin",
        home / ".opencode/bin",
        home / ".qoder/entry",
        home / ".pi/agent/bin",
        Path("/opt/homebrew/bin"),
        Path("/usr/local/bin"),
        Path("/usr/bin"),
    ]
    for item in os.environ.get("PATH", "").split(os.pathsep):
        if item:
            values.append(Path(item))
    result = []
    for path in values:
        if path not in result:
            result.append(path)
    return result


def _is_managed_wrapper(path):
    if path.is_symlink():
        return Path(os.readlink(path)).name == WRAPPER_NAME
    try:
        with path.open("rb") as handle:
            return MANAGED_MARKER.encode() in handle.read(256)
    except OSError:
        return False


def _find_command(home, names):
    for directory in _search_dirs(home):
        for name in names:
            candidate = directory / name
            if (candidate.is_file() and os.access(candidate, os.X_OK)
                    and not _is_managed_wrapper(candidate)):
                return candidate
    return None


def is_detected(home, client):
    if any(Path(path).is_dir() for path in APP_PATHS.get(client, ())):
        return True
    if _find_command(home, COMMANDS.get(client, ())):
        return True
    return False


def _read_json(path):
    if not path.is_file():
        return {}
    with path.open("r", encoding="utf-8") as handle:
        value = json.load(handle)
    if not isinstance(value, dict):
        raise ValueError("配置根节点不是对象：" + str(path))
    return value


def _write_json(path, value):
    _atomic_write(
        path,
        (json.dumps(value, ensure_ascii=False, indent=2, sort_keys=True) + "\n").encode(),
    )


def _top_level_toml_value(text, key):
    pattern = re.compile(r"^\s*" + re.escape(key) + r"\s*=\s*(.*?)\s*(?:#.*)?$")
    for line in text.splitlines():
        stripped = line.lstrip()
        if stripped.startswith("["):
            break
        match = pattern.match(line)
        if match:
            return match.group(1).strip()
    return None


def _set_top_level_toml(text, values):
    lines = text.splitlines()
    first_table = next(
        (index for index, line in enumerate(lines) if line.lstrip().startswith("[")),
        len(lines),
    )
    prefix = lines[:first_table]
    suffix = lines[first_table:]
    for key, value in values.items():
        replacement = key + " = " + json.dumps(value)
        pattern = re.compile(r"^\s*" + re.escape(key) + r"\s*=")
        for index, line in enumerate(prefix):
            if pattern.match(line):
                prefix[index] = replacement
                break
        else:
            prefix.insert(0, replacement)
    return "\n".join(prefix + suffix).rstrip() + "\n"


def _json_spec(client):
    return {
        "claude": ("settings.json", ("permissions", "defaultMode"), "bypassPermissions"),
        "codebuddy": ("settings.json", ("permissions", "defaultMode"), "bypassPermissions"),
        "qoder": ("settings.json", ("general", "defaultPermissionMode"), "bypass_permissions"),
        "zcode": ("setting.json", ("permission", "mode"), "yolo"),
    }.get(client)


def _mode_from_json(path, keys):
    value = _read_json(path)
    for key in keys:
        if not isinstance(value, dict):
            return None
        value = value.get(key)
    return value


def _set_json_mode(path, keys, mode):
    value = _read_json(path)
    current = value
    for key in keys[:-1]:
        child = current.get(key)
        if child is None:
            child = {}
            current[key] = child
        if not isinstance(child, dict):
            raise ValueError("配置字段不是对象：" + ".".join(keys))
        current = child
    current[keys[-1]] = mode
    _write_json(path, value)


def _wrapper_content():
    return """#!/bin/zsh
{marker}
set -eu

command_name=${{0:t}}
case "$command_name" in
  gemini)
    flags=(--yolo)
    ;;
  cursor|cursor-agent)
    flags=(--yolo)
    ;;
  agy)
    flags=(--dangerously-skip-permissions)
    ;;
  opencode)
    flags=(--auto)
    ;;
  droid)
    flags=(--auto high)
    ;;
  crush)
    flags=(--yolo)
    ;;
  copilot)
    flags=(--allow-all-tools)
    ;;
  *)
    print -u2 "agent-yolo-wrapper: unsupported command: $command_name"
    exit 64
    ;;
esac

for dir in "$HOME/.local/share/Termosaic/vendor/bin" ${{(s/:/)PATH}}; do
  [[ "$dir" == "$HOME/.local/bin" ]] && continue
  candidate="$dir/$command_name"
  if [[ -x "$candidate" && ! -d "$candidate" ]]; then
    manage_path="${{TERMYES_MANAGE_PY:-/Applications/TermYes.app/Contents/Resources/AgentGuard/manage.py}}"
    client="$command_name"
    [[ "$client" == "cursor-agent" ]] && client="cursor"
    if [[ ! -r "$manage_path" ]] || ! /usr/bin/python3 -B "$manage_path" ensure "$client" >/dev/null; then
      print -u2 "[TermYes] $command_name 的命令守卫或 YOLO 未就绪，已阻止启动。"
      exit 1
    fi
    export DANGER_GUARD_BYPASS=1
    exec "$candidate" "${{flags[@]}}" "$@"
  fi
done

print -u2 "$command_name 未安装；wrapper 已就位，安装后会自动使用 YOLO/免确认参数。"
exit 127
""".format(marker=MANAGED_MARKER)


def _shell_wrapper_content():
    return """{marker}
_termyes_manage_path="${{TERMYES_MANAGE_PY:-/Applications/TermYes.app/Contents/Resources/AgentGuard/manage.py}}"

_termyes_agent_yolo() {{
  emulate -L zsh
  local client="$1"
  shift
  if [[ ! -r "$_termyes_manage_path" ]]; then
    print -u2 "[TermYes] 缺少权限协调器：$_termyes_manage_path"
    return 1
  elif ! /usr/bin/python3 -B "$_termyes_manage_path" ensure "$client" >/dev/null; then
    print -u2 "[TermYes] $client 的命令守卫或 YOLO 未就绪，已阻止启动。"
    return 1
  fi
  command "$@"
}}

if (( $+commands[codex] )); then codex() {{ _termyes_agent_yolo codex codex "$@"; }}; fi
if (( $+commands[claude] )); then claude() {{ _termyes_agent_yolo claude claude "$@"; }}; fi
if (( $+commands[codebuddy] )); then codebuddy() {{ _termyes_agent_yolo codebuddy codebuddy "$@"; }}; fi
if (( $+commands[zcode] )); then zcode() {{ _termyes_agent_yolo zcode zcode "$@"; }}; fi
if (( $+commands[pi] )); then pi() {{ _termyes_agent_yolo pi pi "$@"; }}; fi
if (( $+commands[qoder] )); then qoder() {{ _termyes_agent_yolo qoder qoder "$@"; }}; fi
if (( $+commands[gemini] )); then gemini() {{ _termyes_agent_yolo gemini gemini "$@"; }}; fi
if (( $+commands[cursor] )); then cursor() {{ _termyes_agent_yolo cursor cursor "$@"; }}; fi
if (( $+commands[cursor-agent] )); then cursor-agent() {{ _termyes_agent_yolo cursor cursor-agent "$@"; }}; fi
if (( $+commands[agy] )); then agy() {{ _termyes_agent_yolo agy agy "$@"; }}; fi
if (( $+commands[opencode] )); then opencode() {{ _termyes_agent_yolo opencode opencode "$@"; }}; fi
if (( $+commands[droid] )); then droid() {{ _termyes_agent_yolo droid droid "$@"; }}; fi
if (( $+commands[crush] )); then crush() {{ _termyes_agent_yolo crush crush "$@"; }}; fi
if (( $+commands[copilot] )); then copilot() {{ _termyes_agent_yolo copilot copilot "$@"; }}; fi
""".format(marker=MANAGED_MARKER)


def _wrapper_names(client):
    if client == "cursor":
        return ("cursor", "cursor-agent")
    command = COMMANDS[client][0]
    return (command,)


def _ensure_wrapper(home, client):
    local_bin = home / ".local/bin"
    wrapper = local_bin / WRAPPER_NAME
    content = _wrapper_content().encode()
    if wrapper.exists():
        if wrapper.is_symlink() or MANAGED_MARKER not in wrapper.read_text(encoding="utf-8", errors="ignore"):
            raise ValueError("已有非 TermYes wrapper，未覆盖：" + str(wrapper))
        if wrapper.read_bytes() != content:
            _atomic_write(wrapper, content, 0o755)
    else:
        _atomic_write(wrapper, content, 0o755)
    for name in _wrapper_names(client):
        link = local_bin / name
        if link.exists() and not link.is_symlink():
            if _is_managed_wrapper(link):
                _atomic_write(link, content, 0o755)
                continue
            raise ValueError("已有非 TermYes 命令，未覆盖：" + str(link))
        if link.is_symlink() and os.readlink(link) != WRAPPER_NAME:
            raise ValueError("已有其他符号链接，未覆盖：" + str(link))
        if not link.exists():
            link.symlink_to(WRAPPER_NAME)


def adopt_local_command(home, client):
    if client not in WRAPPER_FLAGS or len(_wrapper_names(client)) != 1:
        return None
    name = _wrapper_names(client)[0]
    original = home / ".local/bin" / name
    destination = home / ".local/share/Termosaic/vendor/bin" / name
    _checked_path(original.parent)
    _checked_path(destination)
    if original.is_symlink():
        if os.readlink(original) == WRAPPER_NAME:
            return None
        raise ValueError("不自动修改符号链接：" + str(original))
    if not original.is_file() or _is_managed_wrapper(original):
        return None
    if destination.exists() or destination.is_symlink():
        raise ValueError("已有同名命令备份，未移动原文件：" + str(destination))
    destination.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    original.rename(destination)
    return original, destination


def restore_adopted_command(migration):
    original, destination = migration
    if original.is_symlink() and os.readlink(original) == WRAPPER_NAME:
        original.unlink()
    if original.exists() or original.is_symlink():
        raise ValueError("原命令路径已被其他程序占用，原文件仍保留在：" + str(destination))
    destination.rename(original)


def _ensure_zsh_path(home):
    shell_wrapper = home / ".local/bin" / SHELL_WRAPPER_NAME
    shell_content = _shell_wrapper_content().encode()
    if shell_wrapper.exists():
        if shell_wrapper.is_symlink() or MANAGED_MARKER not in shell_wrapper.read_text(encoding="utf-8", errors="ignore"):
            raise ValueError("已有非 TermYes shell loader，未覆盖：" + str(shell_wrapper))
        if shell_wrapper.read_bytes() != shell_content:
            _atomic_write(shell_wrapper, shell_content, 0o755)
    else:
        _atomic_write(shell_wrapper, shell_content, 0o755)

    zshrc = home / ".zshrc"
    text = zshrc.read_text(encoding="utf-8") if zshrc.is_file() else ""
    additions = []
    if PATH_MARKER not in text:
        additions.extend([
            PATH_MARKER,
            'export PATH="$HOME/.local/bin:$PATH"',
        ])
    if SHELL_MARKER not in text:
        additions.extend([
            SHELL_MARKER,
            f'[[ -r "$HOME/.local/bin/{SHELL_WRAPPER_NAME}" ]] && source "$HOME/.local/bin/{SHELL_WRAPPER_NAME}"',
        ])
    if additions:
        mode = stat.S_IMODE(zshrc.stat().st_mode) if zshrc.exists() else 0o600
        block = "\n" + "\n".join(additions) + "\n# End TermYes Agent YOLO shell\n"
        _atomic_write(zshrc, (text.rstrip() + block).encode(), mode)


def inspect(home, client):
    detected = is_detected(home, client)
    result = {
        "detected": detected,
        "permissionMode": "未安装",
        "permissionReady": False,
    }
    if not detected:
        result["permissionReason"] = "未检测到客户端"
        return result
    if client == "pi":
        result.update({
            "permissionMode": "always-yolo",
            "permissionReady": True,
            "permissionReason": "pi 默认不进行命令审批",
        })
        return result
    spec = _json_spec(client)
    if spec:
        relative, keys, expected = spec
        path = home / ROOTS[client] / relative
        try:
            current = _mode_from_json(path, keys)
        except Exception as error:
            result["permissionReason"] = "配置无法读取：" + str(error)
            return result
        result["permissionMode"] = str(current) if current is not None else "default"
        result["permissionReady"] = current == expected
        result["permissionReason"] = (
            "已处于等效 YOLO 模式"
            if result["permissionReady"]
            else "需要设置为 " + expected
        )
        return result
    if client == "codex":
        path = home / ".codex/config.toml"
        try:
            text = path.read_text(encoding="utf-8") if path.is_file() else ""
            approval = _top_level_toml_value(text, "approval_policy")
            sandbox = _top_level_toml_value(text, "sandbox_mode")
        except Exception as error:
            result["permissionReason"] = "配置无法读取：" + str(error)
            return result
        result["permissionMode"] = (
            "approval=" + str(approval) + ", sandbox=" + str(sandbox)
        )
        result["permissionReady"] = approval == '"never"' and sandbox == '"danger-full-access"'
        result["permissionReason"] = (
            "已处于 YOLO 模式"
            if result["permissionReady"]
            else "需要 approval_policy=never 与 sandbox_mode=danger-full-access"
        )
        return result
    if client in WRAPPER_FLAGS:
        if _find_command(home, COMMANDS[client]) is None:
            result["permissionMode"] = "no-cli-launcher"
            result["permissionReason"] = "检测到客户端，但没有可包装的命令行启动器"
            return result
        names = _wrapper_names(client)
        managed = all(
            (home / ".local/bin" / name).exists()
            and _is_managed_wrapper(home / ".local/bin" / name)
            for name in names
        )
        result["permissionMode"] = " ".join(WRAPPER_FLAGS[client]) if managed else "default"
        result["permissionReady"] = managed
        result["permissionReason"] = (
            "启动 wrapper 已强制免确认参数"
            if managed
            else "需要安装免确认启动 wrapper"
        )
        return result
    result["permissionReason"] = "该客户端的免确认模式无法由 TermYes 自动配置"
    return result


def repair(home, client):
    before = inspect(home, client)
    if not before["detected"]:
        return {**before, "repaired": False}
    _ensure_zsh_path(home)
    if before["permissionReady"]:
        return {**before, "repaired": False}
    if client == "pi":
        return {**before, "repaired": False}
    spec = _json_spec(client)
    if spec:
        relative, keys, expected = spec
        _set_json_mode(home / ROOTS[client] / relative, keys, expected)
    elif client == "codex":
        path = home / ".codex/config.toml"
        text = path.read_text(encoding="utf-8") if path.is_file() else ""
        _atomic_write(
            path,
            _set_top_level_toml(
                text,
                {
                    "approval_policy": "never",
                    "sandbox_mode": "danger-full-access",
                },
            ).encode(),
        )
    elif client in WRAPPER_FLAGS:
        _ensure_wrapper(home, client)
    after = inspect(home, client)
    return {**after, "repaired": bool(after["permissionReady"])}


def reconcile(home, clients=None):
    results = []
    for client in clients or ROOTS:
        try:
            result = repair(home, client)
            result.update({"id": client})
        except Exception as error:
            current = inspect(home, client)
            result = {
                **current,
                "id": client,
                "repaired": False,
                "permissionReason": str(error),
            }
        results.append(result)
    return results
