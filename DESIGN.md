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

- The main action is one toggle, “显示终端画布”, and its state is the canvas state.
- “重新排列” uses the display under the pointer; hiding the canvas when another application becomes active is always on, not a setting.
- The top level stays short: canvas toggle, re-tile, and sending `继续` once stay direct; AI approval is one top-level submenu; auto-continue and Agent command guards live under one Automation submenu; shortcuts and updates live under Settings.
- Submenus stay short. Start times are picked in a small floating panel, never as a 24-row clock inside the menu.
- Automation permission failures explain both the problem and the exact recovery path in System Settings.
- The menu-bar control is the sole interface and holds every action, auto-continue status, and online-update state.

- Guard controls distinguish installation records from verified protection. Show pending/known-gap states, never a green “protected” claim without real-client evidence; errors stay in the menu with copyable details.
- AI approval has a dedicated top-level submenu: enable state, current model, model choices, exact-command learning, and a small floating add/manage panel.
- AI approval memory remains local-first, with one optional iCloud Drive merge toggle shown alongside learning controls.
- Window-level approval is a separate opt-in switch with an explicit Accessibility permission entry and a narrow Ctrl-C-only scope.
