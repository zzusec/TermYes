# TermYes Agent 命令守卫

从 `bypass-yes` 合入，保留原项目 MIT 许可证。规则和适配器的开发源码在本目录；运行时由 TermYes 安装独立副本，不依赖原仓库或应用进程存活。

## 已实现的边界

- 十三类客户端适配器：Claude Code、Codex、CodeBuddy、zcode、pi、Qoder、Gemini CLI、Cursor、agy、OpenCode、Factory droid、Crush、GitHub Copilot。
- 原 `warn` 与 `block` 均硬拒绝，不弹确认、不返回 ask/force_ask。无效 Hook 输入、导入失败、桥接异常不再作为允许结果。
- 旧正则白名单不能覆盖危险规则；不迁移可能放行危险命令的白名单。
- **只检查 Shell 工具，不是沙箱。** 不能完整理解 Python/SQL/远程程序、别名或任意脚本的实际行为，也不覆盖独立文件写入、MCP 等工具。`safe` 仅表示未命中规则，不是安全证明。
- Hook 未加载、未信任、被禁用或宿主超时策略仍可能使守卫失效。协议自测通过不证明真实客户端已经受保护。

菜单栏可展开查看已检测 Agent 的 YOLO/守卫状态，只修复未就绪项或选择单个修复。自动巡检仍不会覆盖已有独立命令；**仅显式点击修复**时，若本机 `~/.local/bin` 中的独立可执行文件挡住 YOLO wrapper，会将其原样保留在 `~/.local/share/Termosaic/vendor/bin/` 后安装受管 wrapper；安装失败会把原命令移回原位。同名备份或符号链接冲突不会自动覆盖，并在菜单中报告原因。

## 菜单状态与实际验收

安装记录或 YOLO 设置不是“正常运行”的证明。菜单仅在当前配置有效、真实模型请求成功、安全 Shell 命令无需人工确认执行，并且实际客户端调用了命令守卫后显示勾选。实测以 `/tmp` 中的随机标记为证据；守卫验证也只使用安全的 `printf`，不会执行破坏性命令。异常退出、超时、配置/CLI 变更及超过 24 小时的记录不能继续作为通过证据。

“修复配置”只修复配置与守卫文件，结果仍是“待实测”；“全面实测”与单个 Agent 实测会产生真实模型请求和相应费用。第三方追加的 CodeBuddy/Qoder Hook 会安全保留；已有 Hook 被改写或守卫脚本被外部修改仍会拒绝覆盖并显示原因。未验证或不支持验证的客户端不勾选，可从菜单查看详情。

自动回归可运行 `/usr/bin/python3 -B Tools/run-regression.py`；打包后增加 `--release` 验证更新安装器和两个兼容 DMG。自动测试不替代本机菜单操作、真实 Agent 请求与辅助功能按键投递验收。

## Shell 危险清单

Shell Hook 仅以 GitHub 仓库 `main` 分支的 `AgentGuard/danger-policy.json`（离线时使用已验证本地缓存或 `rules.py` 内置清单）和 `core.py` 中的 `rm -rf` 目标分级为拒绝依据；清单外的有效命令直接放行，不再让 AI 增加隐性拒绝规则。`PreToolUse` 与 `PermissionRequest` 均遵循这一判定。无效 Hook 输入、缺少工作目录、引号或命令替换表达式未闭合、运行时无法判定时仍拒绝；这类输入无法作为有效命令匹配清单。

维护者更新 `danger-policy.json` 的 `block`/`warn` 正则与原因时须递增整数 `version`。TermYes 启动与运行期间每两小时检查 GitHub，也可从菜单手动检查；只采纳校验通过的较高版本并原子写入 `~/Library/Application Support/Termosaic/AgentGuard/danger-policy.json`，Hook 下次运行即读取。网络故障、格式无效或回退版本不清空现有规则，错误在菜单显示。`rm -rf` 目标分级仍随应用版本发布；修改 JSON 不会改变此逻辑。已安装旧版应用不会自动获得独立清单更新能力。

清单包含磁盘格式化/抹盘、物理磁盘覆写、fork bomb、关机重启、递归修改系统目录权限、覆写 `/etc`、下载后直接交给 shell 执行、强制推送、`git reset --hard`、`git clean -f`、`npm publish`、删除定时任务、Docker 卷清理，以及针对根目录、家目录、整个项目等高影响目标的 `rm -rf`。具体正则与路径分级分别以 `rules.py`、`core.py` 为准。清单不能识别任意脚本的真实副作用，也不保护非 Shell 工具或 Hook 未加载时的命令。

旧版本在 `ai-review-history.jsonl` 中保存的模型判断只供人工排查，不再影响 Shell 放行；旧学习记忆不再参与 Shell 判定。窗口级 Ctrl-C 审核仍可选择独立模型。

## 窗口级 Ctrl-C 审批

菜单中的 **Ctrl-C 窗口审核** 可配置独立 AI 模型。**自动确认 Ctrl-C 窗口输入** 开启后，TermYes 会轮询 Terminal 窗口文本，只在完整匹配以下条件时自动选择确认：

- 窗口正在询问是否向现有终端发送输入
- 同时存在明确的 Yes/No 选项
- 发送内容严格为 `\u{3}`（Ctrl-C）
- 独立 reviewer 再次确认允许，且发送前窗口内容没有变化

回车、普通文本、未知控制序列、密码、权限和无法完整读取的弹窗不会自动处理。该功能需要辅助功能权限，并会把每次窗口审批写入本机 `window-approval-history.jsonl`。

配置示例见 `ai-review.example.json`，默认读取：

```text
~/Library/Application Support/Termosaic/AgentGuard/ai-review.json
```

窗口 AI 审核会将对应窗口的提示文本发送到配置的模型端点；Shell 命令不会因为窗口审核而发送给模型。不要使用不受信任的远程模型端点。

## 夜间静音

`quiet-hours.json` 可配置本地时间静音时段，默认示例为 22:00 到次日 08:00。静音只跳过提示音，不影响危险清单拦截。配置无效或关闭时不会静默。

```json
{
  "enabled": true,
  "start": "22:00",
  "end": "08:00"
}
```

## 自动检测与 YOLO 修复

TermYes 启动时和运行期间每 5 分钟检测已安装的 Agent，并在需要时修复权限模式、安装或更新守卫：

- Codex → `approval_policy=never`、`sandbox_mode=danger-full-access`
- Claude Code / CodeBuddy → `permissions.defaultMode=bypassPermissions`
- Qoder → `general.defaultPermissionMode=bypass_permissions`
- zcode → `permission.mode=yolo`
- pi → 本身不进行命令审批
- Gemini / Cursor / agy / OpenCode / droid / Crush / Copilot → `~/.local/bin` 下的受管启动 wrapper

自动修复是幂等的，只处理检测到的客户端；外部修改过的守卫文件不会被覆盖。wrapper 会强制附加对应免确认参数并设置 `DANGER_GUARD_BYPASS=1`，使没有确认框的客户端仍由守卫硬拒危险命令。菜单栏 **Agent 命令守卫 → 立即检查并修复 YOLO 与守卫** 可手动重跑。

新开的 zsh 终端会加载 `~/.local/bin/termyes-agent-yolo-shell`。每个已安装 Agent 在启动前都会先调用 `ensure <client>`：守卫文件及权限模式就绪才启动，否则拒绝启动。参数型客户端的受管 wrapper 同样检查。这样不需要为了加载 YOLO 重启客户端，但已运行的客户端不会因此自动加载 Hook。无论客户端是否自动批准命令，已正确加载的 TermYes `danger-guard` 都会在命令执行前硬拒绝命中的危险操作。

Hook 是否被真实客户端加载、信任和调用仍需逐客户端验证；脚本单测通过不等于客户端端到端已验证。Copilot 宿主超时、agy turbo 等兼容性边界仍需实际取证。

## 使用

菜单栏 → **Agent 命令守卫** → **立即检查并修复 YOLO 与守卫**，也可按客户端手动 **安装 / 更新守卫**。

首次安装、更新守卫后请重启对应客户端；Codex 还需在 `/hooks` 中检查和信任新 Hook。菜单分别显示权限就绪和守卫文件落地，不是进程实时受保护的证明。CLI 的 `uninstall` 只作人工恢复；只要 TermYes 仍在运行，下轮检查会再次安装。

模块需要可用的 `/usr/bin/python3`（本机由 Xcode Command Line Tools 提供）；窗口管理本身没有新增运行依赖。不自动下载或安装 Python。

也可以在源码目录运行：

```sh
/usr/bin/python3 -B AgentGuard/manage.py status
/usr/bin/python3 -B AgentGuard/manage.py monitor
/usr/bin/python3 -B AgentGuard/manage.py ensure agy
/usr/bin/python3 -B AgentGuard/manage.py reconcile
/usr/bin/python3 -B AgentGuard/manage.py install claude
/usr/bin/python3 -B AgentGuard/manage.py uninstall claude
```

- 管理默认用户级配置目录；不接管自定义 `CODEX_HOME`、`XDG_CONFIG_HOME` 等配置根或项目级配置。参数型客户端会写入受管 wrapper，并确保 `~/.local/bin` 位于路径前部。
- `reconcile` 会改变已检测客户端的权限模式或启动 wrapper；模型、自动压缩配置和全局 allow 规则保持不变。
- CLI 安装/恢复使用本地互斥锁，防止两个 TermYes 操作同时改写配置。
- 配置合并保留其他 Hook，混合组也仅替换旧守卫；重复安装保持内容不变。配置结构无效或路径为符号链接则拒绝写入。
- `~/Library/Application Support/Termosaic/AgentGuard/` 保存权限为 0600 的安装记录及原文件内容。备份可能包含原配置中的敏感信息，不要分享。
- 恢复只处理本客户端记录；如果文件被外部修改，拒绝覆盖。不会整目录删除其他 Hook，也不会删除用户原有 bypass-yes 文件。
- Hook 路径迁到各客户端独立的 `hooks/termosaic/<client>/`（pi 为 `guard/termosaic/pi/`）；插件入口保留旧文件名避免重复加载。
- 不承诺进程被强杀或断电时跨多个文件的事务原子性；正常写入错误会回滚已写文件。权限修复与守卫安装分离，安装后仍应先验证客户端。

## 本地测试

测试使用临时目录，危险命令文本仅交给分类器，不执行实际操作。插件自检使用已有 Node.js 22.13+，不下载依赖。

```sh
PYTHONDONTWRITEBYTECODE=1 /usr/bin/python3 -B Tests/test_agent_guard.py
bash AgentGuard/test.sh
PYTHONDONTWRITEBYTECODE=1 bash AgentGuard/test-codex.sh
node Tests/test_guard_plugins.mjs
```

两个 Shell 回归测试验证危险命令硬拒绝。新安装器有十三客户端的合并/恢复/错误测试，监控测试覆盖 YOLO 修复、守卫安装、外部修改拒绝覆盖与启动前失败关闭；真实客户端的 Hook 仍需另行验证。

兼容性说明：应用名称从 Termosaic 改为 TermYes，但既有守卫运行路径、安装记录目录及 Bundle ID 保持不变，避免重复安装或丢失恢复记录。

## Codex / Claude 五小时窗口激活

定时激活在专用 Terminal 窗口中发送 `hi`，并显示真实客户端的回复；不向用户正在工作的 Agent 窗口注入输入。每个选中的客户端每轮只发一次请求，后台只等待窗口进程的私有结果记录，不再额外发第二个模型请求。菜单中的“立即激活一次（发送 hi）”与真正的 Timer 触发共用这条执行路径，也可在定时停用时手动验收。

窗口中先检查 YOLO/守卫配置，失败、空回复或超时会显示原因；菜单只有取得有效退出状态与模型输出后才计为成功。结果目录为同用户 `0700`、记录为 `0600`，包括 macOS `/var/folders` 到 `/private/var/folders` 的系统路径别名；请求完成后清理。关闭激活窗口会取消该窗口的请求。
