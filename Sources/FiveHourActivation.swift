import Foundation

enum ScheduledAgent: String, CaseIterable {
    case claude, codex

    func executablePath(home: String) -> String? {
        let paths = ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
        return paths.map { "\($0)/\(rawValue)" }
            .first(where: { FileManager.default.isExecutableFile(atPath: $0) })
    }

    func activationCommand(scriptPath: String, resultDirectory: String) -> String {
        func quote(_ value: String) -> String {
            "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }
        return "/usr/bin/python3 -B \(quote(scriptPath)) \(rawValue) --result-dir \(quote(resultDirectory))"
    }

}

enum FiveHourActivation {
    static let interval: TimeInterval = 5 * 60 * 60

    static func selectedAgents(from storedValues: [String]?) -> [ScheduledAgent] {
        guard let storedValues else { return ScheduledAgent.allCases }
        let selected = Set(storedValues.compactMap(ScheduledAgent.init(rawValue:)))
        return ScheduledAgent.allCases.filter { selected.contains($0) }
    }

    static func firstAnchor(minutes: Int, after now: Date, calendar: Calendar = .current) -> Date {
        var components = calendar.dateComponents([.year, .month, .day], from: now)
        components.hour = minutes / 60
        components.minute = minutes % 60
        components.second = 0
        let today = calendar.date(from: components)!
        return today > now ? today : calendar.date(byAdding: .day, value: 1, to: today)!
    }

    static func nextFire(after now: Date, anchor: Date) -> Date {
        guard now >= anchor else { return anchor }
        let cycles = floor(now.timeIntervalSince(anchor) / interval) + 1
        return anchor.addingTimeInterval(cycles * interval)
    }
}
