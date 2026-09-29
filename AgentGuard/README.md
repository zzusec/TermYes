# TermYes Agent 命令守卫

从 `bypass-yes` 合入，保留原项目 MIT 许可证。规则和适配器的开发源码在本目录；运行时由 TermYes 安装独立副本，不依赖原仓库或应用进程存活。

## 已实现的边界

- 十三类客户端适配器：Claude Code、Codex、CodeBuddy、zcode、pi、Qoder、Gemini CLI、Cursor、agy、OpenCode、Factory droid、Crush、GitHub Copilot。
- 原 `warn` 与 `block` 均硬拒绝，不弹确认、不返回 ask/force_ask。无效 Hook 输入、导入失败、桥接异常不再作为允许结果。
- 旧正则白名单不能覆盖危险规则；不迁移可能放行危险命令的白名单。
- **只检查 Shell 工具，不是沙箱。** 不能完整理解 Python/SQL/远程程序、别名或任意脚本的实际行为，也不覆盖独立文件写入、MCP 等工具。`safe` 仅表示未命中规则，不是安全证明。
- Hook 未加载、未信任、被禁用或宿主超时策略仍可能使守卫失效。协议自测通过不证明真实客户端已经受保护。

## 可选 AI 审批

Codex 可选用独立 AI reviewer 处理需要越界审批的 Bash 命令。它默认关闭；启用后先经过确定性危险规则，再只接受模型返回的高置信度 `allow`。超时、接口错误、无效 JSON、中低置信度及无法解析的命令均为拒绝。该 reviewer 不处理 Computer Use、MCP 或“向已有终端发送输入”等应用级弹窗。

TermYes 菜单栏的 **Agent 命令守卫 → AI 审批模型** 可直接新增、选择和删除模型。普通构建、测试、本地脚本、Git 操作、软件包安装及 `/tmp`、`/private/tmp` 内的临时写入默认放行；系统级破坏、凭据访问、提权、持久化和下载后直接执行等明确危险仍拒绝。

AI reviewer 默认启用安全学习。模型高置信度放行某条命令后，TermYes 只记录“完整命令 + 当前目录”的哈希；再次遇到完全相同的上下文时可跳过模型调用直接放行。明文命令不写入学习文件，模型拒绝、超时、无效响应和确定性危险规则命中都不会被学习。记忆最多保留 500 条，危险规则始终先于学习结果执行。

配置示例见 `ai-review.example.json`，默认读取：

```text
~/Library/Application Support/Termosaic/AgentGuard/ai-review.json
```

日志只记录命令哈希和决策，不记录原始命令；模型请求本身会发送完整命令和当前目录到配置的端点。不要使用不受信任的远程模型端点。

## 夜间静音

`quiet-hours.json` 可配置本地时间静音时段，默认示例为 22:00 到次日 08:00。静音只跳过提示音，不影响确定性拦截、AI reviewer 或日志。配置无效或关闭时不会静默。

```json
{
  "enabled": true,
  "start": "22:00",
  "end": "08:00"
}
```

## 首版能力门槛

**当前没有客户端被标为已完成真实客户端端到端验证，所以 TermYes 不会为任何客户端开启 YOLO，也不会通过 Hook 自动批准普通权限请求。** 可以安装加固后的守卫，正常操作继续由客户端原有权限流程决定。

这不会关闭用户已有的免确认配置。若客户端原来已处于 YOLO，安装/恢复守卫不改变它，也不代表 TermYes 已验证或认可该状态。

- Copilot：已知宿主 Hook 超时会回到正常权限流程，保留已知缺口状态。
- agy：原项目对 turbo 行为记录存在冲突，禁用原生 turbo 启用入口；等效免确认模式亦待真实客户端验证。
- 其余客户端：待验证，不能仅靠脚本单测或已安装可执行文件放行能力门槛。

以后开放某个版本的免确认入口，至少需要真实客户端的 Hook 加载/信任、安全调用、危险调用、错误/超时、免确认模式下拒绝效果及版本记录。本次没有发起需要账号或付费请求的 Agent 测试。

## 使用

菜单栏 → **Agent 命令守卫** → **检测守卫配置** → 对应客户端 → **安装 / 更新守卫（不改权限）**。

安装与恢复前请退出对应客户端。安装后重新打开，Codex 还需在 `/hooks` 中检查和信任新 Hook。菜单显示安装记录，不是进程实时受保护的证明。

模块需要可用的 `/usr/bin/python3`（本机由 Xcode Command Line Tools 提供）；窗口管理本身没有新增运行依赖。不自动下载或安装 Python。

也可以在源码目录运行：

```sh
/usr/bin/python3 -B AgentGuard/manage.py status
/usr/bin/python3 -B AgentGuard/manage.py install claude
/usr/bin/python3 -B AgentGuard/manage.py uninstall claude
```

- 管理默认用户级配置目录；不接管自定义 `CODEX_HOME`、`XDG_CONFIG_HOME` 等配置根或项目级配置，不改 Shell alias/PATH。
- 不改变权限模式、沙箱、模型、自动压缩配置，也不增加全局 allow 规则。旧 `install-all.sh` 等自动开启 bypass 的安装器未迁入。
- CLI 安装/恢复使用本地互斥锁，防止两个 TermYes 操作同时改写配置。
- 配置合并保留其他 Hook，混合组也仅替换旧守卫；重复安装保持内容不变。配置结构无效或路径为符号链接则拒绝写入。
- `~/Library/Application Support/Termosaic/AgentGuard/` 保存权限为 0600 的安装记录及原文件内容。备份可能包含原配置中的敏感信息，不要分享。
- 恢复只处理本客户端记录；如果文件被外部修改，拒绝覆盖。不会整目录删除其他 Hook，也不会删除用户原有 bypass-yes 文件。
- Hook 路径迁到各客户端独立的 `hooks/termosaic/<client>/`（pi 为 `guard/termosaic/pi/`）；插件入口保留旧文件名避免重复加载。
- 不承诺进程被强杀或断电时跨多个文件的事务原子性；正常写入错误会回滚已写文件。安装后先验证客户端，切勿仅凭安装成功启用 YOLO。

## 本地测试

测试使用临时目录，危险命令文本仅交给分类器，不执行实际操作。插件自检使用已有 Node.js 22.13+，不下载依赖。

```sh
PYTHONDONTWRITEBYTECODE=1 /usr/bin/python3 -B Tests/test_agent_guard.py
bash AgentGuard/test.sh
PYTHONDONTWRITEBYTECODE=1 bash AgentGuard/test-codex.sh
node Tests/test_guard_plugins.mjs
```

两个 Shell 回归测试沿用原项目命令并更新硬拒绝期望。旧自动压缩功能、自动开启 YOLO 的安装器及其安装行为测试未迁入；新安装器有十三客户端合并/恢复/错误测试。

兼容性说明：应用名称从 Termosaic 改为 TermYes，但既有守卫运行路径、安装记录目录及 Bundle ID 保持不变，避免重复安装或丢失恢复记录。
