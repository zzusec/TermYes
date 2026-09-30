<div align="center">
  <img src="Resources/TermYesIcon-1024.png" width="128" alt="TermYes 图标">
  <h1>TermYes</h1>
  <p><strong>终端统一管理，危险指令及时拦截。</strong></p>
  <p>面向系统 Terminal 与 Agent 命令守卫的原生 macOS 菜单栏工具。</p>
  <p>
    <a href="https://github.com/zzusec/TermYes/actions/workflows/build.yml"><img src="https://github.com/zzusec/TermYes/actions/workflows/build.yml/badge.svg" alt="构建与测试"></a>
    <img src="https://img.shields.io/badge/macOS-13%2B-black" alt="macOS 13 或更高版本">
    <img src="https://img.shields.io/badge/Apple_Silicon_%2B_Intel-universal-blue" alt="macOS 通用架构应用">
  </p>
  <p><a href="README.md">English</a> · <strong>简体中文</strong></p>
  <p><a href="https://github.com/zzusec/TermYes/releases/latest">下载安装</a> · <a href="RELEASE_NOTES.md">更新说明</a> · <a href="AgentGuard/README.md">守卫详细说明</a></p>
</div>

TermYes 将 **Termosaic 的终端画布**与 **bypass-yes 的命令守卫**整合到一个应用：集中查看现有 Terminal 会话，隐藏窗口但不中断进程，并在菜单栏统一安装或恢复各 Agent 的 Shell 守卫。

> **先自动进入 YOLO，再硬拦危险。** TermYes 会检测已安装的 Agent，把支持权限模式的客户端修复为 YOLO/等效免确认，只支持启动参数的客户端使用受管 wrapper；危险命令仍由失败关闭的守卫硬拒绝。适配器 Hook 的真实客户端行为仍需验证。

## 主要功能

- **一张终端画布。** 系统 Terminal 窗口无缝平铺：四个窗口组成 2×2，六个组成 3×2，奇数个窗口按左列多一个的两列排布；新增或关闭窗口后自动重排，保持稳定的顺时针顺序。
- **可选 AI 审批与夜间静音。** Codex 的越界审批可交给独立 reviewer，并可在 Agent 命令守卫菜单中新增、切换审批模型。普通开发操作默认放行，明确高影响危险才拒绝，`/tmp` 与 `/private/tmp` 可写；22:00–08:00 静音时段只关闭提示音，不降低命令拦截强度。
- **自迭代命令学习。** 高置信度放行的命令先按“完整命令 + 工作目录”哈希记忆，受限制的安全模式累计 3 次后可自动提升；危险规则始终优先执行。
- **可选 iCloud 记忆同步。** 学习到的命令和模式可通过 iCloud Drive 合并，在多台 Mac 间同步，不依赖自建数据库。
- **本地判断历史与复审。** 每次允许、拒绝、规则拦截和 reviewer 超时都会存入本地历史；再次遇到同一条命令时会把上次拒绝原因交给 reviewer 复审，确认安全后再学习放行。
- **窗口级 Ctrl-C 审批。** 获得辅助功能权限后，TermYes 只会在明确匹配的终端输入确认框中选择 Ctrl-C；回车、文本、密码和权限弹窗仍保持人工处理。
- **减少桌面干扰。** 窗口一起显示或隐藏，包含最小化窗口，内部进程继续运行。不显示 Dock 图标，不嵌入 Shell，不创建常驻控制窗口，也不调整其他应用的窗口。
- **快捷键呼出。** 可配置全局快捷键，默认 `⌘O`；若要保留其他应用的“打开”命令，请修改它。
- **保守恢复任务。** 定时识别部分额度或网络中断并尝试发送“继续”；识别出的确认提示、守卫拒绝、密码提示及未知自动恢复状态会跳过，**不再自动输入 `yes`**。
- **统一管理 Agent 安全。** TermYes 启动时自动检测并修复 YOLO/等效权限模式，在菜单栏安装、更新或恢复守卫，并让危险 Shell 命令在客户端不弹确认时仍被硬拒绝。
- **每次启动前加载 YOLO。** 新开的 zsh 终端会装载轻量 Agent 启动器，在启动所选客户端前修复其 YOLO 模式；修复失败会明确提示，不会静默退化。
- **应用内更新。** 下载对应版本的安装包，验证校验和与应用签名，保留备份后替换并重新启动。

## 安装

支持 **macOS 13+**，同时提供 Apple Silicon 与 Intel 架构。

1. 从 [GitHub Releases](https://github.com/zzusec/TermYes/releases/latest) 下载 **`TermYes-v1.6.5-macOS.dmg`**。
2. 打开安装包，将 **TermYes.app** 拖入 **Applications**。
3. 启动 TermYes，按提示允许控制 Terminal：
   **系统设置 → 隐私与安全性 → 自动化 → TermYes → Terminal**。
4. 点击菜单栏四宫格图标，显示终端画布。

社区版本采用 ad-hoc 签名，尚未经过 Apple 公证。如果 macOS 阻止首次启动，请在确认信任该版本后使用系统针对该应用的“仍要打开”流程；不需要关闭系统级安全保护。

窗口管理功能不需要 Python 或 Node.js。可选的**命令守卫模块**需要可用的 `/usr/bin/python3`，开发机上由 Xcode Command Line Tools 提供；应用不会自动安装依赖。在线更新需要网络连接。

### 从 Termosaic 升级

GitHub 仓库现更名为 **`zzusec/TermYes`**。旧的 Termosaic 链接会重定向到新仓库；Bundle ID、配置目录和兼容安装包名称保持不变。

- Bundle ID、已保存偏好、守卫运行目录和恢复记录沿用原标识，不因改名主动清空；macOS 仍可能再次请求自动化权限。
- Release 同时提供主安装包与 **`Termosaic-v1.6.5-macOS.dmg` 旧版更新兼容包**。二者包含相同的已签名 TermYes 应用，仅外层应用目录名对应不同更新器的预期。
- 自动升级后，安装目录可能仍叫 `Termosaic.app`，应用显示名称则为 **TermYes**。请勿同时运行新旧两个副本。
- 安装守卫不会删除原 bypass-yes 仓库；新安装的运行文件不再依赖该仓库。

## 使用终端画布

| 菜单操作 | 快捷键 |
| --- | --- |
| 显示或隐藏终端画布 | `⌥⌘1` |
| 在鼠标所在显示器重新平铺 | `⌥⌘2` |
| 手动尝试发送一次“继续” | `⌥⌘3` |
| 全局呼出并重新平铺 | 默认 `⌘O`，可修改 |

切换到其他应用时会隐藏画布；隐藏窗口不会停止窗口内的进程。TermYes **只管理 Apple 系统 Terminal.app**，不管理 iTerm2 或其他终端模拟器。

自动“继续”默认开启，间隔 30 分钟。**自动“继续”**子菜单可设置 5–120 分钟的间隔、会话范围，以及从指定时间开始的五小时周期。默认通过窗口标题或进程列表中的 `Codex` / `Claude` 匹配会话。

尾屏文字识别是启发式，不是可靠的会话状态接口，可能漏判或保守暂停，也不能保证恢复进程崩溃。尤其谨慎使用“所有 Terminal 窗口”的手动发送：普通 Shell 可能把“继续”当成命令执行。

## Agent 命令守卫

菜单栏 → **Agent 命令守卫 → 检测守卫配置** → 选择客户端。**安装、更新或恢复前，请退出对应客户端**，完成后重新启动；Codex 还需要在 `/hooks` 中检查并信任新 Hook。

内置适配器覆盖 Claude Code、Codex、CodeBuddy、zcode、pi、Qoder、Gemini CLI、Cursor、agy、OpenCode、Factory droid、Crush 和 GitHub Copilot CLI。

### 策略与当前状态

| 情况 | TermYes 的处理 |
| --- | --- |
| 命中危险或警告规则 | 直接拒绝，不弹确认 |
| 输入无效，或捕获到守卫/桥接错误 | 返回拒绝，不静默放行 |
| 未命中危险规则 | 交回客户端原有权限流程 |
| 尚未通过真实客户端验证 | 不启用自动批准 |
| 安装后文件被外部修改 | 拒绝自动覆盖或恢复 |

**“已安装”不等于“正在受保护”。** 所有适配器目前均处于真实客户端待验证状态；Copilot 的宿主超时处理与 agy 的 turbo 模式存在已知或尚未解决的兼容性问题。Hook 未加载、未信任、被禁用或宿主超时，都可能使守卫失效。

这是 **Shell 命令文本的事故防护层，不是沙箱**。它无法完整理解任意 Python、SQL、远程程序、别名或脚本的实际行为，也不拦截独立的文件编辑或 MCP 工具。`safe` 只表示“未命中规则”，不是“已经证明安全”。

安装器合并默认用户级配置、保留其他 Hook，并保存私有恢复记录；启动协调会开启受支持的 YOLO/等效权限模式，只能通过启动参数控制的客户端使用受管 wrapper。不管理自定义配置根目录或项目级配置。路径、错误边界和命令行用法见[守卫文档](AgentGuard/README.md)。

## 源码构建与测试

构建需要 Xcode Command Line Tools。守卫测试使用 Python；插件测试需要已安装、支持 `node:module.stripTypeScriptTypes` 的 Node.js，CI 使用 Node.js 24。

```sh
# 只构建，不替换已安装应用。
SKIP_INSTALL=1 ./build.sh

# 生成主安装包、旧版兼容包及可移植的 SHA-256 校验文件。
./create-dmg.sh
/usr/bin/python3 -B Tests/test_release.py
```

应用位于 `build/TermYes.app`；安装包和校验文件位于 `dist/`。直接运行 `./build.sh`、**不设置** `SKIP_INSTALL=1` 时，会安装到 `/Applications/TermYes.app`。

```sh
PYTHONDONTWRITEBYTECODE=1 /usr/bin/python3 -B Tests/test_agent_guard.py
PYTHONDONTWRITEBYTECODE=1 /usr/bin/python3 -B Tests/test_ai_review.py
PYTHONDONTWRITEBYTECODE=1 /usr/bin/python3 -B Tests/test_quiet_hours.py
bash AgentGuard/test.sh
PYTHONDONTWRITEBYTECODE=1 bash AgentGuard/test-codex.sh
node Tests/test_guard_plugins.mjs
swiftc Sources/TerminalResumePolicy.swift Tests/TerminalResumeTests.swift -o /tmp/termyes-resume-tests
/tmp/termyes-resume-tests
swiftc Sources/GridLayout.swift Tests/main.swift -o /tmp/termyes-grid-tests
/tmp/termyes-grid-tests
swiftc Sources/AIReviewSettings.swift Tests/AIReviewSettingsTests.swift -o /tmp/termyes-ai-settings-tests
/tmp/termyes-ai-settings-tests
swiftc Sources/SemanticVersion.swift Tests/VersionTests.swift -o /tmp/termyes-version-tests
/tmp/termyes-version-tests
bash Tests/test_update_installer.sh
```

守卫测试只分类命令字符串，不执行危险指令。插件测试模拟宿主 API，不代表真实客户端 YOLO 模式已通过验证。发布测试只读挂载安装包，并在临时副本上测试更新器，不启动应用。

## 更新、隐私与许可

TermYes 在启动后及之后每六小时检查公开 GitHub Release。自动替换要求应用位于 `/Applications` 下，且当前用户有写入权限。校验和及递归严格 `codesign` 验证用于检测包损坏或不一致；ad-hoc 签名不等于 Apple 开发者身份认证。

没有分析统计、账户体系、广告或遥测。应用联网仅用于公开版本检查与下载；守卫安装和 Terminal 自动化都在本地进行。恢复记录可能含已有客户端配置中的敏感值，请勿分享。

采用 [MIT 许可](LICENSE)，迁入的守卫模块保留其[原始 MIT 许可](AgentGuard/LICENSE)。
