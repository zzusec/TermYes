import AppKit
import ApplicationServices
import Combine
import Foundation

@MainActor
final class WindowApprovalController: ObservableObject {
    static let shared = WindowApprovalController()

    @Published private(set) var isEnabled: Bool
    @Published private(set) var isAccessibilityTrusted = false
    @Published private(set) var statusMessage = "窗口级 Ctrl-C 审批未启用"

    private var timer: Timer?
    private var processing = false
    private var approvalGeneration: UInt64 = 0
    private var resultMessage: String?
    private var handled: [Int: (fingerprint: Int, date: Date)] = [:]
    private var menuTrackingObservers: [NSObjectProtocol] = []
    private var menuTracking = false
    private var pendingStatusMessage: String?
    private var pendingAccessibilityTrust: Bool?
    private var lastFullScan = Date.distantPast
    private let defaultsKey = "windowApprovalEnabled"

    private init() {
        isEnabled = UserDefaults.standard.bool(forKey: defaultsKey)
        refreshAccessibilityStatus()
    }

    func start() {
        timer?.invalidate()
        let timer = Timer(timeInterval: 0.25, target: self, selector: #selector(tick), userInfo: nil, repeats: true)
        RunLoop.main.add(timer, forMode: .default)
        self.timer = timer
        observeMenuTracking()
        updateStatus()
    }

    func setEnabled(_ enabled: Bool) {
        approvalGeneration &+= 1
        resultMessage = nil
        isEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: defaultsKey)
        if enabled && !isAccessibilityTrusted {
            requestAccessibility()
        }
        updateStatus()
    }

    func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        refreshAccessibilityStatus()
        updateStatus()
    }

    func openAccessibilitySettings() {
        let values = [
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility",
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility",
        ]
        for value in values {
            if let url = URL(string: value), NSWorkspace.shared.open(url) {
                return
            }
        }
        setResultMessage("无法打开辅助功能设置，请在系统设置中打开隐私与安全性 → 辅助功能")
    }

    @objc private func tick() {
        refreshAccessibilityStatus()
        updateStatus()
        guard isEnabled, isAccessibilityTrusted, AIReviewController.shared.isEnabled,
              AIReviewController.shared.selectedModel != nil, !processing else { return }
        guard TerminalManager.shared.terminalWindowNeedsAttention() else { return }
        let now = Date()
        guard now.timeIntervalSince(lastFullScan) >= 0.5 else { return }
        lastFullScan = now
        scan()
    }

    private func scan() {
        guard let snapshots = TerminalManager.shared.terminalWindowSnapshots() else {
            setResultMessage("无法读取 Terminal 窗口")
            return
        }
        let candidates = snapshots.compactMap { snapshot -> (TerminalWindowSnapshot, Int)? in
            guard Self.isCtrlCPrompt(snapshot.contents) else { return nil }
            return (snapshot, Self.fingerprint(snapshot.contents))
        }
        guard candidates.count == 1, let candidate = candidates.first else {
            if candidates.count > 1 {
                setResultMessage("检测到多个待确认窗口，未自动处理")
            }
            return
        }
        if let previous = handled[candidate.0.id],
           previous.fingerprint == candidate.1,
           Date().timeIntervalSince(previous.date) < 10 {
            return
        }
        guard let script = Bundle.main.url(
            forResource: "ai_review",
            withExtension: "py",
            subdirectory: "AgentGuard"
        ) else {
            setResultMessage("窗口 reviewer 资源缺失")
            return
        }

        let generation = approvalGeneration
        let reviewModel = AIReviewController.shared.selectedModel
        resultMessage = nil
        processing = true
        setResultMessage("正在审查 Ctrl-C 窗口输入…")
        let snapshot = candidate.0
        let fingerprint = candidate.1
        Task {
            let decision = await Task.detached(priority: .userInitiated) {
                Self.review(prompt: snapshot.contents, script: script)
            }.value
            defer { processing = false }
            markHandled(windowID: snapshot.id, fingerprint: fingerprint)
            guard decision.allowed else {
                setResultMessage("未自动确认：\(decision.reason)")
                appendHistory(snapshot: snapshot, allowed: false, reason: decision.reason)
                return
            }
            guard isEnabled, AXIsProcessTrusted(), generation == approvalGeneration,
                  AIReviewController.shared.isEnabled,
                  AIReviewController.shared.selectedModel == reviewModel else {
                setResultMessage("审批设置已变化，取消自动确认")
                return
            }
            guard let fresh = TerminalManager.shared.terminalWindowSnapshots()?
                .first(where: { $0.id == snapshot.id }),
                Self.fingerprint(fresh.contents) == fingerprint,
                Self.isCtrlCPrompt(fresh.contents) else {
                setResultMessage("窗口内容已变化，取消自动确认")
                appendHistory(snapshot: snapshot, allowed: false, reason: "window changed")
                return
            }
            guard TerminalManager.shared.activateTerminalWindow(id: snapshot.id) else {
                setResultMessage("无法激活目标 Terminal 窗口")
                appendHistory(snapshot: snapshot, allowed: false, reason: "activation failed")
                return
            }
            try? await Task.sleep(for: .milliseconds(150))
            guard isEnabled, AXIsProcessTrusted(), generation == approvalGeneration,
                  AIReviewController.shared.isEnabled,
                  AIReviewController.shared.selectedModel == reviewModel,
                  let fresh = TerminalManager.shared.terminalWindowSnapshots()?.first(where: { $0.id == snapshot.id }),
                  Self.fingerprint(fresh.contents) == fingerprint,
                  Self.isCtrlCPrompt(fresh.contents),
                  Self.isFrontTerminalWindow(snapshot.id) else {
                setResultMessage("窗口或审批设置已变化，取消自动确认")
                return
            }
            guard Self.postReturnKey() else {
                setResultMessage("无法发送确认键，请检查辅助功能权限")
                appendHistory(snapshot: snapshot, allowed: false, reason: "key post failed")
                return
            }
            setResultMessage("已自动确认 Ctrl-C")
            appendHistory(snapshot: snapshot, allowed: true, reason: decision.reason)
        }
    }

    private func markHandled(windowID: Int, fingerprint: Int) {
        handled[windowID] = (fingerprint, Date())
    }

    private func refreshAccessibilityStatus() {
        setAccessibilityTrusted(AXIsProcessTrusted())
    }

    private func updateStatus() {
        if !isEnabled {
            setStatusMessage("窗口级 Ctrl-C 审批未启用")
        } else if !isAccessibilityTrusted {
            setStatusMessage("需要辅助功能权限")
        } else if AIReviewController.shared.selectedModel == nil {
            setStatusMessage("请先配置 AI reviewer 模型")
        } else if !AIReviewController.shared.isEnabled {
            setStatusMessage("请先启用 AI reviewer")
        } else if processing {
            return
        } else {
            setStatusMessage(resultMessage ?? "正在监听 Ctrl-C 确认窗口")
        }
    }

    private func setResultMessage(_ value: String) {
        resultMessage = value
        setStatusMessage(value)
    }

    private func setStatusMessage(_ value: String) {
        if menuTracking {
            pendingStatusMessage = value
            return
        }
        guard statusMessage != value else { return }
        statusMessage = value
    }

    private func setAccessibilityTrusted(_ value: Bool) {
        if menuTracking {
            pendingAccessibilityTrust = value
            return
        }
        guard isAccessibilityTrusted != value else { return }
        isAccessibilityTrusted = value
    }

    private func observeMenuTracking() {
        guard menuTrackingObservers.isEmpty else { return }
        let center = NotificationCenter.default
        menuTrackingObservers = [
            center.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.menuTracking = true }
            },
            center.addObserver(forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    self.menuTracking = false
                    if let pending = self.pendingAccessibilityTrust {
                        self.pendingAccessibilityTrust = nil
                        self.isAccessibilityTrusted = pending
                    }
                    if let pendingStatusMessage = self.pendingStatusMessage {
                        self.pendingStatusMessage = nil
                        if self.statusMessage != pendingStatusMessage {
                            self.statusMessage = pendingStatusMessage
                        }
                    }
                }
            }
        ]
    }

    nonisolated static func isCtrlCPrompt(_ text: String) -> Bool {
        guard let marker = text.range(of: "Would you like to send input to terminal", options: .backwards) else { return false }
        let prompt = String(text[marker.lowerBound...])
        let pattern = #"(?m)^\s*Input:\s*"\\u\{3\}"\s*$"#
        let inputPattern = #"(?m)^\s*Input:"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let inputRegex = try? NSRegularExpression(pattern: inputPattern) else { return false }
        let range = NSRange(prompt.startIndex..<prompt.endIndex, in: prompt)
        return prompt.contains("Yes, proceed") && prompt.contains("No")
            && regex.numberOfMatches(in: prompt, range: range) == 1
            && inputRegex.numberOfMatches(in: prompt, range: range) == 1
    }

    private static func isFrontTerminalWindow(_ id: Int) -> Bool {
        guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.Terminal",
              let script = NSAppleScript(source: "tell application id \"com.apple.Terminal\" to get id of front window") else { return false }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        return error == nil && result.int32Value == Int32(id)
    }

    nonisolated private static func fingerprint(_ text: String) -> Int {
        text.utf8.reduce(5381) { (($0 << 5) &+ $0) &+ Int($1) }
    }

    nonisolated private static func postReturnKey() -> Bool {
        guard AXIsProcessTrusted(),
              let terminal = NSWorkspace.shared.frontmostApplication,
              terminal.bundleIdentifier == "com.apple.Terminal",
              let source = CGEventSource(stateID: .hidSystemState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: 36, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 36, keyDown: false) else {
            return false
        }
        down.postToPid(terminal.processIdentifier)
        up.postToPid(terminal.processIdentifier)
        return true
    }

    nonisolated private static func review(prompt: String, script: URL) -> (allowed: Bool, reason: String) {
        let process = Process()
        let stdin = Pipe()
        let stdout = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-B", script.path]
        process.environment = ProcessInfo.processInfo.environment.merging([
            "PYTHONDONTWRITEBYTECODE": "1",
        ]) { _, new in new }
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let request = try JSONSerialization.data(withJSONObject: [
                "prompt": prompt,
                "input": "\\u{3}",
            ])
            stdin.fileHandleForWriting.write(request)
            try stdin.fileHandleForWriting.close()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                return (false, "窗口 reviewer 执行失败")
            }
            let data = stdout.fileHandleForReading.readDataToEndOfFile()
            guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let behavior = value["behavior"] as? String else {
                return (false, "窗口 reviewer 返回无效")
            }
            return (behavior == "allow", value["reason"] as? String ?? "")
        } catch {
            return (false, error.localizedDescription)
        }
    }

    private func appendHistory(snapshot: TerminalWindowSnapshot, allowed: Bool, reason: String) {
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Termosaic/AgentGuard", isDirectory: true)
        let log = root.appendingPathComponent("window-approval-history.jsonl")
        let record: [String: Any] = [
            "timestamp": ISO8601DateFormatter().string(from: Date()),
            "window_id": snapshot.id,
            "window_name": snapshot.name,
            "input": "\\u{3}",
            "allowed": allowed,
            "reason": reason,
        ]
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let data = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
            if !FileManager.default.fileExists(atPath: log.path) {
                FileManager.default.createFile(atPath: log.path, contents: nil)
            }
            let handle = try FileHandle(forWritingTo: log)
            try handle.seekToEnd()
            handle.write(data)
            handle.write(Data([0x0A]))
            try handle.close()
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: log.path
            )
        } catch {
            setResultMessage("窗口审批日志写入失败：\(error.localizedDescription)")
        }
    }
}
