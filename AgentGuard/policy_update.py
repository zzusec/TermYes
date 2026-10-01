"""Check the versioned, data-only GitHub danger list without touching installed hooks."""
import json
import time
from urllib.request import Request, urlopen

import rules

POLICY_URL = "https://raw.githubusercontent.com/zzusec/TermYes/refs/heads/main/AgentGuard/danger-policy.json"
CHECK_INTERVAL = 2 * 60 * 60


def state_path(home):
    return rules.policy_path(home).with_name("danger-policy-state.json")


def state(home):
    path = state_path(home)
    if not path.exists() or path.is_symlink() or not path.is_file():
        return {}
    try:
        value = json.loads(path.read_bytes())
        return value if isinstance(value, dict) else {}
    except (OSError, ValueError):
        return {}


def status(home):
    policy, error = rules.active_policy(home)
    record = state(home)
    message = "规则 v{} 已启用".format(policy["version"])
    if error:
        message += "；本地缓存无效，已使用内置规则：" + error
    elif isinstance(record.get("error"), str) and record["error"]:
        message += "；在线检查失败，保留现有规则：" + record["error"]
    return policy["version"], message, bool(error or record.get("error"))


def fetch_policy():
    request = Request(POLICY_URL, headers={"User-Agent": "TermYes-AgentGuard", "Accept": "application/json"})
    with urlopen(request, timeout=5) as response:
        if response.geturl() != POLICY_URL:
            raise ValueError("危险清单来源发生重定向")
        return response.read(rules.MAX_POLICY_BYTES + 1)


def check(home, atomic_write, now=None, fetch=fetch_policy, force=False):
    now = time.time() if now is None else now
    record = state(home)
    last_attempt = record.get("lastAttempt")
    if (not force and type(last_attempt) in (int, float)
            and 0 <= now - last_attempt < CHECK_INTERVAL):
        return status(home)
    try:
        data = fetch()
        incoming = rules.validate_policy(data)
        current, _ = rules.active_policy(home)
        if incoming["version"] > current["version"]:
            atomic_write(rules.policy_path(home), data)
            updated, error = rules.active_policy(home)
            if error or updated["version"] != incoming["version"]:
                raise ValueError("写入后危险清单校验失败：" + str(error))
        outcome = {"lastAttempt": now, "error": ""}
    except Exception as error:
        outcome = {"lastAttempt": now, "error": str(error)}
    atomic_write(state_path(home), (json.dumps(outcome, ensure_ascii=False) + "\n").encode())
    return status(home)
