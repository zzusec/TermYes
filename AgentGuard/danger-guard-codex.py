#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""TermYes shell hook adapter. Normal calls retain native permissions.
Warnings/errors deny; no ask/force_ask and no silent error fallback.
PermissionRequest can optionally use an independent, opt-in AI reviewer.
Host hook loading, trust and timeout behavior still require client validation.
"""

import json
import os
import sys

EVENT = sys.argv[1] if len(sys.argv) > 1 else "PreToolUse"


def out_pretooluse(decision, reason):
    print(json.dumps({
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": decision,
            "permissionDecisionReason": "[命令守卫] " + reason,
        }
    }, ensure_ascii=False))


def out_permission(behavior, message=None):
    decision = {"behavior": behavior}
    if message:
        decision["message"] = "[命令守卫] " + message
    print(json.dumps({
        "hookSpecificOutput": {
            "hookEventName": "PermissionRequest",
            "decision": decision,
        }
    }, ensure_ascii=False))


def main():
    global EVENT
    data = json.loads(sys.stdin.read())
    if len(sys.argv) == 1 and isinstance(data, dict):
        EVENT = data.get("hook_event_name") or "PreToolUse"
    if EVENT not in ("PreToolUse", "PermissionRequest"):
        raise ValueError("未知 hook 事件")
    if not isinstance(data, dict) or not isinstance(data.get("tool_name"), str):
        raise ValueError("缺失工具名")
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    import core
    if data.get("tool_name") not in core.TOOL_NAMES:
        return
    cmd = core.get_command(data)

    level, reason = core.classify(cmd, data.get("cwd") or os.getcwd())

    if EVENT == "PermissionRequest":
        if level == "block":
            core.play_sound()
            out_permission("deny", reason)
        else:
            try:
                import ai_review
                decision = ai_review.review(
                    cmd,
                    data.get("cwd") or os.getcwd(),
                    (data.get("tool_input") or {}).get("description"),
                )
            except Exception:
                decision = None
            if decision:
                if decision["behavior"] == "deny":
                    core.play_sound()
                out_permission(decision["behavior"], decision["reason"])
        return

    if level == "block":
        core.play_sound()
        core.notify_user(cmd, reason)
        out_pretooluse("deny", reason)

if __name__ == "__main__":
    try:
        main()
    except Exception:
        if EVENT == "PermissionRequest":
            out_permission("deny", "守卫无法判定命令，已拒绝；请修复守卫，不要重试或绕过。")
        else:
            out_pretooluse("deny", "守卫无法判定命令，已拒绝；请修复守卫，不要重试或绕过。")
