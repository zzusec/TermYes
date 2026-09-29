# TermYes v1.5.0

## 简体中文

本版新增可选的 Codex AI 审批和夜间静音，并保留奇数窗口的两列布局。

### 本次更新

- 增加可选的 Codex `PermissionRequest` 独立 AI reviewer。危险命令仍由确定性规则先行拒绝；仅高置信度、可验证且局限于批准工作区的命令可自动放行。
- reviewer 超时、接口错误、无效响应、中低置信度、越界路径和无法核实的脚本均拒绝，不会退回无提示放行。
- AI reviewer 不处理密码、终端输入、Computer Use、MCP 或其他应用级弹窗。
- 增加本地时间 22:00–08:00 夜间静音配置；静音只跳过提示音，不改变命令拦截、AI 决策或审计日志。
- 保留奇数窗口左列多一个的两列布局，以及旧版更新兼容包。

### 下载与升级

- **新安装：** `TermYes-v1.5.0-macOS.dmg`。
- **旧版自动更新：** `Termosaic-v1.5.0-macOS.dmg`，为兼容包，不是另一个产品版本。
- 两个包均为 macOS 13+ 的 Apple Silicon / Intel 通用架构，附各自的 `.sha256` 文件。
- 保留原 Bundle ID 与配置路径；旧版自动升级后应用目录可能仍叫 `Termosaic.app`，但显示名称为 TermYes。
- GitHub 仓库暂保留 `zzusec/Termosaic`。请勿同时运行新旧应用副本。

### 重要限制

**本版本不自动开启任何客户端的 YOLO，也不自动批准原生权限请求。** 十三类适配器尚未完成真实客户端端到端验证，已有权限配置保持不变。Hook 加载/信任与宿主超时行为仍可能影响拦截；守卫不是沙箱，不覆盖全部危险语义、独立文件编辑或 MCP 工具。

窗口管理无需 Python；可选守卫需要可用的 `/usr/bin/python3`。社区构建为 ad-hoc 签名，尚未 Apple 公证。

## English

This release adds optional Codex AI approval and quiet hours while retaining the two-column odd-window layout.

### What's new

- Adds an optional independent AI reviewer for Codex `PermissionRequest` events. Deterministic rules still block dangerous commands first; only high-confidence, verifiable actions within approved workspace roots can be auto-approved.
- Reviewer timeouts, API errors, invalid responses, medium/low confidence, out-of-scope paths, and unverifiable scripts are denied without falling back to silent approval.
- The reviewer does not handle passwords, terminal input, Computer Use, MCP, or other app-level prompts.
- Adds a configurable 22:00–08:00 local quiet period that suppresses audible alerts without weakening blocking, AI decisions, or audit logging.
- Retains the two-column odd-window layout and the legacy-updater compatibility image.

### Downloads and migration

- **New installs:** `TermYes-v1.5.0-macOS.dmg`.
- **Older automatic updaters:** `Termosaic-v1.5.0-macOS.dmg`, a compatibility image of the same application.
- Both support macOS 13+ on Apple Silicon and Intel, with matching `.sha256` files.
- Existing bundle identity and configuration paths remain stable. Automatic upgrades may keep the installed folder named `Termosaic.app` while displaying TermYes.
- The repository remains `zzusec/Termosaic`. Do not run old and new copies simultaneously.

### Important limitations

**This release does not enable client YOLO modes or auto-approve native permission requests.** All thirteen adapters await real-client end-to-end validation; existing permission settings are unchanged. Hook loading/trust and host timeout behavior can still prevent interception. The guard is not a sandbox and does not cover every dangerous operation, independent file-editing tools, or MCP calls.

Window management does not require Python; optional guards require a working `/usr/bin/python3`. Community builds are ad-hoc signed and not Apple-notarized.
