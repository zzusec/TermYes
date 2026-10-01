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
        WindowApprovalController.shared.start()
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
        alert.informativeText = detail
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

    private func isAgentReady(_ client: AgentGuardClient) -> Bool {
        client.permissionReady && client.guardReady && client.serviceError == nil
    }

    private var readyAgentCount: Int {
        detectedAgents.filter(isAgentReady).count
    }

    private var orderedDetectedAgents: [AgentGuardClient] {
        detectedAgents.filter { !isAgentReady($0) } + detectedAgents.filter(isAgentReady)
    }

    private var agentSafetyText: String {
        guard !detectedAgents.isEmpty else { return "检测中…" }
        return "已就绪 \(readyAgentCount)/\(detectedAgents.count)"
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
            Menu("自动审批") {
                Text(agentSafetyText)
                if readyAgentCount < detectedAgents.count {
                    Button(agentGuard.isWorking ? "正在修复…" : "修复未就绪（\(detectedAgents.count - readyAgentCount)）") {
                        agentGuard.repairUnready()
                    }
                    .disabled(agentGuard.isWorking)
                }
                Button("刷新状态") { agentGuard.refresh() }
                    .disabled(agentGuard.isWorking)
                Divider()
                ForEach(orderedDetectedAgents) { client in
                    if isAgentReady(client) {
                        Label(client.name, systemImage: "checkmark.square.fill")
                    } else {
                        Button {
                            agentGuard.repair(client)
                        } label: {
                            Label("\(client.name)\(client.permissionReady ? " · 待修复" : "")",
                                  systemImage: client.permissionReady ? "checkmark.square.fill" : "xmark.square")
                        }
                        .disabled(agentGuard.isWorking)
                    }
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
                if agentGuard.lastCheckFailed {
                    Divider()
                    Text(agentMenuStatus)
                    Button("查看 Agent 状态…") {
                        showIssue("Agent 检查结果", detail: agentGuard.diagnosticDetails)
                    }
                }
            }
            Menu("定时激活5h窗口") {
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
