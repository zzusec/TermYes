#!/usr/bin/env python3
"""Resume each agent's most recent conversation with a short "继续" prompt."""
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
MESSAGE = "继续"
ARGUMENTS = {
    "claude": ["--dangerously-skip-permissions", "-p", "--continue",
               "--output-format", "text", MESSAGE],
    "codex": ["--dangerously-bypass-approvals-and-sandbox", "exec", "--skip-git-repo-check",
              "--color", "never", "resume", "--last", "--ephemeral", MESSAGE],
}


def checked_directory(path):
    canonical = path.resolve()
    system_alias = (sys.platform == "darwin" and str(path).startswith("/var/folders/")
                    and str(canonical) == "/private" + str(path))
    if path != canonical and not system_alias:
        raise ValueError("继续任务结果目录不能是符号链接")
    info = path.lstat()
    if (not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid()
            or stat.S_IMODE(info.st_mode) != 0o700):
        raise ValueError("继续任务结果目录必须为当前用户的 0700 目录")


def write_result(directory, client, result):
    checked_directory(directory)
    fd, temporary = tempfile.mkstemp(prefix=".continue-", dir=str(directory))
    try:
        with os.fdopen(fd, "w") as handle:
            json.dump(result, handle, ensure_ascii=False)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, directory / (client + ".json"))
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def run_visible(command, home, environment, timeout):
    process = subprocess.Popen(
        command, cwd=str(home), env=environment, stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    captured = {"stdout": b"", "stderr": b""}
    selector = selectors.DefaultSelector()
    selector.register(process.stdout, selectors.EVENT_READ, "stdout")
    selector.register(process.stderr, selectors.EVENT_READ, "stderr")
    deadline = time.monotonic() + timeout
    timed_out = False
    try:
        while selector.get_timeout() is not None or True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                timed_out = True
                process.terminate()
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=5)
                break
            events = selector.select(remaining)
            if not events:
                if process.poll() is not None:
                    break
                continue
            for key, _ in events:
                chunk = os.read(key.fileobj.fileno(), 65536)
                if not chunk:
                    selector.unregister(key.fileobj)
                else:
                    captured[key.data] += chunk
            if process.poll() is not None and not selector.select(0):
                break
    finally:
        selector.close()
        for stream in (process.stdout, process.stderr):
            stream.close()
    return process.returncode, captured["stdout"], captured["stderr"], timed_out


def continue_task(client, directory, home, manager=None, timeout=120):
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
        print("[TermYes] " + client + "：" + MESSAGE, flush=True)
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
        result["detail"] = "继续任务失败：" + str(error)
    write_result(directory, client, result)
    print("\n[TermYes] " + ("继续成功" if result["code"] == 0 and result["hasReply"] else result["detail"] or "继续失败"), flush=True)
    return result


class ContinueCancelled(Exception):
    pass


def cancel_continue(_signal, _frame):
    raise ContinueCancelled("继续任务窗口已关闭，请求已取消")


def main():
    signal.signal(signal.SIGHUP, cancel_continue)
    signal.signal(signal.SIGTERM, cancel_continue)
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("client", choices=ARGUMENTS)
    parser.add_argument("--result-dir", type=Path, required=True)
    parser.add_argument("--home", type=Path, default=Path.home())
    args = parser.parse_args()
    result = continue_task(args.client, args.result_dir, args.home)
    return 0 if result["code"] == 0 and result["hasReply"] else 1


if __name__ == "__main__":
    sys.exit(main())
