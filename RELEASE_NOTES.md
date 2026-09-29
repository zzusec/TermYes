# TermYes v1.5.1

## 简体中文

本版完善 AI 审批模型管理，并调整为“普通开发操作默认放行，只拒绝明确危险”。

### 本次更新

- 增加可选的 Codex `PermissionRequest` 独立 AI reviewer。危险命令仍由确定性规则先行拒绝；仅高置信度、可验证且局限于批准工作区的命令可自动放行。
- 在菜单栏的 Agent 命令守卫中新增“AI 审批模型”，可添加、选择和删除多个模型配置。
- AI reviewer 默认放行构建、测试、脚本、本地 Git 操作和软件包安装；明确危险仍拒绝。
- 允许在 `/tmp` 和 `/private/tmp` 内写入及清理构建暂存，不会仅因路径在工作区外而拒绝。
- reviewer 超时、接口错误、无效响应、中低置信度、越界路径和无法核实的脚本均拒绝，不会退回无提示放行。
- AI reviewer 不处理密码、终端输入、Computer Use、MCP 或其他应用级弹窗。
- 增加本地时间 22:00–08:00 夜间静音配置；静音只跳过提示音，不改变命令拦截、AI 决策或审计日志。
- 保留奇数窗口左列多一个的两列布局，以及旧版更新兼容包。

### 下载与升级

- **新安装：** `TermYes-v1.5.1-macOS.dmg`。
- **旧版自动更新：** `Termosaic-v1.5.1-macOS.dmg`，为兼容包，不是另一个产品版本。
- 两个包均为 macOS 13+ 的 Apple Silicon / Intel 通用架构，附各自的 `.sha256` 文件。
- 保留原 Bundle ID 与配置路径；旧版自动升级后应用目录可能仍叫 `Termosaic.app`，但显示名称为 TermYes。
- GitHub 仓库暂保留 `zzusec/Termosaic`。请勿同时运行新旧应用副本。

### 重要限制

**本版本不自动开启任何客户端的 YOLO，也不自动批准原生权限请求。** 十三类适配器尚未完成真实客户端端到端验证，已有权限配置保持不变。Hook 加载/信任与宿主超时行为仍可能影响拦截；守卫不是沙箱，不覆盖全部危险语义、独立文件编辑或 MCP 工具。

窗口管理无需 Python；可选守卫需要可用的 `/usr/bin/python3`。社区构建为 ad-hoc 签名，尚未 Apple 公证。

## English

This release adds in-app AI approval model management and defaults ordinary development work to allow.

### What's new

- Adds an optional independent AI reviewer for Codex `PermissionRequest` events. Deterministic rules still block dangerous commands first; only high-confidence, verifiable actions within approved workspace roots can be auto-approved.
- Adds an **AI approval models** menu with add, select, and delete controls.
- Defaults builds, tests, scripts, local Git operations, and package installation to allow; explicit high-impact dangers still deny.
- Allows build staging and cleanup under `/tmp` and `/private/tmp`.
- Reviewer timeouts, API errors, invalid responses, medium/low confidence, out-of-scope paths, and unverifiable scripts are denied without falling back to silent approval.
- The reviewer does not handle passwords, terminal input, Computer Use, MCP, or other app-level prompts.
- Adds a configurable 22:00–08:00 local quiet period that suppresses audible alerts without weakening blocking, AI decisions, or audit logging.
- Retains the two-column odd-window layout and the legacy-updater compatibility image.

### Downloads and migration

- **New installs:** `TermYes-v1.5.1-macOS.dmg`.
- **Older automatic updaters:** `Termosaic-v1.5.1-macOS.dmg`, a compatibility image of the same application.
- Both support macOS 13+ on Apple Silicon and Intel, with matching `.sha256` files.
- Existing bundle identity and configuration paths remain stable. Automatic upgrades may keep the installed folder named `Termosaic.app` while displaying TermYes.
- The repository remains `zzusec/Termosaic`. Do not run old and new copies simultaneously.

### Important limitations

**This release does not enable client YOLO modes or auto-approve native permission requests.** All thirteen adapters await real-client end-to-end validation; existing permission settings are unchanged. Hook loading/trust and host timeout behavior can still prevent interception. The guard is not a sandbox and does not cover every dangerous operation, independent file-editing tools, or MCP calls.

Window management does not require Python; optional guards require a working `/usr/bin/python3`. Community builds are ad-hoc signed and not Apple-notarized.
