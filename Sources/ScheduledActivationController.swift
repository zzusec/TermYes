import AppKit
import Combine
import Darwin

@MainActor
final class ScheduledActivationController: NSObject, ObservableObject {
    static let shared = ScheduledActivationController()

    @Published private(set) var windowStartMinutes: Int?
    @Published private(set) var windowAgents: Set<ScheduledAgent>
    @Published private(set) var lastActivationStatus: String?
    @Published private(set) var lastActivationDetail: String?

    private var windowTimer: Timer?
    private var windowAnchor: Date?
    private(set) var activating = false
    private var started = false
    private var scheduleRevision = 0
    private let defaults: UserDefaults
    private let home: String
    private let managerPath: String?
    private let openAgentWindows: @MainActor ([ScheduledAgent], String, String) -> [String]

    init(
        defaults: UserDefaults = .standard,
        home: String = NSHomeDirectory(),
        manager: String? = Bundle.main.url(forResource: "manage", withExtension: "py", subdirectory: "AgentGuard")?.path,
        openAgentWindows: @escaping @MainActor ([ScheduledAgent], String, String) -> [String] = {
            TerminalManager.shared.openAgentActivationWindows($0, scriptPath: $1, resultDirectory: $2)
        }
    ) {
        self.defaults = defaults
        self.home = home
        managerPath = manager
        self.openAgentWindows = openAgentWindows
        let savedMinutes = defaults.object(forKey: "autoContinueWindowStartMinutes") as? Int
        windowStartMinutes = savedMinutes.flatMap { (0..<1440).contains($0) ? $0 : nil }
        windowAgents = Set(FiveHourActivation.selectedAgents(
            from: defaults.stringArray(forKey: "autoContinueWindowAgents")
        ))
        windowAnchor = defaults.object(forKey: "autoContinueWindowAnchorDate") as? Date
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
        scheduleRevision += 1
        windowAgents = agents
        defaults.set(agents.map(\.rawValue).sorted(), forKey: "autoContinueWindowAgents")
        windowStartMinutes = minutes
        lastActivationStatus = nil
        lastActivationDetail = nil
        if let minutes {
            defaults.set(minutes, forKey: "autoContinueWindowStartMinutes")
            if timeChanged {
                windowAnchor = FiveHourActivation.firstAnchor(minutes: minutes, after: Date())
                defaults.set(windowAnchor, forKey: "autoContinueWindowAnchorDate")
            }
        } else {
            defaults.set(-1, forKey: "autoContinueWindowStartMinutes")
            defaults.removeObject(forKey: "autoContinueWindowAnchorDate")
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

    /// Makes a fresh model request at each scheduled five-hour boundary.
    private func scheduleWindow() {
        windowTimer?.invalidate()
        windowTimer = nil
        guard let windowStartMinutes, !windowAgents.isEmpty else { return }
        if windowAnchor == nil {
            windowAnchor = FiveHourActivation.firstAnchor(minutes: windowStartMinutes, after: Date())
            defaults.set(windowAnchor, forKey: "autoContinueWindowAnchorDate")
        }
        guard let windowAnchor else { return }
        let fireDate = FiveHourActivation.nextFire(after: Date(), anchor: windowAnchor)

        let timer = Timer(fireAt: fireDate, interval: 0, target: self, selector: #selector(windowOpened), userInfo: nil, repeats: false)
        RunLoop.main.add(timer, forMode: .common)
        windowTimer = timer
    }

    func activateNow() {
        activateSelectedWindows()
    }

    @objc private func windowOpened() {
        scheduleWindow()
        activateSelectedWindows()
    }

    private func activateSelectedWindows() {
        let selectedAgents = FiveHourActivation.selectedAgents(
            from: windowAgents.map(\.rawValue)
        )
        guard !activating, !selectedAgents.isEmpty else { return }
        activating = true
        lastActivationStatus = "正在激活…"
        lastActivationDetail = nil
        let revision = scheduleRevision
        let home = home
        let manager = managerPath
        let resultDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("termyes-window-activation-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        do {
            try FileManager.default.createDirectory(at: resultDirectory, withIntermediateDirectories: false,
                                                   attributes: [.posixPermissions: 0o700])
        } catch {
            activating = false
            lastActivationStatus = "激活失败"
            lastActivationDetail = "无法创建激活结果目录：\(error.localizedDescription)"
            return
        }
        Task {
            defer {
                activating = false
                try? FileManager.default.removeItem(at: resultDirectory)
            }
            let checks = await Task.detached(priority: .utility) {
                selectedAgents.map { agent in
                    (agent, Self.ensureReady(agent, home: home, manager: manager))
                }
            }.value
            guard revision == scheduleRevision else { return }
            let ready = checks.compactMap { $0.1 == nil ? $0.0 : nil }
            let activationScript = manager.map {
                URL(fileURLWithPath: $0).deletingLastPathComponent().appendingPathComponent("activate.py").path
            }
            let windowFailures = activationScript.map {
                ready.isEmpty ? [] : openAgentWindows(ready, $0, resultDirectory.path)
            } ?? []
            let launched = ready.filter { agent in
                !windowFailures.contains { $0.hasPrefix(agent.rawValue + "：") }
            }
            let results = await withTaskGroup(of: (ScheduledAgent, String?).self) { group in
                for agent in launched {
                    group.addTask {
                        (agent, Self.awaitWindowActivation(agent, resultDirectory: resultDirectory.path))
                    }
                }
                var results: [(ScheduledAgent, String?)] = []
                for await result in group { results.append(result) }
                return results.sorted { $0.0.rawValue < $1.0.rawValue }
            }
            guard revision == scheduleRevision else { return }
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
        }
    }

    nonisolated static func ensureReady(_ agent: ScheduledAgent, home: String, manager: String?) -> String? {
        guard agent.executablePath(home: home) != nil else { return "未找到命令" }
        guard let manager else { return "缺少守卫管理器" }
        let result = run("/usr/bin/python3", ["-B", manager, "ensure", agent.rawValue], home: home)
        return result.code == 0 ? nil : "守卫检查失败（\(result.code)）：\(result.detail ?? "无错误输出")"
    }

    private struct ActivationResult: Decodable {
        let code: Int
        let hasReply: Bool
        let detail: String?
    }

    nonisolated static func awaitWindowActivation(_ agent: ScheduledAgent, resultDirectory: String, timeout: TimeInterval = 165) -> String? {
        let path = URL(fileURLWithPath: resultDirectory).appendingPathComponent(agent.rawValue + ".json")
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if FileManager.default.fileExists(atPath: path.path) {
                do {
                    let result = try JSONDecoder().decode(ActivationResult.self, from: Data(contentsOf: path))
                    if result.code != 0 { return "模型请求失败（\(result.code)）：\(result.detail ?? "无错误输出")" }
                    return result.hasReply ? nil : result.detail ?? "模型未返回内容"
                } catch {
                    return "无法读取窗口激活结果：\(error.localizedDescription)"
                }
            }
            Thread.sleep(forTimeInterval: 0.05)
        } while Date() < deadline
        return "窗口激活超时，未取得模型回复"
    }

    nonisolated static func run(_ path: String, _ arguments: [String], home: String, timeout: TimeInterval = 120) -> (code: Int32, hasReply: Bool, detail: String?) {
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
        let errorURL = outputURL.appendingPathExtension("stderr")
        var output: FileHandle?
        var errors: FileHandle?
        defer {
            output?.closeFile()
            errors?.closeFile()
            try? FileManager.default.removeItem(at: outputURL)
            try? FileManager.default.removeItem(at: errorURL)
        }
        guard FileManager.default.createFile(atPath: outputURL.path, contents: nil, attributes: [.posixPermissions: 0o600]),
              FileManager.default.createFile(atPath: errorURL.path, contents: nil, attributes: [.posixPermissions: 0o600]),
              let outputHandle = try? FileHandle(forWritingTo: outputURL),
              let errorHandle = try? FileHandle(forWritingTo: errorURL) else {
            return (-1, false, "无法创建请求输出文件")
        }
        output = outputHandle
        errors = errorHandle
        process.standardOutput = outputHandle
        process.standardError = errorHandle
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do {
            try process.run()
            let timedOut = finished.wait(timeout: .now() + timeout) == .timedOut
            if timedOut {
                process.terminate()
                if finished.wait(timeout: .now() + 2) == .timedOut, process.isRunning {
                    kill(process.processIdentifier, SIGKILL)
                }
            }
            process.waitUntilExit()
            outputHandle.synchronizeFile()
            errorHandle.synchronizeFile()
            let reply = readOutput(outputURL)
            let error = readOutput(errorURL)
            let hasReply = !reply.isEmpty
            let detail = timedOut ? "执行超时（\(timeout) 秒）" :
                (error.isEmpty ? (reply.isEmpty ? nil : String(reply.prefix(2000))) : String(error.prefix(2000)))
            return (timedOut ? -1 : process.terminationStatus, hasReply, detail)
        } catch {
            return (-1, false, error.localizedDescription)
        }
    }

    nonisolated private static func readOutput(_ url: URL) -> String {
        guard let reader = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { reader.closeFile() }
        return String(decoding: reader.readData(ofLength: 8192), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
