#!/usr/bin/env python3
"""Check the installed distribution before updating; never treat errors as latest."""
import argparse
from concurrent.futures import ThreadPoolExecutor
import json
import os
from pathlib import Path
import platform
import re
import shlex
import shutil
import signal
import subprocess
import sys
import urllib.request

sys.path.insert(0, str(Path(__file__).resolve().parent))
import permission_modes  # noqa: E402

HOME = Path.home()
TIMEOUT = 900
REGISTRY = "https://registry.npmjs.org"
# Package identities are fixed, not taken from remote metadata or CLI output.
NPM_PACKAGES = {
    "claude": ("@anthropic-ai/claude-code",),
    "codex": ("@openai/codex",),
    "codebuddy": ("@tencent-ai/codebuddy-code",),
    "qoder": ("@qoder-ai/qodercli",),
    "opencode": ("opencode-ai", "@opencode/cli", "@opencode-ai/cli", "@opencode/cli-node", "@opencode-ai/cli-node"),
    "pi": ("@earendil-works/pi-coding-agent", "@mariozechner/pi-coding-agent"),
    "gemini": ("@google/gemini-cli",),
    "copilot": ("@github/copilot",),
    "zcode": ("zcode-app-cli",),
}
NATIVE_SOURCES = {
    "claude": "https://downloads.claude.ai/claude-code-releases/latest",
    "codebuddy": "https://acc-1258344699.cos.accelerate.myqcloud.com/@tencent-ai/codebuddy-code/releases/latest",
    "qoder": "https://download.qoder.com/qodercli/channels/manifest.json",
    "agy": "https://antigravity-cli-auto-updater-974169037036.us-central1.run.app/manifests/{}_{}.json".format(
        platform.system().lower(), "arm64" if platform.machine() in ("aarch64", "arm64") else "amd64"),
    "opencode": REGISTRY + "/opencode-ai/latest",
}
NATIVE_UPDATE = {
    "claude": ["update"], "codebuddy": ["update"], "qoder": ["update"],
    "agy": ["update"], "opencode": ["upgrade"],
}
PLUGIN_UPDATE_ALL = {
    "codex": [["plugin", "marketplace", "upgrade"]],
    "opencode": [["plugin", "update"]],
    "pi": [["update", "--extensions", "--no-approve"]],
    "zcode": [["plugins", "marketplace", "update"], ["plugins", "update"]],
}
PLUGIN_LIST_ARGS = {"claude": ["plugin", "list"], "codebuddy": ["plugin", "list"], "qoder": ["plugins", "list"]}
PLUGIN_UPDATE_ONE = {"claude": ["plugin", "update"], "codebuddy": ["plugin", "update"], "qoder": ["plugins", "update"]}
VERSION = r"[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z]+(?:[.-][0-9A-Za-z]+)*)?(?:\+[0-9A-Za-z.-]+)?"


def env():
    extra = [str(HOME / ".local/bin"), "/opt/homebrew/bin", "/usr/local/bin",
             str(HOME / ".opencode/bin"), str(HOME / ".npm-global/bin")]
    return dict(os.environ, PATH=os.pathsep.join(extra + [os.environ.get("PATH", "")]), NO_COLOR="1")


def cli_command(client):
    for path in reversed(permission_modes.executable_paths(HOME, client)):
        if path.name != permission_modes.WRAPPER_NAME and os.access(path, os.X_OK):
            return [str(path)]
    return None


def run(args, timeout=TIMEOUT):
    try:
        process = subprocess.Popen(args, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                   text=True, env=env(), cwd=str(HOME),
                                   stdin=subprocess.DEVNULL, start_new_session=True)
        try:
            stdout, stderr = process.communicate(timeout=timeout)
        except subprocess.TimeoutExpired:
            # Self-updaters spawn downloaders; killing only the CLI leaves them alive.
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            process.communicate()
            return False, "超时（{} 秒），已终止升级进程组".format(timeout)
        return process.returncode == 0, (stdout + stderr).strip()[-12000:]
    except (OSError, UnicodeError) as error:
        return False, str(error)


def fetch_text(url):
    request = urllib.request.Request(url, headers={"User-Agent": "TermYes-AgentUpdater", "Accept": "application/json, text/plain"})
    with urllib.request.urlopen(request, timeout=20) as response:
        data = response.read(4 * 1024 * 1024 + 1)
    if len(data) > 4 * 1024 * 1024:
        raise ValueError("版本响应过大")
    return data.decode("utf-8").strip()


def version_from_output(text):
    text = re.sub(r"\x1b\[[0-?]*[ -/]*[@-~]", "", text)
    for line in text.splitlines():
        match = re.fullmatch(r"(?:[A-Za-z][A-Za-z0-9 _.-]*\s+)?v?(" + VERSION + r")(?:\s+\([^\n]*\))?", line.strip())
        if match:
            return match.group(1)
    raise ValueError("无法解析版本输出：" + text[-300:])


def version_key(version):
    if not re.fullmatch(VERSION, version):
        raise ValueError("无效版本号：" + version)
    core, _, prerelease = version.split("+", 1)[0].partition("-")
    parts = tuple((0, int(p)) if p.isdigit() else (1, p) for p in prerelease.split(".")) if prerelease else ()
    return tuple(int(p) for p in core.split(".")) + (not prerelease, parts)


def current_version(cli):
    ok, output = run(cli + ["--version"], timeout=30)
    if not ok:
        raise ValueError("读取当前版本失败：" + output)
    return version_from_output(output)


def underlying_file(cli):
    path = Path(cli[0]).resolve()
    # Follow the user's simple Codex forwarding launcher, not arbitrary shell code.
    try:
        with path.open("rb") as handle:
            data = handle.read(4096)
        if data.startswith(b"#!/"):
            lines = [line.strip() for line in data.decode("utf-8").splitlines()
                     if line.strip() and not line.startswith("#")]
            if len(lines) == 1:
                words = shlex.split(lines[0])
                if len(words) == 3 and words[0] == "exec" and words[2] == "$@" and words[1].startswith("/"):
                    target = Path(words[1]).resolve()
                    if target.is_file() and os.access(target, os.X_OK):
                        path = target
    except (OSError, UnicodeError, ValueError):
        pass
    return path


def npm_installation(client, cli):
    path = underlying_file(cli)
    for root in path.parents:
        package_json = root / "package.json"
        if not package_json.is_file():
            continue
        try:
            package = json.loads(package_json.read_text())
        except (OSError, ValueError):
            continue
        name = package.get("name")
        if name not in NPM_PACKAGES.get(client, ()):
            continue
        modules = root.parent.parent if name.startswith("@") else root.parent
        if modules.name == "node_modules" and modules.parent.name == "lib":
            return {"name": name, "prefix": modules.parent.parent}
    return None


def version_source(client, installation, current=""):
    if installation:
        source = REGISTRY + "/" + installation["name"].replace("/", "%2f") + "/latest"
    else:
        source = NATIVE_SOURCES.get(client, "")
        if client == "opencode" and current and version_key(current)[0] >= 2:
            # OpenCode 2 has a separate official channel; npm opencode-ai is v1.
            source = "https://opencode.ai/update/api/latest/cli/npm"
        if client == "claude":
            settings = HOME / ".claude/settings.json"
            if settings.is_file():
                channel = json.loads(settings.read_text()).get("autoUpdatesChannel", "latest")
                if channel not in ("latest", "stable"):
                    raise ValueError("未知 Claude 更新通道：" + str(channel))
                source = source.rsplit("/", 1)[0] + "/" + channel
        if not source and client in NPM_PACKAGES and client != "zcode":
            source = REGISTRY + "/" + NPM_PACKAGES[client][0].replace("/", "%2f") + "/latest"
    return source


def latest_version(client, installation, current=""):
    source = version_source(client, installation, current)
    if not source:
        return "", ""
    text = fetch_text(source)
    if source.startswith(REGISTRY + "/"):
        data = json.loads(text)
        expected = installation["name"] if installation else NPM_PACKAGES[client][0]
        if data.get("name") != expected:
            raise ValueError("发行包身份不匹配：" + source)
        latest = data.get("version", "")
    elif client == "qoder":
        latest = json.loads(text).get("latest", "")
    elif client == "agy":
        latest = json.loads(text).get("version", "")
    elif client == "opencode":
        data = json.loads(text)
        if data.get("active") is not True or data.get("metadata", {}).get("package") not in NPM_PACKAGES["opencode"]:
            raise ValueError("OpenCode 2 更新源未返回有效发行包")
        latest = data.get("version", "")
    else:
        latest = text.removeprefix("v")
    version_key(latest)
    return latest, source


def update_command(client, cli, installation, latest):
    if installation:
        prefix = installation["prefix"]
        for name in permission_modes.COMMANDS[client]:
            candidate = prefix / "bin" / name
            if candidate.resolve().name == permission_modes.WRAPPER_NAME or permission_modes._is_managed_wrapper(candidate):
                return [], "npm 的安装入口是免确认 wrapper，不能覆盖；请使用独立安装前缀"
        npm = prefix / "bin/npm"
        executable = str(npm) if npm.is_file() and os.access(npm, os.X_OK) else shutil.which("npm", path=env()["PATH"])
        if not executable:
            return [], "找不到当前安装所需的 npm"
        args = [executable, "install", "--global", "--prefix", str(prefix), "--registry", REGISTRY]
        if client == "pi":
            args.append("--ignore-scripts")
        return args + [installation["name"] + "@" + latest], ""
    if client not in NATIVE_UPDATE:
        return [], "尚无经过核实的自动升级方式，未运行猜测的更新命令"
    # Native self-updaters are used only for their own confirmed installation layout.
    path = underlying_file(cli)
    layouts = {
        "claude": HOME / ".local/share/claude/versions",
        "codebuddy": HOME / ".local/share/codebuddy/versions",
        "qoder": HOME / ".qoder/bin/qodercli",
        "opencode": HOME / ".opencode/bin",
    }
    if client in layouts and layouts[client].resolve() not in path.parents:
        return [], "安装来源无法确认；不跨安装方式覆盖现有客户端"
    return cli + NATIVE_UPDATE[client] + ([latest] if client == "opencode" else []), ""


def check_client(client, check_only=False):
    item = {"client": client, "target": "CLI", "command": "", "ok": False,
            "changed": False, "detail": "", "currentVersion": "", "latestVersion": "",
            "status": "failed", "source": ""}
    try:
        cli = cli_command(client)
        if not cli:
            item.update(status="unsupported", detail="仅检测到桌面应用，没有可检查的 CLI；请用应用自身的升级入口")
            return item
        item["command"] = shlex.join(cli + ["--version"])
        item["currentVersion"] = current_version(cli)
        installation = npm_installation(client, cli)
        if installation and installation["name"] == "zcode-app-cli":
            item["sourceLabel"] = "当前发行（第三方）"
        # Keep the authoritative URL visible even if its request fails.
        item["source"] = version_source(client, installation, item["currentVersion"])
        latest, source = latest_version(client, installation, item["currentVersion"])
        item.update(latestVersion=latest, source=source)
        if not latest:
            item.update(status="unsupported", detail="尚未核实此安装方式的官方版本来源，未将它标为最新")
            return item
        current_key, latest_key = version_key(item["currentVersion"]), version_key(latest)
        if current_key >= latest_key:
            item.update(ok=True, status="upToDate" if current_key == latest_key else "ahead",
                        detail="当前版本与发行源一致" if current_key == latest_key else "本机版本高于该发行源；保留本机版本，不自动降级")
            return item
        item.update(ok=True, status="updateAvailable", detail="发现新版本" + ("（仅检查，未安装）" if check_only else ""))
        args, reason = update_command(client, cli, installation, latest)
        if not args:
            item.update(detail="发现新版本；" + reason)
            return item
        item["command"] = shlex.join(args)
        if check_only:
            return item
        apply_update(item)
    except Exception as error:
        item.update(ok=False, status="failed", detail=str(error)[-600:])
    return item


def apply_update(item):
    if item["status"] != "updateAvailable":
        return
    try:
        client = item["client"]
        cli = cli_command(client)
        if not cli:
            raise ValueError("找不到客户端入口")
        args, reason = update_command(client, cli, npm_installation(client, cli), item["latestVersion"])
        if not args:
            item["detail"] = "发现新版本；" + reason
            return
        item["command"] = shlex.join(args)
        ok, output = run(args)
        if not ok:
            raise ValueError("升级命令失败：" + output[-500:])
        after_cli = cli_command(client)
        if not after_cli:
            raise ValueError("升级后找不到客户端入口")
        after = current_version(after_cli)
        if version_key(after) < version_key(item["latestVersion"]):
            raise ValueError("升级命令返回成功，但实际版本仍为 {}，目标为 {}；{}".format(after, item["latestVersion"], output[-300:]))
        before = item["currentVersion"]
        item.update(currentVersion=after, changed=True, status="updated", detail="已验证实际版本：{} → {}".format(before, after))
    except Exception as error:
        item.update(ok=False, status="failed", detail=str(error)[-600:])


def changed_from_output(output):
    if re.search(r"already|up.?to.?date|no update|最新|无需|没有更新|unchanged", output, re.I):
        return False
    return bool(re.search(VERSION + r"\s*(?:->|→|to)\s*v?" + VERSION, output))


def plugin_ids_from_output(text):
    ids = []
    for line in text.splitlines():
        token = line.strip().lstrip("❯*-•>").strip().split()[0] if line.strip() else ""
        token = token.strip("│,")
        if re.fullmatch(r"[A-Za-z0-9_.-]+@[A-Za-z0-9_.-]+", token) and token not in ids:
            ids.append(token)
    return ids


def supported_command(cli, subcommand):
    ok, output = run(cli + subcommand + ["--help"], timeout=30)
    return ok and bool(re.search(r"Usage|USAGE|DESCRIPTION", output)) and not re.search(r"unknown command|unrecognized|not found", output, re.I)


def update_plugins(client):
    cli = cli_command(client)
    if not cli:
        return []
    commands = list(PLUGIN_UPDATE_ALL.get(client, []))
    if client in PLUGIN_LIST_ARGS and supported_command(cli, PLUGIN_LIST_ARGS[client]):
        ok, output = run(cli + PLUGIN_LIST_ARGS[client], timeout=120)
        if not ok:
            return [{"client": client, "target": "plugins", "command": shlex.join(cli + PLUGIN_LIST_ARGS[client]),
                     "ok": False, "changed": False, "detail": output[-500:]}]
        plugin_ids = plugin_ids_from_output(output)
        if client == "claude":
            installed = HOME / ".claude/plugins/installed_plugins.json"
            try:
                plugin_ids = sorted(json.loads(installed.read_text()).get("plugins", {}).keys())
            except FileNotFoundError:
                pass
            except (OSError, ValueError) as error:
                return [{"client": client, "target": "plugins", "command": str(installed), "ok": False,
                         "changed": False, "detail": "插件清单读取失败：" + str(error)}]
        if plugin_ids and supported_command(cli, PLUGIN_UPDATE_ONE[client]):
            commands += [PLUGIN_UPDATE_ONE[client] + [identifier] for identifier in plugin_ids]
    items = []
    for subcommand in commands:
        if not supported_command(cli, subcommand[:3] if client == "codex" else subcommand[:2]):
            continue
        args = cli + subcommand
        ok, output = run(args)
        items.append({"client": client, "target": " ".join(subcommand), "command": shlex.join(args),
                      "ok": ok, "changed": ok and changed_from_output(output),
                      "detail": output[-500:] or ("插件更新命令执行完成" if ok else "插件更新命令失败")})
    return items


def build_report(check_only=False):
    detected = [client for client in sorted(permission_modes.COMMANDS) if permission_modes.is_detected(HOME, client)]
    with ThreadPoolExecutor(max_workers=3) as pool:
        cli_items = list(pool.map(lambda client: check_client(client, True), detected))
    items = []
    for item in cli_items:
        items.append(item)
        if not check_only:
            # npm clients can share an installation prefix; never update them concurrently.
            apply_update(item)
            if item["status"] not in ("failed", "unsupported"):
                try:
                    items.extend(update_plugins(item["client"]))
                except Exception as error:
                    items.append({"client": item["client"], "target": "plugins", "command": "",
                                  "ok": False, "changed": False, "detail": str(error)[-500:]})
    updated = sum(item["changed"] for item in items)
    available = sum(item.get("status") == "updateAvailable" for item in items)
    failed = sum(not item["ok"] for item in items)
    return {"items": items, "message": "已检查 {} 个 Agent：已更新 {} 项，待更新 {} 项，失败或暂不支持 {} 项".format(len(detected), updated, available, failed)}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check-only", action="store_true", help="只读检测 CLI 版本，不升级 CLI 或插件")
    args = parser.parse_args()
    print(json.dumps(build_report(args.check_only), ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
