// swiftc Sources/{GridLayout,FiveHourActivation,TerminalManager,GlobalHotKeyController,ScheduledActivationController,WindowSchedulePicker}.swift Tests/menu_activation_regression.swift -o /tmp/termyes-menu-regression
// This suite compiles but never executes Terminal AppleScripts. Agent processes and
// guard management use executables in a temporary HOME, never installed user agents.
import AppKit
import Carbon.HIToolbox
import Foundation

@main
struct MenuActivationRegression {
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
        shortcutFailures()
        try await scheduledActivation()
        try receiptValidation()
        print("Menu activation regression tests passed (Terminal script compilation/error handling, shortcuts, schedule persistence/cancellation, dedicated-window receipts, explicit schedule reconfirmation/next timer date, fake requests/timeouts).")
    }

    @MainActor
    static func scheduleReconfirmation() {
        let confirmations: [(Int, Set<ScheduledAgent>)] = [(10, [.claude]), (-10, [.claude]), (10, [.codex])]
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
            let controller = ScheduledActivationController(defaults: defaults, home: FileManager.default.temporaryDirectory.path, manager: nil, openAgentWindows: { _, _, _ in
                expect(false, "Reconfirming or restoring a schedule must not open any agent window")
                return []
            })
            defer { controller.setWindowSchedule(minutes: nil, agents: []) }
            expect(controller.nextActivationDate == nil, "A controller not yet started must not advertise an unscheduled timer")
            let beforeStart = Date()
            controller.start()
            let afterStart = Date()
            expect(defaults.object(forKey: "autoContinueWindowAnchorDate") as? Date == oldAnchor, "Startup must preserve the saved five-hour timeline until explicit confirmation")
            expect(controller.nextActivationDate == FiveHourActivation.nextFire(after: beforeStart, anchor: oldAnchor) || controller.nextActivationDate == FiveHourActivation.nextFire(after: afterStart, anchor: oldAnchor), "Restored cross-day schedules must expose the actual next five-hour boundary, not the original HH:mm")
            expectScheduledTimer(controller)
            let oldTimer = scheduledTimer(controller)!
            let before = Date()
            controller.setWindowSchedule(minutes: minutes, agents: agents)
            let after = Date()
            let anchor = defaults.object(forKey: "autoContinueWindowAnchorDate") as? Date
            expect(anchor != oldAnchor, "Confirming the saved minutes, even with unchanged agents, must replace yesterday's anchor (old: \(oldAnchor), saved: \(String(describing: anchor)))")
            expect(anchor == FiveHourActivation.firstAnchor(minutes: minutes, after: before) || anchor == FiveHourActivation.firstAnchor(minutes: minutes, after: after), "Confirmation must restart at the next occurrence of the freely selected HH:mm")
            expect(!oldTimer.isValid, "Confirmation must cancel the old timeline's timer")
            expect(controller.nextActivationDate == anchor, "The replacement timer must fire at the newly confirmed anchor")
            if offset < 0 {
                expect(!calendar.isDate(anchor!, inSameDayAs: after), "A past HH:mm must start on the next day, not continue yesterday's cycle")
            }
            expect(controller.windowScheduleDescription == String(format: "%02d:%02d", minutes / 60, minutes % 60), "The picker label must show the freely selected HH:mm without implying it repeats daily")
            expectScheduledTimer(controller)
            let restored = ScheduledActivationController(defaults: defaults, home: FileManager.default.temporaryDirectory.path, manager: nil, openAgentWindows: { _, _, _ in
                expect(false, "Restart restoration must only schedule, never open an agent window")
                return []
            })
            defer { restored.setWindowSchedule(minutes: nil, agents: []) }
            restored.start()
            expect(restored.windowStartMinutes == minutes && restored.windowAgents == agents, "A restart must restore the confirmed arbitrary time and agent selection")
            expect(defaults.object(forKey: "autoContinueWindowAnchorDate") as? Date == anchor && restored.nextActivationDate == anchor, "A restart must retain the confirmed timeline without reconfirming the picker")
            expectScheduledTimer(restored)
            let activeTimer = scheduledTimer(controller)!
            controller.setWindowSchedule(minutes: nil, agents: [.claude])
            expect(!activeTimer.isValid && scheduledTimer(controller) == nil && controller.nextActivationDate == nil, "Disabling must invalidate the real timer and clear the advertised next activation")
            expect(defaults.object(forKey: "autoContinueWindowAnchorDate") == nil && controller.windowScheduleDescription == "关闭", "Disable must remove the persisted anchor and report disabled")
            expect(controller.nextActivationDescription == "未启用", "Disabled menus must not keep showing the previous firing date")
        }
    }

    @MainActor
    static func scheduledTimer(_ controller: ScheduledActivationController) -> Timer? {
        Mirror(reflecting: controller).children.first { $0.label == "windowTimer" }?.value as? Timer
    }

    @MainActor
    static func expectScheduledTimer(_ controller: ScheduledActivationController) {
        guard let date = controller.nextActivationDate else {
            expect(false, "An enabled schedule must expose its next activation date")
            return
        }
        let timer = scheduledTimer(controller)
        expect(timer?.isValid == true && timer?.fireDate == date, "The published next activation must exactly match the live Timer.fireDate")
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.calendar = .current
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd HH:mm z"
        expect(controller.nextActivationDescription.contains(formatter.string(from: date)), "The menu must show the next timer's complete local date, 24-hour time, and timezone: \(controller.nextActivationDescription)")
    }

    @MainActor
    static func terminalScripts() throws {
        var scripts: [String] = []
        var result = NSAppleEventDescriptor(boolean: true)
        var error: NSDictionary?
        let manager = TerminalManager(scriptExecutor: { source in
            scripts.append(source)
            var compilationError: NSDictionary?
            expect(NSAppleScript(source: source)!.compileAndReturnError(&compilationError), "Terminal script must compile: \(compilationError?.description ?? source)")
            return (result, error)
        })
        result = .init(boolean: true)
        expect(manager.openAgentActivationWindows([.claude, .codex], scriptPath: "/a'b/with \"quotes\"/activate.py", resultDirectory: "/result's/with \"quotes\"").isEmpty, "Window-start scripts must compile with quoted bundle paths")
        expect(scripts.suffix(2).allSatisfy { $0.contains("do script ") && !$0.contains("every window") && !$0.contains("tabRef") && !$0.contains("in window") && !$0.contains("selected tab") && !$0.contains("return false") && !$0.contains("try") }, "Each activation must create a dedicated window without inspecting, skipping, or targeting user sessions")
        expect(manager.applyWindowLayout(windowIDs: [12, 13], frames: [CGRect(x: 0, y: 30, width: 500, height: 800), CGRect(x: 500, y: 30, width: 500, height: 800)]), "Layout script must compile")
        expect(scripts.last?.contains("try") == false, "Layout must not silently report success after per-window errors")
        error = [NSAppleScript.errorNumber: -1743, NSAppleScript.errorMessage: "Not authorized"]
        expect(!manager.applyWindowLayout(windowIDs: [12], frames: [.zero]), "Denied automation must fail layout")
        expect(!manager.automationAuthorized && manager.phase == .needsAutomationPermission, "Permission denial must expose the automation-settings route")
        expect(!manager.openAgentActivationWindows([.claude], scriptPath: "/fake/activate.py", resultDirectory: "/fake/results").isEmpty, "Denied window creation must report a failure")
        error = [NSAppleScript.errorNumber: -10000, NSAppleScript.errorMessage: "Window write failed"]
        expect(!manager.applyWindowLayout(windowIDs: [12], frames: [.zero]), "Layout failures must be returned")
        expect(manager.phase == .error("Terminal 自动化失败：Window write failed"), "Automation failures must retain actual error details")
        error = nil
        result = .init(string: "")
        _ = manager.applyWindowLayout(windowIDs: [12], frames: [.zero])
        expect(manager.automationAuthorized, "A successful automation call must clear the permission-denied flag")
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
            return ScheduledActivationController.awaitWindowActivation(.claude, resultDirectory: root.path, timeout: 0.1)
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
        let missing = ScheduledActivationController.awaitWindowActivation(.claude, resultDirectory: root.path, timeout: 0.1)
        expect(missing?.contains("超时") == true && Date().timeIntervalSince(start) < 1, "Missing per-client receipts must time out within the configured bound")
    }

    @MainActor
    static func scheduledActivation() async throws {
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
        func callCount(_ agent: ScheduledAgent) -> Int {
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
        mode=$(/bin/cat "$HOME/request-mode")
        case "$mode" in
          delay) /bin/sleep 0.3; /usr/bin/printf 'received\\n' ;;
          empty) exit 0 ;;
          stderr) /usr/bin/printf 'warning only\\n' >&2 ;;
          fail) /usr/bin/printf 'partial reply\\n'; /usr/bin/printf 'authentication failed\\n' >&2; exit 7 ;;
          *) /usr/bin/printf 'received\\n' ;;
        esac
        """
        for agent in ScheduledAgent.allCases {
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
        var windowFailures: [ScheduledAgent: String] = [:]
        var windowCalls = 0
        var openedAgents: [[ScheduledAgent]] = []
        var resultDirectories: [String] = []
        var fakeWindows: [Task<Void, Never>] = []
        let controller = ScheduledActivationController(defaults: defaults, home: root.path, manager: managerURL.path, openAgentWindows: { agents, script, resultDirectory in
            windowCalls += 1
            openedAgents.append(agents)
            resultDirectories.append(resultDirectory)
            expect(script == root.appendingPathComponent("activate.py").path, "Windows must receive the bundled activation helper, not the guard manager")
            let directory = URL(fileURLWithPath: resultDirectory)
            expect(directory.resolvingSymlinksInPath().path == resultDirectory, "Result directories must be canonical before reaching Terminal")
            let attributes = try! fm.attributesOfItem(atPath: resultDirectory)
            expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700, "Window receipts must live in an owner-only directory")
            for agent in agents where windowFailures[agent] == nil {
                // Emulate a dedicated window with only the temporary fake executable.
                // Production helper CLI/environment contracts are tested separately in Python.
                fakeWindows.append(Task.detached {
                    let execution = ScheduledActivationController.run(root.appendingPathComponent(".local/bin/" + agent.rawValue).path, [], home: root.path)
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
        })
        defer { controller.setWindowSchedule(minutes: nil, agents: []) }
        expect(controller.windowStartMinutes == nil && controller.windowAgents == [.claude, .codex], "A new schedule must be disabled and default to both supported agents")
        controller.activateNow()
        await waitUntil { !controller.activating }
        expect(controller.lastActivationStatus == "激活请求成功（2/2）" && controller.lastActivationDetail == nil, "Manual activation must consume the two window receipts")
        expect(controller.windowStartMinutes == nil && defaults.object(forKey: "autoContinueWindowAnchorDate") == nil && controller.nextActivationDate == nil && scheduledTimer(controller) == nil, "Manual activation must not enable a timer, advertise a next firing, or create an anchor")
        expect(callCount(.claude) == 1 && callCount(.codex) == 1 && windowCalls == 1, "Only the fake windows may make a request; no second background model request is allowed")
        for agent in ScheduledAgent.allCases {
            let env = try String(contentsOf: root.appendingPathComponent(agent.rawValue + "-env"), encoding: .utf8)
            expect(env.hasPrefix(root.path + "\n" + root.path + "/.local/bin:"), "Fake processes must remain in temporary HOME with wrapper precedence")
            try expect(try Data(contentsOf: root.appendingPathComponent(agent.rawValue + "-stdin")).isEmpty, "Noninteractive requests must receive EOF on stdin")
        }
        expect(!fm.fileExists(atPath: resultDirectories.last!), "Finished activation directories must be removed")
        controller.setWindowSchedule(minutes: -1, agents: [.claude])
        controller.setWindowSchedule(minutes: 1440, agents: [.claude])
        controller.setWindowSchedule(minutes: 600, agents: [])
        expect(controller.windowStartMinutes == nil, "Invalid minutes/empty selections must not enable activation")
        controller.setWindowSchedule(minutes: 600, agents: [.claude])
        let anchor = defaults.object(forKey: "autoContinueWindowAnchorDate") as? Date
        expect(anchor != nil && controller.windowScheduleDescription == "10:00", "Valid settings must persist an anchor and expose their menu label")
        let beforeAgentConfirmation = Date()
        controller.setWindowSchedule(minutes: 600, agents: [.codex])
        let afterAgentConfirmation = Date()
        let confirmedAnchor = defaults.object(forKey: "autoContinueWindowAnchorDate") as? Date
        expect(confirmedAnchor == FiveHourActivation.firstAnchor(minutes: 600, after: beforeAgentConfirmation) || confirmedAnchor == FiveHourActivation.firstAnchor(minutes: 600, after: afterAgentConfirmation), "Confirming only an agent change must also start at the next selected HH:mm")
        expectScheduledTimer(controller)
        expect(defaults.stringArray(forKey: "autoContinueWindowAgents") == ["codex"], "Selections must persist deterministically")
        let restored = ScheduledActivationController(defaults: defaults, home: root.path, manager: managerURL.path, openAgentWindows: { _, _, _ in [] })
        defer { restored.setWindowSchedule(minutes: nil, agents: []) }
        expect(restored.windowStartMinutes == 600 && restored.windowAgents == [.codex], "Saved schedule settings must restore")
        controller.setWindowSchedule(minutes: 600, agents: [.claude, .codex])
        let beforeTimer = windowCalls
        trigger(controller)
        await waitUntil { !controller.activating }
        expect(controller.lastActivationStatus == "激活请求成功（2/2）" && windowCalls == beforeTimer + 1, "Timer activation must share the dedicated-window receipt path")
        expectScheduledTimer(controller)
        expect(callCount(.claude) == 2 && callCount(.codex) == 2, "Each timer firing must make exactly one request per selected agent")
        expect(ScheduledActivationController.ensureReady(.claude, home: root.path, manager: nil) == "缺少守卫管理器", "A missing bundled manager must be a visible prerequisite failure")
        controller.setWindowSchedule(minutes: 600, agents: [.claude])
        for mode in ["empty", "stderr"] {
            try write("request-mode", mode)
            controller.activateNow()
            await waitUntil { !controller.activating }
            expect(controller.lastActivationStatus?.contains("1 项失败") == true, "Guard stdout, empty stdout, or stderr alone must not count as a model reply")
            if mode == "stderr" { expect(controller.lastActivationDetail?.contains("warning only") == true, "Stderr-only diagnostics must remain visible") }
        }
        try write("request-mode", "fail")
        controller.activateNow()
        await waitUntil { !controller.activating }
        expect(controller.lastActivationDetail?.contains("authentication failed") == true && controller.lastActivationStatus?.contains("0/1") == true, "A nonzero window request must fail even after returning partial stdout")
        try write("ensure-mode", "fail")
        let beforeFailure = windowCalls
        let beforeGuardFailure = callCount(.claude)
        controller.activateNow()
        await waitUntil { !controller.activating }
        expect(windowCalls == beforeFailure && callCount(.claude) == beforeGuardFailure, "Guard failures must prevent window opening and all requests")
        expect(controller.lastActivationDetail?.contains("fake guard permission denied") == true, "Guard failures must preserve stderr")
        try write("ensure-mode", "fail-codex")
        try write("request-mode", "success")
        controller.setWindowSchedule(minutes: 600, agents: [.claude, .codex])
        let beforeCodex = callCount(.codex)
        controller.activateNow()
        await waitUntil { !controller.activating }
        expect(openedAgents.last == [.claude] && callCount(.codex) == beforeCodex && controller.lastActivationStatus?.contains("1/2") == true, "A partial readiness failure must only open the ready client's window")
        try write("ensure-mode", "success")
        windowFailures = [.claude: "fake automation denied"]
        let beforeClaude = callCount(.claude)
        controller.activateNow()
        await waitUntil { !controller.activating }
        expect(callCount(.claude) == beforeClaude && controller.lastActivationStatus?.contains("1/2") == true && controller.lastActivationDetail?.contains("fake automation denied") == true, "Partial window failures must skip unopened clients and promptly report the other receipt")
        controller.setWindowSchedule(minutes: 600, agents: [.claude])
        controller.activateNow()
        await waitUntil { !controller.activating }
        expect(controller.lastActivationStatus?.contains("0/1") == true && callCount(.claude) == beforeClaude, "A denied window must not trigger a background fallback or wait for a nonexistent receipt")
        windowFailures = [:]
        controller.setWindowSchedule(minutes: 601, agents: [.claude])
        try write("ensure-mode", "delay")
        remove("ensure-started")
        let beforeCancelledCheck = windowCalls
        controller.activateNow()
        await waitUntil { exists("ensure-started") }
        controller.setWindowSchedule(minutes: 602, agents: [.claude])
        await waitUntil { !controller.activating }
        expect(windowCalls == beforeCancelledCheck && controller.lastActivationStatus == nil, "Changing time during readiness must abandon activation before opening a window")
        try write("ensure-mode", "success")
        try write("request-mode", "delay")
        remove("claude-started")
        let beforeDelayed = windowCalls
        let beforeDelayedRequest = callCount(.claude)
        controller.activateNow()
        await waitUntil { exists("claude-started") }
        controller.activateNow()
        trigger(controller)
        controller.setWindowSchedule(minutes: nil, agents: [.claude])
        await waitUntil { !controller.activating }
        expect(windowCalls == beforeDelayed + 1 && callCount(.claude) == beforeDelayedRequest + 1, "Manual and timer activation must share the same reentrancy guard")
        expect(controller.lastActivationStatus == nil && controller.lastActivationDetail == nil, "A disabled schedule must not be overwritten by its in-flight window receipt")
        expect(defaults.object(forKey: "autoContinueWindowAnchorDate") == nil && controller.windowScheduleDescription == "关闭" && controller.nextActivationDate == nil && scheduledTimer(controller) == nil, "Disable must remove its anchor and timer, clear the next firing, and report disabled")
        controller.setWindowSchedule(minutes: 603, agents: [.claude])
        remove("claude-started")
        controller.activateNow()
        await waitUntil { exists("claude-started") }
        controller.setWindowSchedule(minutes: 604, agents: [.codex])
        await waitUntil { !controller.activating }
        expect(controller.lastActivationStatus == nil, "Changing agents must not publish an obsolete window success")
        try write("request-mode", "success")
        let nextBeforeManual = controller.nextActivationDate
        let anchorBeforeManual = defaults.object(forKey: "autoContinueWindowAnchorDate") as? Date
        let timerBeforeManual = scheduledTimer(controller)
        controller.activateNow()
        await waitUntil { !controller.activating }
        expect(openedAgents.last == [.codex] && controller.lastActivationStatus == "激活请求成功（1/1）", "A subsequent activation must only use the current selection")
        expect(nextBeforeManual != nil && controller.nextActivationDate == nextBeforeManual && scheduledTimer(controller) === timerBeforeManual && defaults.object(forKey: "autoContinueWindowAnchorDate") as? Date == anchorBeforeManual, "Manual activation must not reset the confirmed anchor or replace/change its next timer")
        expectScheduledTimer(controller)
        expect(Set(resultDirectories).count == resultDirectories.count, "Every activation must have an isolated result directory; stale receipts cannot be reused")
        expect(resultDirectories.allSatisfy { !fm.fileExists(atPath: $0) }, "Success, failure, and cancelled window result directories must all be cleaned")
        for task in fakeWindows { await task.value }
        let missing = ScheduledActivationController.run(root.appendingPathComponent("missing-executable").path, [], home: root.path)
        expect(missing.code == -1 && missing.detail != nil, "Launch errors must retain their underlying diagnostic")
        let beforeTimeout = Date()
        let timeout = ScheduledActivationController.run("/usr/bin/python3", ["-c", "import signal,time; signal.signal(signal.SIGTERM, signal.SIG_IGN); time.sleep(30)"], home: root.path, timeout: 0.2)
        expect(timeout.code == -1 && timeout.detail?.contains("超时") == true, "A child ignoring SIGTERM must still produce a timeout failure")
        expect(Date().timeIntervalSince(beforeTimeout) < 5, "Timeout escalation must bound the blocking wait")
    }

    @MainActor
    static func trigger(_ controller: ScheduledActivationController) {
        controller.perform(NSSelectorFromString("windowOpened"))
    }

    @MainActor
    static func waitUntil(_ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(5)
        while !condition() && Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        expect(condition(), "Asynchronous activation should finish within the fake-process deadline")
    }
}
