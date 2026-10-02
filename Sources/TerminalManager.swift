@preconcurrency import AppKit
import Combine
import os

struct TerminalWindowSnapshot {
    let id: Int
    let name: String
    let contents: String
}

@MainActor
final class TerminalManager: NSObject, ObservableObject {
    static let shared = TerminalManager()

    enum Phase: Equatable {
        case starting
        case needsAutomationPermission
        case hidden
        case visible
        case terminalNotRunning
        case error(String)
    }

    @Published private(set) var phase: Phase = .starting
    @Published private(set) var terminalWindowCount = 0
    @Published private(set) var automationAuthorized = true

    private let terminalBundleIdentifier = "com.apple.Terminal"
    private let logger = Logger(subsystem: "io.github.zzusec.termosaic", category: "TerminalManager")
    private let pollInterval: TimeInterval = 0.2
    private var pollTimer: Timer?
    private var menuTrackingObservers: [NSObjectProtocol] = []
    private var lastTiledWindowIDs: [Int] = []
    private var lastWindowServerCandidateCount = -1
    private var pendingWindowIDPasses = 0
    private let pendingWindowIDPassLimit = 10
    private var orderedWindowIDs: [Int] = []
    private var targetScreen: NSScreen?
    private var started = false
    private var dashboardRequested = false

    private let scriptExecutor: ((String) -> (NSAppleEventDescriptor, NSDictionary?))?

    init(scriptExecutor: ((String) -> (NSAppleEventDescriptor, NSDictionary?))? = nil) {
        self.scriptExecutor = scriptExecutor
        super.init()
    }

    /// Publishing identical values would rebuild the menu on every poll tick, which closes it
    /// while the user is reading. State therefore only changes when it really changes.
    private func updatePhase(_ newPhase: Phase) {
        if phase != newPhase { phase = newPhase }
    }

    private func updateWindowCount(_ value: Int) {
        if terminalWindowCount != value { terminalWindowCount = value }
    }

    private func updateAutomationAuthorized(_ value: Bool) {
        if automationAuthorized != value { automationAuthorized = value }
    }

    func start() {
        guard !started else { return }
        started = true
        observeMenuTracking()
        startPolling()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
            self?.showDashboard()
        }
    }

    func openAutomationSettings() {
        let candidates = [
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation",
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Automation"
        ]
        for value in candidates {
            if let url = URL(string: value), NSWorkspace.shared.open(url) { return }
        }
        updatePhase(.error("无法打开自动化设置，请在系统设置中打开隐私与安全性 → 自动化"))
    }

    func showDashboard() {
        dashboardRequested = true
        lastWindowServerCandidateCount = -1
        pendingWindowIDPasses = 0
        targetScreen = screenUnderPointer() ?? NSScreen.main

        if let terminal = terminalApplication() {
            guard terminal.unhide(), terminal.activate(options: [.activateAllWindows]) else {
                updatePhase(.error("无法显示或激活 Terminal"))
                return
            }
            updatePhase(.visible)
            scheduleTilePasses()
        } else {
            launchTerminal()
        }
    }

    func hideDashboardIfVisible() {
        guard dashboardRequested, terminalApplication()?.isHidden == false else { return }
        hideDashboard(activateManager: false)
    }

    func hideDashboard(activateManager: Bool = true) {
        dashboardRequested = false
        if let terminal = terminalApplication(), !terminal.hide() {
            updatePhase(.error("无法隐藏 Terminal"))
            return
        }

        updatePhase(terminalApplication() == nil ? .terminalNotRunning : .hidden)

        if activateManager {
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    func toggleDashboard() {
        if dashboardRequested, terminalApplication()?.isHidden == false {
            hideDashboard()
        } else {
            showDashboard()
        }
    }

    func openAgentActivationWindows(_ agents: [ScheduledAgent], scriptPath: String, resultDirectory: String) -> [String] {
        agents.compactMap { agent in
            let command = agent.activationCommand(scriptPath: scriptPath, resultDirectory: resultDirectory)
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            // Always create a dedicated window; never send input into a user's active Agent session.
            let source = """
            tell application id "com.apple.Terminal"
                do script "\(command)"
            end tell
            """
            return executeAppleScript(source) == nil ? "\(agent.rawValue)：无法打开激活窗口" : nil
        }
    }

    func terminalWindowSnapshots() -> [TerminalWindowSnapshot]? {
        let source = """
        set fieldSeparator to ASCII character 31
        set recordSeparator to ASCII character 30
        set output to ""
        tell application id "com.apple.Terminal"
            repeat with windowRef in every window
                set currentWindow to contents of windowRef
                set currentID to id of currentWindow
                set currentName to name of currentWindow as text
                set currentText to contents of selected tab of currentWindow
                set output to output & currentID & fieldSeparator & currentName & fieldSeparator & currentText & recordSeparator
            end repeat
        end tell
        return output
        """
        guard let result = executeAppleScript(source) else { return nil }
        let recordSeparator = Character(UnicodeScalar(30))
        let fieldSeparator = Character(UnicodeScalar(31))
        guard let output = result.stringValue else {
            updatePhase(.error("Terminal 窗口快照未返回文本"))
            return nil
        }
        var snapshots: [TerminalWindowSnapshot] = []
        for record in output.split(separator: recordSeparator, omittingEmptySubsequences: true) {
            let fields = record.split(separator: fieldSeparator, maxSplits: 2, omittingEmptySubsequences: false)
            guard fields.count == 3, let id = Int(fields[0]), id > 0 else {
                updatePhase(.error("Terminal 窗口快照格式无效"))
                return nil
            }
            snapshots.append(TerminalWindowSnapshot(
                id: id,
                name: String(fields[1]),
                contents: String(fields[2])
            ))
        }
        return snapshots
    }

    func terminalWindowNeedsAttention() -> Bool {
        let source = "tell application id \"com.apple.Terminal\" to get name of every window"
        guard let result = executeAppleScript(source) else { return false }
        guard result.numberOfItems > 0 else { return false }
        return (1...result.numberOfItems).contains { index in
            result.atIndex(index)?.stringValue?.contains("Action Required") == true
        }
    }

    func activateTerminalWindow(id: Int) -> Bool {
        let source = """
        tell application id "com.apple.Terminal"
            set targetWindow to first window whose id is \(id)
            set frontmost of targetWindow to true
            activate
        end tell
        """
        return executeAppleScript(source) != nil
    }

    func prepareForTermination() {
        hideDashboard(activateManager: false)
    }

    private func startPolling() {
        pollTimer?.invalidate()
        let timer = Timer(timeInterval: pollInterval, target: self, selector: #selector(pollTerminalState), userInfo: nil, repeats: true)
        // Default mode, not .common: menu tracking uses event-tracking mode, and we must not
        // mutate published state while the user has the menu open.
        RunLoop.main.add(timer, forMode: .default)
        pollTimer = timer
    }

    /// Polling stops entirely while a menu is being tracked, so nothing invalidates the menu
    /// the user is reading. Window changes made during that time are picked up on resume.
    private func observeMenuTracking() {
        let center = NotificationCenter.default
        menuTrackingObservers = [
            center.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { _ in
                Task { @MainActor in TerminalManager.shared.stopPolling() }
            },
            center.addObserver(forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main) { _ in
                Task { @MainActor in TerminalManager.shared.resumePolling() }
            }
        ]
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    private func resumePolling() {
        guard pollTimer == nil else { return }
        lastWindowServerCandidateCount = -1
        startPolling()
    }

    @objc private func pollTerminalState() {
        guard let terminal = terminalApplication() else {
            updateWindowCount(0)
            lastTiledWindowIDs = []
            if dashboardRequested { updatePhase(.terminalNotRunning) }
            return
        }

        if terminal.isHidden {
            dashboardRequested = false
            updatePhase(.hidden)
            return
        }

        guard dashboardRequested else { return }

        // Poll Window Server cheaply for near-instant change detection. Confirm with
        // Terminal AppleScript only when the candidate count changes, excluding the
        // small Terminal settings/helper window from the fast count.
        let candidateCount = windowServerCandidateCount(pid: terminal.processIdentifier)
        guard candidateCount != lastWindowServerCandidateCount else { return }

        guard let windowIDs = readTerminalWindowIDs() else { return }
        // A window that was just opened is on screen before Terminal exposes its id.
        // Keep re-reading for a few passes so it joins the layout instead of floating on top of it.
        guard windowIDs.count >= candidateCount || pendingWindowIDPasses >= pendingWindowIDPassLimit else {
            pendingWindowIDPasses += 1
            return
        }
        pendingWindowIDPasses = 0
        lastWindowServerCandidateCount = candidateCount

        let orderedWindowIDs = stableWindowOrder(currentWindowIDs: windowIDs)
        updateWindowCount(orderedWindowIDs.count)
        guard orderedWindowIDs != lastTiledWindowIDs else { return }

        tileTerminalWindows(knownWindowIDs: orderedWindowIDs)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { [weak self] in
            guard let self, self.dashboardRequested else { return }
            self.tileTerminalWindows()
        }
    }

    private func launchTerminal() {
        let candidateURLs = [
            URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"),
            URL(fileURLWithPath: "/Applications/Utilities/Terminal.app")
        ]
        guard let appURL = candidateURLs.first(where: { FileManager.default.fileExists(atPath: $0.path) }) else {
            updatePhase(.error("找不到系统 Terminal.app"))
            return
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: appURL, configuration: configuration) { [weak self] app, error in
            DispatchQueue.main.async {
                guard let self, self.dashboardRequested else { return }
                if let error {
                    self.updatePhase(.error("无法启动 Terminal：\(error.localizedDescription)"))
                    return
                }
                guard let app, app.unhide() else {
                    self.updatePhase(.error("Terminal 启动后无法显示"))
                    return
                }
                self.updatePhase(.visible)
                self.scheduleTilePasses()
            }
        }
    }

    private func scheduleTilePasses() {
        lastTiledWindowIDs = []
        for delay in [0.2, 0.8] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, self.dashboardRequested else { return }
                self.tileTerminalWindows()
            }
        }
    }

    private func tileTerminalWindows(knownWindowIDs: [Int]? = nil) {
        guard terminalApplication() != nil else {
            updatePhase(.terminalNotRunning)
            updateWindowCount(0)
            return
        }

        guard let currentWindowIDs = knownWindowIDs ?? readTerminalWindowIDs() else { return }
        let windowIDs = stableWindowOrder(currentWindowIDs: currentWindowIDs)
        let count = windowIDs.count
        updateWindowCount(count)

        guard count > 0 else {
            lastTiledWindowIDs = []
            updatePhase(.visible)
            return
        }
        guard let screen = targetScreen ?? NSScreen.main else {
            updatePhase(.error("找不到可用显示器"))
            return
        }

        let frames = GridLayout.clockwiseFrames(count: count, within: screen.visibleFrame, gap: 0)
            .map(accessibilityFrame(from:))
        guard frames.count == count else { return }

        guard applyWindowLayout(windowIDs: windowIDs, frames: frames) else {
            lastWindowServerCandidateCount = -1
            return
        }
        lastTiledWindowIDs = windowIDs
        updatePhase(.visible)
    }

    func applyWindowLayout(windowIDs: [Int], frames: [CGRect]) -> Bool {
        let windowIDList = windowIDs.map(String.init).joined(separator: ", ")
        let boundsList = frames.map { frame in
            let left = Int(frame.minX.rounded())
            let top = Int(frame.minY.rounded())
            let right = Int(frame.maxX.rounded())
            let bottom = Int(frame.maxY.rounded())
            return "{\(left), \(top), \(right), \(bottom)}"
        }.joined(separator: ", ")

        let source = """
        set targetWindowIDs to {\(windowIDList)}
        set targetBounds to {\(boundsList)}
        tell application id "com.apple.Terminal"
            repeat with i from 1 to count of targetWindowIDs
                set currentID to item i of targetWindowIDs
                set currentWindow to first window whose id is currentID
                set miniaturized of currentWindow to false
                set visible of currentWindow to true
                set bounds of currentWindow to item i of targetBounds
            end repeat
        end tell
        return count of targetBounds
        """

        return executeAppleScript(source) != nil
    }

    private func windowServerCandidateCount(pid: pid_t) -> Int {
        guard let windows = CGWindowListCopyWindowInfo(
            [.optionAll, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else { return lastWindowServerCandidateCount }

        return windows.reduce(into: 0) { count, window in
            guard (window[kCGWindowOwnerPID as String] as? Int32) == pid,
                  (window[kCGWindowLayer as String] as? Int) == 0,
                  let bounds = window[kCGWindowBounds as String] as? [String: Any],
                  let width = (bounds["Width"] as? NSNumber)?.doubleValue,
                  let height = (bounds["Height"] as? NSNumber)?.doubleValue,
                  width >= 300,
                  height >= 160 else { return }
            count += 1
        }
    }

    private func readTerminalWindowIDs() -> [Int]? {
        let source = "tell application id \"com.apple.Terminal\" to get id of every window"
        guard let result = executeAppleScript(source) else { return nil }
        guard result.numberOfItems > 0 else { return [] }
        // Terminal lists windows that are still materializing; their id comes back as
        // `missing value` and would otherwise occupy a tile that no window can fill.
        return (1...result.numberOfItems).compactMap { index in
            guard let item = result.atIndex(index), item.descriptorType == typeSInt32 else { return nil }
            let id = Int(item.int32Value)
            return id > 0 ? id : nil
        }
    }

    private func stableWindowOrder(currentWindowIDs: [Int]) -> [Int] {
        let currentSet = Set(currentWindowIDs)
        let surviving = orderedWindowIDs.filter { currentSet.contains($0) }
        let survivingSet = Set(surviving)
        let added = currentWindowIDs.filter { !survivingSet.contains($0) }.sorted()
        orderedWindowIDs = surviving.isEmpty && orderedWindowIDs.isEmpty
            ? currentWindowIDs.sorted()
            : surviving + added
        return orderedWindowIDs
    }

    private func executeAppleScript(_ source: String) -> NSAppleEventDescriptor? {
        var errorInfo: NSDictionary?
        let result: NSAppleEventDescriptor
        logger.debug("Executing Terminal automation script")
        if let scriptExecutor {
            (result, errorInfo) = scriptExecutor(source)
        } else {
            guard let script = NSAppleScript(source: source) else {
                updatePhase(.error("无法创建 Terminal 自动化脚本"))
                return nil
            }
            result = script.executeAndReturnError(&errorInfo)
        }
        guard errorInfo == nil else {
            let number = (errorInfo?[NSAppleScript.errorNumber] as? NSNumber)?.intValue ?? 0
            let message = (errorInfo?[NSAppleScript.errorMessage] as? String) ?? "未知自动化错误"
            if number == -1743 {
                updateAutomationAuthorized(false)
                logger.error("Terminal automation permission denied")
                updatePhase(.needsAutomationPermission)
            } else {
                logger.error("Terminal automation failed: \(message, privacy: .public)")
                updatePhase(.error("Terminal 自动化失败：\(message)"))
            }
            return nil
        }

        updateAutomationAuthorized(true)
        logger.debug("Terminal automation script completed")
        return result
    }

    private func terminalApplication() -> NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: terminalBundleIdentifier)
            .first(where: { !$0.isTerminated })
    }

    private func accessibilityFrame(from cocoaFrame: CGRect) -> CGRect {
        guard let primaryScreen = NSScreen.screens.first else { return cocoaFrame }
        return CGRect(
            x: cocoaFrame.minX,
            y: primaryScreen.frame.maxY - cocoaFrame.maxY,
            width: cocoaFrame.width,
            height: cocoaFrame.height
        )
    }

    private func screenUnderPointer() -> NSScreen? {
        let pointer = NSEvent.mouseLocation
        return NSScreen.screens.first(where: { $0.frame.contains(pointer) })
    }
}
