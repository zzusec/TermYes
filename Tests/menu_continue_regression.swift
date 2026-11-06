// swiftc Sources/{GridLayout,ContinueSchedule,TerminalManager,GlobalHotKeyController,ScheduledContinueController}.swift Tests/menu_continue_regression.swift -o /tmp/termyes-menu-regression
// This suite compiles Terminal AppleScripts and executes snapshot fixtures against
// in-memory script objects, never the user's Terminal. Agent processes and guard
// management use executables in a temporary HOME, never installed user agents.
import AppKit
import Carbon.HIToolbox
import Foundation

@main
struct MenuContinueRegression {
    static func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) rethrows {
        if try !condition() {
            fputs("FAIL: \(message)\n", stderr)
            exit(1)
        }
    }

    @MainActor
    static func main() async throws {
        scheduleReconfirmation()
        try terminalScripts()
        terminalLayoutSnapshots()
        terminalPollingLifecycle()
        shortcutFailures()
        try await scheduledContinue()
        try receiptValidation()
        print("Menu continue regression tests passed (Terminal scripts, complete layout snapshots/recovery, activation/hide/new/close lifecycle, shortcuts, schedule persistence/cancellation, dedicated-window receipts, explicit schedule reconfirmation/next timer date, fake requests/timeouts).")
    }

    @MainActor
    static func scheduleReconfirmation() {
        let confirmations: [(Int, Set<ContinueAgent>)] = [(10, [.claude]), (-10, [.claude]), (10, [.codex])]
        for (offset, agents) in confirmations {
            let suite = "termyes-schedule-reconfirmation.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            let calendar = Calendar.current
            let now = Date()
            let current = calendar.dateComponents([.hour, .minute], from: now)
            let future = calendar.dateComponents([.hour, .minute], from: now.addingTimeInterval(TimeInterval(offset * 60)))
            // Near midnight the past choice stays at today's 00:00 instead of wrapping to a future HH:mm.
            let minutes = offset > 0 ? future.hour! * 60 + future.minute! : max(0, current.hour! * 60 + current.minute! + offset)
            let yesterday = calendar.date(byAdding: .day, value: -1, to: now)!
            let oldAnchor = calendar.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: yesterday)!
            defaults.set(minutes, forKey: "autoContinueWindowStartMinutes")
            defaults.set(["claude"], forKey: "autoContinueWindowAgents")
            defaults.set(oldAnchor, forKey: "autoContinueWindowAnchorDate")
            let controller = ScheduledContinueController(defaults: defaults, home: FileManager.default.temporaryDirectory.path, manager: nil, openAgentWindows: { _, _, _ in
                expect(false, "Reconfirming or restoring a schedule must not open any agent window")
                return []
            }, closeAgentWindows: {
                expect(false, "Reconfirming or restoring a schedule must not close any window")
            })
            defer { controller.setWindowSchedule(minutes: nil, agents: []) }
            expect(controller.nextContinueDate == nil, "A controller not yet started must not advertise an unscheduled timer")
            let beforeStart = Date()
            controller.start()
            let afterStart = Date()
            expect(defaults.object(forKey: "autoContinueWindowAnchorDate") as? Date == oldAnchor, "Startup must preserve the saved five-hour timeline until explicit confirmation")
            expect(controller.nextContinueDate == ContinueSchedule.nextFire(after: beforeStart, anchor: oldAnchor) || controller.nextContinueDate == ContinueSchedule.nextFire(after: afterStart, anchor: oldAnchor), "Restored cross-day schedules must expose the actual next five-hour boundary, not the original HH:mm")
            expectScheduledTimer(controller)
            let oldTimer = scheduledTimer(controller)!
            let before = Date()
            controller.setWindowSchedule(minutes: minutes, agents: agents)
            let after = Date()
            let anchor = defaults.object(forKey: "autoContinueWindowAnchorDate") as? Date
            expect(anchor != oldAnchor, "Confirming the saved minutes, even with unchanged agents, must replace yesterday's anchor (old: \(oldAnchor), saved: \(String(describing: anchor)))")
            expect(anchor == ContinueSchedule.firstAnchor(minutes: minutes, after: before) || anchor == ContinueSchedule.firstAnchor(minutes: minutes, after: after), "Confirmation must restart at the next occurrence of the freely selected HH:mm")
            expect(!oldTimer.isValid, "Confirmation must cancel the old timeline's timer")
            expect(controller.nextContinueDate == anchor, "The replacement timer must fire at the newly confirmed anchor")
            if offset < 0 {
                expect(!calendar.isDate(anchor!, inSameDayAs: after), "A past HH:mm must start on the next day, not continue yesterday's cycle")
            }
            expect(controller.windowScheduleDescription == String(format: "%02d:%02d", minutes / 60, minutes % 60), "The picker label must show the freely selected HH:mm without implying it repeats daily")
            expectScheduledTimer(controller)
            let restored = ScheduledContinueController(defaults: defaults, home: FileManager.default.temporaryDirectory.path, manager: nil, openAgentWindows: { _, _, _ in
                expect(false, "Restart restoration must only schedule, never open an agent window")
                return []
            }, closeAgentWindows: {
                expect(false, "Restart restoration must only schedule, never close a window")
            })
            defer { restored.setWindowSchedule(minutes: nil, agents: []) }
            restored.start()
            expect(restored.windowStartMinutes == minutes && restored.windowAgents == agents, "A restart must restore the confirmed arbitrary time and agent selection")
            expect(defaults.object(forKey: "autoContinueWindowAnchorDate") as? Date == anchor && restored.nextContinueDate == anchor, "A restart must retain the confirmed timeline without reconfirming the picker")
            expectScheduledTimer(restored)
            let activeTimer = scheduledTimer(controller)!
            controller.setWindowSchedule(minutes: nil, agents: [.claude])
            expect(!activeTimer.isValid && scheduledTimer(controller) == nil && controller.nextContinueDate == nil, "Disabling must invalidate the real timer and clear the advertised next continue date")
            expect(defaults.object(forKey: "autoContinueWindowAnchorDate") == nil && controller.windowScheduleDescription == "关闭", "Disable must remove the persisted anchor and report disabled")
            expect(controller.nextContinueDescription == "未启用", "Disabled menus must not keep showing the previous firing date")
        }
    }

    @MainActor
    static func scheduledTimer(_ controller: ScheduledContinueController) -> Timer? {
        Mirror(reflecting: controller).children.first { $0.label == "windowTimer" }?.value as? Timer
    }

    @MainActor
    static func expectScheduledTimer(_ controller: ScheduledContinueController) {
        guard let date = controller.nextContinueDate else {
            expect(false, "An enabled schedule must expose its next continue date")
            return
        }
        let timer = scheduledTimer(controller)
        expect(timer?.isValid == true && timer?.fireDate == date, "The published next continue date must exactly match the live Timer.fireDate")
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.calendar = .current
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd HH:mm z"
        expect(controller.nextContinueDescription.contains(formatter.string(from: date)), "The menu must show the next timer's complete local date, 24-hour time, and timezone: \(controller.nextContinueDescription)")
    }

    @MainActor
    static func terminalScripts() throws {
        var scripts: [String] = []
        var result = NSAppleEventDescriptor(boolean: true)
        var error: NSDictionary?
        var nextContinueWindowID: Int32 = 345
        let manager = TerminalManager(scriptExecutor: { source in
            scripts.append(source)
            var compilationError: NSDictionary?
            expect(NSAppleScript(source: source)!.compileAndReturnError(&compilationError), "Terminal script must compile: \(compilationError?.description ?? source)")
            if source.contains("do script "), error == nil {
                defer { nextContinueWindowID += 1 }
                return (.init(int32: nextContinueWindowID), nil)
            }
            return (result, error)
        })
        expect(manager.openAgentContinueWindows([.claude, .codex], scriptPath: "/a'b/with \"quotes\"/continue_task.py", resultDirectory: "/result's/with \"quotes\"").isEmpty, "Window-start scripts must compile with quoted bundle paths")
        expect(scripts.suffix(2).allSatisfy { $0.contains("do script ") && !$0.contains("every window") && !$0.contains("tabRef") && !$0.contains("in window") && !$0.contains("selected tab") && !$0.contains("return false") && !$0.contains("try") }, "Each continue round must create a dedicated window without inspecting, skipping, or targeting user sessions")
        let scriptsAfterWindows = scripts.count
        manager.closeAgentContinueWindow(.claude)
        expect(scripts.count == scriptsAfterWindows + 1 && scripts.last?.contains("345") == true && scripts.last?.contains("346") == false, "A completed Agent must close its own recorded window immediately")
        let scriptsAfterAgentClose = scripts.count
        manager.closeAgentContinueWindows()
        expect(scripts.count == scriptsAfterAgentClose + 1, "A finished continue round must close any remaining dedicated windows")
        let closeScript = scripts.last ?? ""
        expect(closeScript.contains("exists (first window whose id is currentID)") && closeScript.contains("close (first window whose id is currentID)") && closeScript.contains("346") && !closeScript.contains("345") && !closeScript.contains("front window") && !closeScript.contains("every window"), "Batch cleanup must target only remaining continue window IDs and leave user windows alone")
        let scriptsAfterClose = scripts.count
        manager.closeAgentContinueWindows()
        expect(scripts.count == scriptsAfterClose, "Closing without a recorded continue round must not run a script")
        result = .list()
        result.insert(.init(int32: 12), at: 1)
        result.insert(.null(), at: 2)
        result.insert(.init(int32: -1), at: 3)
        result.insert(.init(int32: 13), at: 4)
        expect(manager.readTerminalWindowIDs() == [12, 13], "Window snapshots must retain live IDs and skip missing or invalid IDs")
        let snapshotScript = scripts.last ?? ""
        expect(snapshotScript.contains("if (count of tabs of currentWindow) > 0 then"), "Window snapshots must exclude closed zero-tab windows")
        expect(snapshotScript.contains("else if visible of currentWindow then") && snapshotScript.contains("set visible of currentWindow to false"), "Already-visible zero-tab windows must be hidden")
        expect(!snapshotScript.contains("close ") && !snapshotScript.contains("do script "), "Window snapshots must never close sessions or create terminals")
        snapshotFixtures(snapshotScript)
        result = .list()
        expect(manager.readTerminalWindowIDs() == [], "An empty snapshot must not reserve any layout slots")
        result = .init(boolean: true)
        expect(manager.applyWindowLayout(windowIDs: [12, 13], frames: [CGRect(x: 0, y: 30, width: 500, height: 800), CGRect(x: 500, y: 30, width: 500, height: 800)], nextWindowSize: CGSize(width: 500, height: 400)), "Layout script with next-window sizing must compile")
        expect(scripts.last?.contains("try") == false, "Layout must not silently report success after per-window errors")
        expect(scripts.last?.contains("if (count of tabs of currentWindow) > 0 then") == true, "Layout must recheck tabs before showing a window that may have closed after the snapshot")
        expect(scripts.last?.contains("if not (visible of currentWindow) then") == true && scripts.last?.contains("if miniaturized of currentWindow then") == true, "Layout must not unconditionally re-show already-visible windows above frontmost apps")
        expect(scripts.last?.contains("set number of columns of default settings to nextCols") == true && scripts.last?.contains("set number of rows of default settings to nextRows") == true, "Layout must pre-size default settings to the (N+1)th grid slot")
        error = [NSAppleScript.errorNumber: -1743, NSAppleScript.errorMessage: "Not authorized"]
        expect(!manager.applyWindowLayout(windowIDs: [12], frames: [.zero]), "Denied automation must fail layout")
        expect(!manager.automationAuthorized && manager.phase == .needsAutomationPermission, "Permission denial must expose the automation-settings route")
        expect(!manager.openAgentContinueWindows([.claude], scriptPath: "/fake/continue_task.py", resultDirectory: "/fake/results").isEmpty, "Denied window creation must report a failure")
        let scriptsAfterDeniedOpen = scripts.count
        manager.closeAgentContinueWindows()
        expect(scripts.count == scriptsAfterDeniedOpen, "Denied window creation must not leave closable window records")
        error = [NSAppleScript.errorNumber: -10000, NSAppleScript.errorMessage: "Window write failed"]
        expect(!manager.applyWindowLayout(windowIDs: [12], frames: [.zero]), "Layout failures must be returned")
        expect(manager.phase == .error("Terminal 自动化失败：Window write failed"), "Automation failures must retain actual error details")
        error = nil
        result = .init(string: "")
        _ = manager.applyWindowLayout(windowIDs: [12], frames: [.zero])
        expect(manager.automationAuthorized, "A successful automation call must clear the permission-denied flag")
    }

    @MainActor
    static func terminalLayoutSnapshots() {
        var liveIDs = [12, 13]
        var candidateIDs: Set<Int>? = [12, 13]
        var layouts: [String] = []
        var layoutError: NSDictionary?
        let manager = TerminalManager(scriptExecutor: { source in
            if source.contains("return liveWindowIDs") {
                let result = NSAppleEventDescriptor.list()
                for (index, id) in liveIDs.enumerated() {
                    result.insert(.init(int32: Int32(id)), at: index + 1)
                }
                return (result, nil)
            }
            layouts.append(source)
            return (.init(boolean: true), layoutError)
        }, windowServerSnapshot: {
            candidateIDs
        }, visibleFrame: {
            CGRect(x: 0, y: 0, width: 1200, height: 800)
        })

        manager.tileTerminalWindows()
        expect(layouts.count == 1 && manager.terminalWindowCount == 2, "Two live windows must produce a two-window layout")
        let originalLayout = layouts.last

        liveIDs = [12]
        for _ in 0..<15 { manager.tileTerminalWindows() }
        expect(layouts.count == 1 && manager.terminalWindowCount == 2, "Even after repeated retries, an incomplete snapshot must preserve the existing two-window layout instead of maximizing one window")

        liveIDs = [12, 14]
        manager.tileTerminalWindows()
        expect(layouts.count == 1, "Matching counts with different window IDs must not pass snapshot validation")

        liveIDs = [13, 12]
        manager.tileTerminalWindows()
        expect(layouts.count == 2 && layouts.last == originalLayout, "Recovery with the same Window Server candidates must restore both windows and preserve their original order")

        candidateIDs = [12]
        manager.tileTerminalWindows(force: false)
        expect(layouts.count == 2 && manager.terminalWindowCount == 2, "Minimizing a window or changing Spaces must not force an unchanged set of live windows back onscreen")

        candidateIDs = []
        liveIDs = [12]
        manager.tileTerminalWindows(force: false)
        expect(layouts.count == 2, "Passive polling with zero onscreen candidates must not maximize a partial or minimized window set")
        liveIDs = [13, 12]

        candidateIDs = [12]
        liveIDs = [12]
        manager.tileTerminalWindows()
        expect(layouts.count == 3 && manager.terminalWindowCount == 1, "A genuinely closed window must allow the remaining window to fill the screen")

        // A minimized/offscreen live Terminal still occupies a slot when the canvas is shown.
        liveIDs = [12, 13]
        manager.tileTerminalWindows()
        expect(layouts.count == 4 && manager.terminalWindowCount == 2, "Live offscreen or minimized windows must remain part of the layout")

        candidateIDs = nil
        liveIDs = [12]
        manager.tileTerminalWindows()
        expect(layouts.count == 4 && manager.terminalWindowCount == 2, "An unavailable Window Server snapshot must not shrink the layout")

        candidateIDs = []
        liveIDs = []
        manager.tileTerminalWindows()
        expect(layouts.count == 4 && manager.terminalWindowCount == 0, "Closing all windows must clear the count without writing a layout")

        candidateIDs = [12]
        liveIDs = [12]
        layoutError = [NSAppleScript.errorNumber: -10000, NSAppleScript.errorMessage: "Window write failed"]
        manager.tileTerminalWindows()
        expect(manager.phase == .error("Terminal 自动化失败：Window write failed"), "Snapshot validation must not hide actual layout write failures")
        layoutError = nil
        manager.tileTerminalWindows()
        expect(manager.phase == .visible && layouts.count == 6, "A failed layout must remain retryable with unchanged window candidates")

        layoutError = [NSAppleScript.errorNumber: -10000, NSAppleScript.errorMessage: "Window write failed again"]
        manager.tileTerminalWindows()
        layoutError = nil
        expect(manager.tileTerminalWindows(force: false) && manager.phase == .visible && layouts.count == 8, "Polling must retry a failed forced layout even when the same windows were previously laid out successfully")
    }

    @MainActor
    static func terminalPollingLifecycle() {
        var liveIDs = [12, 13]
        var candidateIDs: Set<Int> = [12, 13]
        var layoutWrites = 0
        let manager = TerminalManager(scriptExecutor: { source in
            if source.contains("return liveWindowIDs") {
                let result = NSAppleEventDescriptor.list()
                for (index, id) in liveIDs.enumerated() {
                    result.insert(.init(int32: Int32(id)), at: index + 1)
                }
                return (result, nil)
            }
            layoutWrites += 1
            return (.init(boolean: true), nil)
        }, windowServerSnapshot: {
            candidateIDs
        }, visibleFrame: {
            CGRect(x: 0, y: 0, width: 1200, height: 800)
        })

        manager.pollTerminalWindows(isHidden: false, isActive: true)
        expect(layoutWrites == 1 && manager.terminalWindowCount == 2, "Activating Terminal normally must start automatic arrangement without the global hotkey")

        manager.pollTerminalWindows(isHidden: false, isActive: false)
        expect(layoutWrites == 1 && manager.phase == .visible, "Switching focus to Finder or another app must keep Terminal visible behind it without rewriting unchanged bounds")

        manager.pollTerminalWindows(isHidden: true, isActive: false)
        expect(manager.phase == .hidden, "Hiding Terminal must pause its canvas")
        liveIDs = [12, 13, 14]
        candidateIDs = [12, 13, 14]
        manager.pollTerminalWindows(isHidden: true, isActive: false)
        manager.pollTerminalWindows(isHidden: false, isActive: false)
        expect(layoutWrites == 1, "Hidden or inactive Terminal must not resume itself or write a layout")

        manager.pollTerminalWindows(isHidden: false, isActive: true)
        expect(layoutWrites == 2 && manager.terminalWindowCount == 3 && manager.phase == .visible, "Returning normally and opening a window must resume automatic arrangement")

        liveIDs = [12, 13]
        candidateIDs = [12, 13]
        manager.pollTerminalWindows(isHidden: false, isActive: true)
        expect(layoutWrites == 3 && manager.terminalWindowCount == 2, "Closing a window after returning must automatically align the survivors")

        manager.pollTerminalWindows(isHidden: true, isActive: false)
        candidateIDs = [12]
        manager.pollTerminalWindows(isHidden: false, isActive: true)
        expect(layoutWrites == 3 && manager.terminalWindowCount == 2, "Returning with unchanged live windows must preserve minimized windows instead of forcing a layout")

        manager.pollTerminalWindows(isHidden: true, isActive: false)
        candidateIDs = [12, 13, 14]
        manager.pollTerminalWindows(isHidden: false, isActive: true)
        expect(layoutWrites == 3, "Resuming with an incomplete AppleScript list must wait without enlarging a window")
        liveIDs = [12, 13, 14]
        manager.pollTerminalWindows(isHidden: false, isActive: true)
        expect(layoutWrites == 4 && manager.terminalWindowCount == 3, "The same candidates must be retried after the resumed snapshot becomes complete")
    }

    @MainActor
    static func snapshotFixtures(_ source: String) {
        let fixture = """
        script firstLiveWindow
            property fixtureID : 12
            property fixtureTabs : {1}
            property fixtureVisible : true
        end script
        script closedWindow
            property fixtureID : 13
            property fixtureTabs : {}
            property fixtureVisible : true
        end script
        script lastLiveWindow
            property fixtureID : 14
            property fixtureTabs : {1}
            property fixtureVisible : true
        end script
        script pendingWindow
            property fixtureID : missing value
        end script
        script invalidIDWindow
            property fixtureID : -1
        end script
        script nonnumericIDWindow
            property fixtureID : "not a window ID"
        end script
        script windowSource
            property fixtureWindows : {}
        end script
        set fixtureWindows of windowSource to {missing value, firstLiveWindow, pendingWindow, closedWindow, invalidIDWindow, nonnumericIDWindow, missing value, lastLiveWindow}
        """
        // Alias Terminal dictionary terms so the same loop runs on local script properties.
        let snapshot = source.replacingOccurrences(of: "tell application id \"com.apple.Terminal\"", with: "tell windowSource")
            .replacingOccurrences(of: "in windows", with: "in (fixtureWindows of windowSource)")
            .replacingOccurrences(of: "id of currentWindow", with: "fixtureID of currentWindow")
            .replacingOccurrences(of: "tabs of currentWindow", with: "fixtureTabs of currentWindow")
            .replacingOccurrences(of: "visible of currentWindow", with: "fixtureVisible of currentWindow")
            .replacingOccurrences(of: "return liveWindowIDs", with: "return {liveWindowIDs, fixtureVisible of closedWindow}")
        var error: NSDictionary?
        let result = NSAppleScript(source: fixture + "\n" + snapshot)!.executeAndReturnError(&error)
        expect(error == nil, "Stale window references must not abort a snapshot: \(error?.description ?? "")")
        let ids = result.atIndex(1)
        expect(ids?.numberOfItems == 2 && ids?.atIndex(1)?.int32Value == 12 && ids?.atIndex(2)?.int32Value == 14, "Snapshots must preserve live windows before and after stale, pending, nonnumeric, negative-ID and zero-tab windows")
        expect(result.atIndex(2)?.booleanValue == false, "Snapshots must still hide zero-tab frames without closing live sessions")

        let indexRaceSnapshot = snapshot.replacingOccurrences(
            of: "set currentID to fixtureID of currentWindow",
            with: "if currentWindow is closedWindow then error \"Invalid index\" number -1719\nset currentID to fixtureID of currentWindow"
        )
        error = nil
        let indexRaceResult = NSAppleScript(source: fixture + "\n" + indexRaceSnapshot)!.executeAndReturnError(&error)
        expect(error == nil && indexRaceResult.atIndex(1)?.numberOfItems == 2, "Mid-poll window closures throwing -1719 (errAEIllegalIndex) must be skipped instead of failing automation")

        for number in [-1743, -10000] {
            let failingSnapshot = snapshot.replacingOccurrences(of: "set currentID to fixtureID of currentWindow", with: "error \"Unexpected window read failure\" number \(number)")
            error = nil
            _ = NSAppleScript(source: fixture + "\n" + failingSnapshot)!.executeAndReturnError(&error)
            expect((error?[NSAppleScript.errorNumber] as? NSNumber)?.intValue == number, "Snapshot filtering must propagate permission failures and unexpected AppleEvent errors (\(number))")
        }
    }

    @MainActor
    static func shortcutFailures() {
        expect(GlobalShortcut.allCases.count == 6, "All five shortcut choices and disabled must remain available")
        expect(Set(GlobalShortcut.allCases.map(\.menuTitle)).count == 6, "Shortcut menu choices must have distinct labels")
        expect(GlobalShortcut.commandP.displayName == "⌘P" && GlobalShortcut.commandO.displayName == "⌘O", "Print/open shortcut warnings must match key choices")
        expect(GlobalHotKeyController.registrationFailure(.commandO, status: OSStatus(eventHotKeyExistsErr)).contains("占用"), "Exclusive-key conflicts must identify the conflict")
        let unexpected = GlobalHotKeyController.registrationFailure(.commandO, status: -50)
        expect(unexpected.contains("-50") && !unexpected.contains("占用"), "Non-conflict errors must retain OSStatus instead of falsely blaming another app")
        // Do not register any global key or persist a real user preference.
        GlobalHotKeyController.shared.setShortcut(.disabled, persist: false)
        expect(GlobalHotKeyController.shared.selectedShortcut == .disabled && GlobalHotKeyController.shared.registrationError == nil, "Disabling an unregistered shortcut must not leave an error")
    }

    static func receiptValidation() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("termyes-receipt-tests-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: root) }
        let receipt = root.appendingPathComponent("claude.json")
        func result(_ text: String) throws -> String? {
            try text.write(to: receipt, atomically: true, encoding: .utf8)
            return ScheduledContinueController.awaitWindowContinue(.claude, resultDirectory: root.path, timeout: 0.1)
        }
        try expect(try result(#"{"code":0,"hasReply":true,"detail":null}"#) == nil, "A completed successful receipt must be accepted")
        try expect(try result(#"{"code":0,"hasReply":true,"detail":"warning only"}"#) == nil, "Warnings must not invalidate a real successful stdout reply")
        try expect(try result(#"{"code":0,"hasReply":false,"detail":null}"#) != nil, "A zero exit without a reply must fail")
        try expect(try result(#"{"code":0,"hasReply":false,"detail":"stderr only"}"#)?.contains("stderr only") == true, "Stderr-only failures must remain visible without counting as a reply")
        try expect(try result(#"{"code":7,"hasReply":true,"detail":"authentication failed"}"#)?.contains("authentication failed") == true, "A reply cannot hide the nonzero CLI exit code")
        try expect(try result(#"{"code":-1,"hasReply":false,"detail":"执行超时"}"#)?.contains("超时") == true, "Helper timeout diagnostics must survive receipt parsing")
        for invalid in ["not JSON", "[]", "{}", #"{"code":"0","hasReply":true}"#, #"{"code":0,"hasReply":"true"}"#, #"{"code":false,"hasReply":true}"#, #"{"code":0,"hasReply":1}"#, #"{"code":0,"hasReply":true,"detail":17}"#] {
            try expect(try result(invalid) != nil, "Malformed or wrong-type receipts must not masquerade as success: \(invalid)")
        }
        // A successful receipt belonging to another client is not this client's reply.
        try #"{"code":0,"hasReply":true,"detail":null}"#.write(to: receipt, atomically: true, encoding: .utf8)
        try fm.moveItem(at: receipt, to: root.appendingPathComponent("codex.json"))
        let start = Date()
        let missing = ScheduledContinueController.awaitWindowContinue(.claude, resultDirectory: root.path, timeout: 0.1)
        expect(missing?.contains("超时") == true && Date().timeIntervalSince(start) < 1, "Missing per-client receipts must time out within the configured bound")
    }

    @MainActor
    static func scheduledContinue() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("termyes-menu-regression-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root.appendingPathComponent(".local/bin"), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let suite = "termyes-menu-regression.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        func write(_ name: String, _ text: String) throws {
            try text.write(to: root.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        func remove(_ name: String) {
            try? fm.removeItem(at: root.appendingPathComponent(name))
        }
        func exists(_ name: String) -> Bool {
            fm.fileExists(atPath: root.appendingPathComponent(name).path)
        }
        func callCount(_ agent: ContinueAgent) -> Int {
            let text = (try? String(contentsOf: root.appendingPathComponent(agent.rawValue + "-calls"), encoding: .utf8)) ?? ""
            return text.split(separator: "\n").count
        }
        let agentScript = """
        #!/bin/sh
        agent=$(/usr/bin/basename "$0")
        /usr/bin/printf '%s\\n' "$HOME" "$PATH" > "$HOME/$agent-env"
        /usr/bin/printf 'request\\n' >> "$HOME/$agent-calls"
        /usr/bin/touch "$HOME/$agent-started"
        /bin/cat > "$HOME/$agent-stdin"
        mode_file="$HOME/$agent-request-mode"
        if [ ! -f "$mode_file" ]; then mode_file="$HOME/request-mode"; fi
        mode=$(/bin/cat "$mode_file")
        case "$mode" in
          delay) /bin/sleep 0.3; /usr/bin/printf 'received\\n' ;;
          slow) /bin/sleep 1; /usr/bin/printf 'received\\n' ;;
          empty) exit 0 ;;
          stderr) /usr/bin/printf 'warning only\\n' >&2 ;;
          fail) /usr/bin/printf 'partial reply\\n'; /usr/bin/printf 'authentication failed\\n' >&2; exit 7 ;;
          *) /usr/bin/printf 'received\\n' ;;
        esac
        """
        for agent in ContinueAgent.allCases {
            let name = ".local/bin/\(agent.rawValue)"
            try write(name, agentScript)
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.appendingPathComponent(name).path)
            expect(agent.executablePath(home: root.path) == root.appendingPathComponent(name).path, "Temporary HOME wrappers must precede installed agents")
        }
        let managerURL = root.appendingPathComponent("fake-manage.py")
        try write("fake-manage.py", """
        import os, sys, time
        from pathlib import Path
        home = Path(os.environ['HOME'])
        assert sys.argv[1] == 'ensure' and sys.argv[2] in ('claude', 'codex')
        (home / 'ensure-started').touch()
        mode = (home / 'ensure-mode').read_text()
        if mode == 'delay': time.sleep(0.3)
        if mode == 'fail' or mode == 'fail-' + sys.argv[2]:
            print('fake guard permission denied', file=sys.stderr)
            sys.exit(8)
        print('ready')
        """)
        try write("ensure-mode", "success")
        try write("request-mode", "success")
        var windowFailures: [ContinueAgent: String] = [:]
        var windowCalls = 0
        var closeCalls = 0
        var closedAgents: [ContinueAgent] = []
        var openedAgents: [[ContinueAgent]] = []
        var resultDirectories: [String] = []
        var fakeWindows: [Task<Void, Never>] = []
        let controller = ScheduledContinueController(defaults: defaults, home: root.path, manager: managerURL.path, openAgentWindows: { agents, script, resultDirectory in
            windowCalls += 1
            openedAgents.append(agents)
            resultDirectories.append(resultDirectory)
            expect(script == root.appendingPathComponent("continue_task.py").path, "Windows must receive the bundled continue helper, not the guard manager")
            let directory = URL(fileURLWithPath: resultDirectory)
            expect(directory.resolvingSymlinksInPath().path == resultDirectory, "Result directories must be canonical before reaching Terminal")
            let attributes = try! fm.attributesOfItem(atPath: resultDirectory)
            expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700, "Window receipts must live in an owner-only directory")
            for agent in agents where windowFailures[agent] == nil {
                // Emulate a dedicated window with only the temporary fake executable.
                // Production helper CLI/environment contracts are tested separately in Python.
                fakeWindows.append(Task.detached {
                    let execution = ScheduledContinueController.run(root.appendingPathComponent(".local/bin/" + agent.rawValue).path, [], home: root.path)
                    let record: [String: Any] = ["code": Int(execution.code), "hasReply": execution.hasReply, "detail": execution.detail.map { $0 as Any } ?? NSNull()]
                    do {
                        let data = try JSONSerialization.data(withJSONObject: record)
                        let temporary = directory.appendingPathComponent("." + agent.rawValue + ".writing")
                        expect(fm.createFile(atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600]), "Fake windows must create private receipt files")
                        try fm.moveItem(at: temporary, to: directory.appendingPathComponent(agent.rawValue + ".json"))
                    } catch {
                        expect(false, "Fake window could not publish its receipt: \(error)")
                    }
                })
            }
            return agents.compactMap { agent in windowFailures[agent].map { agent.rawValue + "：" + $0 } }
        }, closeAgentWindow: { agent in
            closedAgents.append(agent)
        }, closeAgentWindows: {
            closeCalls += 1
        })
        defer { controller.setWindowSchedule(minutes: nil, agents: []) }
        expect(controller.windowStartMinutes == nil && controller.windowAgents == [.claude, .codex], "A new schedule must be disabled and default to both supported agents")
        controller.continueNow()
        await waitUntil { !controller.continuing }
        expect(controller.lastContinueStatus == "继续请求成功（2/2）" && controller.lastContinueDetail == nil, "Manual continue must consume the two window receipts")
        expect(Set(closedAgents) == Set(ContinueAgent.allCases), "Successful Agent windows must close as soon as their receipts arrive")
        expect(closeCalls == 1, "A finished manual continue must close the dedicated windows it opened")
        expect(controller.windowStartMinutes == nil && defaults.object(forKey: "autoContinueWindowAnchorDate") == nil && controller.nextContinueDate == nil && scheduledTimer(controller) == nil, "Manual continue must not enable a timer, advertise a next firing, or create an anchor")
        expect(callCount(.claude) == 1 && callCount(.codex) == 1 && windowCalls == 1, "Only the fake windows may make a request; no second background model request is allowed")
        for agent in ContinueAgent.allCases {
            let env = try String(contentsOf: root.appendingPathComponent(agent.rawValue + "-env"), encoding: .utf8)
            expect(env.hasPrefix(root.path + "\n" + root.path + "/.local/bin:"), "Fake processes must remain in temporary HOME with wrapper precedence")
            try expect(try Data(contentsOf: root.appendingPathComponent(agent.rawValue + "-stdin")).isEmpty, "Noninteractive requests must receive EOF on stdin")
        }
        expect(!fm.fileExists(atPath: resultDirectories.last!), "Finished continue directories must be removed")
        controller.setWindowSchedule(minutes: -1, agents: [.claude])
        controller.setWindowSchedule(minutes: 1440, agents: [.claude])
        controller.setWindowSchedule(minutes: 600, agents: [])
        expect(controller.windowStartMinutes == nil, "Invalid minutes/empty selections must not enable the schedule")
        controller.setWindowSchedule(minutes: 600, agents: [.claude])
        let anchor = defaults.object(forKey: "autoContinueWindowAnchorDate") as? Date
        expect(anchor != nil && controller.windowScheduleDescription == "10:00", "Valid settings must persist an anchor and expose their menu label")
        let beforeAgentConfirmation = Date()
        controller.setWindowSchedule(minutes: 600, agents: [.codex])
        let afterAgentConfirmation = Date()
        let confirmedAnchor = defaults.object(forKey: "autoContinueWindowAnchorDate") as? Date
        expect(confirmedAnchor == ContinueSchedule.firstAnchor(minutes: 600, after: beforeAgentConfirmation) || confirmedAnchor == ContinueSchedule.firstAnchor(minutes: 600, after: afterAgentConfirmation), "Confirming only an agent change must also start at the next selected HH:mm")
        expectScheduledTimer(controller)
        expect(defaults.stringArray(forKey: "autoContinueWindowAgents") == ["codex"], "Selections must persist deterministically")
        let restored = ScheduledContinueController(defaults: defaults, home: root.path, manager: managerURL.path, openAgentWindows: { _, _, _ in [] }, closeAgentWindows: {
            expect(false, "Restoring saved settings must not close any window")
        })
        defer { restored.setWindowSchedule(minutes: nil, agents: []) }
        expect(restored.windowStartMinutes == 600 && restored.windowAgents == [.codex], "Saved schedule settings must restore")
        controller.setWindowSchedule(minutes: 600, agents: [.claude, .codex])
        let beforeTimer = windowCalls
        let beforeTimerClose = closeCalls
        trigger(controller)
        await waitUntil { !controller.continuing }
        expect(controller.lastContinueStatus == "继续请求成功（2/2）" && windowCalls == beforeTimer + 1, "Timer continue must share the dedicated-window receipt path")
        expect(closeCalls == beforeTimerClose + 1, "A finished timer continue must also close its windows")
        expectScheduledTimer(controller)
        expect(callCount(.claude) == 2 && callCount(.codex) == 2, "Each timer firing must make exactly one request per selected agent")
        expect(ScheduledContinueController.ensureReady(.claude, home: root.path, manager: nil) == "缺少守卫管理器", "A missing bundled manager must be a visible prerequisite failure")
        controller.setWindowSchedule(minutes: 600, agents: [.claude])
        for mode in ["empty", "stderr"] {
            try write("request-mode", mode)
            controller.continueNow()
            await waitUntil { !controller.continuing }
            expect(controller.lastContinueStatus?.contains("1 项失败") == true, "Guard stdout, empty stdout, or stderr alone must not count as a model reply")
            if mode == "stderr" { expect(controller.lastContinueDetail?.contains("warning only") == true, "Stderr-only diagnostics must remain visible") }
        }
        try write("request-mode", "fail")
        let closedBeforeFailure = closedAgents.count
        controller.continueNow()
        await waitUntil { !controller.continuing }
        expect(controller.lastContinueDetail?.contains("authentication failed") == true && controller.lastContinueStatus?.contains("0/1") == true, "A nonzero window request must fail even after returning partial stdout")
        expect(closedAgents.count == closedBeforeFailure + 1 && closedAgents.last == .claude, "A failed Agent window must close after publishing its failure receipt")
        try write("ensure-mode", "fail")
        let beforeFailure = windowCalls
        let beforeGuardFailure = callCount(.claude)
        controller.continueNow()
        await waitUntil { !controller.continuing }
        expect(windowCalls == beforeFailure && callCount(.claude) == beforeGuardFailure, "Guard failures must prevent window opening and all requests")
        expect(controller.lastContinueDetail?.contains("fake guard permission denied") == true, "Guard failures must preserve stderr")
        try write("ensure-mode", "fail-codex")
        try write("request-mode", "success")
        controller.setWindowSchedule(minutes: 600, agents: [.claude, .codex])
        let beforeCodex = callCount(.codex)
        controller.continueNow()
        await waitUntil { !controller.continuing }
        expect(openedAgents.last == [.claude] && callCount(.codex) == beforeCodex && controller.lastContinueStatus?.contains("1/2") == true, "A partial readiness failure must only open the ready client's window")
        try write("ensure-mode", "success")
        windowFailures = [.claude: "fake automation denied"]
        let beforeClaude = callCount(.claude)
        controller.continueNow()
        await waitUntil { !controller.continuing }
        expect(callCount(.claude) == beforeClaude && controller.lastContinueStatus?.contains("1/2") == true && controller.lastContinueDetail?.contains("fake automation denied") == true, "Partial window failures must skip unopened clients and promptly report the other receipt")
        controller.setWindowSchedule(minutes: 600, agents: [.claude])
        controller.continueNow()
        await waitUntil { !controller.continuing }
        expect(controller.lastContinueStatus?.contains("0/1") == true && callCount(.claude) == beforeClaude, "A denied window must not trigger a background fallback or wait for a nonexistent receipt")
        windowFailures = [:]
        controller.setWindowSchedule(minutes: 601, agents: [.claude])
        try write("ensure-mode", "delay")
        remove("ensure-started")
        let beforeCancelledCheck = windowCalls
        controller.continueNow()
        await waitUntil { exists("ensure-started") }
        controller.setWindowSchedule(minutes: 602, agents: [.claude])
        await waitUntil { !controller.continuing }
        expect(windowCalls == beforeCancelledCheck && controller.lastContinueStatus == nil, "Changing time during readiness must abandon the round before opening a window")
        try write("ensure-mode", "success")
        try write("request-mode", "delay")
        remove("claude-started")
        let beforeDelayed = windowCalls
        let beforeDelayedRequest = callCount(.claude)
        controller.continueNow()
        await waitUntil { exists("claude-started") }
        controller.continueNow()
        trigger(controller)
        controller.setWindowSchedule(minutes: nil, agents: [.claude])
        await waitUntil { !controller.continuing }
        expect(windowCalls == beforeDelayed + 1 && callCount(.claude) == beforeDelayedRequest + 1, "Manual and timer continue must share the same reentrancy guard")
        expect(controller.lastContinueStatus == nil && controller.lastContinueDetail == nil, "A disabled schedule must not be overwritten by its in-flight window receipt")
        expect(defaults.object(forKey: "autoContinueWindowAnchorDate") == nil && controller.windowScheduleDescription == "关闭" && controller.nextContinueDate == nil && scheduledTimer(controller) == nil, "Disable must remove its anchor and timer, clear the next firing, and report disabled")
        controller.setWindowSchedule(minutes: 603, agents: [.claude])
        remove("claude-started")
        controller.continueNow()
        await waitUntil { exists("claude-started") }
        controller.setWindowSchedule(minutes: 604, agents: [.codex])
        await waitUntil { !controller.continuing }
        expect(controller.lastContinueStatus == nil, "Changing agents must not publish an obsolete window success")
        try write("request-mode", "success")
        let nextBeforeManual = controller.nextContinueDate
        let anchorBeforeManual = defaults.object(forKey: "autoContinueWindowAnchorDate") as? Date
        let timerBeforeManual = scheduledTimer(controller)
        controller.continueNow()
        await waitUntil { !controller.continuing }
        expect(openedAgents.last == [.codex] && controller.lastContinueStatus == "继续请求成功（1/1）", "A subsequent round must only use the current selection")
        expect(nextBeforeManual != nil && controller.nextContinueDate == nextBeforeManual && scheduledTimer(controller) === timerBeforeManual && defaults.object(forKey: "autoContinueWindowAnchorDate") as? Date == anchorBeforeManual, "Manual continue must not reset the confirmed anchor or replace/change its next timer")
        expectScheduledTimer(controller)
        try write("claude-request-mode", "slow")
        try write("codex-request-mode", "success")
        controller.setWindowSchedule(minutes: 605, agents: [.claude, .codex])
        let closedBeforeStaggered = closedAgents.count
        controller.continueNow()
        await waitUntil { closedAgents.dropFirst(closedBeforeStaggered).contains(.codex) }
        expect(controller.continuing && !closedAgents.dropFirst(closedBeforeStaggered).contains(.claude), "A completed Agent window must close while another Agent is still running")
        await waitUntil { !controller.continuing }
        expect(Set(closedAgents.dropFirst(closedBeforeStaggered)) == Set(ContinueAgent.allCases), "The remaining Agent window must close when its result arrives")
        remove("claude-request-mode")
        remove("codex-request-mode")
        expect(Set(resultDirectories).count == resultDirectories.count, "Every continue round must have an isolated result directory; stale receipts cannot be reused")
        expect(resultDirectories.allSatisfy { !fm.fileExists(atPath: $0) }, "Success, failure, and cancelled window result directories must all be cleaned")
        for task in fakeWindows { await task.value }
        let missing = ScheduledContinueController.run(root.appendingPathComponent("missing-executable").path, [], home: root.path)
        expect(missing.code == -1 && missing.detail != nil, "Launch errors must retain their underlying diagnostic")
        let beforeTimeout = Date()
        let timeout = ScheduledContinueController.run("/usr/bin/python3", ["-c", "import signal,time; signal.signal(signal.SIGTERM, signal.SIG_IGN); time.sleep(30)"], home: root.path, timeout: 0.2)
        expect(timeout.code == -1 && timeout.detail?.contains("超时") == true, "A child ignoring SIGTERM must still produce a timeout failure")
        expect(Date().timeIntervalSince(beforeTimeout) < 5, "Timeout escalation must bound the blocking wait")
    }

    @MainActor
    static func trigger(_ controller: ScheduledContinueController) {
        controller.perform(NSSelectorFromString("windowOpened"))
    }

    @MainActor
    static func waitUntil(_ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(5)
        while !condition() && Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        expect(condition(), "Asynchronous continue should finish within the fake-process deadline")
    }
}
