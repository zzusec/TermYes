@preconcurrency import AppKit
import Combine
import os

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
    struct TerminalWindowState: Equatable {
        let id: Int
        let visible: Bool
        let miniaturized: Bool
    }

    private struct WindowServerSnapshot {
        let candidateIDs: Set<Int>
        let onScreenIDs: Set<Int>
    }

    private var continueWindowIDs: [ContinueAgent: Int] = [:]
    private var lastTiledWindowIDs: [Int] = []
    private var lastWindowServerCandidateIDs: Set<Int>?
    private var orderedWindowIDs: [Int] = []
    private var targetScreen: NSScreen?
    private var started = false
    private var dashboardRequested = false

    private let scriptExecutor: ((String) -> (NSAppleEventDescriptor, NSDictionary?))?
    private let windowServerSnapshot: (() -> Set<Int>?)?
    private let visibleFrame: (() -> CGRect?)?

    init(
        scriptExecutor: ((String) -> (NSAppleEventDescriptor, NSDictionary?))? = nil,
        windowServerSnapshot: (() -> Set<Int>?)? = nil,
        visibleFrame: (() -> CGRect?)? = nil
    ) {
        self.scriptExecutor = scriptExecutor
        self.windowServerSnapshot = windowServerSnapshot
        self.visibleFrame = visibleFrame
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
        lastWindowServerCandidateIDs = nil
        targetScreen = screenUnderPointer() ?? NSScreen.main

        if let terminal = terminalApplication() {
            let wasHidden = terminal.isHidden
            // unhide() returns false when the app is already visible. That is
            // a no-op, not a connection failure; hotkeys must still re-tile it.
            if wasHidden && !terminal.unhide() {
                updatePhase(.error("无法显示 Terminal"))
                return
            }
            let activated = terminal.activate(options: [.activateAllWindows])
            guard activated || terminal.isActive else {
                updatePhase(.error("无法激活 Terminal"))
                return
            }
            updatePhase(.visible)
            scheduleTilePasses(afterUnhide: wasHidden)
        } else {
            launchTerminal()
        }
    }

    @discardableResult
    func rotateVisibleOrderClockwise() -> Bool {
        guard let snapshot = readWindowServerSnapshot(),
              let liveWindows = readTerminalWindowStates() else { return false }
        let allLiveIDs = liveWindows.map(\.id)
        guard snapshot.candidateIDs.isSubset(of: Set(allLiveIDs)) else { return false }

        let targetIDs = targetWindowIDs(
            from: liveWindows,
            onScreenIDs: snapshot.onScreenIDs,
            restoreMinimized: false
        )
        let currentOrder = stableWindowOrder(targetIDs: targetIDs, allLiveIDs: allLiveIDs)
        guard currentOrder.count > 1 else { return false }

        let rotatedTarget = GridLayout.advancedClockwise(currentOrder)
        let targetSet = Set(targetIDs)
        var rotatedIndex = 0
        orderedWindowIDs = orderedWindowIDs.map { id in
            guard targetSet.contains(id) else { return id }
            defer { rotatedIndex += 1 }
            return rotatedTarget[rotatedIndex]
        }
        lastTiledWindowIDs = []
        return true
    }

    func advanceDashboard() {
        if dashboardRequested,
           let terminal = terminalApplication(),
           !terminal.isHidden,
           terminal.isActive {
            _ = rotateVisibleOrderClockwise()
        }
        showDashboard()
    }

    func hideDashboardIfVisible() {
        guard dashboardRequested, terminalApplication()?.isHidden == false else { return }
        hideDashboard(activateManager: false)
    }

    func hideDashboard(activateManager: Bool = true) {
        dashboardRequested = false
        if let terminal = terminalApplication(), !terminal.isHidden && !terminal.hide() {
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

    func openAgentContinueWindows(_ agents: [ContinueAgent], scriptPath: String, resultDirectory: String) -> [String] {
        var failures: [String] = []
        var openedWindowIDs: [ContinueAgent: Int] = [:]
        for agent in agents {
            let command = agent.continueCommand(scriptPath: scriptPath, resultDirectory: resultDirectory)
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            // Always create a dedicated window; never send input into a user's active Agent session.
            // `do script` without a target creates a new front window; its id lets us close exactly
            // that window later instead of touching any user window.
            let source = """
            tell application id "com.apple.Terminal"
                do script "\(command)"
                return id of front window
            end tell
            """
            guard let result = executeAppleScript(source), result.descriptorType == typeSInt32,
                  result.int32Value > 0 else {
                failures.append("\(agent.rawValue)：无法打开激活窗口")
                continue
            }
            openedWindowIDs[agent] = Int(result.int32Value)
        }
        // One batch per continue round; the previous batch is closed when its own round finishes.
        continueWindowIDs = openedWindowIDs
        return failures
    }

    /// Closes only the dedicated windows opened by the most recent continue round and leaves every
    /// other Terminal window untouched. Windows the user already closed are skipped instead of
    /// raising an automation error.
    func closeAgentContinueWindows() {
        let windowIDs = Array(continueWindowIDs.values)
        continueWindowIDs = [:]
        closeAgentContinueWindows(windowIDs)
    }

    func closeAgentContinueWindow(_ agent: ContinueAgent) {
        guard let windowID = continueWindowIDs.removeValue(forKey: agent) else { return }
        closeAgentContinueWindows([windowID])
    }

    private func closeAgentContinueWindows(_ windowIDs: [Int]) {
        guard !windowIDs.isEmpty else { return }
        let windowIDList = windowIDs.map(String.init).joined(separator: ", ")
        let source = """
        tell application id "com.apple.Terminal"
            repeat with currentID in {\(windowIDList)}
                if exists (first window whose id is currentID) then
                    close (first window whose id is currentID)
                end if
            end repeat
        end tell
        """
        _ = executeAppleScript(source)
    }

    func prepareForTermination() {
        stopPolling()
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
        lastWindowServerCandidateIDs = nil
        startPolling()
    }

    @objc private func pollTerminalState() {
        guard let terminal = terminalApplication() else {
            updateWindowCount(0)
            lastTiledWindowIDs = []
            if dashboardRequested { updatePhase(.terminalNotRunning) }
            return
        }

        pollTerminalWindows(isHidden: terminal.isHidden, isActive: terminal.isActive)
    }

    func pollTerminalWindows(isHidden: Bool, isActive: Bool) {
        if isHidden {
            dashboardRequested = false
            updatePhase(.hidden)
            return
        }

        // Dock, Command-Tab and a normal new-window action can reveal Terminal without
        // showDashboard(). Resume watching it without activating or forcing a re-tile.
        if isActive && !dashboardRequested {
            dashboardRequested = true
            lastWindowServerCandidateIDs = nil
            targetScreen = activeScreen()
            updatePhase(.visible)
        }

        guard dashboardRequested else { return }

        guard let snapshot = readWindowServerSnapshot(),
              snapshot.candidateIDs != lastWindowServerCandidateIDs else { return }
        guard tileTerminalWindows(force: false, restoreMinimized: false) else {
            if pollTimer != nil {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                    guard let self, self.dashboardRequested, self.pollTimer != nil else { return }
                    _ = self.tileTerminalWindows(force: false, restoreMinimized: false)
                }
            }
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { [weak self] in
            guard let self, self.dashboardRequested else { return }
            self.tileTerminalWindows(force: true, restoreMinimized: false)
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
                guard let app else {
                    self.updatePhase(.error("Terminal 启动后无法显示"))
                    return
                }
                // Opening with activates=true normally returns an already-visible app.
                // As in showDashboard(), a redundant unhide is not a launch failure.
                if app.isHidden && !app.unhide() {
                    self.updatePhase(.error("Terminal 启动后无法显示"))
                    return
                }
                self.updatePhase(.visible)
                self.scheduleTilePasses()
            }
        }
    }

    private func scheduleTilePasses(afterUnhide: Bool = false) {
        lastTiledWindowIDs = []
        let passes: [(delay: TimeInterval, restoreMinimized: Bool)]
        if afterUnhide {
            passes = [(0.12, true), (0.35, false), (0.90, false)]
        } else {
            tileTerminalWindows(force: true, restoreMinimized: true)
            passes = [(0.25, false), (0.85, false)]
        }
        for pass in passes {
            DispatchQueue.main.asyncAfter(deadline: .now() + pass.delay) { [weak self] in
                guard let self, self.dashboardRequested else { return }
                self.tileTerminalWindows(force: true, restoreMinimized: pass.restoreMinimized)
            }
        }
    }

    @discardableResult
    func tileTerminalWindows(force: Bool = true, restoreMinimized: Bool = true) -> Bool {
        guard let snapshot = readWindowServerSnapshot(),
              let liveWindows = readTerminalWindowStates() else { return false }

        let allLiveIDs = liveWindows.map(\.id)
        let allLiveSet = Set(allLiveIDs)
        // Terminal can briefly omit a still-visible window from its AppleScript list.
        // Every pass, including delayed/hotkey passes, must wait for a complete snapshot.
        // Do not change the saved order or cache a partial snapshot: polling must retry it.
        guard snapshot.candidateIDs.isSubset(of: allLiveSet) else {
            lastWindowServerCandidateIDs = nil
            return false
        }
        let targetIDs = targetWindowIDs(
            from: liveWindows,
            onScreenIDs: snapshot.onScreenIDs,
            restoreMinimized: restoreMinimized
        )
        let windowIDs = stableWindowOrder(targetIDs: targetIDs, allLiveIDs: allLiveIDs)
        let count = windowIDs.count
        updateWindowCount(count)

        if !force && windowIDs == lastTiledWindowIDs {
            lastWindowServerCandidateIDs = snapshot.candidateIDs
            return false
        }
        guard count > 0 else {
            lastTiledWindowIDs = []
            lastWindowServerCandidateIDs = snapshot.candidateIDs
            updatePhase(.visible)
            return false
        }
        let screenFrame: CGRect?
        if let visibleFrame {
            screenFrame = visibleFrame()
        } else {
            screenFrame = activeScreen()?.visibleFrame
        }
        guard let screenFrame else {
            updatePhase(.error("找不到可用显示器"))
            return false
        }

        if count == 1 {
            let accessibilityScreen = accessibilityFrame(from: screenFrame)
            let recenter = lastTiledWindowIDs.count > 1
            guard applySingleWindowDefaultSize(
                windowID: windowIDs[0],
                within: accessibilityScreen,
                recenter: recenter
            ) else {
                lastTiledWindowIDs = []
                lastWindowServerCandidateIDs = nil
                return false
            }
            lastTiledWindowIDs = windowIDs
            lastWindowServerCandidateIDs = snapshot.candidateIDs
            updatePhase(.visible)
            return true
        }

        let frames = GridLayout.clockwiseFrames(count: count, within: screenFrame, gap: 0)
            .map(accessibilityFrame(from:))
        guard frames.count == count else { return false }

        guard applyWindowLayout(windowIDs: windowIDs, frames: frames) else {
            lastTiledWindowIDs = []
            lastWindowServerCandidateIDs = nil
            return false
        }
        lastTiledWindowIDs = windowIDs
        lastWindowServerCandidateIDs = snapshot.candidateIDs
        updatePhase(.visible)
        return true
    }

    func applySingleWindowDefaultSize(windowID: Int, within screenBounds: CGRect, recenter: Bool = false) -> Bool {
        guard screenBounds.width > 0, screenBounds.height > 0 else { return false }
        let screenLeft = Int(screenBounds.minX.rounded())
        let screenTop = Int(screenBounds.minY.rounded())
        let screenRight = Int(screenBounds.maxX.rounded())
        let screenBottom = Int(screenBounds.maxY.rounded())
        let forceRecenter = recenter ? "true" : "false"

        let source = """
        set targetWindowIDs to {\(windowID)}
        set screenBounds to {\(screenLeft), \(screenTop), \(screenRight), \(screenBottom)}
        set forceRecenter to \(forceRecenter)
        tell application id "com.apple.Terminal"
            set defaultCols to number of columns of default settings
            set defaultRows to number of rows of default settings
            repeat with i from 1 to count of targetWindowIDs
                set currentID to item i of targetWindowIDs
                set currentWindow to first window whose id is currentID
                if (count of tabs of currentWindow) > 0 then
                    if miniaturized of currentWindow then
                        set miniaturized of currentWindow to false
                    end if
                    if not (visible of currentWindow) then
                        set visible of currentWindow to true
                    end if
                    set sizeChanged to false
                    if defaultCols > 0 and number of columns of selected tab of currentWindow is not defaultCols then
                        set number of columns of selected tab of currentWindow to defaultCols
                        set sizeChanged to true
                    end if
                    if defaultRows > 0 and number of rows of selected tab of currentWindow is not defaultRows then
                        set number of rows of selected tab of currentWindow to defaultRows
                        set sizeChanged to true
                    end if
                    set currentBounds to bounds of currentWindow
                    set curLeft to item 1 of currentBounds
                    set curTop to item 2 of currentBounds
                    set curRight to item 3 of currentBounds
                    set curBottom to item 4 of currentBounds
                    set winWidth to curRight - curLeft
                    set winHeight to curBottom - curTop
                    set screenLeft to item 1 of screenBounds
                    set screenTop to item 2 of screenBounds
                    set screenRight to item 3 of screenBounds
                    set screenBottom to item 4 of screenBounds
                    set screenWidth to screenRight - screenLeft
                    set screenHeight to screenBottom - screenTop
                    if winWidth > screenWidth then set winWidth to screenWidth
                    if winHeight > screenHeight then set winHeight to screenHeight
                    set centerX to curLeft + (winWidth div 2)
                    set centerY to curTop + (winHeight div 2)
                    set offTargetScreen to (centerX < screenLeft or centerX > screenRight or centerY < screenTop or centerY > screenBottom)
                    if forceRecenter or sizeChanged or offTargetScreen then
                        set newLeft to screenLeft + ((screenWidth - winWidth) div 2)
                        set newTop to screenTop + ((screenHeight - winHeight) div 2)
                        if newLeft < screenLeft then set newLeft to screenLeft
                        if newTop < screenTop then set newTop to screenTop
                        set bounds of currentWindow to {newLeft, newTop, newLeft + winWidth, newTop + winHeight}
                        set postResize to false
                        if defaultCols > 0 and number of columns of selected tab of currentWindow is not defaultCols then
                            set number of columns of selected tab of currentWindow to defaultCols
                            set postResize to true
                        end if
                        if defaultRows > 0 and number of rows of selected tab of currentWindow is not defaultRows then
                            set number of rows of selected tab of currentWindow to defaultRows
                            set postResize to true
                        end if
                        if postResize then
                            set currentBounds to bounds of currentWindow
                            set winWidth to (item 3 of currentBounds) - (item 1 of currentBounds)
                            set winHeight to (item 4 of currentBounds) - (item 2 of currentBounds)
                            if winWidth > screenWidth then set winWidth to screenWidth
                            if winHeight > screenHeight then set winHeight to screenHeight
                            set newLeft to screenLeft + ((screenWidth - winWidth) div 2)
                            set newTop to screenTop + ((screenHeight - winHeight) div 2)
                            if newLeft < screenLeft then set newLeft to screenLeft
                            if newTop < screenTop then set newTop to screenTop
                            set bounds of currentWindow to {newLeft, newTop, newLeft + winWidth, newTop + winHeight}
                        end if
                    end if
                else if visible of currentWindow then
                    set visible of currentWindow to false
                end if
            end repeat
        end tell
        return count of targetWindowIDs
        """

        return executeAppleScript(source) != nil
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
                if (count of tabs of currentWindow) > 0 then
                    if miniaturized of currentWindow then
                        set miniaturized of currentWindow to false
                    end if
                    if not (visible of currentWindow) then
                        set visible of currentWindow to true
                    end if
                    set bounds of currentWindow to item i of targetBounds
                else if visible of currentWindow then
                    set visible of currentWindow to false
                end if
            end repeat
        end tell
        return count of targetBounds
        """

        return executeAppleScript(source) != nil
    }

    private func activeScreen() -> NSScreen? {
        if let targetScreen, NSScreen.screens.contains(targetScreen) {
            return targetScreen
        }
        targetScreen = screenUnderPointer() ?? NSScreen.main
        return targetScreen
    }

    private func readWindowServerSnapshot() -> WindowServerSnapshot? {
        if let windowServerSnapshot {
            guard let ids = windowServerSnapshot() else { return nil }
            return WindowServerSnapshot(candidateIDs: ids, onScreenIDs: ids)
        }
        guard let terminal = terminalApplication() else {
            updatePhase(.terminalNotRunning)
            updateWindowCount(0)
            return nil
        }
        return windowServerSnapshot(pid: terminal.processIdentifier)
    }

    private func windowServerSnapshot(pid: pid_t) -> WindowServerSnapshot? {
        guard let windows = CGWindowListCopyWindowInfo(
            // Hidden Terminal utility windows are not part of the AppleScript window list.
            // Live minimized/offscreen windows are filtered against onScreenIDs before tiling.
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else { return nil }

        var candidateIDs = Set<Int>()
        var onScreenIDs = Set<Int>()
        for window in windows {
            guard (window[kCGWindowOwnerPID as String] as? Int32) == pid,
                  (window[kCGWindowLayer as String] as? Int) == 0,
                  let windowNumber = (window[kCGWindowNumber as String] as? NSNumber)?.intValue,
                  let bounds = window[kCGWindowBounds as String] as? [String: Any],
                  let width = (bounds["Width"] as? NSNumber)?.doubleValue,
                  let height = (bounds["Height"] as? NSNumber)?.doubleValue,
                  width > 0,
                  height > 0 else { continue }
            onScreenIDs.insert(windowNumber)
            if width >= 290, height >= 145 {
                candidateIDs.insert(windowNumber)
            }
        }
        return WindowServerSnapshot(candidateIDs: candidateIDs, onScreenIDs: onScreenIDs)
    }

    func readTerminalWindowIDs() -> [Int]? {
        readTerminalWindowStates()?.map(\.id)
    }

    func readTerminalWindowStates() -> [TerminalWindowState]? {
        // Terminal retains closed windows with no tabs and stale references with no ID.
        // Read IDs first: asking a stale reference for its tabs fails the entire snapshot.
        let source = """
        set liveWindowIDs to {}
        tell application id "com.apple.Terminal"
            repeat with currentWindow in windows
                try
                    set currentID to id of currentWindow
                    if class of currentID is integer then
                        if currentID > 0 then
                            if (count of tabs of currentWindow) > 0 then
                                set end of liveWindowIDs to {currentID, visible of currentWindow, miniaturized of currentWindow}
                            else if visible of currentWindow then
                                set visible of currentWindow to false
                            end if
                        end if
                    end if
                on error messageText number errorNumber
                    if errorNumber is not -1728 and errorNumber is not -1719 then error messageText number errorNumber
                end try
            end repeat
        end tell
        return liveWindowIDs
        """
        guard let result = executeAppleScript(source) else { return nil }
        guard result.numberOfItems > 0 else { return [] }
        // Terminal lists windows that are still materializing; their id comes back as
        // `missing value` and would otherwise occupy a tile that no window can fill.
        return (1...result.numberOfItems).compactMap { index in
            guard let item = result.atIndex(index) else { return nil }
            if item.descriptorType == typeAEList,
               item.numberOfItems >= 3,
               let idDescriptor = item.atIndex(1),
               idDescriptor.descriptorType == typeSInt32 {
                let id = Int(idDescriptor.int32Value)
                guard id > 0 else { return nil }
                let visible = item.atIndex(2)?.booleanValue ?? true
                let miniaturized = item.atIndex(3)?.booleanValue ?? false
                return TerminalWindowState(id: id, visible: visible, miniaturized: miniaturized)
            }
            if item.descriptorType == typeSInt32 {
                let id = Int(item.int32Value)
                guard id > 0 else { return nil }
                return TerminalWindowState(id: id, visible: true, miniaturized: false)
            }
            return nil
        }
    }

    private func targetWindowIDs(
        from liveWindows: [TerminalWindowState],
        onScreenIDs: Set<Int>,
        restoreMinimized: Bool
    ) -> [Int] {
        liveWindows.compactMap { window in
            if restoreMinimized {
                // Exclude visible, unminimized windows absent from WindowServer's onscreen list
                // (ghost restored windows, native fullscreen windows, and windows on other Spaces).
                guard onScreenIDs.contains(window.id) || window.miniaturized || !window.visible else {
                    return nil
                }
                return window.id
            }
            guard onScreenIDs.contains(window.id) && !window.miniaturized else {
                return nil
            }
            return window.id
        }
    }

    private func stableWindowOrder(targetIDs: [Int], allLiveIDs: [Int]) -> [Int] {
        let liveSet = Set(allLiveIDs)
        let survivingAll = orderedWindowIDs.filter { liveSet.contains($0) }
        let survivingSet = Set(survivingAll)
        let addedAll = allLiveIDs.filter { !survivingSet.contains($0) }.sorted()
        orderedWindowIDs = survivingAll.isEmpty && orderedWindowIDs.isEmpty
            ? allLiveIDs.sorted()
            : survivingAll + addedAll
        let targetSet = Set(targetIDs)
        return orderedWindowIDs.filter { targetSet.contains($0) }
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
