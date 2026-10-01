# TermYes — Design

<!-- impeccable:design-schema 1 -->

## Direction

A quiet, menu-bar-only macOS utility. It must remain available without creating a desktop window or Dock presence that competes with the terminal wall.

## Visual System

- Use macOS semantic colors so light mode, dark mode, contrast settings, and accent color work automatically.
- Use SF Symbols for all icons.
- Use standard bordered and bordered-prominent controls with clear text labels.
- Reserve green for an actively displayed terminal wall, amber for hidden/idle state, and red only for actionable errors.
- Use the standard compact menu-bar menu; do not create a desktop control window.
- Use system typography with monospaced digits only for the live window count.

## Interaction

- The top level starts with three workflows: “自动排列”, “自动审批”, and “定时激活5h窗口”.
- “自动排列” contains a show/hide toggle and one configurable global shortcut to show and re-tile; re-tiling uses the display under the pointer, and hiding on app switch is always on.
- Version and update checking stay in the main menu.
- Failures show a short, contextual “查看原因…” action; full details and an optional copy action live in a dialog, not in the main menu.
- Submenus stay short. Start times are picked in a small floating panel, never as a 24-row clock inside the menu.
- Automation permission failures explain both the problem and the exact recovery path in System Settings.
- The menu-bar control is the sole interface and holds every action and online-update state.

- Guard controls distinguish installation records from verified protection. Show pending/known-gap states, never a green “protected” claim without real-client evidence; errors stay in the menu with copyable details.
- “自动审批” shows agent readiness, repairs, and dangerous-command policy updates; it does not imply model review of shell commands.
