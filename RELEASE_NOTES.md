# TermYes v1.4.1

## 简体中文

本版调整奇数个 Terminal 窗口的排列方式。

### 本次更新

- 奇数个窗口改为两列布局，左列比右列多一个；三个窗口为左侧上下两个、右侧一个，五个窗口为左侧三个、右侧两个。
- 偶数个窗口继续使用原有平衡网格，窗口仍按顺时针顺序稳定分配。
- 同步发布旧版更新兼容包，修复 1.3.8 等旧版本检查更新后没有可见结果的问题。

### 下载与升级

- **新安装：** `TermYes-v1.4.1-macOS.dmg`。
- **旧版自动更新：** `Termosaic-v1.4.1-macOS.dmg`，为兼容包，不是另一个产品版本。
- 两个包均为 macOS 13+ 的 Apple Silicon / Intel 通用架构，附各自的 `.sha256` 文件。
- 保留原 Bundle ID 与配置路径；旧版自动升级后应用目录可能仍叫 `Termosaic.app`，但显示名称为 TermYes。
- GitHub 仓库暂保留 `zzusec/Termosaic`。请勿同时运行新旧应用副本。

### 重要限制

**本版本不自动开启任何客户端的 YOLO，也不自动批准原生权限请求。** 十三类适配器尚未完成真实客户端端到端验证，已有权限配置保持不变。Hook 加载/信任与宿主超时行为仍可能影响拦截；守卫不是沙箱，不覆盖全部危险语义、独立文件编辑或 MCP 工具。

窗口管理无需 Python；可选守卫需要可用的 `/usr/bin/python3`。社区构建为 ad-hoc 签名，尚未 Apple 公证。

## English

This release changes how odd-numbered Terminal window sets are arranged.

### What's new

- Odd window counts now use two columns, with one extra window on the left: three windows become two stacked on the left and one on the right; five become three on the left and two on the right.
- Even window counts retain the balanced grid, with stable clockwise window assignment.
- Publishes the legacy-updater compatibility image so older versions such as 1.3.8 can detect and install the update.

### Downloads and migration

- **New installs:** `TermYes-v1.4.1-macOS.dmg`.
- **Older automatic updaters:** `Termosaic-v1.4.1-macOS.dmg`, a compatibility image of the same application.
- Both support macOS 13+ on Apple Silicon and Intel, with matching `.sha256` files.
- Existing bundle identity and configuration paths remain stable. Automatic upgrades may keep the installed folder named `Termosaic.app` while displaying TermYes.
- The repository remains `zzusec/Termosaic`. Do not run old and new copies simultaneously.

### Important limitations

**This release does not enable client YOLO modes or auto-approve native permission requests.** All thirteen adapters await real-client end-to-end validation; existing permission settings are unchanged. Hook loading/trust and host timeout behavior can still prevent interception. The guard is not a sandbox and does not cover every dangerous operation, independent file-editing tools, or MCP calls.

Window management does not require Python; optional guards require a working `/usr/bin/python3`. Community builds are ad-hoc signed and not Apple-notarized.
