import Foundation

@main
struct FiveHourActivationTests {
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

        print("Five-hour activation tests passed.")
    }
}
