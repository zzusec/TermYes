#!/usr/bin/env python3
"""Check installed agents and their plugins for new versions; update immediately.

Prints a JSON report for TermYes. Each client runs its own official update
command, which only installs when a newer version exists:

- claude:      claude update                      + claude plugin update <id>…
- codex:       codex update                       + codex plugin marketplace upgrade
- opencode:    opencode update                    + opencode plugin update
- codebuddy:   codebuddy update                   + codebuddy plugin update <id>…
- qoder:       qoder update                       + qoder plugins update <id>…
- zcode:       (no self-update command)           + zcode plugins update / marketplace update
- pi:          pi update (also updates extensions and model catalogs)
- agy:         agy update
"""
import json
import os
from pathlib import Path
import re
import subprocess
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))

import permission_modes  # noqa: E402

HOME = Path.home()
TIMEOUT = 900

SELF_UPDATE_SUBCOMMANDS = {
    "claude": ["update"],
    "codex": ["update"],
    "opencode": ["update"],
    "codebuddy": ["update"],
    "qoder": ["update"],
    "pi": ["update"],
    "agy": ["update"],
}

PLUGIN_UPDATE_ALL = {
    "codex": [["plugin", "marketplace", "upgrade"]],
    "opencode": [["plugin", "update"]],
    "zcode": [["plugins", "update"], ["plugins", "marketplace", "update"]],
}

PLUGIN_LIST_ARGS = {
    "claude": ["plugin", "list"],
    "codebuddy": ["plugin", "list"],
    "qoder": ["plugins", "list"],
}

PLUGIN_UPDATE_ONE = {
    "claude": ["plugin", "update"],
    "codebuddy": ["plugin", "update"],
    "qoder": ["plugins", "update"],
}


def env():
    extra = [
        str(HOME / ".local/bin"),
        "/opt/homebrew/bin",
        "/usr/local/bin",
        str(HOME / ".opencode/bin"),
        str(HOME / ".qoder/entry"),
        str(HOME / ".npm-global/bin"),
    ]
    return dict(os.environ, PATH=os.pathsep.join(extra + [os.environ.get("PATH", "")]))


def cli_command(client):
    # Prefer the deepest underlying binary; avoid TermYes's yolo wrapper link itself.
    for path in reversed(permission_modes.executable_paths(HOME, client)):
        text = str(path)
        if text.endswith("agent-yolo-wrapper"):
            continue
        if os.access(text, os.X_OK):
            return [text]
    return None


def qoder_command():
    entry = HOME / ".qoder/entry/qoder"
    if entry.is_file() and os.access(entry, os.X_OK):
        return [str(entry)]
    return cli_command("qoder")


def run(args, timeout=TIMEOUT):
    try:
        process = subprocess.run(
            args, capture_output=True, text=True, timeout=timeout, env=env()
        )
        output = (process.stdout + process.stderr).strip()
        return process.returncode == 0, output[-1200:]
    except subprocess.TimeoutExpired:
        return False, "超时（{} 秒）".format(timeout)
    except OSError as error:
        return False, str(error)


def changed_from_output(output):
    lowered = output.lower()
    if re.search(r"already|up.?to.?date|no update|最新|无需|未发现|没有更新|相同|unchanged", lowered):
        return False
    return bool(re.search(r"updat|upgrad|install|新版|升级|已更新|更新到|->|success", lowered))


def plugin_ids_from_output(text):
    ids = []
    for line in text.splitlines():
        token = line.strip().lstrip("❯*-•>").strip().split()[0] if line.strip() else ""
        token = token.strip("│,")
        if re.match(r"^[^\s@/]+@[^\s@/]+$", token) and token not in ids:
            ids.append(token)
    return ids


def claude_installed_plugin_ids():
    path = HOME / ".claude/plugins/installed_plugins.json"
    try:
        data = json.loads(path.read_text())
        return sorted(data.get("plugins", {}).keys())
    except (OSError, ValueError):
        return []


def record(items, client, target, args, ok, output):
    items.append({
        "client": client,
        "target": target,
        "command": " ".join(args),
        "ok": ok,
        "changed": ok and changed_from_output(output),
        "detail": output[-500:],
    })


def main():
    items = []
    checked = 0

    for client in sorted(permission_modes.COMMANDS):
        if not permission_modes.is_detected(HOME, client):
            continue
        cli = qoder_command() if client == "qoder" else cli_command(client)
        checked += 1

        # Client self-update.
        subcommands = SELF_UPDATE_SUBCOMMANDS.get(client)
        if cli and subcommands:
            ok, output = run(cli + subcommands)
            record(items, client, "CLI", cli + subcommands, ok, output)

        # Plugin updates: "update all" style commands first.
        if cli:
            for subcommand in PLUGIN_UPDATE_ALL.get(client, []):
                args = cli + subcommand
                ok, output = run(args)
                record(items, client, " ".join(subcommand), args, ok, output)

            # Per-plugin updates enumerated from the client's own list.
            if client == "claude":
                plugin_ids = claude_installed_plugin_ids()
            elif client in PLUGIN_LIST_ARGS:
                ok, output = run(cli + PLUGIN_LIST_ARGS[client], timeout=120)
                plugin_ids = plugin_ids_from_output(output) if ok else []
            else:
                plugin_ids = []
            for plugin_id in plugin_ids:
                args = cli + PLUGIN_UPDATE_ONE[client] + [plugin_id]
                ok, output = run(args)
                record(items, client, plugin_id, args, ok, output)

    changed = [item for item in items if item["changed"]]
    failed = [item for item in items if not item["ok"]]
    summary = "已检查 {} 个 Agent：更新 {} 项，失败 {} 项".format(len({i["client"] for i in items}), len(changed), len(failed))
    print(json.dumps({"items": items, "message": summary}, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
