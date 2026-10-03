import SwiftUI
import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(workspaceDidActivateApplication(_:)),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )
        GlobalHotKeyController.shared.activateSavedShortcut()
        TerminalManager.shared.start()
        ScheduledActivationController.shared.start()
        AgentGuardController.shared.start()
        UpdateController.shared.start()
    }

    @objc private func workspaceDidActivateApplication(_ notification: Notification) {
        guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              application.bundleIdentifier != "com.apple.Terminal",
              application.bundleIdentifier != "io.github.zzusec.termosaic" else { return }
        TerminalManager.shared.hideDashboardIfVisible()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        TerminalManager.shared.showDashboard()
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        AgentGuardController.shared.stop()
        if !UpdateController.shared.isInstallingUpdate {
            TerminalManager.shared.prepareForTermination()
        }
    }
}

@main
struct TermYesApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var manager = TerminalManager.shared
    @StateObject private var hotKeys = GlobalHotKeyController.shared
    @StateObject private var scheduledActivation = ScheduledActivationController.shared
    @StateObject private var updater = UpdateController.shared
    @StateObject private var agentGuard = AgentGuardController.shared

    private var updateVersionText: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "未知"
        if updater.isUpToDate {
            return "版本 v\(version)（已是最新）"
        }
        return "版本 v\(version)"
    }

    private func showIssue(_ title: String, detail: String) {
        let alert = NSAlert()
        alert.messageText = title
        if detail.count > 1200 {
            alert.informativeText = "完整详情如下，可选择文本或复制。"
            let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 500, height: 280))
            scroll.hasVerticalScroller = true
            scroll.borderType = .bezelBorder
            let text = NSTextView(frame: scroll.contentView.bounds)
            text.string = detail
            text.isEditable = false
            text.isSelectable = true
            text.font = .systemFont(ofSize: 12)
            text.textContainerInset = NSSize(width: 8, height: 8)
            text.autoresizingMask = [.width]
            text.textContainer?.widthTracksTextView = true
            scroll.documentView = text
            alert.accessoryView = scroll
        } else {
            alert.informativeText = detail
        }
        alert.alertStyle = .warning
        alert.addButton(withTitle: "关闭")
        alert.addButton(withTitle: "复制详情")
        NSApplication.shared.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertSecondButtonReturn {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(detail, forType: .string)
        }
    }

    private var detectedAgents: [AgentGuardClient] {
        agentGuard.clients.filter(\.detected)
    }

    private func isAgentConfigured(_ client: AgentGuardClient) -> Bool {
        client.configurationReady
    }

    private var configuredAgentCount: Int {
        detectedAgents.filter(isAgentConfigured).count
    }

    private var verifiedAgentCount: Int {
        detectedAgents.filter { $0.requestStatus == "passed" }.count
    }

    private var loadedGuardCount: Int {
        detectedAgents.filter { $0.guardLiveStatus == "passed" }.count
    }

    private var orderedDetectedAgents: [AgentGuardClient] {
        detectedAgents.sorted { left, right in
            func rank(_ client: AgentGuardClient) -> Int {
                if !isAgentConfigured(client) { return 0 }
                if client.liveStatus == "failed" { return 1 }
                if client.liveStatus != "passed" { return 2 }
                return 3
            }
            let leftRank = rank(left)
            let rightRank = rank(right)
            return leftRank == rightRank ? left.name < right.name : leftRank < rightRank
        }
    }

    private var agentSafetyText: String {
        guard !detectedAgents.isEmpty else { return "检测中…" }
        return "配置 \(configuredAgentCount)/\(detectedAgents.count) · 请求 \(verifiedAgentCount)/\(detectedAgents.count) · 守卫 \(loadedGuardCount)/\(detectedAgents.count)"
    }

    private func agentStatusText(_ client: AgentGuardClient) -> String {
        if !isAgentConfigured(client) { return "配置待修复" }
        if client.isVerified { return "实测通过" }
        if client.requestStatus == "failed" { return "请求/免确认失败" }
        if client.guardLiveStatus == "failed" { return "守卫未加载" }
        if client.liveStatus == "stale" { return "配置已变化，待重测" }
        if client.liveStatus == "unsupported" { return "暂不支持实测" }
        return "待实测"
    }

    private func agentStatusIcon(_ client: AgentGuardClient) -> String {
        if !isAgentConfigured(client) { return "xmark.square" }
        if client.isVerified { return "checkmark.square.fill" }
        if client.liveStatus == "failed" { return "exclamationmark.triangle.fill" }
        return "questionmark.square"
    }

    private var agentMenuStatus: String {
        if agentGuard.isWorking { return "正在检查…" }
        let message = agentGuard.message
        return message.count > 24 ? String(message.prefix(24)) + "…" : message
    }

    @ViewBuilder
    private var shortcutMenuContent: some View {
        Text("显示并排列快捷键")
        ForEach(GlobalShortcut.allCases) { shortcut in
            Toggle(
                shortcut.menuTitle,
                isOn: Binding(
                    get: { hotKeys.selectedShortcut == shortcut },
                    set: { selected in
                        if selected { hotKeys.setShortcut(shortcut) }
                    }
                )
            )
        }

        if hotKeys.selectedShortcut == .commandP {
            Text("⌘P 占用“打印”快捷键")
        } else if hotKeys.selectedShortcut == .commandO {
            Text("⌘O 占用“打开”快捷键")
        }
        if let error = hotKeys.registrationError {
            Button("快捷键未启用 · 查看原因…") {
                showIssue("快捷键未启用", detail: error)
            }
        }
    }

    var body: some Scene {
        MenuBarExtra {
            if case .error(let error) = manager.phase {
                Button("终端连接异常 · 查看原因…") {
                    showIssue("终端连接异常", detail: error)
                }
            }
            Menu("自动排列") {
                Toggle(
                    "显示终端",
                    isOn: Binding(
                        get: { manager.phase == .visible },
                        set: { $0 ? manager.showDashboard() : manager.hideDashboard() }
                    )
                )
                if !manager.automationAuthorized {
                    Divider()
                    Button("打开自动化设置…") {
                        manager.openAutomationSettings()
                    }
                }
                Divider()
                shortcutMenuContent
            }
            Menu("命令守卫") {
                Text(agentSafetyText)
                Button(agentGuard.isWorking ? "正在全面实测…" : "全面实测（会产生模型请求）") {
                    agentGuard.verifyAll()
                }
                .disabled(agentGuard.isWorking || detectedAgents.isEmpty)
                if configuredAgentCount < detectedAgents.count {
                    Button(agentGuard.isWorking ? "正在修复…" : "修复配置未就绪（\(detectedAgents.count - configuredAgentCount)）") {
                        agentGuard.repairUnready()
                    }
                    .disabled(agentGuard.isWorking)
                }
                Button("刷新配置与实测记录") { agentGuard.refresh() }
                    .disabled(agentGuard.isWorking)
                Divider()
                ForEach(orderedDetectedAgents) { client in
                    Button {
                        if client.liveStatus == "unsupported" {
                            showIssue("\(client.name) 尚未实测", detail: client.liveReason ?? "该客户端暂不支持端到端验证，不能标为就绪。")
                        } else if isAgentConfigured(client) {
                            agentGuard.verify(client)
                        } else {
                            agentGuard.repair(client)
                        }
                    } label: {
                        Label("\(client.name) · \(agentStatusText(client))", systemImage: agentStatusIcon(client))
                    }
                    .disabled(agentGuard.isWorking)
                }
                Divider()
                Text("危险命令清单 v\(agentGuard.clients.first?.policyVersion ?? 0)\(agentGuard.clients.first?.policyError == true ? " · 异常" : "")")
                Button("更新危险命令清单") { agentGuard.checkPolicy() }
                    .disabled(agentGuard.isWorking)
                if agentGuard.clients.first?.policyError == true {
                    Button("查看清单问题…") {
                        showIssue("危险命令清单异常", detail: agentGuard.policyDetails)
                    }
                }
                Divider()
                Text(agentMenuStatus)
                Button("查看 Agent 状态与实测详情…") {
                    showIssue("Agent 检查结果", detail: agentGuard.diagnosticDetails)
                }
            }
            Menu("定时激活5h窗口") {
                Button(scheduledActivation.activating ? "正在激活…" : "立即激活一次（发送 hi）") {
                    scheduledActivation.activateNow()
                }
                .disabled(scheduledActivation.activating || scheduledActivation.windowAgents.isEmpty)
                Button("设置时间：\(scheduledActivation.windowScheduleDescription)") {
                    WindowSchedulePicker.shared.show()
                }
                if let status = scheduledActivation.lastActivationStatus {
                    Text(status)
                }
                if let detail = scheduledActivation.lastActivationDetail {
                    Button("查看激活问题…") {
                        showIssue("定时激活异常", detail: detail)
                    }
                }
            }
            Divider()
            Text(updateVersionText)
            Button(updater.isChecking ? "正在检查更新…" : updater.isDownloading || updater.isInstallingUpdate ? "正在更新…" : "检查更新") {
                updater.checkForUpdates()
            }
            .disabled(updater.isChecking || updater.isDownloading || updater.isInstallingUpdate)
            if let issue = updater.updateIssue {
                Button("更新失败 · 查看原因…") {
                    showIssue("更新失败", detail: issue)
                }
            }
            Divider()
            Button("退出 TermYes") {
                NSApplication.shared.terminate(nil)
            }
        } label: {
            Image(systemName: "rectangle.grid.2x2")
        }
        .menuBarExtraStyle(.menu)
    }
}
