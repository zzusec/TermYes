import AppKit

@main
struct TerminalResumeTests {
    static func main() {
        precondition(FiveHourActivation.selectedAgents(from: nil) == [.claude, .codex])
        precondition(FiveHourActivation.selectedAgents(from: ["codex"]) == [.codex])
        precondition(FiveHourActivation.selectedAgents(from: ["codex", "unknown", "codex"]) == [.codex])
        precondition(FiveHourActivation.selectedAgents(from: []) == [])
        let now = Date(timeIntervalSince1970: 100_000)
        var utcCalendar = Calendar(identifier: .gregorian)
        utcCalendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let beforeStart = Date(timeIntervalSince1970: 86_400 + 8 * 3600)
        let afterStart = Date(timeIntervalSince1970: 86_400 + 10 * 3600)
        precondition(FiveHourActivation.firstAnchor(minutes: 9 * 60, after: beforeStart, calendar: utcCalendar) == Date(timeIntervalSince1970: 86_400 + 9 * 3600))
        precondition(FiveHourActivation.firstAnchor(minutes: 9 * 60, after: afterStart, calendar: utcCalendar) == Date(timeIntervalSince1970: 2 * 86_400 + 9 * 3600))
        precondition(FiveHourActivation.nextFire(after: now, anchor: now.addingTimeInterval(60)) == now.addingTimeInterval(60))
        precondition(FiveHourActivation.nextFire(after: now, anchor: now) == now.addingTimeInterval(FiveHourActivation.interval))
        precondition(FiveHourActivation.nextFire(after: now.addingTimeInterval(2 * FiveHourActivation.interval + 1), anchor: now) == now.addingTimeInterval(3 * FiveHourActivation.interval))
        precondition(ScheduledAgent.claude.activationArguments == ["-p", FiveHourActivation.prompt])
        precondition(ScheduledAgent.codex.activationArguments == ["exec", "--skip-git-repo-check", FiveHourActivation.prompt])
        precondition(ScheduledAgent.codex.startupCommand(guardPath: "/a'b/manage.py").contains("'/a'\\''b/manage.py' ensure codex"))

        func evaluate(_ text: String) -> Bool? {
            let escaped = text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            let source = TerminalResumePolicy.appleScriptHandlers + "\nreturn mustPauseResume(\"\(escaped)\")"
            var error: NSDictionary?
            guard let script = NSAppleScript(source: source) else { fatalError("Invalid policy script") }
            let result = script.executeAndReturnError(&error)
            if (error?[NSAppleScript.errorNumber] as? Int) == -600 {
                return nil
            }
            precondition(error == nil, "\(String(describing: error))")
            return result.booleanValue
        }
        for text in ["Proceed? (y/n)", "YES/NO", "是否继续", "[命令守卫] 已拦截", "Permission denied",
                     "Would you like to run this command?", "Password:", "需要授权", "Hook failed", "Trust this hook?"] {
            guard let result = evaluate(text) else {
                print("Terminal resume policy tests skipped: AppleScript unavailable in this environment.")
                return
            }
            precondition(result, "Must not type into: \(text)")
        }
        guard let normal = evaluate("Usage limit reached; retry later") else {
            print("Terminal resume policy tests skipped: AppleScript unavailable in this environment.")
            return
        }
        guard let interrupted = evaluate("Connection interrupted") else {
            print("Terminal resume policy tests skipped: AppleScript unavailable in this environment.")
            return
        }
        precondition(!normal)
        precondition(!interrupted)
        print("Terminal resume policy tests passed (no Terminal events sent).")
    }
}
