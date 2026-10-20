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


def extract_code(cmd):
    """提取会被 shell 重新执行的内联代码(bash -c / sh -c / eval),作为危险扫描的补充输入,
    防止把真正危险命令藏在引号里绕过 mask_strings()。"""
    def literal_text(literal):
        if literal.startswith("$'"):
            # Decode ASCII escape sequences only; preserve surrounding Unicode.
            return re.sub(
                r"\\(?:[\\'\"abfnrtv]|[0-7]{1,3}|x[0-9a-fA-F]{1,2}|u[0-9a-fA-F]{4}|U[0-9a-fA-F]{8})",
                lambda match: match[0].encode("ascii").decode("unicode_escape"),
                literal[2:-1],
            )
        return literal[1:-1] if literal[0] in "'\"" else literal

    payloads = []
    literal_pattern = r"(\$'(?:\\.|[^'\\])*'|'[^']*'|\"[^\"]*\"|\S+)"
    for m in re.finditer(r"\b(?:ba|z|da|t?c|k|a)?sh\b[^\n;|&]*?\s-c\s+" + literal_pattern, cmd):
        literal = m.group(1)
        payloads.append(literal_text(literal))
    for m in re.finditer(r"\beval\s+(\$'(?:\\.|[^'\\])*'|'[^']*'|\"[^\"]*\"|[^\n;|&]+)", cmd):
        literal = m.group(1)
        payloads.append(literal_text(literal))
    return payloads


def strip_heredocs(cmd):
    """把「定界符带引号」的 heredoc 正文清空(<<'EOF' / <<"EOF")。

    这类正文不做变量/命令替换,也不会被当作命令执行,是纯数据 —— 里面的 JS 模板串反引号、
    SQL、$(...)、reboot 之类的词都不该影响判定(否则写个 seed 脚本都要弹确认)。
    不带引号的 <<EOF 正文会被 shell 展开(可能触发命令替换),保持原样继续扫描。
    """
    if "<<" not in cmd:
        return cmd
    lines = cmd.split("\n")
    mlines = mask_strings(cmd).split("\n")   # 与原文等长,用来判断 << 是否在引号外
    if len(mlines) != len(lines):
        return cmd
    out = []
    i = 0
    while i < len(lines):
        out.append(lines[i])
        delims = []
        bare = False
        for m in re.finditer(r"<<-?", mlines[i]):
            dm = re.match(r"\s*(?:'([^']*)'|\"([^\"]*)\")", lines[i][m.end():])
            if dm:
                delims.append(dm.group(1) if dm.group(1) is not None else dm.group(2))
            else:
                bare = True   # <<EOF / <<< / << 变量:交给原逻辑保守处理
        i += 1
        if bare or not delims:
            continue
        for delim in delims:      # 多个 heredoc 时正文按顺序排列
            while i < len(lines) and lines[i].strip() != delim:
                out.append("")    # 正文清空,保留行数
                i += 1
            if i < len(lines):
                out.append("")    # 结束定界符行
                i += 1
    return "\n".join(out)


def build_scan_text(cmd):
    """用于危险匹配的文本 = 屏蔽数据后的命令 + 内联代码补扫。"""
    cmd = strip_shell_comments(cmd)
    masked = mask_strings(cmd)
    payloads = [strip_shell_comments(payload) for payload in extract_code(cmd)]
    if payloads:
        return masked + "\n" + "\n".join(payloads)
    return masked


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
    """按顶层 shell 分隔符切段;引号内的分隔符保留为参数内容。"""
    out, buf = [], []
    quote = None
    i = 0
    while i < len(cmd):
        c = cmd[i]
        if quote:
            buf.append(c)
            if quote == '"' and c == "\\" and i + 1 < len(cmd):
                buf.append(cmd[i + 1])
                i += 2
                continue
            if c == quote:
                quote = None
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


def classify_rm_targets(cmd, cwd, policy):
    """解析原始命令里所有直接执行的 rm -rf 目标,聚合为 block/warn/safe;解析不了一律 warn。

    同一条命令里 `DIR=/tmp/x; rm -rf $DIR` 这种字面量赋值会先展开再判定 —— 展开后按真实路径
    走同一套分级(展开成家目录照样 block),既不误拦临时目录,也不会被变量绕过。
    """
    cmd = mask_cmd_subs(cmd)
    if cmd is None:
        return rm_level("unknown", policy)  # 引号/命令替换不闭合,解析不了

    home = os.path.expanduser("~")
    found = False
    worst = "safe"
    env = {}
    for segment in shell_segments(cmd):
        try:
            args = shlex.split(segment, posix=True)
        except ValueError:
            return rm_level("unknown", policy)
        if not args:
            continue

        # 前置赋值(含 `export A=b` / `A=b cmd` 形态)记进 env,供后面的 $VAR 展开
        i = 0
        if args[0] == "export" and len(args) > 1:
            i = 1
        while i < len(args):
            m = ASSIGN_RE.match(args[i])
            if not m:
                break
            value = expand_vars(m.group(2), env)
            if value is None:
                env.pop(m.group(1), None)   # 值里有未知变量 → 该变量此后不可信
            else:
                env[m.group(1)] = value
            i += 1
        args = args[i:]
        if not args or args[0] != "rm":
            continue

        has_r = has_f = False
        operands = []
        end_options = False
        for arg in args[1:]:
            if not end_options and arg == "--":
                end_options = True
            elif not end_options and arg.startswith("-") and arg != "-":
                has_r = has_r or arg == "--recursive" or "r" in arg[1:].lower()
                has_f = has_f or arg == "--force" or "f" in arg[1:].lower()
            else:
                operands.append(arg)

        if has_r and has_f:
            found = True
            if not operands:
                return rm_level("unknown", policy)
            for path in operands:
                path = expand_vars(path, env) or path
                level = rm_target_level(path, cwd, home, policy)
                if level == "block":
                    return "block"
                if level == "warn":
                    worst = "warn"

    if not found:
        return rm_level("unknown", policy)
    return worst


def rm_arg_windows(text):
    """每个 rm 调用的参数窗口 = `rm` 之后到下一个 shell 分隔符之前的文本。

    -r/-f 必须在 rm 自己的参数里判定:整条命令通扫会把别的命令的选项算到 rm 头上,
    例如 `sips -r 90 a.jpg && rm -f b.png` 曾被误判成 rm -rf 而弹确认。
    """
    out = []
    for m in re.finditer(r"\brm\b", text):
        rest = text[m.end():]
        cut = re.search(r"[;&|\n()]", rest)
        out.append(rest[:cut.start()] if cut else rest)
    return out


def classify_rm(text, raw_cmd, cwd, policy):
    """删根/家/用户目录级 → block;删整个项目/系统路径 → warn;普通目录 → safe。
    非递归 rm(如 `rm -f 单个文件`)不归本函数管,返回 None。"""
    rf_windows = [
        w for w in rm_arg_windows(text)
        if (re.search(r"(?:^|\s)-\w*r", w, re.I) or "--recursive" in w)
        and (re.search(r"(?:^|\s)-\w*f", w, re.I) or "--force" in w)
    ]
    if not rf_windows:
        return None
    known = "safe"
    for w in rf_windows:
        for match in re.finditer(r"(?:^|\s)(/|/\*|~|~/|~/\*|\$HOME|\$HOME/|\$HOME/\*|\$\{HOME\})(?:\s|$)", w):
            level = rm_level("root" if match.group(1).startswith("/") else "home", policy)
            if level == "block":
                return level
            if level == "warn":
                known = level
    parsed = classify_rm_targets(raw_cmd, cwd, policy)
    return "warn" if parsed != "block" and known == "warn" else parsed


# ============================================================
# 对外唯一入口
# ============================================================

def _unwrap_rm(cmd, cwd, fallback, policy, depth=0):
    """Only relax wrapper noise if every extracted deletion is safe.

    ponytail: bounded shell-wrapper inspection, not a full shell parser. An outer rm,
    an unknown inner target, or excessive nesting keeps the conservative denial.
    """
    if depth >= 4 or re.search(r"\brm\b", mask_strings(cmd)):
        return fallback
    saw_safe = False
    for inner in extract_code(cmd):
        level = classify_rm(build_scan_text(inner), inner, cwd, policy)
        if level == "warn":
            level = _unwrap_rm(inner, cwd, level, policy, depth + 1)
        if level == "block":
            return "block"
        if level == "warn":
            return fallback
        if level == "safe":
            saw_safe = True
    return "safe" if saw_safe else fallback


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
    core = strip_heredocs(cmd)
    scan = build_scan_text(core)
    cwd = cwd or os.getcwd()
    policy, _ = rules.active_policy()

    rm_policy = policy["rm"]
    rm = classify_rm(scan, core, cwd, rm_policy)
    if rm == "warn":
        rm = _unwrap_rm(cmd, cwd, rm, rm_policy)

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
