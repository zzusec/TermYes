import Foundation

@main
struct FiveHourActivationTests {
    static func main() throws {
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
        arbitraryStartTimesAndFiveHourCadence()
        try activationCommands()

        print("Five-hour activation tests passed.")
    }

    static func arbitraryStartTimesAndFiveHourCadence() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let day = Date(timeIntervalSince1970: 86_400)
        precondition(FiveHourActivation.interval == 5 * 3600, "The cadence must remain exactly five elapsed hours")
        for minutes in 0..<1440 {
            let selected = day.addingTimeInterval(TimeInterval(minutes * 60))
            precondition(FiveHourActivation.firstAnchor(minutes: minutes, after: selected.addingTimeInterval(-1), calendar: calendar) == selected, "Any HH:mm must be selectable, including midnight and 23:59: \(minutes)")
            for offset: TimeInterval in [0, 1] {
                precondition(FiveHourActivation.firstAnchor(minutes: minutes, after: selected.addingTimeInterval(offset), calendar: calendar) == selected.addingTimeInterval(86_400), "A time already reached must start tomorrow, not fire immediately: \(minutes)")
            }
            precondition(FiveHourActivation.nextFire(after: selected.addingTimeInterval(-1), anchor: selected) == selected, "The initial firing must use the selected HH:mm: \(minutes)")
            for cycle in 0...10 {
                let boundary = selected.addingTimeInterval(TimeInterval(cycle) * FiveHourActivation.interval)
                let following = boundary.addingTimeInterval(FiveHourActivation.interval)
                precondition(FiveHourActivation.nextFire(after: boundary.addingTimeInterval(-1), anchor: selected) == boundary, "Cross-day firings must not snap back to the selected wall time: \(minutes), cycle \(cycle)")
                for offset: TimeInterval in [0, 1] {
                    precondition(FiveHourActivation.nextFire(after: boundary.addingTimeInterval(offset), anchor: selected) == following, "Exact or missed boundaries must advance along the same five-hour timeline: \(minutes), cycle \(cycle)")
                }
            }
        }
        // 05:17 is one example, not a fixed daily start: 20:17 is followed by 01:17.
        let example = day.addingTimeInterval(TimeInterval((5 * 60 + 17) * 60))
        let nextDay = FiveHourActivation.nextFire(after: example.addingTimeInterval(3 * FiveHourActivation.interval), anchor: example)
        let components = calendar.dateComponents([.day, .hour, .minute], from: nextDay)
        precondition(components.day == 3 && components.hour == 1 && components.minute == 17, "A five-hour cycle must continue across midnight rather than repeat 05:17 every day")
    }

    static func activationCommands() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("termyes-command-test-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: root) }
        let script = root.appendingPathComponent("activate ' \" $ \\ `.py")
        try """
        import json, sys
        from pathlib import Path
        (Path(sys.argv[3]) / 'argv.json').write_text(json.dumps(sys.argv[1:]))
        """.write(to: script, atomically: true, encoding: .utf8)
        for agent in ScheduledAgent.allCases {
            let directory = root.appendingPathComponent("\(agent.rawValue) ' \" $ \\ `", isDirectory: true)
            try fm.createDirectory(at: directory, withIntermediateDirectories: false)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            let command = agent.activationCommand(scriptPath: script.path, resultDirectory: directory.path)
            precondition(command.hasPrefix("/usr/bin/python3 -B "), "Activation must use the bundled Python helper without bytecode writes")
            process.arguments = ["-f", "-c", command]
            process.currentDirectoryURL = root
            process.standardInput = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            precondition(process.terminationStatus == 0, "Quoted activation commands must execute the fake helper")
            let value = try JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("argv.json")))
            precondition(value as? [String] == [agent.rawValue, "--result-dir", directory.path], "Helper arguments must survive shell quoting unchanged")
        }
    }
}
