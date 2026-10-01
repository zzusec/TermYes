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
        AutoContinueController.shared.start()
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
    @StateObject private var autoContinue = AutoContinueController.shared
    @StateObject private var updater = UpdateController.shared
    @StateObject private var agentGuard = AgentGuardController.shared
    @StateObject private var aiReview = AIReviewController.shared
    @StateObject private var windowApproval = WindowApprovalController.shared

    private var updateVersionText: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "未知"
        if updater.isDownloading || updater.isInstallingUpdate {
            return "版本 v\(version)（正在更新…）"
        }
        if updater.isChecking {
            return "版本 v\(version)（正在检查…）"
        }
        if updater.isUpToDate {
            return "版本 v\(version)（已是最新）"
        }
        return "版本 v\(version)"
    }

    private var updateDetailText: String? {
        guard !updater.isChecking,
              !updater.isDownloading,
              !updater.isInstallingUpdate,
              !updater.isUpToDate else { return nil }
        return updater.statusMessage
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
        return "已开启 \(detectedAgents.filter(\.permissionReady).count)/\(detectedAgents.count)"
    }

    private var agentMenuStatus: String {
        if agentGuard.isWorking { return "正在检查…" }
        let message = agentGuard.message
        return message.count > 24 ? String(message.prefix(24)) + "…" : message
    }

    @ViewBuilder
    private var aiApprovalMenuContent: some View {
        Toggle("启用 Ctrl-C 模型审核", isOn: Binding(
            get: { aiReview.isEnabled && aiReview.selectedModel != nil },
            set: { aiReview.setEnabled($0 && aiReview.selectedModel != nil) }
        ))
        .disabled(aiReview.models.isEmpty)

        Divider()
        Text("审核模型")
        ForEach(aiReview.models) { model in
            Toggle(
                model.name,
                isOn: Binding(
                    get: { aiReview.selectedModelID == model.id },
                    set: { selected in
                        if selected { aiReview.select(model.id) }
                    }
                )
            )
        }
        Button("添加或管理模型…") {
            AIReviewModelPicker.shared.show()
        }
        if aiReview.models.isEmpty {
            Text("窗口审核需配置模型")
        }
        Toggle(
            "自动确认 Ctrl-C 窗口输入",
            isOn: Binding(
                get: { windowApproval.isEnabled },
                set: { windowApproval.setEnabled($0) }
            )
        )
        if windowApproval.isEnabled && !windowApproval.isAccessibilityTrusted {
            Button("Ctrl-C 辅助功能权限…") {
                windowApproval.requestAccessibility()
                windowApproval.openAccessibilitySettings()
            }
        }
        Text(windowApproval.statusMessage)
        if let error = aiReview.errorMessage {
            Text("模型审核异常")
            Button("复制审核错误") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(error, forType: .string)
            }
        }
    }

    @ViewBuilder
    private var settingsMenuContent: some View {
        Text("快捷键")
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

        if hotKeys.selectedShortcut == .commandO {
            Text("⌘O 占用“打开”快捷键")
        }
        if let error = hotKeys.registrationError {
            Text("快捷键设置失败")
            Button("复制快捷键错误") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(error, forType: .string)
            }
        }

    }

    var body: some Scene {
        MenuBarExtra {
            if case .error(let error) = manager.phase {
                Text("终端连接异常")
                Button("复制终端错误") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(error, forType: .string)
                }
            }
            Menu("自动审批") {
                Text(agentSafetyText)
                Button(agentGuard.isWorking ? "正在修复…" : "修复未就绪（\(detectedAgents.count - readyAgentCount)）") {
                    agentGuard.repairUnready()
                }
                .disabled(agentGuard.isWorking || readyAgentCount == detectedAgents.count)
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
                Text("危险清单 v\(agentGuard.clients.first?.policyVersion ?? 0)\(agentGuard.clients.first?.policyError == true ? " · 检查失败" : "")")
                Button("检查危险清单") { agentGuard.checkPolicy() }
                    .disabled(agentGuard.isWorking)
                if agentGuard.clients.first?.policyError == true {
                    Button("复制清单错误") { agentGuard.copyPolicyStatus() }
                }
                Divider()
                Text(agentMenuStatus)
                Button("复制诊断详情") { agentGuard.copyDetails() }
            }
            Divider()

            Toggle(
                "显示终端",
                isOn: Binding(
                    get: { manager.phase == .visible },
                    set: { $0 ? manager.showDashboard() : manager.hideDashboard() }
                )
            )
            .keyboardShortcut("1", modifiers: [.command, .option])

            Button("在鼠标屏幕重排") {
                manager.useDisplayUnderPointerAndRetile()
            }
            .keyboardShortcut("2", modifiers: [.command, .option])
            .disabled(!manager.automationAuthorized)

            Button("发送“继续”") {
                autoContinue.sendNow()
            }
            .keyboardShortcut("3", modifiers: [.command, .option])
            .disabled(!manager.automationAuthorized)
            if let status = autoContinue.lastStatusMessage {
                Text(status)
            }

            if !manager.automationAuthorized {
                Button("打开自动化设置…") {
                    manager.openAutomationSettings()
                }
            }

            Divider()
            Menu("AI自动审核") {
                Text(aiReview.isEnabled ? "已开启" : "未开启")
                aiApprovalMenuContent
            }
            Menu("定时激活5h窗口") {
                Button("设置时间：\(autoContinue.windowScheduleDescription)") {
                    WindowSchedulePicker.shared.show()
                }
                if let status = autoContinue.lastActivationStatus {
                    Text(status)
                }
                if let detail = autoContinue.lastActivationDetail {
                    Button("复制请求错误") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(detail, forType: .string)
                    }
                }
            }
            Menu("设置") {
                settingsMenuContent
            }

            Divider()
            Text(updateVersionText)
            Button(updater.isChecking ? "正在检查…" : "检查更新") {
                updater.checkForUpdates()
            }
            .disabled(updater.isChecking || updater.isDownloading || updater.isInstallingUpdate)
            if let detail = updateDetailText {
                Text(detail.contains("失败") || detail.contains("无法") ? "更新检查异常" : detail)
                if detail.contains("失败") || detail.contains("无法") {
                    Button("复制更新错误") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(detail, forType: .string)
                    }
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
