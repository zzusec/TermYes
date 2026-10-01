# TermYes v1.6.18

## 简体中文

- 一级菜单「自动化」更名为「定时激活5h窗口」，内部只显示起始时间设置与最近激活状态；保留手动「发送“继续”」，不恢复自动发送。

## English

- Rename the Automation menu to Scheduled 5h Windows, with start-time settings and latest activation status; manual Continue remains available without a scheduled send.

# TermYes v1.6.17（待发布）

## 简体中文

- 移除自动发送“继续”的定时器、间隔与范围设置；旧版偏好不会再触发终端输入。
- 保留手动「发送“继续”」（仅匹配 Codex / Claude 会话并跳过待确认提示）与独立的「定时激活5h」。AI 自动审核仍只处理 Ctrl-C 确认。

## English

- Remove scheduled auto-continue and its interval/scope settings; saved settings no longer trigger terminal input.
- Keep manual Continue for matching Codex/Claude sessions and independent scheduled 5h activation. AI Auto Review still covers Ctrl-C prompts only.

# TermYes v1.6.16（待发布）

## 简体中文

- 「Agent自动审批」简化为「自动审批」；单独修复 Agent 后弹出明确的成功或失败结果。
- Claude Code 新增的第三方 Hook 不再阻止安全重基；TermYes 自身守卫被改动时仍拒绝覆盖。
- 定时激活 5h 可选择 Claude、Codex 或两者；自动“继续”的间隔与范围移入紧凑设置窗口。

## English

- Rename Agent Auto Approval to Auto Approval and show a repair result for individual agents.
- Preserve independently added Claude Code hooks while rejecting edits to the managed guard.
- Choose Claude, Codex, or both for scheduled five-hour activation; move auto-continue options into a compact settings panel.

# TermYes v1.6.15（待发布）

## 简体中文

- 将菜单「Ctrl-C 审核」更名为「AI自动审核」，「每 5h 请求」更名为「定时激活5h」；菜单内继续标明 AI 审核范围是 Ctrl-C 窗口确认，不改变实际逻辑。

## English

- Rename the Ctrl-C Review menu to AI Auto Review and the five-hour request setting to Scheduled 5h activation; neither changes behavior.

# TermYes v1.6.14（待发布）

## 简体中文

- 修复 agy 已使用 TermYes 免确认 wrapper 时，点击「修复」被自身符号链接误拦截的问题；独立添加的 `orca-status` 配置会保留，守卫本身被改动仍拒绝覆盖。卸载守卫时同样保留独立配置。
- 未修复原因与目标 Agent 直接显示在菜单中，完整诊断仍可复制；菜单栏图标固定为四宫格，不再因窗口或守卫状态变形。
- 「Ctrl-C 辅助功能权限」只在开启 Ctrl-C 自动确认但尚未授权时显示；此权限与 Agent 免确认无关。

## English

- Fix agy repair rejecting TermYes's own YOLO wrapper symlink. Preserve independent `orca-status` additions, including on uninstall, while refusing edits to the managed guard.
- Show targeted repair failures in the menu and keep the menu-bar icon stable. Only show the Ctrl-C Accessibility shortcut when that separate feature is enabled and permission is missing.

# TermYes v1.6.13（待发布）

## 简体中文

- 主菜单「Agent」更名为「Agent自动审批」；各 Agent 在同一层显示免确认开关状态（勾/叉），未就绪时点击该项可单独修复；守卫未就绪但免确认已开启时保持勾号并提示待修复。
- 审核模型、自动化选项和快捷键选项统一放在各自的二级菜单内，移除所有三级及更深层菜单。

## English

- Rename the Agent menu to Agent Auto Approval and display check/cross icons for each detected client's permission state; clicking an unready client repairs it.
- Flatten model review, automation, and shortcut choices into their second-level menus; no third-level menus remain.

# TermYes v1.6.12（待发布）

## 简体中文

- 自动化菜单新增独立于自动“继续”的每 5 小时定时请求。按用户指定时间启动缺失的 Claude/Codex Terminal 窗口，并分别发送一句简短问候以触发模型请求，不向可能退回 Shell 的标签页键入文字。守卫未就绪、命令失败或模型无回复时显示失败并可复制详情。

## English

- Add a five-hour scheduled model request independent of Auto Continue. Open missing Claude/Codex Terminal windows and make a short non-interactive request for each agent, reporting guard, CLI, and empty-response failures without typing into a shell.

# TermYes v1.6.11（待发布）

## 简体中文

- 菜单栏仅保留状态图标，不再常驻显示「配置 8/8」；主菜单及 Agent 子菜单缩短文案、收起完整错误信息，诊断信息仍可复制。

## English

- Show only the status icon in the menu bar. Shorten main and Agent menu labels while keeping full error details available through copy actions.

# TermYes v1.6.10（待发布）

## 简体中文

- 菜单栏「一键检查并修复 Agent」可展开查看每个已检测 Agent 的 YOLO/守卫状态；可只修复一个未就绪 Agent，或一次只修复所有未就绪项，不重复安装已就绪项。
- 显式修复时若免确认启动 wrapper 被原有独立可执行文件占用，先迁移保留原文件再安装 wrapper；修复失败会恢复原命令，外部修改的 Hook 文件仍不会被覆盖。菜单展示具体失败原因。

## English

- Expand the menu-bar Agent action to inspect readiness and repair either one client or only those not ready.
- Explicit repairs can preserve an existing standalone client executable under the local vendor directory before installing the YOLO wrapper; a failed repair restores the original command and exposes the error.

# TermYes v1.6.9（待发布）

## 简体中文

- GitHub `main` 的 `AgentGuard/danger-policy.json` 独立维护危险命令清单；递增 `version` 后，客户端启动时及每两小时检查并在校验通过后原子更新，Hook 下一次调用生效。失败保留上版规则并在菜单显示。
- GitHub 正式版应用检查周期缩短为两小时；仅发布更高版本的 Release 时自动下载、验证并更新。旧版应用需先升级才支持规则热更新。

## English

- Independently versioned GitHub danger list, checked at launch and every two hours while the app runs. Valid higher revisions activate atomically for subsequent hooks; errors preserve the last valid policy and appear in the menu.
- Published application releases are checked every two hours; older clients must upgrade to support data-only rule updates.

# TermYes v1.6.8

## 简体中文

- Codex Shell Hook 只按 `AgentGuard/rules.py` 危险清单与 `AgentGuard/core.py` 的 `rm -rf` 目标分级拒绝；未命中规则的有效命令直接放行，不再由 AI 二次否决。
- 模型缺失、离线或给出保守判断不会再阻拦清单外命令。无效 Hook 输入和无法可靠解析的命令仍拒绝；窗口级 Ctrl-C 可选模型审核与 Shell 放行完全分离。
- 已保存的旧版 AI 拒绝记录与学习记忆不参与 Shell 放行决策。

## English

- Codex Shell hooks deny only commands matching the shared danger list or high-impact `rm -rf` target rules. Valid unmatched commands are permitted without an AI veto, including when the reviewer is unavailable.
- Invalid hook input and unclassifiable shell syntax still deny. Optional AI review applies only to the separate Ctrl-C terminal-input workflow; old reviewer history and learning memory do not control Shell commands.

# TermYes v1.6.7

## 简体中文

- 未配置独立 AI 审批模型时，Codex Shell 守卫自动使用 Codex 用户级配置的默认模型复核未被确定性规则拦截的命令；模型故障或无效响应拒绝执行，不依赖 YOLO 下可能缺失的 `PermissionRequest`。单次启动参数与项目级模型覆盖不在自动跟随范围内。
- 自动模式不使用已学习命令的放行缓存；菜单显示“跟随 Codex”，已手动配置并主动关闭的模型仍保持关闭。
- 当前仅覆盖 Codex Shell Hook；其他客户端、独立文件编辑及 MCP 不在本次 AI 审批范围内。

## English

- Codex shell hooks now review non-blocked commands with the user-configured default Codex model. Missing or invalid model responses deny rather than silently allowing commands, even without `PermissionRequest` under YOLO. CLI and project-level model overrides are not tracked.
- Automatic review bypasses learned allow caches; explicitly disabled custom reviewers remain disabled. The menu displays the active mode.

# TermYes v1.6.6

## 简体中文

- 增加常驻检查：启动后每 5 分钟检查已检测到的 Agent，修复 YOLO/等效权限模式并安装或更新危险命令守卫。
- 启动器会在启动 Agent 前确认守卫文件与权限配置就绪；检查失败则拒绝启动，不再只提示后继续运行。
- 菜单分别显示 YOLO 状态与守卫文件状态；配置被外部修改时拒绝覆盖并报告错误。守卫文件就绪不代表客户端实际加载或信任 Hook，仍须逐客户端验证。
- 菜单栏图标旁显示就绪数；展开后直接显示 YOLO/守卫汇总和“一键检查并修复 Agent”，异常时使用警示图标。
- 危险与警告级 Shell 指令继续硬拒绝，普通指令交回客户端；守卫不覆盖独立文件编辑、MCP 等操作。

本地构建产物：`TermYes-v1.6.6-macOS.dmg` 与旧版更新兼容包 `Termosaic-v1.6.6-macOS.dmg`。未自动发布到 GitHub。

## English

- Monitor detected agents at launch and every five minutes, maintaining YOLO-equivalent modes and installing or updating shell-command guards.
- Agent launchers fail closed when guard files or permissions cannot be prepared; changed files are reported, not overwritten.
- The menu distinguishes YOLO readiness from installed guard files. Client-side hook loading and trust remain unverified; file edits and MCP calls are outside the shell guard.
- The menu bar shows a ready count, a prominent one-click repair action, and a warning icon when a check fails.

# TermYes v1.6.5

## 简体中文

本版新增 Agent 权限模式的自动检测、修复和启动前加载。

### 本次更新

- TermYes 启动时自动检测本机已安装的 Agent，并在菜单中显示权限模式与修复状态。
- Codex、Claude Code、CodeBuddy、Qoder、zcode 会直接修复为 YOLO 或等效免确认配置；pi 默认无需审批。
- Gemini、Cursor、agy、OpenCode、Factory droid、Crush、Copilot 使用 `~/.local/bin` 下的幂等启动 wrapper 强制附加免确认参数。
- 新开的 zsh 终端加载 `termyes-agent-yolo-shell`；每次启动已安装 Agent 前先调用 `enable-yolo <client>`，无需为加载 YOLO 重启客户端。
- 启动前修复失败会明确提示；TermYes `danger-guard` 仍是独立的失败关闭安全层，危险命令即使在 YOLO/`bypassPermissions` 下也硬拒绝。
- 安装守卫前先协调权限模式，恢复守卫时不会把 YOLO 配置一起回退。
- 菜单新增“自动检测并修复 YOLO”，并展示每个客户端的检测结果、权限模式和守卫安装状态。

### 下载与升级

- **新安装：** `TermYes-v1.6.5-macOS.dmg`。
- **旧版自动更新：** `Termosaic-v1.6.5-macOS.dmg`，为兼容包，不是另一个产品版本。
- 两个包均为 macOS 13+ 的 Apple Silicon / Intel 通用架构，附各自的 `.sha256` 文件。

### 重要限制

本次修改的是 Agent 权限模式和启动参数，不等于已完成十三类客户端 Hook 的真实端到端验证。Hook 未加载、未信任、被宿主超时或客户端自身绕过仍可能使守卫失效；守卫不是沙箱，也不覆盖全部危险语义、独立文件编辑或 MCP 工具。

窗口管理无需 Python；可选守卫需要可用的 `/usr/bin/python3`。社区构建为 ad-hoc 签名，尚未 Apple 公证。

## English

This release adds automatic detection, repair, and pre-launch loading of Agent YOLO-equivalent permission modes.

### What's new

- TermYes scans installed agents at startup and shows each client's permission mode and repair state in the menu.
- Codex, Claude Code, CodeBuddy, Qoder, and zcode are repaired directly to YOLO or equivalent no-confirmation settings; pi requires no approval configuration.
- Gemini, Cursor, agy, OpenCode, Factory droid, Crush, and Copilot use idempotent launchers under `~/.local/bin` that add their no-confirmation flags.
- New zsh terminals load `termyes-agent-yolo-shell`. Each installed agent runs `enable-yolo <client>` before its real command, so YOLO can load without restarting the client.
- Repair failures are reported explicitly. The TermYes `danger-guard` remains an independent fail-closed safety layer and hard-denies dangerous commands even under YOLO or `bypassPermissions`.
- Guard installation reconciles permissions first, and restoring a guard no longer rolls back YOLO configuration.
- Adds a **Detect and repair YOLO** menu action with per-client detection, permission, and guard-install status.

### Downloads and migration

- **New installs:** `TermYes-v1.6.5-macOS.dmg`.
- **Older automatic updaters:** `Termosaic-v1.6.5-macOS.dmg`, a compatibility image of the same application.
- Both support macOS 13+ on Apple Silicon and Intel, with matching `.sha256` files.

### Important limitations

This change covers permission modes and launch parameters, not real-client end-to-end certification of all thirteen hook adapters. Missing or untrusted hooks, host timeouts, or client-specific bypasses can still prevent interception. The guard is not a sandbox and does not cover every dangerous operation, independent file editing, or MCP calls.

Window management does not require Python; optional guards require a working `/usr/bin/python3`. Community builds are ad-hoc signed and not Apple-notarized.

# TermYes v1.6.4

## 简体中文

本版将产品和 GitHub 仓库统一更名为 TermYes。

### 本次更新

- 增加可选的 Codex `PermissionRequest` 独立 AI reviewer。危险命令仍由确定性规则先行拒绝；仅高置信度、可验证且局限于批准工作区的命令可自动放行。
- 在菜单栏的 Agent 命令守卫中新增“AI 审批模型”，可添加、选择和删除多个模型配置。
- AI reviewer 默认放行构建、测试、脚本、本地 Git 操作和软件包安装；明确危险仍拒绝。
- 允许在 `/tmp` 和 `/private/tmp` 内写入及清理构建暂存，不会仅因路径在工作区外而拒绝。
- 增加精确命令学习：只记忆“完整命令 + 工作目录”哈希，重复的同一命令可跳过模型，明文命令不落盘。
- 精确命令累计 3 次后，可提升为受限安全模式，例如 `git status`、`swift test` 或 `npm run lint`。
- 含管道、重定向、变量和内联解释器的命令不会生成模式；危险规则始终先执行并覆盖学习结果。
- 新增“同步记忆到 iCloud”开关，本机记忆与 iCloud Drive 文件自动合并。
- 命令记忆改为跨电脑哈希，不再绑定本机绝对工作目录；每次放行仍按当前电脑的路径执行危险规则。
- reviewer 请求超时或网络中断时会自动重试一次；只有重试仍失败才拒绝。
- 每次允许、拒绝、规则拦截和超时都会写入本地 `0600` 历史文件，记录命令、目录、原因和时间。
- 同一条命令再次出现时，最近的拒绝原因会随审批请求交给 reviewer 复审；确认安全后再学习放行。
- 原始命令历史只存本机；iCloud 只同步命令哈希和受限模式，不上传命令明文。
- 新增窗口级 Ctrl-C 审批：获得辅助功能权限后，只自动确认输入严格为 `\u{3}` 的终端输入弹窗。
- 回车、普通文本、未知控制序列、密码和权限弹窗不会自动处理；发送前会再次核对窗口内容。
- 一级菜单仅保留画布操作、AI 审批、自动化、设置和退出。
- 自动继续与 Agent 命令守卫并入“自动化”；快捷键与更新并入“设置”。
- 菜单打开时暂停窗口审批状态发布，且只在状态真正变化时刷新，避免 SwiftUI 重建并关闭菜单。
- 窗口标题每 0.25 秒检查一次，只有出现 `Action Required` 才读取正文；正文最多每 0.5 秒扫描一次。
- GitHub 仓库更名为 `zzusec/TermYes`，应用内更新检查改用新仓库地址。
- 将 AI 审批提升为顶层菜单，直接显示当前模型；审批模型、启用状态和自动学习都集中在同一子菜单。
- AI 审批菜单显示已学习的精确命令数量，并提供自动学习开关。
- reviewer 超时、接口错误、无效响应、中低置信度、越界路径和无法核实的脚本均拒绝，不会退回无提示放行。
- AI reviewer 不处理密码、终端输入、Computer Use、MCP 或其他应用级弹窗。
- 增加本地时间 22:00–08:00 夜间静音配置；静音只跳过提示音，不改变命令拦截、AI 决策或审计日志。
- 保留奇数窗口左列多一个的两列布局，以及旧版更新兼容包。

### 下载与升级

- **新安装：** `TermYes-v1.6.4-macOS.dmg`。
- **旧版自动更新：** `Termosaic-v1.6.4-macOS.dmg`，为兼容包，不是另一个产品版本。
- 两个包均为 macOS 13+ 的 Apple Silicon / Intel 通用架构，附各自的 `.sha256` 文件。
- 保留原 Bundle ID 与配置路径；旧版自动升级后应用目录可能仍叫 `Termosaic.app`，但显示名称为 TermYes。
- GitHub 仓库更名为 `zzusec/TermYes`，旧地址会自动重定向。请勿同时运行新旧应用副本。

### 重要限制

**本版本不自动开启任何客户端的 YOLO，也不自动批准原生权限请求。** 十三类适配器尚未完成真实客户端端到端验证，已有权限配置保持不变。Hook 加载/信任与宿主超时行为仍可能影响拦截；守卫不是沙箱，不覆盖全部危险语义、独立文件编辑或 MCP 工具。

窗口管理无需 Python；可选守卫需要可用的 `/usr/bin/python3`。社区构建为 ad-hoc 签名，尚未 Apple 公证。

## English

This release unifies the product and GitHub repository under the TermYes name.

### What's new

- Adds an optional independent AI reviewer for Codex `PermissionRequest` events. Deterministic rules still block dangerous commands first; only high-confidence, verifiable actions within approved workspace roots can be auto-approved.
- Adds an **AI approval models** menu with add, select, and delete controls.
- Defaults builds, tests, scripts, local Git operations, and package installation to allow; explicit high-impact dangers still deny.
- Allows build staging and cleanup under `/tmp` and `/private/tmp`.
- Adds exact-context learning: the reviewer remembers a command/working-directory hash after a high-confidence allow, while deterministic danger rules always run first.
- Promotes an exact command to a narrow learned pattern after three uses, such as `git status`, `swift test`, or `npm run lint`.
- Shell composition, redirection, variables, and inline interpreters never produce learned patterns; danger rules always override learning.
- Adds a **Sync memory to iCloud** toggle that merges local and iCloud Drive memory.
- Makes command memory portable across Macs while still evaluating each approval against the current local paths and danger rules.
- Retries reviewer timeouts and network failures once before denying.
- Stores every allow, deny, rule block, and timeout in a local `0600` history with command, directory, reason, and time.
- Feeds recent denial reasons back into the reviewer when the same command appears again; only a safe re-review can learn and allow it.
- Keeps raw command history local; iCloud sync stores only command hashes and bounded patterns.
- Adds window-level Ctrl-C approval: with Accessibility permission, only terminal-input prompts whose requested input is exactly `\u{3}` can be confirmed automatically.
- Enter, ordinary text, unknown control sequences, password prompts, and permission prompts remain manual; window contents are rechecked before sending Return.
- Keeps the top level focused on canvas actions, AI approval, Automation, Settings, and Quit.
- Moves auto-continue and Agent guard controls under Automation; moves shortcuts and updates under Settings.
- Pauses window-approval status publishing while a menu is open and publishes only real changes, preventing SwiftUI from rebuilding and closing the menu.
- Checks Terminal window titles every 0.25 seconds and reads full contents only for `Action Required`, with full scans capped at once per 0.5 seconds.
- Renames the GitHub repository to `zzusec/TermYes` and switches in-app update checks to the new repository.
- Promotes AI approval to a top-level menu showing the active model, enable state, model selection, and learning controls.
- Shows the learned exact-command count and allows learning to be disabled without removing existing memory.
- Reviewer timeouts, API errors, invalid responses, medium/low confidence, out-of-scope paths, and unverifiable scripts are denied without falling back to silent approval.
- The reviewer does not handle passwords, terminal input, Computer Use, MCP, or other app-level prompts.
- Adds a configurable 22:00–08:00 local quiet period that suppresses audible alerts without weakening blocking, AI decisions, or audit logging.
- Retains the two-column odd-window layout and the legacy-updater compatibility image.

### Downloads and migration

- **New installs:** `TermYes-v1.6.4-macOS.dmg`.
- **Older automatic updaters:** `Termosaic-v1.6.4-macOS.dmg`, a compatibility image of the same application.
- Both support macOS 13+ on Apple Silicon and Intel, with matching `.sha256` files.
- Existing bundle identity and configuration paths remain stable. Automatic upgrades may keep the installed folder named `Termosaic.app` while displaying TermYes.
- The repository is now `zzusec/TermYes`; old URLs redirect automatically. Do not run old and new copies simultaneously.

### Important limitations

**This release does not enable client YOLO modes or auto-approve native permission requests.** All thirteen adapters await real-client end-to-end validation; existing permission settings are unchanged. Hook loading/trust and host timeout behavior can still prevent interception. The guard is not a sandbox and does not cover every dangerous operation, independent file-editing tools, or MCP calls.

Window management does not require Python; optional guards require a working `/usr/bin/python3`. Community builds are ad-hoc signed and not Apple-notarized.
