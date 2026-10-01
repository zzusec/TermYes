import Foundation

enum ScheduledAgent: String, CaseIterable {
    case claude, codex

    func executablePath(home: String) -> String? {
        let paths = ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
        return paths.map { "\($0)/\(rawValue)" }
            .first(where: { FileManager.default.isExecutableFile(atPath: $0) })
    }

    var activationArguments: [String] {
        switch self {
        case .claude: return ["-p", FiveHourActivation.prompt]
        case .codex: return ["exec", "--skip-git-repo-check", FiveHourActivation.prompt]
        }
    }

    func startupCommand(guardPath: String) -> String {
        let quotedPath = guardPath.replacingOccurrences(of: "'", with: "'\\''")
        return "/usr/bin/python3 -B '\(quotedPath)' ensure \(rawValue) && export PATH=\"$HOME/.local/bin:$PATH\" && exec \(rawValue)"
    }
}

enum FiveHourActivation {
    static let prompt = "你好，请只回复收到，不要调用工具或修改文件。"
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

enum TerminalResumePolicy {
    static let appleScriptHandlers = """
    on mustPauseResume(screenText)
        ignoring case
            repeat with marker in {"y/n", "yes/no", "want to continue", "输入 yes", "是否继续", "确认继续", "requires approval", "approval required", "would you like", "allow this", "approve", "permission denied", "命令守卫", "已拦截", "已拦下", "guard blocked", "hook failed", "blocked by", "password", "passphrase", "verification code", "密码", "验证码", "登录", "sign in", "trust", "授权", "拒绝", "确认", "choose", "请选择"}
                if screenText contains (marker as text) then return true
            end repeat
        end ignoring
        return false
    end mustPauseResume

    """
}
