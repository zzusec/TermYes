#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""TermYes shell-text classifier migrated from bypass-yes (see LICENSE).

classify(command, absolute_cwd) returns block or safe. Internal warn becomes block.
"safe" means no rule matched, not a guarantee of safety. Client hooks decide protocol.
"""

import datetime
import json
import os
from pathlib import Path
import re
import shlex
import subprocess
import stat
import time

import rules

# 各家对 shell 工具的命名:Claude/CodeBuddy/zcode/Qoder 用 Bash,Codex 用 shell / local_shell,
# Gemini CLI 用 run_shell_command,Factory droid 用 Execute。
# pi / opencode / Crush 的小写 bash 由各自入口自行过滤、agy 的 run_command 同理、
# Cursor 的 beforeShellExecution 事件不带工具名(直接给 command),都不走这里。
TOOL_NAMES = ("Bash", "shell", "local_shell", "run_shell_command", "Execute")

SOUND_FILE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "chime.wav")
SOUND_VOLUME = "0.5"  # afplay 相对系统音量的比例(0~1)
QUIET_HOURS_CONFIG_ENV = "TERMOSAIC_QUIET_HOURS_CONFIG"
DEFAULT_QUIET_HOURS_CONFIG = os.path.expanduser(
    "~/Library/Application Support/Termosaic/AgentGuard/quiet-hours.json"
)
GUARD_PROBE_TOKEN_ENV = "TERMYES_GUARD_PROBE_TOKEN"
GUARD_PROBE_RECEIPT_ENV = "TERMYES_GUARD_PROBE_RECEIPT"

GUARD_RUNTIME_ROOTS = {
    "claude": ".claude", "codex": ".codex", "codebuddy": ".codebuddy",
    "zcode": ".zcode/cli", "pi": ".pi/agent", "qoder": ".qoder",
    "gemini": ".gemini", "cursor": ".cursor", "agy": ".gemini",
    "opencode": ".config/opencode", "droid": ".factory",
    "crush": ".config/crush", "copilot": ".copilot",
}


def guard_pause_path(home, client):
    if client not in GUARD_RUNTIME_ROOTS:
        raise ValueError("未知 Agent")
    return Path(home) / "Library/Application Support/Termosaic/AgentGuard/pauses" / (client + ".json")


def guard_paused_until(home, client, now=None):
    """Only a valid, private user decision can suspend this client's review."""
    path = guard_pause_path(home, client)
    for item in (path, *path.parents):
        if item.is_symlink():
            raise ValueError("审查暂停配置不能是符号链接：" + str(item))
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    except FileNotFoundError:
        return None
    with os.fdopen(fd, "r", encoding="utf-8") as handle:
        info = os.fstat(handle.fileno())
        if (not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid()
                or stat.S_IMODE(info.st_mode) != 0o600 or info.st_size > 4096):
            raise ValueError("审查暂停配置必须为当前用户的 0600 普通文件")
        record = json.load(handle)
    if (not isinstance(record, dict) or record.get("client") != client
            or not isinstance(record.get("expiresAt"), str)
            or not re.fullmatch(r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z", record["expiresAt"])):
        raise ValueError("审查暂停配置格式无效")
    expires = datetime.datetime.fromisoformat(record["expiresAt"].replace("Z", "+00:00"))
    current = now or datetime.datetime.now(datetime.timezone.utc)
    return record["expiresAt"] if expires > current else None


def installed_guard_identity():
    # The installed code location identifies the client, never hook input or env.
    location = Path(__file__).absolute()
    for client, root in GUARD_RUNTIME_ROOTS.items():
        suffix = Path(root) / ("guard" if client == "pi" else "hooks") / "termosaic" / client / "core.py"
        if location.parts[-len(suffix.parts):] == suffix.parts:
            return location.parents[len(suffix.parts) - 1], client
    return None


# ============================================================
# 预处理:屏蔽「数据」,补扫「会被执行的代码」
# ============================================================

def strip_shell_comments(cmd):
    """Mask comments at unquoted word boundaries, preserving offsets/newlines."""
    out = []
    quote = None
    word_start = True
    i, n = 0, len(cmd)
    while i < n:
        c = cmd[i]
        if quote:
            out.append(c)
            if quote in ('"', "$'") and c == "\\" and i + 1 < n:
                out.append(cmd[i + 1])
                i += 2
                continue
            if c == quote[-1]:
                quote = None
            i += 1
        elif c == "\\" and i + 1 < n:
            out.append(cmd[i:i + 2])
            if cmd[i + 1] != "\n":
                word_start = False
            i += 2
        elif cmd.startswith("$'", i):
            quote = "$'"
            word_start = False
            out.append("$'")
            i += 2
        elif c in ("'", '"'):
            quote = c
            word_start = False
            out.append(c)
            i += 1
        elif c == "#" and word_start:
            end = cmd.find("\n", i)
            end = n if end < 0 else end
            out.append(" " * (end - i))
            i = end
        else:
            out.append(c)
            word_start = c in " \t\n;|&()<>"
            i += 1
    return "".join(out)


def mask_strings(cmd):
    """把引号内字符串内容替换为空格,使命令中的「数据词」(SQL、commit 信息、echo 文本、
    参数值等)不再误触危险规则;保留引号本身及引号外的 shell 结构(管道、重定向)。"""
    cmd = strip_shell_comments(cmd)
    out = []
    quote = None
    i, n = 0, len(cmd)
    while i < n:
        c = cmd[i]
        if quote:
            # 双引号与 ANSI-C 引号内的反斜杠转义。
            if quote in ('"', "$'") and c == '\\' and i + 1 < n:
                out.append('  ')
                i += 2
                continue
            if c == quote[-1]:
                out.append(c)
                quote = None
            else:
                out.append('\n' if c == '\n' else ' ')
            i += 1
        else:
            if cmd.startswith("$'", i):
                quote = "$'"
                out.append("$'")
                i += 2
                continue
            if c in ('"', "'"):
                quote = c
            out.append(c)
            i += 1
    return ''.join(out)


def shell_words(segment):
    """Return quote-removed words with their source spelling, without evaluating them."""
    words = []
    i = 0
    while i < len(segment):
        if segment[i].isspace():
            i += 1
            continue
        start = i
        value = []
        quote = None
        while i < len(segment):
            char = segment[i]
            if quote is None and char.isspace():
                break
            if quote is None and segment.startswith("$'", i):
                quote = "$'"
                i += 2
                continue
            if quote == "$'" and char == "\\":
                match = re.match(r"\\(?:[\\'\"abfnrtv]|[0-7]{1,3}|x[0-9a-fA-F]{1,2}|u[0-9a-fA-F]{4}|U[0-9a-fA-F]{8})", segment[i:])
                if match:
                    value.append(match[0].encode("ascii").decode("unicode_escape"))
                    i += len(match[0])
                    continue
            if char == "\\" and quote != "'" and i + 1 < len(segment):
                following = segment[i + 1]
                if quote is None or following in '$`"\\\n':
                    if following != "\n":
                        value.append(following)
                    i += 2
                    continue
            if quote is None and char in "'\"":
                quote = char
            elif quote and char == quote[-1]:
                quote = None
            else:
                value.append(char)
            i += 1
        if quote:
            raise ValueError("命令引号未闭合")
        words.append(("".join(value), segment[start:i]))
    return words


def command_arguments(args):
    """Peel common executable wrappers, never words contained in a data argument."""
    args = list(args)
    while args:
        while args and ASSIGN_RE.match(args[0]):
            args.pop(0)
        if not args:
            break
        name = os.path.basename(args[0])
        if name not in ("sudo", "env", "command", "exec", "nohup", "time"):
            break
        args.pop(0)
        while args and args[0].startswith("-"):
            option = args.pop(0)
            if option == "--":
                break
            if option in ("-u", "-g", "-h", "-p", "-C", "-D", "-T", "--user", "--group", "--host", "--prompt", "--chdir", "--unset") and args:
                args.pop(0)
    return args


def is_shell(name):
    return os.path.basename(name) in ("sh", "bash", "zsh", "dash", "ksh", "ash", "csh", "tcsh")


def extract_substitutions(cmd):
    """Find executable substitutions, but not single-quoted or escaped examples."""
    payloads = []
    quote = None
    i = 0
    while i < len(cmd):
        char = cmd[i]
        if char == "\\" and quote != "'":
            i += 2
            continue
        if quote in ("'", "$'"):
            if char == "'":
                quote = None
            i += 1
            continue
        if quote is None and cmd.startswith("$'", i):
            quote = "$'"
            i += 2
            continue
        if char == "'" and quote is None:
            quote = "'"
        elif char == '"':
            quote = None if quote == '"' else '"'
        elif cmd.startswith("$(", i):
            end = _skip_cmdsub(cmd, i + 2)
            if end is None:
                break
            # Arithmetic expansion is not a shell command, but may contain one.
            body = cmd[i + 2:end - 1]
            payloads.extend(extract_substitutions(body) if body.startswith("(") else [body])
            i = end
            continue
        elif char == "`":
            end = i + 1
            while end < len(cmd) and cmd[end] != "`":
                end += 2 if cmd[end] == "\\" else 1
            if end >= len(cmd):
                break
            payloads.append(cmd[i + 1:end])
            i = end + 1
            continue
        i += 1
    return payloads


def extract_code(cmd):
    """Extract only executable shell/eval arguments and command substitutions."""
    cmd = strip_shell_comments(cmd)
    payloads = extract_substitutions(cmd)
    outer = mask_cmd_subs(cmd)
    if outer is None:
        return payloads
    for segment in shell_segments(outer):
        args = command_arguments([word for word, _ in shell_words(segment)])
        if not args:
            continue
        if os.path.basename(args[0]) == "eval":
            payloads.append(" ".join(args[1:]))
        elif is_shell(args[0]):
            for index, arg in enumerate(args[1:], 1):
                if arg == "--" or not arg.startswith("-"):
                    break
                if re.fullmatch(r"-[A-Za-z]*c[A-Za-z]*", arg) and index + 1 < len(args):
                    payloads.append(args[index + 1])
                    break
    return payloads


def heredoc_parts(cmd):
    """Separate quoted heredoc data from bodies passed to an actual shell."""
    if "<<" not in cmd:
        return cmd, []
    lines = cmd.split("\n")
    out, payloads = [], []
    i = 0
    while i < len(lines):
        line = lines[i]
        out.append(line)
        delims = []
        bare = False
        for match in re.finditer(r"<<-?", mask_strings(line)):
            delimiter = re.match(r"\s*(?:'([^']*)'|\"([^\"]*)\")", line[match.end():])
            if delimiter:
                prefix = shell_segments(line[:match.start()])
                args = command_arguments([word for word, _ in shell_words(prefix[-1])]) if prefix else []
                executable = bool(args and is_shell(args[0]))
                delims.append((delimiter.group(1) if delimiter.group(1) is not None else delimiter.group(2),
                               match[0].endswith("-"), executable))
            else:
                bare = True  # Preserve existing handling of unquoted expansion/<<<.
        i += 1
        if bare or not delims:
            continue
        for delimiter, strip_tabs, executable in delims:
            body = []
            while i < len(lines) and (lines[i].lstrip("\t") if strip_tabs else lines[i]) != delimiter:
                body.append(lines[i].lstrip("\t") if strip_tabs else lines[i])
                out.append("")
                i += 1
            if i < len(lines):
                out.append("")
                i += 1
            if executable:
                payloads.append("\n".join(body))
    return "\n".join(out), payloads


def strip_heredocs(cmd):
    return heredoc_parts(cmd)[0]


def build_scan_text(cmd, depth=0):
    """Mask data while preserving executable names, options and path operands."""
    if depth >= 16:
        raise ValueError("Shell 嵌套过深，无法可靠判定")
    cmd, heredocs = heredoc_parts(strip_shell_comments(cmd))
    masked = mask_strings(cmd)
    outer = mask_cmd_subs(cmd)
    normalized = []
    if outer is not None:
        for segment in shell_segments(outer):
            words = shell_words(segment)
            args = command_arguments([value for value, _ in words])
            if not args:
                continue
            # Shell payloads are parsed recursively below, never as flat strings.
            # The first argv word is executable even when the shell quotes it.
            start = len(words) - len(args)
            name = os.path.basename(args[0])
            parts = [name]
            for index, (value, spelling) in enumerate(words[start + 1:], 1):
                semantic = (
                    (name in ("git", "npm", "docker", "diskutil") and index == 1)
                    or (name in ("git", "crontab", "docker", "chmod", "chown") and value.startswith("-"))
                    or (name in ("chmod", "chown") and value.startswith("/"))
                    or (name == "dd" and value.startswith("of="))
                )
                parts.append(value if semantic and not any(c.isspace() for c in value) else mask_strings(spelling))
            normalized.append(" ".join(parts))
    payloads = extract_code(cmd) + heredocs
    return "\n".join([masked, *normalized, *(build_scan_text(payload, depth + 1) for payload in payloads)])


# ============================================================
# 提示音 / 本地提示
# ============================================================

def play_sound():
    """后台异步播放提示音,不阻塞决策返回。"""
    if os.environ.get("DANGER_GUARD_SILENT"):   # 回归测试批量跑用例时静音
        return
    if in_quiet_hours():
        return
    try:
        subprocess.Popen(
            ["afplay", "-v", SOUND_VOLUME, SOUND_FILE],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
    except Exception:
        pass


def _parse_clock(value):
    if not isinstance(value, str):
        return None
    match = re.fullmatch(r"(\d{1,2}):(\d{2})", value.strip())
    if not match:
        return None
    hour, minute = int(match.group(1)), int(match.group(2))
    if hour > 23 or minute > 59:
        return None
    return hour * 60 + minute


def in_quiet_hours(now=None):
    """Return True when the configured local-time quiet period is active."""
    path = os.environ.get(QUIET_HOURS_CONFIG_ENV) or DEFAULT_QUIET_HOURS_CONFIG
    try:
        with open(path, "r", encoding="utf-8") as handle:
            config = json.load(handle)
        if not isinstance(config, dict) or config.get("enabled") is not True:
            return False
        start = _parse_clock(config.get("start"))
        end = _parse_clock(config.get("end"))
        if start is None or end is None or start == end:
            return False
        current = now or datetime.datetime.now()
        minute = current.hour * 60 + current.minute
        if start < end:
            return start <= minute < end
        return minute >= start or minute < end
    except Exception:
        return False


def _osa_quote(s):
    """转成 AppleScript 字符串字面量(只有通知中心那条路用得到)。"""
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'


def notify_user(cmd, reason):
    """把「为什么被拦」写到命令行,不等待输入、不弹系统对话框。

    提示直接写 /dev/tty,也就是你跑 Claude / CodeBuddy 的那个终端;
    写不到就拉倒(TUI 可能重绘盖掉,CI 里压根没有 tty)。
    rules.NOTIFY_CENTER = True 时额外发一条 macOS 通知中心横幅(不带按钮、不抢焦点)。

    返回是否成功写到终端。声音由调用方在前面响(core.play_sound)。
    """
    if os.environ.get("DANGER_GUARD_ASK") == "0":
        return False
    shown = " ".join(cmd.split())[:400]
    text = ("[命令守卫] 已拦截:%s\n  %s\n  请改用安全方案；不要重复尝试或绕过守卫"
            % (reason, shown))
    written = False
    try:
        fd = os.open("/dev/tty", os.O_WRONLY)
        try:
            os.write(fd, ("\n" + text + "\n").encode("utf-8"))
            written = True
        finally:
            os.close(fd)
    except Exception:
        pass
    if getattr(rules, "NOTIFY_CENTER", False):
        try:
            subprocess.run(
                ["osascript", "-e",
                 'display notification %s with title "命令守卫" subtitle "已拦截"'
                 % _osa_quote(text)],
                capture_output=True, timeout=5)
        except Exception:
            pass
    return written


# ============================================================
# rm 目标分级
# ============================================================

CMDSUB_TOKEN = "$__CMDSUB__"


def _skip_cmdsub(cmd, i):
    """从 `$(` 之后开始扫描,返回配对 `)` 之后的下标;不闭合返回 None。"""
    depth = 1
    n = len(cmd)
    while i < n:
        c = cmd[i]
        if cmd.startswith("$'", i):
            i += 2
            while i < n and cmd[i] != "'":
                i += 2 if cmd[i] == "\\" else 1
            if i >= n:
                return None
            i += 1
        elif c == "'":
            j = cmd.find("'", i + 1)
            if j < 0:
                return None
            i = j + 1
        elif c == '"':
            i += 1
            while i < n and cmd[i] != '"':
                i += 2 if cmd[i] == "\\" else 1
            if i >= n:
                return None
            i += 1
        elif c == "\\":
            i += 2
        elif cmd.startswith("$(", i):
            depth += 1
            i += 2
        elif c == "(":
            depth += 1
            i += 1
        elif c == ")":
            depth -= 1
            i += 1
            if depth == 0:
                return i
        else:
            i += 1
    return None


def mask_cmd_subs(cmd):
    """把 $(...) / `...` 整段换成占位符 $__CMDSUB__;引号或命令替换不闭合返回 None。

    以前只要命令里出现过 $( 就整条放弃 rm 分级 → 一律 ask,像
    `B=$(osascript ...); rm -rf ~/Downloads/x.app` 这种命令替换跟 rm 目标毫无关系的
    也被误拦。换成占位符后:沾到它的赋值/rm 目标展开不出值,照旧按「目标不明」判 warn,
    其余目标仍按真实路径分级。
    """
    cmd = strip_shell_comments(cmd)
    out = []
    i, n = 0, len(cmd)
    in_dq = False
    while i < n:
        c = cmd[i]
        if c == "\\" and i + 1 < n:
            out.append(cmd[i:i + 2])
            i += 2
        elif not in_dq and cmd.startswith("$'", i):
            j = i + 2
            while j < n and cmd[j] != "'":
                j += 2 if cmd[j] == "\\" else 1
            if j >= n:
                return None
            out.append(cmd[i:j + 1])
            i = j + 1
        elif not in_dq and c == "'":
            j = cmd.find("'", i + 1)
            if j < 0:
                return None
            out.append(cmd[i:j + 1])
            i = j + 1
        elif c == '"':
            in_dq = not in_dq
            out.append(c)
            i += 1
        elif c == "`":
            j = i + 1
            while j < n and cmd[j] != "`":
                j += 2 if cmd[j] == "\\" else 1
            if j >= n:
                return None
            out.append(CMDSUB_TOKEN)
            i = j + 1
        elif cmd.startswith("$(", i):
            j = _skip_cmdsub(cmd, i + 2)
            if j is None:
                return None
            out.append(CMDSUB_TOKEN)
            i = j
        else:
            out.append(c)
            i += 1
    if in_dq:
        return None
    return "".join(out)


def shell_segments(cmd):
    """Split top-level shell commands without cutting quoted or substituted code."""
    out, buf = [], []
    quote = None
    i = 0
    while i < len(cmd):
        c = cmd[i]
        if c == "\\" and quote != "'" and i + 1 < len(cmd):
            buf.append(cmd[i:i + 2])
            i += 2
            continue
        if quote not in ("'", "$'") and cmd.startswith("$(", i):
            end = _skip_cmdsub(cmd, i + 2)
            if end is None:
                return []
            buf.append(cmd[i:end])
            i = end
            continue
        if quote not in ("'", "$'") and c == "`":
            end = i + 1
            while end < len(cmd) and cmd[end] != "`":
                end += 2 if cmd[end] == "\\" else 1
            if end >= len(cmd):
                return []
            buf.append(cmd[i:end + 1])
            i = end + 1
            continue
        if quote:
            buf.append(c)
            if c == quote[-1]:
                quote = None
        elif cmd.startswith("$'", i):
            quote = "$'"
            buf.append("$'")
            i += 2
            continue
        elif c in ("'", '"'):
            quote = c
            buf.append(c)
        elif c in ";|&\n":
            if "".join(buf).strip():
                out.append("".join(buf))
            buf = []
        else:
            buf.append(c)
        i += 1
    if quote:
        return []
    if "".join(buf).strip():
        out.append("".join(buf))
    return out


def rm_level(kind, policy):
    if kind in policy["block"]:
        return "block"
    if kind in policy["warn"]:
        return "warn"
    return "safe"


def rm_target_level(path, cwd, home, policy):
    """单个 rm -rf 目标的级别:
    block = 根/家目录/整个用户目录/一级系统目录;
    warn  = 整个项目级(git 仓库根、家目录直接子项、当前所在目录)、系统路径、看不清的目标;
    safe  = 普通目录/文件(项目内子目录、临时目录等)。"""
    if re.search(r"[$`]", path):
        return rm_level("unknown", policy)  # 变量/命令替换,目标真的看不清
    glob = re.search(r"[*?\[]", path)
    if glob:
        # 通配符不展开,只按它前面的固定父目录判级。
        # 通配符按固定父目录的清单分类判定。
        head = path[:glob.start()]
        prefix, stub = head.rsplit("/", 1) if "/" in head else ("", head)
        if prefix in policy["temporaryRoots"] and stub:
            return "safe"      # /tmp/foo-* 具名前缀；清空整个临时目录按清单拒绝
        parent = prefix or ("/" if path.startswith("/") else ".")
        return rm_target_level(parent, cwd, home, policy)
    if path == "~":
        p = home
    elif path.startswith("~/"):
        p = os.path.join(home, path[2:])
    elif path.startswith("/"):
        p = path
    elif cwd:
        p = os.path.join(cwd, path)
    else:
        return rm_level("unknown", policy)
    p = os.path.normpath(p)

    if p == "/":
        return rm_level("root", policy)
    if p == home:
        return rm_level("home", policy)
    parts = p.strip("/").split("/")
    if len(parts) == 1:
        return rm_level("top_level", policy)  # /etc、/usr、/tmp 等一级目录整删
    if parts[0] == "Users" and len(parts) == 2:
        return rm_level("user_home", policy)  # 整个用户目录

    if cwd:
        ncwd = os.path.normpath(cwd)
        if p == ncwd or ncwd.startswith(p + "/"):
            return rm_level("cwd_tree", policy)  # 删当前所在目录(所在项目)或其祖先
    inside_home = p.startswith(home + "/")
    if inside_home and "/" not in p[len(home) + 1:]:
        return rm_level("home_child", policy)  # 家目录直接子项,多半是整个项目/重要目录

    # 临时目录要在 .git 之前判掉:/tmp 下的一律算临时,包括临时 git clone。
    # 否则下面的 .git 检查会把 /tmp/某个仓库 当成「整个项目」拦下来 ——
    # 删不掉自己刚 clone 的目录,很常见也很烦。
    if any(p.startswith(root + "/") for root in policy["temporaryRoots"]):
        return "safe"

    try:
        if os.path.isdir(os.path.join(p, ".git")):
            return rm_level("git_root", policy)  # git 仓库根 = 整个项目
    except OSError:
        return rm_level("unknown", policy)

    if inside_home:
        return "safe"
    return rm_level("outside_home", policy)  # 系统路径、其他用户、外接卷等


ASSIGN_RE = re.compile(r"^([A-Za-z_]\w*)=(.*)$", re.S)


def expand_vars(text, env):
    """用同条命令里收集到的字面量赋值展开 $VAR / ${VAR};有未知变量返回 None(上层硬拒绝)。"""
    if "$" not in text:
        return text
    unknown = []

    def repl(m):
        name = m.group(1) or m.group(2)
        if name in env:
            return env[name]
        unknown.append(name)
        return ""

    out = re.sub(r"\$\{(\w+)\}|\$(\w+)", repl, text)
    return None if unknown else out


def classify_rm_targets(cmd, cwd, policy, env=None, depth=0):
    """Aggregate every executed rm, including wrappers, with local shell state."""
    if depth >= 16:
        return rm_level("unknown", policy)
    cmd, heredocs = heredoc_parts(strip_shell_comments(cmd))
    home = os.path.expanduser("~")
    env = {"HOME": home, **(env or {})}
    directories = [cwd]
    levels = []
    for segment in shell_segments(cmd):
        # Substitutions execute before the outer command. Their directory/env
        # changes do not propagate out of their subshell.
        for payload in extract_substitutions(segment):
            for directory in directories:
                level = classify_rm_targets(payload, directory, policy, env, depth + 1)
                if level is not None:
                    levels.append(level)
        outer = mask_cmd_subs(segment)
        if outer is None:
            levels.append(rm_level("unknown", policy))
            continue
        words = shell_words(outer)
        args = [value for value, _ in words]
        if not args:
            continue
        local_env = dict(env)
        index = 1 if args[0] == "export" else 0
        while index < len(args):
            match = ASSIGN_RE.match(args[index])
            if not match:
                break
            value = expand_vars(match.group(2), local_env)
            if value is None:
                local_env.pop(match.group(1), None)
            else:
                local_env[match.group(1)] = value
            index += 1
        # NAME=value command has a temporary environment; it cannot rewrite the
        # shell's later $NAME. Operands of that command expand in the original env.
        if index == len(args) or args[0] == "export":
            env = local_env
            continue
        invocation = args[index:]
        args = command_arguments(invocation)
        if not args:
            continue
        command_directories = directories
        if invocation and os.path.basename(invocation[0]) in ("env", "sudo"):
            # These wrapper flags change only the child's directory. An unknown
            # relative target must not be resolved against the outer shell's cwd.
            flags = invocation[1:len(invocation) - len(args)]
            if any(flag in ("-C", "-D", "--chdir") or flag.startswith("--chdir=") for flag in flags):
                command_directories = [None]
        name = os.path.basename(args[0])
        if name == "cd":
            targets = [value for value in args[1:] if value != "--"]
            target = expand_vars(targets[0], env) if len(targets) == 1 else home if not targets else None
            if target is not None and target != "-":
                if target == "~" or target.startswith("~/"):
                    target = home + target[1:]
                updated = [os.path.normpath(target if os.path.isabs(target) else os.path.join(directory, target))
                           if directory is not None or os.path.isabs(target) else None for directory in directories]
            else:
                updated = [None]
            # A preceding cd may fail (or live on the other side of ||). Keep
            # every possible directory rather than assuming the safe branch ran.
            directories = list(dict.fromkeys(directories + updated))
            continue
        for payload in extract_code(outer):
            for directory in command_directories:
                level = classify_rm_targets(payload, directory, policy, local_env, depth + 1)
                if level is not None:
                    levels.append(level)
        if name != "rm":
            # Compound shell grammar (if/for/groups/functions) is not fully
            # interpreted here. Do not let a known safe deletion elsewhere turn
            # an unparsed executable rm into a safe result. Quoted data stays masked.
            for match in re.finditer(r"\brm\b([^;&|\n()]*)", mask_strings(outer)):
                options = match.group(1)
                if ((re.search(r"(?:^|\s)-\w*r", options, re.I) or "--recursive" in options)
                        and (re.search(r"(?:^|\s)-\w*f", options, re.I) or "--force" in options)):
                    levels.append(rm_level("unknown", policy))
            continue
        has_r = has_f = False
        operands = []
        end_options = False
        for arg in args[1:]:
            if not end_options and arg == "--":
                end_options = True
            elif not end_options and arg.startswith("-") and arg != "-":
                has_r = has_r or arg == "--recursive" or (not arg.startswith("--") and "r" in arg[1:].lower())
                has_f = has_f or arg == "--force" or (not arg.startswith("--") and "f" in arg[1:].lower())
            else:
                operands.append(arg)
        if has_r and has_f:
            if not operands:
                levels.append(rm_level("unknown", policy))
            for path in operands:
                path = expand_vars(path, env) or path
                levels.extend(rm_target_level(path, directory, home, policy) for directory in command_directories)
    for payload in heredocs:
        for directory in directories:
            level = classify_rm_targets(payload, directory, policy, env, depth + 1)
            if level is not None:
                levels.append(level)
    return "block" if "block" in levels else "warn" if "warn" in levels else "safe" if levels else None


# ============================================================
# 对外唯一入口
# ============================================================

def _guard_probe(cmd):
    token = os.environ.get(GUARD_PROBE_TOKEN_ENV, "")
    receipt = os.environ.get(GUARD_PROBE_RECEIPT_ENV, "")
    # A shared Agent daemon does not inherit the requesting CLI's environment.
    # Only the exact safe probe with a fresh, owner-only authorization may use
    # the file-backed receipt protocol; ordinary commands remain unchanged.
    if not token:
        match = re.fullmatch(
            r"/usr/bin/printf %s ([a-f0-9]{32}) > /tmp/termyes-guard-executed-\1", cmd
        )
        if not match:
            return False
        token = match.group(1)
        authorization = "/tmp/termyes-guard-request-" + token
        try:
            fd = os.open(authorization, os.O_RDONLY | os.O_NOFOLLOW)
            with os.fdopen(fd, "r") as handle:
                info = os.fstat(handle.fileno())
                if (not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid()
                        or stat.S_IMODE(info.st_mode) != 0o600
                        or not 0 <= time.time() - info.st_mtime <= 300
                        or handle.read(64) != token):
                    return False
        except OSError:
            return False
        receipt = "/tmp/termyes-guard-receipt-" + token
    if not re.fullmatch(r"[a-f0-9]{32}", token) or token not in cmd:
        return False
    real_receipt = os.path.realpath(receipt)
    if (not re.fullmatch(r"/private/tmp/termyes-guard-receipt-[a-f0-9]{32}", real_receipt)
            or os.path.lexists(receipt)):
        return False
    try:
        fd = os.open(receipt, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            handle.write(token)
        return True
    except OSError:
        return False


def classify(cmd, cwd=None, bypass=None):
    """TermYes: every warning is a denial, regardless of client/permission mode.

    ponytail: retain the legacy bypass argument for adapters, but it cannot weaken policy.
    An explicit per-client pause skips policy, never payload validation.
    This is a shell-text accident guard, not a sandbox or a proof of command safety.
    """
    if not isinstance(cmd, str) or not cmd.strip() or len(cmd) > 262144:
        raise ValueError("缺失、无效或过长的命令")
    if not isinstance(cwd, str) or not os.path.isabs(cwd):
        raise ValueError("缺失或无效的工作目录")
    if mask_cmd_subs(strip_heredocs(cmd)) is None:
        return "block", "命令引号或替换表达式未闭合，无法可靠判定"
    identity = installed_guard_identity()
    if identity and guard_paused_until(*identity):
        return "safe", "此 Agent 的命令审查已临时暂停，危险命令也不拦截"
    if _guard_probe(cmd):
        return "block", "TermYes 守卫端到端验证命令"
    level, reason = _classify(cmd, cwd)
    return ("block", reason) if level == "warn" else (level, reason)


def _classify(cmd, cwd=None):
    scan = build_scan_text(cmd)
    cwd = cwd or os.getcwd()
    policy, _ = rules.active_policy()

    rm_policy = policy["rm"]
    rm = classify_rm_targets(cmd, cwd, rm_policy)

    if rm == "block":
        return "block", rm_policy["blockReason"]

    for pattern, reason in policy["block"]:
        if re.search(pattern, scan):
            return "block", reason

    if rm == "warn":
        return "warn", rm_policy["warnReason"]

    for pattern, reason in policy["warn"]:
        if re.search(pattern, scan):
            return "warn", reason

    return "safe", rules.RM_SAFE_REASON if rm == "safe" else "未命中危险规则，交回客户端原有权限流程"


def get_command(data):
    """Validate hook input; never classify missing/ambiguous arguments as safe."""
    tool_input = data.get("tool_input")
    if not isinstance(tool_input, dict):
        raise ValueError("无效的 tool_input")
    return command_text(tool_input.get("command"))


def command_text(cmd):
    if isinstance(cmd, list):
        if not cmd or not all(isinstance(x, str) for x in cmd):
            raise ValueError("无效的命令参数")
        cmd = shlex.join(cmd)
    if not isinstance(cmd, str) or not cmd.strip():
        raise ValueError("缺失命令")
    return cmd


# ============================================================
# 会话毒化 token 守卫
# ============================================================
# 背景：某些上游模型（如 weixin-glm/Deepseek-v4-flash）会把全角尖括号包裹的
# "<｜deepseek_image｜>" 当成真正的图片特殊 token。它一旦进入会话历史的任意一条
# function_call_output，后续每个请求都会被上游以 400 拒绝，整个会话报废，
# 只能开新会话重述任务（上下文里的历史无法删除）。
#
# 只在命令文本进入上下文之前中和，副作用仅限本地 shell 命令，
# 不碰任何真实文件或远端内容。
# 实测触发形态：只有完整的 "<｜identifier｜>" 会打死请求；
# 半角 "<identifier>"、"<｜identifier｜"、"identifier｜>" 均不触发。

import re as _re

# 已知会打死上游请求的 token：字面量 -> 安全写法
TOXIC_TOKENS = {
    "<\uff5cdeepseek_image\uff5c>": "<deepseek_image>",
}

# 兜底：任何 <｜全角竖线包裹的标识符｜> 都按同样规则中和
TOXIC_GENERIC_RE = _re.compile(r"<\uff5c([A-Za-z0-9_.-]{1,64})\uff5c>")

TOXIC_GUARD_LOG = os.environ.get(
    "TOXIC_GUARD_LOG",
    os.path.expanduser("~/.codex/hooks/toxic-token-guard.log"),
)
TOXIC_GUARD_DISABLE = "TOXIC_GUARD_DISABLE"


def neutralize_toxic_tokens(text):
    """把会话毒化 token 中和成等义的安全写法。

    返回 (改写后的文本, 命中次数)。不改变任何非 token 内容。
    """
    if not isinstance(text, str) or not text:
        return text, 0
    hits = 0
    out = text
    for bad, good in TOXIC_TOKENS.items():
        if bad in out:
            hits += out.count(bad)
            out = out.replace(bad, good)

    def _sub(m):
        nonlocal hits
        hits += 1
        return "<%s>" % m.group(1)

    out = TOXIC_GENERIC_RE.sub(_sub, out)
    return out, hits


def log_toxic_hit(hits, tool_name, cwd):
    try:
        with open(TOXIC_GUARD_LOG, "a", encoding="utf-8") as fh:
            fh.write("neutralized %d toxic token(s) tool=%s cwd=%s\n"
                     % (hits, tool_name, cwd))
    except Exception:
        pass
