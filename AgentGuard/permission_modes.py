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
    "qoder": ("qodercli", "qoder"),
    "gemini": ("gemini",),
    "cursor": ("cursor-agent",),
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


def _default_search_dirs(home):
    return [
        home / ".local/bin",
        home / ".local/share/Termosaic/vendor/bin",
        home / ".opencode/bin",
        home / ".qoder/bin/qodercli",
        home / ".pi/agent/bin",
        home / ".cursor/bin",
        Path("/opt/homebrew/bin"),
        Path("/usr/local/bin"),
        Path("/usr/bin"),
    ]


def _search_dirs(home):
    # PATH order is the shell's launch order; known locations are only fallbacks.
    values = [Path(item or ".") for item in os.environ.get("PATH", "").split(os.pathsep)]
    return list(dict.fromkeys(values + _default_search_dirs(home)))


def _is_managed_wrapper(path):
    try:
        with path.open("rb") as handle:
            lines = handle.read(256).splitlines()
        return (len(lines) > 1 and lines[0].startswith(b"#!")
                and lines[1] == MANAGED_MARKER.encode())
    except OSError:
        return False


def _find_command(home, names, directories=None):
    for directory in _search_dirs(home) if directories is None else directories:
        for name in names:
            candidate = directory / name
            if (candidate.is_file() and os.access(candidate, os.X_OK)
                    and not _is_managed_wrapper(candidate)):
                return candidate
    return None


def _underlying_path(home, client):
    directories = _search_dirs(home)
    if client in WRAPPER_FLAGS:
        directories = [home / ".local/share/Termosaic/vendor/bin", *directories]
    if client == "qoder":
        # qoder is also a valid older CLI name. Only exclude the known IDE/CLI
        # dispatcher when its qodercli dependency is actually missing.
        cli = _find_command(home, ("qodercli",), directories)
        if cli:
            return cli
        candidate = _find_command(home, ("qoder",), directories)
        if candidate:
            with candidate.open("rb") as handle:
                if b"# Qoder Command Dispatcher\n" in handle.read(256):
                    return None
        return candidate
    return _find_command(home, COMMANDS.get(client, ()), directories)


def launcher_path(home, client):
    underlying = _underlying_path(home, client)
    if underlying is None:
        return None
    if client in WRAPPER_FLAGS:
        for name in _wrapper_names(client):
            candidate = home / ".local/bin" / name
            if (candidate.is_file() and os.access(candidate, os.X_OK)
                    and _is_managed_wrapper(candidate)):
                return candidate
    return underlying


def executable_paths(home, client):
    paths = []
    for candidate in (launcher_path(home, client), _underlying_path(home, client)):
        if candidate:
            # A symlink's mtime alone cannot detect a replaced executable target.
            for path in (candidate, candidate.resolve()):
                if path not in paths:
                    paths.append(path)
    return paths


def is_detected(home, client):
    if any(Path(path).is_dir() for path in APP_PATHS.get(client, ())):
        return True
    return _underlying_path(home, client) is not None


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


def _toml_string_value(literal):
    if literal.startswith("'"):
        return literal[1:-1]
    # TOML basic strings additionally allow eight-digit Unicode escapes. Only
    # inspect escape tokens, so a literal \\U sequence is not decoded twice.
    def convert(match):
        escape = match.group(0)
        return json.dumps(chr(int(escape[2:], 16)), ensure_ascii=True)[1:-1] if escape.startswith("\\U") else escape
    return json.loads(re.sub(r"\\(?:U[0-9A-Fa-f]{8}|.)", convert, literal))


def _top_level_toml_entries(text):
    """Locate root assignments without interpreting strings as keys or tables.

    Keep unrelated TOML verbatim, including multiline strings and arrays. The
    system Python is 3.9, so this small lexical scan does not require tomllib.
    """
    lines = text.splitlines()
    part = r'''(?:[A-Za-z0-9_-]+|"(?:[^"\\]|\\.)*"|'[^']*')'''
    assignment = re.compile(r"^\s*(" + part + r"(?:\s*\.\s*" + part + r")*)\s*=")
    entries = []
    index = 0
    while index < len(lines):
        stripped = lines[index].lstrip()
        if not stripped or stripped.startswith("#"):
            index += 1
            continue
        if stripped.startswith("["):
            break
        match = assignment.match(lines[index])
        if not match:
            raise ValueError("无法识别 TOML 顶层配置，第 %d 行" % (index + 1))
        raw_key = match.group(1)
        key = raw_key
        if re.fullmatch(r"(?:\"(?:[^\"\\]|\\.)*\"|'[^']*')", raw_key):
            key = _toml_string_value(raw_key)
        start = index
        column = match.end()
        value_column = column
        quote = None
        brackets = []
        while index < len(lines):
            line = lines[index]
            while column < len(line):
                char = line[column]
                if quote is not None:
                    if quote.startswith('"') and char == "\\":
                        column += 2
                        continue
                    if line.startswith(quote, column):
                        column += len(quote)
                        # TOML permits one or two extra quotes at a multiline end.
                        if len(quote) == 3:
                            for _ in range(2):
                                if column < len(line) and line[column] == quote[0]:
                                    column += 1
                        quote = None
                    else:
                        column += 1
                    continue
                if char == "#":
                    break
                if char in ("'", '"'):
                    quote = char * 3 if line.startswith(char * 3, column) else char
                    column += len(quote)
                    continue
                if char in "[{":
                    brackets.append(char)
                elif char in "]}":
                    if not brackets or brackets.pop() != ("[" if char == "]" else "{"):
                        raise ValueError("TOML 配置括号不匹配")
                column += 1
            if quote is None and not brackets:
                break
            if quote is not None and len(quote) == 1:
                raise ValueError("TOML 单行字符串未闭合")
            index += 1
            column = 0
        if quote is not None or brackets:
            raise ValueError("TOML 多行配置未闭合")
        value = "\n".join([lines[start][value_column:], *lines[start + 1:index + 1]])
        entries.append((key, start, index + 1, value.strip()))
        index += 1
    return lines, entries


def _top_level_toml_value(text, key):
    _, entries = _top_level_toml_entries(text)
    values = [value for name, _, _, value in entries if name == key]
    if len(values) > 1:
        raise ValueError("TOML 顶层配置重复：" + key)
    if not values:
        return None
    string = re.fullmatch(r'''("(?:[^"\\\n]|\\.)*"|'[^'\n]*')\s*(?:#.*)?''', values[0])
    if string:
        literal = string.group(1)
        return _toml_string_value(literal)
    return None


def _set_top_level_toml(text, values):
    lines, entries = _top_level_toml_entries(text)
    edits = {}
    seen = set()
    for key, start, end, _ in entries:
        if key not in values:
            continue
        if key in seen:
            raise ValueError("TOML 顶层配置重复：" + key)
        seen.add(key)
        edits[start] = (end, key + " = " + json.dumps(values[key]))
    updated = [key + " = " + json.dumps(value) for key, value in values.items() if key not in seen]
    index = 0
    while index < len(lines):
        if index in edits:
            index, replacement = edits[index]
            updated.append(replacement)
        else:
            updated.append(lines[index])
            index += 1
    return "\n".join(updated).rstrip() + "\n"


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


def _permission_arguments_content():
    # Refuse conflicting options instead of relying on a CLI's first/last-wins
    # parsing. Do not inspect positional text after the explicit -- delimiter.
    return """_termyes_check_yolo_arguments() {
  local client="$1" arg option value expected
  shift
  local -a args=("$@")
  local i
  for (( i=1; i <= ${#args}; i++ )); do
    arg="${args[i]}"
    [[ "$arg" == "--" ]] && break
    option="${arg%%=*}"
    value="${arg#*=}"
    expected=""
    case "$client:$option" in
      gemini:--approval-mode) expected=yolo ;;
      droid:--auto) expected=high ;;
      claude:--permission-mode|codebuddy:--permission-mode) expected=bypassPermissions ;;
      qoder:--permission-mode) expected=bypass_permissions ;;
      codex:--ask-for-approval|codex:-a) expected=never ;;
      codex:--sandbox|codex:-s) expected=danger-full-access ;;
      codex:--config|codex:-c)
        if [[ "$arg" != *=* ]]; then
          (( i++ ))
          value="${args[i]:-}"
        fi
        case "$value" in
          approval_policy=*) expected=never ;;
          sandbox_mode=*) expected=danger-full-access ;;
          *) continue ;;
        esac
        value="${value#*=}"
        value="${value//\\\"/}"
        value="${value//\\'/}"
        if [[ "$value" != "$expected" ]]; then
          print -u2 "[TermYes] $option 的权限覆盖与强制 YOLO 模式冲突，已阻止启动。"
          return 64
        fi
        continue ;;
      codex:--full-auto)
        print -u2 "[TermYes] $arg 与强制 YOLO 模式冲突，已阻止启动。"
        return 64 ;;
    esac
    if [[ -n "$expected" ]]; then
      if [[ "$arg" != *=* ]]; then
        (( i++ ))
        value="${args[i]:-}"
      fi
      if [[ "$value" != "$expected" ]]; then
        print -u2 "[TermYes] $option=$value 与强制 YOLO 模式冲突，已阻止启动。"
        return 64
      fi
    fi
    case "$client:$arg" in
      gemini:--yolo=false|gemini:--no-yolo|cursor:--yolo=false|cursor:--no-yolo|\
      opencode:--auto=false|opencode:--no-auto|copilot:--allow-all-tools=false|\
      agy:--dangerously-skip-permissions=false|claude:--dangerously-skip-permissions=false|\
      codebuddy:--dangerously-skip-permissions=false|qoder:--dangerously-skip-permissions=false)
        print -u2 "[TermYes] $arg 与强制 YOLO 模式冲突，已阻止启动。"
        return 64 ;;
    esac
  done
}
"""


def _wrapper_content():
    cases = []
    for client, flags in WRAPPER_FLAGS.items():
        names = "|".join(_wrapper_names(client))
        command = COMMANDS[client][0]
        cases.append(f"  {names}) client={client}; command_name={command}; flags=({' '.join(flags)}) ;;")
    fallback = []
    for directory in _default_search_dirs(Path("/TERMYES_HOME")):
        value = str(directory).replace("/TERMYES_HOME", "$HOME")
        fallback.append('"' + value + '"')
    return """#!/bin/zsh
{marker}
set -eu

{argument_check}
entry_name=${{0:t}}
case "$entry_name" in
{cases}
  *)
    print -u2 "agent-yolo-wrapper: unsupported command: $entry_name"
    exit 64 ;;
esac
_termyes_check_yolo_arguments "$client" "$@" || exit $?

for dir in "$HOME/.local/share/Termosaic/vendor/bin" "${{path[@]}}" {fallback}; do
  [[ -z "$dir" ]] && dir=.
  [[ "${{dir:A}}" == "${{HOME:A}}/.local/bin" ]] && continue
  candidate="$dir/$command_name"
  [[ "${{candidate:A}}" == "${{0:A}}" ]] && continue
  if [[ -x "$candidate" && ! -d "$candidate" ]]; then
    # A copied managed wrapper is also not an underlying CLI.
    header="$(/usr/bin/head -c 256 "$candidate")"
    first_line="${{header%%$'\n'*}}"
    remaining_header="${{header#*$'\n'}}"
    second_line="${{remaining_header%%$'\n'*}}"
    [[ "$first_line" == '#!'* && "$second_line" == "{marker}" ]] && continue
    manage_path="${{TERMYES_MANAGE_PY:-/Applications/TermYes.app/Contents/Resources/AgentGuard/manage.py}}"
    if [[ ! -r "$manage_path" ]]; then
      print -u2 "[TermYes] 缺少权限协调器：$manage_path；继续启动 $entry_name。"
    elif ! ensure_output="$(/usr/bin/python3 -B "$manage_path" ensure "$client")"; then
      if [[ -n "$ensure_output" ]]; then
        print -ru2 -- "$ensure_output"
      fi
      print -u2 "[TermYes] $entry_name 的命令守卫或 YOLO 检查失败；继续启动，请稍后检查守卫配置。"
    fi
    export DANGER_GUARD_BYPASS=1
    # --auto belongs to the run command, not the root parser, in current OpenCode.
    if [[ "$client" == "opencode" && "${{1:-}}" == "run" ]]; then
      shift
      exec "$candidate" run "${{flags[@]}}" "$@"
    fi
    exec "$candidate" "${{flags[@]}}" "$@"
  fi
done

print -u2 "$entry_name 未安装；wrapper 已就位，安装后会自动使用 YOLO/免确认参数。"
exit 127
""".format(marker=MANAGED_MARKER, argument_check=_permission_arguments_content(),
           cases="\n".join(cases), fallback=" ".join(fallback))


def _shell_wrapper_content():
    functions = []
    for client in ROOTS:
        names = _wrapper_names(client) if client in WRAPPER_FLAGS else COMMANDS[client]
        if client == "qoder":
            names = tuple(dict.fromkeys((*names, "qoder")))
        for name in names:
            functions.append(
                f'if (( $+commands[{name}] )) || [[ -x "$HOME/.local/bin/{name}" ]]; then '
                f'function {name} {{ _termyes_agent_yolo {client} {name} "$@"; }}; fi'
            )
    wrapped = "|".join(WRAPPER_FLAGS)
    flag_cases = "\n".join(
        f"    {client}) flags=({' '.join(flags)}) ;;"
        for client, flags in WRAPPER_FLAGS.items()
    )
    return """{marker}
_termyes_manage_path="${{TERMYES_MANAGE_PY:-/Applications/TermYes.app/Contents/Resources/AgentGuard/manage.py}}"

{argument_check}
_termyes_agent_yolo() {{
  emulate -L zsh
  local client="$1" entry="$2" ensure_output arg
  local -a flags=() header_lines=()
  shift 2
  _termyes_check_yolo_arguments "$client" "$@" || return $?
  if [[ ! -r "$_termyes_manage_path" ]]; then
    print -u2 "[TermYes] 缺少权限协调器：$_termyes_manage_path；继续启动 $client。"
  elif ! ensure_output="$(/usr/bin/python3 -B "$_termyes_manage_path" ensure "$client")"; then
    if [[ -n "$ensure_output" ]]; then
      print -ru2 -- "$ensure_output"
    fi
    print -u2 "[TermYes] $client 的命令守卫或 YOLO 检查失败；继续启动，请稍后检查守卫配置。"
  fi
  case "$client" in
    {wrapped})
      if [[ -x "$HOME/.local/bin/$entry" ]]; then
        header_lines=("${{(@f)$(/usr/bin/head -c 256 "$HOME/.local/bin/$entry")}}")
        if [[ "${{header_lines[1]:-}}" == '#!'* && "${{header_lines[2]:-}}" == "{marker}" ]]; then
          command "$HOME/.local/bin/$entry" "$@"
          return $?
        fi
      fi ;;
  esac
  case "$client" in
{flag_cases}
    codex) flags=(--dangerously-bypass-approvals-and-sandbox) ;;
    claude|codebuddy) flags=(--dangerously-skip-permissions) ;;
  esac
  for arg in "$@"; do
    [[ "$arg" == "--" ]] && break
    case "$client:$arg" in
      codex:--yolo|codex:--dangerously-bypass-approvals-and-sandbox|\
      claude:--dangerously-skip-permissions|codebuddy:--dangerously-skip-permissions)
        flags=(); break ;;
    esac
  done
  if [[ "$client" == "opencode" && "${{1:-}}" == "run" ]]; then
    shift
    DANGER_GUARD_BYPASS=1 command "$entry" run "${{flags[@]}}" "$@"
  elif [[ "$client" == "codebuddy" ]]; then
    CODEBUDDY_IS_SANDBOX=1 DANGER_GUARD_BYPASS=1 command "$entry" "${{flags[@]}}" "$@"
  else
    DANGER_GUARD_BYPASS=1 command "$entry" "${{flags[@]}}" "$@"
  fi
}}

{functions}
""".format(marker=MANAGED_MARKER, argument_check=_permission_arguments_content(),
           wrapped=wrapped, flag_cases=flag_cases, functions="\n".join(functions))


def _wrapper_names(client):
    if client == "cursor":
        return ("cursor-agent", "cursor")
    command = COMMANDS[client][0]
    return (command,)


def _ensure_wrapper(home, client):
    local_bin = home / ".local/bin"
    wrapper = local_bin / WRAPPER_NAME
    content = _wrapper_content().encode()
    if wrapper.exists():
        if wrapper.is_symlink() or not _is_managed_wrapper(wrapper):
            raise ValueError("已有非 TermYes wrapper，未覆盖：" + str(wrapper))
        if wrapper.read_bytes() != content or stat.S_IMODE(wrapper.stat().st_mode) != 0o755:
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
    # Relocating a launcher that resolves assets from its own filename silently
    # breaks the CLI. Keep it untouched rather than report a broken wrapper ready.
    with original.open("rb") as handle:
        is_script = handle.read(2) == b"#!"
    if is_script:
        script = original.read_text(encoding="utf-8", errors="replace")
        if re.search(r"\$0|\$\{0(?:\}|[^A-Za-z0-9_])|BASH_SOURCE|\$\{?\(%\).*%N|"
                     r"__file__|__dirname|__filename|import\.meta\.(?:url|dirname|filename)|"
                     r"sys\.argv\s*\[\s*0\s*\]|process\.argv\s*\[\s*1\s*\]", script):
            raise ValueError("启动脚本引用自身位置，不能安全迁移；原命令保持不变：" + str(original))
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
    block = (PATH_MARKER + '\nexport PATH="$HOME/.local/bin:$PATH"\n'
             + SHELL_MARKER + '\n'
             + f'[[ -r "$HOME/.local/bin/{SHELL_WRAPPER_NAME}" ]] && source "$HOME/.local/bin/{SHELL_WRAPPER_NAME}"\n'
             + "# End TermYes Agent YOLO shell\n")
    if text.endswith(block):
        return
    lines = text.splitlines()
    kept = []
    index = 0
    while index < len(lines):
        line = lines[index]
        if line in (PATH_MARKER, SHELL_MARKER):
            marker = line
            index += 1
            if index < len(lines):
                expected = ('export PATH="$HOME/.local/bin:$PATH"' if marker == PATH_MARKER
                            else f'[[ -r "$HOME/.local/bin/{SHELL_WRAPPER_NAME}" ]] && source "$HOME/.local/bin/{SHELL_WRAPPER_NAME}"')
                legacy = f'source "$HOME/.local/bin/{SHELL_WRAPPER_NAME}"'
                if lines[index] == expected or (marker == SHELL_MARKER and lines[index] == legacy):
                    index += 1
            continue
        if line != "# End TermYes Agent YOLO shell":
            kept.append(line)
        index += 1
    updated = "\n".join(kept).rstrip() + "\n" + block
    mode = stat.S_IMODE(zshrc.stat().st_mode) if zshrc.exists() else 0o600
    _atomic_write(zshrc, updated.encode(), mode)


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
        if client == "codebuddy" and result["permissionReady"]:
            result["permissionReason"] = "bypassPermissions 已配置；受管终端入口追加 CODEBUDDY_IS_SANDBOX=1 与免确认参数，守卫加载需实测"
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
        result["permissionReady"] = approval == "never" and sandbox == "danger-full-access"
        result["permissionReason"] = (
            "已处于 YOLO 模式"
            if result["permissionReady"]
            else "需要 approval_policy=never 与 sandbox_mode=danger-full-access"
        )
        return result
    if client in WRAPPER_FLAGS:
        if _underlying_path(home, client) is None:
            result["permissionMode"] = "no-cli-launcher"
            result["permissionReason"] = "检测到客户端，但没有可包装的命令行启动器"
            return result
        names = _wrapper_names(client)
        content = _wrapper_content().encode()
        managed = all(
            (home / ".local/bin" / name).is_file()
            and os.access(home / ".local/bin" / name, os.X_OK)
            and _is_managed_wrapper(home / ".local/bin" / name)
            and (home / ".local/bin" / name).read_bytes() == content
            for name in names
        )
        result["permissionMode"] = " ".join(WRAPPER_FLAGS[client]) if managed else "default"
        result["permissionReady"] = managed
        result["permissionReason"] = (
            "启动 wrapper 已强制免确认参数"
            if managed
            else "需要安装或更新可执行的免确认启动 wrapper"
        )
        return result
    result["permissionReason"] = "该客户端的免确认模式无法由 TermYes 自动配置"
    return result


def repair(home, client):
    before = inspect(home, client)
    if not before["detected"]:
        return {**before, "repaired": False}
    _retire_shell_policies(home, client)
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


def _retire_shell_policies(home, client):
    spec = _json_spec(client)
    if spec:
        relative, _, _ = spec
        root = home / ROOTS[client]
        paths = [root / relative]
        if client in ("claude", "codebuddy", "qoder"):
            paths.append(root / "settings.local.json")
        for path in paths:
            if not path.exists():
                continue
            _checked_path(path)
            data = _read_json(path)
            before = json.dumps(data, sort_keys=True)
            data = without_shell_policies(data)
            if json.dumps(data, sort_keys=True) != before:
                _write_json(path, data)
    if client == "codex":
        path = home / ".codex/rules/danger-guard.rules"
        if path.exists():
            _checked_path(path)
            if path.read_text().startswith("# 本文件由 gen_codex_rules.py 从 rules.py 生成,请勿手改"):
                path.unlink()


def without_shell_policies(data):
    data = json.loads(json.dumps(data))
    for owner in (data, data.get("permissions", {}), data.get("permission", {})):
        if not isinstance(owner, dict):
            continue
        for key in ("deny", "ask", "disallowedTools"):
            entries = owner.get(key)
            if isinstance(entries, list):
                owner[key] = [x for x in entries if not (isinstance(x, str)
                              and re.match(r"^(?:Bash|shell|run_shell_command)(?:\(|$)", x))]
    return data


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
