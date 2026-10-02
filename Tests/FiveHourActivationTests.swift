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
        try activationCommands()

        print("Five-hour activation tests passed.")
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
