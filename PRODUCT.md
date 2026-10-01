# TermYes — Product

<!-- impeccable:product-schema 1 -->

## Platform

TermYes is a native macOS menu-bar utility.

## Stack

Swift 6, SwiftUI, AppKit, and Apple Events automation. No third-party runtime dependencies for window management; the optional Agent guard requires /usr/bin/python3 from Xcode Command Line Tools.

## Primary User

A macOS user who runs several long-lived processes in Apple's built-in Terminal.app and wants to inspect them together without allowing a global window manager to rearrange unrelated work.

## Core Job

Show every existing Terminal.app shell window as one balanced wall on the current display, then hide the wall without stopping the processes running inside those windows.

## Confirmed Capabilities

- Manage Apple's system Terminal.app only.
- Show, hide, and manually re-tile Terminal windows with edge-to-edge, zero-gap placement.
- Automatically re-tile when a Terminal window is added or closed, preserving stable window identity and assigning positions clockwise.
- Restore minimized Terminal windows and include them in the grid.
- Keep Terminal processes running while their windows are hidden.
- Treat Terminal windows as one logical canvas and optionally hide the canvas when another application becomes active.
- Never reposition windows belonging to other applications.
- Remain available only from the macOS menu bar, with no Dock icon or desktop control window.
- Check public GitHub Releases online and securely stage, validate, replace, and relaunch newer TermYes versions.
- Provide a persisted, configurable global shortcut that shows and forcibly re-tiles the complete Terminal mosaic.
- Manually send “继续” only to matching Codex/Claude Terminal sessions on request; skip recognized confirmation/guard-denial prompts and never automatically answer `yes`.
- Bundle thirteen shell-guard adapters from bypass-yes with per-client installation and exact restore; dangerous/warning rules and captured input/bridge errors deny.
- Keep detected agents in YOLO-equivalent modes while maintaining independently installed command guards; refuse to launch through managed entry points when readiness fails. Installed files alone are not proof of runtime protection.
- Deny Shell commands only when shared explicit danger rules or high-impact rm target rules match; permit valid unmatched commands without a Codex AI veto. Keep optional AI review for Ctrl-C terminal-input prompts separate.
- Optionally merge learned approval memory through iCloud Drive so the same command and pattern memory follows the user across Macs without a backend database.
- With Accessibility permission, auto-confirm only verified terminal-input prompts whose requested input is exactly Ctrl-C; all text, Enter, credentials, and permission prompts remain manual.

## Durable Constraints

- Existing Terminal sessions remain owned by Terminal.app; the utility does not embed or migrate shells.
- Window movement requires permission for TermYes to automate Apple Terminal.
- Interacting with a tiled terminal naturally makes Terminal.app the active application; the manager remains available from its menu-bar item.
- The utility must not require a third-party window manager or terminal emulator.

## Success

Four Terminal windows form a clean 2×2 wall. Adding or closing a window causes the remaining windows to form a balanced grid automatically. Hiding the wall removes Terminal windows from the workspace while their commands continue running.
