#!/usr/bin/env python3
"""Run one guarded greeting inside a dedicated Terminal window and record its result."""
import argparse
import json
import os
from pathlib import Path
import selectors
import signal
import stat
import subprocess
import sys
import tempfile
import time

import permission_modes

SOURCE = Path(__file__).resolve().parent
ARGUMENTS = {
    "claude": ["-p", "--output-format", "text", "--no-session-persistence", "hi"],
    "codex": ["exec", "--skip-git-repo-check", "--ephemeral", "--color", "never", "hi"],
}


def checked_directory(path):
    canonical = path.resolve()
    system_alias = (sys.platform == "darwin" and str(path).startswith("/var/folders/")
                    and str(canonical) == "/private" + str(path))
    if path != canonical and not system_alias:
        raise ValueError("激活结果目录不能是符号链接")
    info = path.lstat()
    if (not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid()
            or stat.S_IMODE(info.st_mode) != 0o700):
        raise ValueError("激活结果目录必须为当前用户的 0700 目录")


def write_result(directory, client, result):
    checked_directory(directory)
    fd, temporary = tempfile.mkstemp(prefix=".activation-", dir=str(directory))
    try:
        with os.fdopen(fd, "w") as handle:
            json.dump(result, handle, ensure_ascii=False)
            handle.write("\n")
        os.chmod(temporary, 0o600)
        os.replace(temporary, directory / (client + ".json"))
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def run_visible(command, home, environment, timeout):
    process = subprocess.Popen(command, cwd=str(home), env=environment,
                               stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                               stderr=subprocess.PIPE, start_new_session=True)
    captured = {"stdout": bytearray(), "stderr": bytearray()}
    selector = selectors.DefaultSelector()
    for stream, name in ((process.stdout, "stdout"), (process.stderr, "stderr")):
        selector.register(stream, selectors.EVENT_READ, name)
    deadline = time.monotonic() + timeout
    timed_out = False
    kill_deadline = None
    try:
        while selector.get_map() or process.poll() is None:
            now = time.monotonic()
            if not timed_out and now >= deadline:
                timed_out = True
                kill_deadline = now + 1
                try:
                    os.killpg(process.pid, signal.SIGTERM)
                except ProcessLookupError:
                    pass
            elif timed_out and kill_deadline is not None and now >= kill_deadline:
                try:
                    os.killpg(process.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                kill_deadline = None
            for key, _ in selector.select(0.1):
                data = os.read(key.fileobj.fileno(), 65536)
                if not data:
                    selector.unregister(key.fileobj)
                    key.fileobj.close()
                    continue
                name = key.data
                captured[name].extend(data)
                del captured[name][:-16384]
                destination = sys.stdout if name == "stdout" else sys.stderr
                destination.write(data.decode("utf-8", errors="replace"))
                destination.flush()
        code = process.wait()
    finally:
        if process.poll() is None:
            try:
                os.killpg(process.pid, signal.SIGTERM)
                process.wait(timeout=1)
            except (ProcessLookupError, subprocess.TimeoutExpired):
                try:
                    os.killpg(process.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                process.wait()
        selector.close()
        for stream in (process.stdout, process.stderr):
            stream.close()
    return code, bytes(captured["stdout"]), bytes(captured["stderr"]), timed_out


def activate(client, directory, home, manager=None, timeout=120):
    checked_directory(directory)
    manager = manager or SOURCE / "manage.py"
    environment = dict(os.environ, HOME=str(home), PYTHONDONTWRITEBYTECODE="1")
    environment["PATH"] = os.pathsep.join([str(home / ".local/bin"), "/opt/homebrew/bin",
                                           "/usr/local/bin", "/usr/bin", "/bin",
                                           environment.get("PATH", "")])
    result = {"code": 1, "hasReply": False, "detail": None}
    try:
        check = subprocess.run(["/usr/bin/python3", "-B", str(manager), "ensure", client],
                               cwd=str(home), env=environment, stdin=subprocess.DEVNULL,
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=30)
        if check.returncode:
            detail = check.stderr.decode("utf-8", errors="replace").strip()
            raise ValueError("守卫检查失败：" + (detail[-600:] or "请查看 Agent 配置状态"))
        command = permission_modes.launcher_path(home, client)
        if command is None:
            raise ValueError("未找到客户端命令：" + client)
        print("[TermYes] " + client + "：hi", flush=True)
        code, stdout, stderr, timed_out = run_visible([str(command), *ARGUMENTS[client]], home, environment, timeout)
        has_reply = bool(stdout.decode("utf-8", errors="replace").strip())
        detail = (stderr or stdout).decode("utf-8", errors="replace").strip()[-600:]
        result = {
            "code": 124 if timed_out else code,
            "hasReply": has_reply,
            "detail": "模型请求超时" if timed_out else detail if code else None,
        }
        if not timed_out and code == 0 and not has_reply:
            result["detail"] = "模型未返回内容"
    except Exception as error:
        result["detail"] = "激活失败：" + str(error)
    write_result(directory, client, result)
    print("\n[TermYes] " + ("激活成功" if result["code"] == 0 and result["hasReply"] else result["detail"] or "激活失败"), flush=True)
    return result


class ActivationCancelled(Exception):
    pass


def cancel_activation(_signal, _frame):
    raise ActivationCancelled("激活窗口已关闭，请求已取消")


def main():
    signal.signal(signal.SIGHUP, cancel_activation)
    signal.signal(signal.SIGTERM, cancel_activation)
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("client", choices=ARGUMENTS)
    parser.add_argument("--result-dir", type=Path, required=True)
    parser.add_argument("--home", type=Path, default=Path.home())
    args = parser.parse_args()
    result = activate(args.client, args.result_dir, args.home)
    return 0 if result["code"] == 0 and result["hasReply"] else 1


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as error:
        print("[TermYes] " + str(error), file=sys.stderr)
        raise SystemExit(1)
