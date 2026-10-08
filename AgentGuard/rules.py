# -*- coding: utf-8 -*-
"""Read the versioned GitHub policy; the bundled JSON is the offline copy."""
import json
import os
from pathlib import Path
import re

MAX_POLICY_BYTES = 32768
RM_TARGETS = {"root", "home", "top_level", "user_home", "unknown", "cwd_tree",
              "home_child", "git_root", "outside_home"}
NOTIFY_CENTER = False
RM_SAFE_REASON = "rm -rf 目标为普通目录，未命中删除保护规则"


def policy_path(home=None):
    return (home or Path.home()) / "Library/Application Support/Termosaic/AgentGuard/danger-policy.json"


def validate_policy(data):
    if len(data) > MAX_POLICY_BYTES:
        raise ValueError("危险清单超过大小上限")
    value = json.loads(data)
    if not isinstance(value, dict) or set(value) not in (
            {"version", "block", "warn"}, {"version", "block", "warn", "rm"}):
        raise ValueError("危险清单结构无效")
    version = value["version"]
    if type(version) is not int or not 1 <= version <= 2147483647:
        raise ValueError("危险清单版本无效")
    if version >= 3 and "rm" not in value:
        raise ValueError("危险清单缺少 rm 路径规则")
    for group in ("block", "warn"):
        entries = value[group]
        if not isinstance(entries, list) or len(entries) > 128:
            raise ValueError("危险清单条目数无效")
        for entry in entries:
            if (not isinstance(entry, list) or len(entry) != 2
                    or any(not isinstance(text, str) or not 1 <= len(text) <= 512 for text in entry)):
                raise ValueError("危险清单条目无效")
            re.compile(entry[0])
    if not value["block"] and not value["warn"]:
        raise ValueError("危险清单不能清空")
    if "rm" in value:
        rm = value["rm"]
        if not isinstance(rm, dict) or set(rm) != {
                "block", "warn", "temporaryRoots", "blockReason", "warnReason"}:
            raise ValueError("rm 路径规则结构无效")
        for group in ("block", "warn"):
            entries = rm[group]
            if (not isinstance(entries, list) or any(not isinstance(x, str) or x not in RM_TARGETS for x in entries)
                    or len(entries) != len(set(entries))):
                raise ValueError("rm 目标类型无效")
        if set(rm["block"]) & set(rm["warn"]):
            raise ValueError("rm 目标类型不能重复分级")
        roots = rm["temporaryRoots"]
        if (not isinstance(roots, list) or len(roots) > 32
                or any(not isinstance(x, str) or not 1 <= len(x) <= 512
                       or not x.startswith("/") or x == "/" or os.path.normpath(x) != x for x in roots)):
            raise ValueError("rm 临时目录无效")
        for key in ("blockReason", "warnReason"):
            if not isinstance(rm[key], str) or not 1 <= len(rm[key]) <= 512:
                raise ValueError("rm 拒绝原因无效")
    return value


BUNDLED_POLICY = validate_policy(Path(__file__).with_name("danger-policy.json").read_bytes())
BUILTIN_VERSION = BUNDLED_POLICY["version"]
# Compatibility names for callers inspecting the bundled policy, never another rule source.
BLOCK = BUNDLED_POLICY["block"]
WARN = BUNDLED_POLICY["warn"]


def active_policy(home=None):
    path = policy_path(home)
    if not path.exists() and not path.is_symlink():
        return BUNDLED_POLICY, None
    try:
        if path.is_symlink() or not path.is_file():
            raise ValueError("危险清单路径不是普通文件")
        with path.open("rb") as file:
            value = validate_policy(file.read(MAX_POLICY_BYTES + 1))
        if value["version"] <= BUILTIN_VERSION:
            return BUNDLED_POLICY, None
        return value, None
    except (OSError, ValueError, re.error) as error:
        return BUNDLED_POLICY, str(error)
