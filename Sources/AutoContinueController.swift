import AppKit
import Combine

@MainActor
final class AutoContinueController: NSObject, ObservableObject {
    static let shared = AutoContinueController()

    @Published private(set) var windowStartMinutes: Int?
    @Published private(set) var windowAgents: Set<ScheduledAgent>
    @Published private(set) var lastStatusMessage: String?
    @Published private(set) var lastActivationStatus: String?
    @Published private(set) var lastActivationDetail: String?

    private var windowTimer: Timer?
    private var windowAnchor: Date?
    private var activating = false
    private var started = false

    override private init() {
        let savedMinutes = UserDefaults.standard.object(forKey: "autoContinueWindowStartMinutes") as? Int
        windowStartMinutes = savedMinutes.flatMap { (0..<1440).contains($0) ? $0 : nil }
        windowAgents = Set(FiveHourActivation.selectedAgents(
            from: UserDefaults.standard.stringArray(forKey: "autoContinueWindowAgents")
        ))
        windowAnchor = UserDefaults.standard.object(forKey: "autoContinueWindowAnchorDate") as? Date
        super.init()
    }

    func start() {
        guard !started else { return }
        started = true
        scheduleWindow()
    }

    func setWindowSchedule(minutes: Int?, agents: Set<ScheduledAgent>) {
        if let minutes, !(0..<1440).contains(minutes) { return }
        if minutes != nil && agents.isEmpty { return }
        let timeChanged = minutes != windowStartMinutes
        if !timeChanged && agents == windowAgents { return }
        windowAgents = agents
        UserDefaults.standard.set(agents.map(\.rawValue).sorted(), forKey: "autoContinueWindowAgents")
        windowStartMinutes = minutes
        lastActivationStatus = nil
        lastActivationDetail = nil
        if let minutes {
            UserDefaults.standard.set(minutes, forKey: "autoContinueWindowStartMinutes")
            if timeChanged {
                windowAnchor = FiveHourActivation.firstAnchor(minutes: minutes, after: Date())
                UserDefaults.standard.set(windowAnchor, forKey: "autoContinueWindowAnchorDate")
            }
        } else {
            UserDefaults.standard.set(-1, forKey: "autoContinueWindowStartMinutes")
            UserDefaults.standard.removeObject(forKey: "autoContinueWindowAnchorDate")
            windowAnchor = nil
        }
        scheduleWindow()
    }

    var windowScheduleDescription: String {
        guard let windowStartMinutes else { return "关闭" }
        return String(format: "%02d:%02d 起", windowStartMinutes / 60, windowStartMinutes % 60)
    }

    /// Today's anchor date, used to seed the time picker.
    var windowStartDate: Date? {
        guard let windowStartMinutes else { return nil }
        var components = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        components.hour = windowStartMinutes / 60
        components.minute = windowStartMinutes % 60
        components.second = 0
        return Calendar.current.date(from: components)
    }

    func sendNow() {
        guard let result = TerminalManager.shared.sendContinueToTerminalSessions() else {
            lastStatusMessage = "无法检查 Terminal 会话"
            return
        }
        if result.sent > 0 {
            lastStatusMessage = "已手动继续 \(result.sent) 个会话"
            if result.blocked > 0 {
                lastStatusMessage = (lastStatusMessage ?? "") + "；跳过 \(result.blocked) 个待处理会话"
            }
        } else if result.blocked > 0 {
            lastStatusMessage = "\(result.blocked) 个会话需确认、已拦截或状态不明，未发送文字"
        } else if result.busy > 0 {
            lastStatusMessage = "\(result.busy) 个会话正在运行中，已跳过"
        } else {
            lastStatusMessage = "没有找到匹配的 Codex / Claude 会话"
        }
    }

    /// Makes a fresh model request at each scheduled five-hour boundary.
    private func scheduleWindow() {
        windowTimer?.invalidate()
        windowTimer = nil
        guard let windowStartMinutes, !windowAgents.isEmpty else { return }
        if windowAnchor == nil {
            windowAnchor = FiveHourActivation.firstAnchor(minutes: windowStartMinutes, after: Date())
            UserDefaults.standard.set(windowAnchor, forKey: "autoContinueWindowAnchorDate")
        }
        guard let windowAnchor else { return }
        let fireDate = FiveHourActivation.nextFire(after: Date(), anchor: windowAnchor)

        let timer = Timer(fireAt: fireDate, interval: 0, target: self, selector: #selector(windowOpened), userInfo: nil, repeats: false)
        RunLoop.main.add(timer, forMode: .common)
        windowTimer = timer
    }

    @objc private func windowOpened() {
        scheduleWindow()
        let selectedAgents = FiveHourActivation.selectedAgents(
            from: windowAgents.map(\.rawValue)
        )
        guard !activating, windowStartMinutes != nil, !selectedAgents.isEmpty else { return }
        activating = true
        lastActivationStatus = "正在激活…"
        let home = NSHomeDirectory()
        let manager = Bundle.main.url(forResource: "manage", withExtension: "py", subdirectory: "AgentGuard")?.path
        Task {
            let checks = await Task.detached(priority: .utility) {
                selectedAgents.map { agent in
                    (agent, Self.ensureReady(agent, home: home, manager: manager))
                }
            }.value
            guard windowStartMinutes != nil, Set(selectedAgents) == windowAgents else {
                activating = false
                return
            }
            let ready = checks.compactMap { $0.1 == nil ? $0.0 : nil }
            let windowFailures = manager.map {
                ready.isEmpty ? [] : TerminalManager.shared.openMissingAgentWindows(ready, guardPath: $0)
            } ?? []
            let results = await Task.detached(priority: .utility) {
                ready.map { agent in
                    (agent, Self.requestActivation(agent, home: home))
                }
            }.value
            let failures = checks.compactMap { check -> String? in
                check.1.map { "\(check.0.rawValue)：\($0)" }
            } + results.compactMap { result -> String? in
                result.1.map { "\(result.0.rawValue)：\($0)" }
            } + windowFailures
            lastActivationDetail = failures.isEmpty ? nil : failures.joined(separator: "；")
            let successCount = results.filter { $0.1 == nil }.count
            lastActivationStatus = failures.isEmpty
                ? "激活请求成功（\(successCount)/\(selectedAgents.count)）"
                : "激活请求 \(successCount)/\(selectedAgents.count)，\(failures.count) 项失败"
            activating = false
        }
    }

    nonisolated private static func ensureReady(_ agent: ScheduledAgent, home: String, manager: String?) -> String? {
        guard agent.executablePath(home: home) != nil else { return "未找到命令" }
        guard let manager else { return "缺少守卫管理器" }
        let result = run("/usr/bin/python3", ["-B", manager, "ensure", agent.rawValue], home: home)
        return result.code == 0 ? nil : "守卫检查失败（\(result.code)）"
    }

    nonisolated private static func requestActivation(_ agent: ScheduledAgent, home: String) -> String? {
        guard let path = agent.executablePath(home: home) else {
            return "未找到命令"
        }
        let result = run(path, agent.activationArguments, home: home, captureOutput: true)
        if result.code != 0 { return "模型请求失败（\(result.code)）" }
        return result.hasReply ? nil : "模型未返回内容"
    }

    nonisolated private static func run(_ path: String, _ arguments: [String], home: String, captureOutput: Bool = false) -> (code: Int32, hasReply: Bool) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: home)
        process.environment = ProcessInfo.processInfo.environment.merging([
            "HOME": home,
            "PATH": "\(home)/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        ]) { _, new in new }
        process.standardInput = FileHandle.nullDevice
        let outputURL = FileManager.default.temporaryDirectory.appendingPathComponent("termyes-activation-\(UUID().uuidString)")
        var output: FileHandle?
        if captureOutput {
            guard FileManager.default.createFile(atPath: outputURL.path, contents: nil, attributes: [.posixPermissions: 0o600]),
                  let handle = try? FileHandle(forWritingTo: outputURL) else { return (-1, false) }
            output = handle
        }
        defer {
            output?.closeFile()
            if captureOutput { try? FileManager.default.removeItem(at: outputURL) }
        }
        process.standardOutput = output ?? FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + 120, execute: timeout)
            process.waitUntilExit()
            timeout.cancel()
            guard captureOutput else { return (process.terminationStatus, false) }
            output?.synchronizeFile()
            let reader = try? FileHandle(forReadingFrom: outputURL)
            let reply = reader?.readData(ofLength: 8192) ?? Data()
            reader?.closeFile()
            let hasReply = !String(decoding: reply, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            return (process.terminationStatus, hasReply)
        } catch {
            return (-1, false)
        }
    }

}
