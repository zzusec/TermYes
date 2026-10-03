<div align="center">
  <img src="Resources/TermYesIcon-1024.png" width="128" alt="TermYes icon">
  <h1>TermYes</h1>
  <p><strong>Your terminals, together. Risky commands, stopped.</strong></p>
  <p>A native macOS menu-bar utility for Apple Terminal and Agent command guards.</p>
  <p>
    <a href="https://github.com/zzusec/TermYes/actions/workflows/build.yml"><img src="https://github.com/zzusec/TermYes/actions/workflows/build.yml/badge.svg" alt="Build and tests"></a>
    <img src="https://img.shields.io/badge/macOS-13%2B-black" alt="macOS 13 or later">
    <img src="https://img.shields.io/badge/Apple_Silicon_%2B_Intel-universal-blue" alt="Universal macOS application">
  </p>
  <p><strong>English</strong> · <a href="README.zh-CN.md">Chinese</a></p>
  <p><a href="https://github.com/zzusec/TermYes/releases/latest">Download</a> · <a href="RELEASE_NOTES.md">Release notes</a> · <a href="AgentGuard/README.md">Guard details</a></p>
</div>

TermYes brings **Termosaic's terminal canvas** and **bypass-yes's command guards** into one application. Keep existing Terminal sessions visible together, hide them without stopping their processes, and manage per-Agent shell guards from the menu bar.

> **YOLO first, then hard-deny danger.** TermYes detects installed agents, repairs supported permission modes to YOLO or an equivalent auto-approval mode, and keeps the command guard as a fail-closed layer for dangerous operations. Adapter hook behavior still requires real-client validation.

## What it does

- **One terminal canvas.** Tile Apple's Terminal windows edge to edge: four windows form a 2×2 grid; six form a 3×2 grid; odd counts use two columns with the extra window on the left. New and closed windows trigger re-layout, with stable clockwise ordering.
- **Readiness proven by live checks.** Command Guard separates installed configuration, actual model requests, and loaded guards. A client is checked only after YOLO-equivalent execution and a safe Shell probe succeed and the real client invokes its guard. Repairing files alone is not readiness; individual/full verification makes model requests, with scrollable, copyable diagnostics.
- **Explicit shell danger list and quiet hours.** Shell hooks deny matches in the versioned GitHub `AgentGuard/danger-policy.json` (falling back to verified cache or built-in `AgentGuard/rules.py`) or the `rm -rf` target rules in `AgentGuard/core.py`; valid commands outside those rules proceed without an AI veto. A configurable 22:00–08:00 quiet period suppresses sound without weakening blocking.
- **Less desktop clutter.** Show or hide the canvas together, including minimized windows, while processes keep running. No Dock icon, embedded shell, or permanent control window; other applications' windows are not rearranged.
- **Keyboard access.** A configurable global shortcut brings the canvas back. The default is `⌘O`; change it if you need to preserve another application's Open command.
- **One place for Agent safety.** Detect and repair YOLO-equivalent modes when TermYes starts, install/update guards from the menu, and keep dangerous shell commands blocked even when the client itself will not ask.
- **YOLO loaded before each launch.** New zsh terminals install a lightweight agent launcher that repairs the selected client's YOLO mode before starting it; failures are reported without silently falling back.
- **In-app updates.** Check the public GitHub Release redirect without using the anonymous API quota, then download versioned images, verify checksums and application signatures, and replace and relaunch with a backup for recovery.

## Install

Requires **macOS 13+**, on Apple Silicon or Intel.

1. Download the latest published version from [GitHub Releases](https://github.com/zzusec/TermYes/releases/latest). The v1.6.23 build artifact is at `dist/TermYes-v1.6.23-macOS.dmg`.
2. Open it and drag **TermYes.app** to **Applications**.
3. Launch TermYes and allow it to control Terminal when requested:
   **System Settings → Privacy & Security → Automation → TermYes → Terminal**.
4. Open the menu-bar grid icon, then choose Auto Arrange → Show Terminal.

The community build is ad-hoc signed, not Apple-notarized. If macOS blocks first launch, use its per-application **Open Anyway** workflow only if you trust this release. Do not disable system-wide security protections.

Window management needs no Python or Node.js. The **optional guard module** needs a working `/usr/bin/python3`, provided on the development machine by Xcode Command Line Tools. TermYes does not install dependencies automatically. Online updates need internet access.

### Upgrading from Termosaic

The GitHub repository is now **`zzusec/TermYes`**. Existing Termosaic links redirect to the renamed repository, while bundle identity and compatibility image names remain stable.

- The bundle identifier, saved preferences, guard runtime directories, and restore records retain their existing identifiers. The rename does not intentionally reset them; macOS may still request automation permission again.
- v1.6.23 includes a **`Termosaic-v1.6.23-macOS.dmg` compatibility image** for older updaters. Both images contain the same signed TermYes app and are uploaded together when the release is published.
- An automatic upgrade can keep the installed folder named `Termosaic.app` while the app displays **TermYes**. Do not run the old and new copies simultaneously.
- Guard installation does not delete the old bypass-yes checkout. Newly installed runtime files no longer depend on that checkout.

## Use the canvas

| Menu action | Shortcut |
| --- | --- |
| Show and re-tile globally | `⌘O` by default; configurable |

Switching to another application hides the canvas. Hiding windows does not stop the processes inside them. TermYes manages **Apple's Terminal.app only**, not iTerm2 or other terminal emulators.

Auto Arrange lets you show or hide the terminal canvas. Its configurable global shortcut shows and re-tiles the canvas on the display under the pointer. TermYes does not send Continue into existing agent sessions, manually or automatically.

**Scheduled 5h Windows → Set time** lets you choose the start time and Claude, Codex, or both. Every five hours while TermYes runs, it checks the selected guards, opens dedicated Terminal windows, sends `hi`, and displays the actual model replies. It never injects input into active user sessions or sends a duplicate background request. Success requires a successful exit and a reply; failures remain visible. **Activate now (send hi)** uses the same path as the Timer without waiting five hours. Requests may incur model usage charges and do not guarantee a provider's quota window resets; no timer runs while the app is closed.

**No Ctrl-C auto-confirmation or AI approval.** Native Ctrl-C and business dialogs remain manual; Shell enforcement uses YOLO and explicit danger rules.

## Agent command guards

TermYes checks detected clients at launch and every five minutes, maintaining YOLO-equivalent modes and command-guard files. The Command Guard menu separates configuration from live verification; repair one or all unconfigured clients, then verify actual execution and loaded hooks before a checkmark appears. Individual repairs show their result. All controls are at most two menu levels deep. Restart clients after a guard update; Codex also requires checking and trusting new hooks in `/hooks`.

Bundled adapters cover Claude Code, Codex, CodeBuddy, zcode, pi, Qoder, Gemini CLI, Cursor, agy, OpenCode, Factory droid, Crush, and GitHub Copilot CLI.

### Policy and current status

| Situation | TermYes behavior |
| --- | --- |
| Command matches a danger or warning rule | Deny; do not ask for confirmation |
| Invalid input or a caught guard/bridge failure | Return a denial, not a silent allow |
| No danger rule matches | Leave the client's existing permission flow in charge |
| Detected client | Maintain YOLO-equivalent mode and install the command guard; client-side hook loading still requires validation |
| Files changed after TermYes installed them | Refuse automatic overwrite/restore |

**Installed is not the same as protected.** Every adapter is currently unverified at the real-client level. Copilot's host timeout behavior and agy's turbo behavior have known or unresolved compatibility concerns. Loading, trust, disabled hooks, or host timeouts may prevent a guard from taking effect.

These are **shell-text accident guards, not a sandbox**. They do not fully understand arbitrary Python, SQL, remote programs, aliases, or script contents, and do not intercept separate file-editing or MCP tools. A `safe` result means “no rule matched,” not “proved safe.”

Installation merges default user-level client configurations, preserves unrelated hooks, and keeps private restore records. Startup reconciliation enables supported YOLO-equivalent modes; clients that only support launch flags use managed wrappers. Custom configuration roots and project-level configurations are not managed. See [guard documentation](AgentGuard/README.md) for paths, failure behavior, and CLI usage.

## Build and test

Building requires Xcode Command Line Tools. Guard tests use Python; plugin tests require an existing Node.js with `node:module.stripTypeScriptTypes` support. CI uses Node.js 24.

```sh
# Build without replacing an installed app.
SKIP_INSTALL=1 ./build.sh

# Produce main and legacy-compatible DMGs plus portable SHA-256 files.
./create-dmg.sh
/usr/bin/python3 -B Tests/test_release.py
```

The app is written to `build/TermYes.app`; images and checksums go to `dist/`. Running `./build.sh` **without** `SKIP_INSTALL=1` installs into `/Applications/TermYes.app`.

```sh
PYTHONDONTWRITEBYTECODE=1 /usr/bin/python3 -B Tests/test_agent_guard.py
PYTHONDONTWRITEBYTECODE=1 /usr/bin/python3 -B Tests/test_quiet_hours.py
bash AgentGuard/test.sh
PYTHONDONTWRITEBYTECODE=1 bash AgentGuard/test-codex.sh
node Tests/test_guard_plugins.mjs
swiftc Sources/FiveHourActivation.swift Tests/FiveHourActivationTests.swift -o /tmp/termyes-activation-tests
/tmp/termyes-activation-tests
swiftc Sources/GridLayout.swift Tests/main.swift -o /tmp/termyes-grid-tests
/tmp/termyes-grid-tests
swiftc Sources/SemanticVersion.swift Tests/VersionTests.swift -o /tmp/termyes-version-tests
/tmp/termyes-version-tests
swiftc Sources/SemanticVersion.swift Sources/GitHubReleaseLocation.swift Tests/ReleaseLocationTests.swift -o /tmp/termyes-release-location-tests
/tmp/termyes-release-location-tests
bash Tests/test_update_installer.sh
```

Guard tests classify command strings without executing them. Plugin tests mock host APIs; passing them is not real-client YOLO certification. Release tests mount images read-only and exercise the updater on temporary copies without launching the app.

## Updates, privacy, and license

TermYes checks public GitHub Releases shortly after launch and every two hours; it installs only a newer published release. Automatic replacement requires an installation under `/Applications` and permission to write there. Checksums and strict recursive `codesign` verification detect corrupted or inconsistent packages; ad-hoc signing is not an Apple developer-identity guarantee.

The separately versioned danger list lives in `AgentGuard/danger-policy.json` on the repository's `main` branch. Change its `block`/`warn` entries and **increment the integer `version`** before publishing. Updated TermYes clients check at launch and every two hours while running (or immediately via the menu), validate the downloaded data, then atomically activate a higher version for subsequent hooks without reinstalling them. Equal/older versions, invalid downloads and offline checks retain the last valid list; invalid local caches fall back to built-in rules with a visible error. `rm -rf` path grading remains in app code. Older clients need the new app first.

No analytics, accounts, advertising, or telemetry. App network access is used for public release and danger-list checks/downloads. Guard installation and Terminal automation are local. Restore records may include sensitive values from existing client configurations; do not share them.

[MIT](LICENSE). The migrated command-guard module retains its [original MIT license](AgentGuard/LICENSE).
