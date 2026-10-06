import AppKit
import Combine
import Foundation

struct AgentAutoUpdateReport: Decodable {
    struct Item: Decodable {
        let client: String
        let target: String
        let command: String
        let ok: Bool
        let changed: Bool
        let detail: String
    }
    let items: [Item]
    let message: String
}

@MainActor
final class AgentAutoUpdateController: ObservableObject {
    static let shared = AgentAutoUpdateController()
    @Published private(set) var isRunning = false
    @Published private(set) var message = "每 30 分钟自动检测 Agent 与插件更新"
    @Published private(set) var lastRunDescription = "尚未检测"
    @Published private(set) var details = ""
    private var timer: Timer?

    func start() {
        guard timer == nil else { return }
        runNow()
        let timer = Timer(timeInterval: 1800, target: self, selector: #selector(scheduledCheck), userInfo: nil, repeats: true)
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() { timer?.invalidate(); timer = nil }
    func runNow() { run() }

    @objc private func scheduledCheck() { run() }

    private func run() {
        guard !isRunning else { return }
        guard let script = Bundle.main.url(forResource: "agent_updates", withExtension: "py", subdirectory: "AgentGuard") else {
            message = "自动更新脚本缺失，请重新构建或安装 TermYes"
            return
        }
        isRunning = true
        message = "正在检测 Agent 与插件更新…"
        Task {
            let result = await Task.detached(priority: .utility) {
                Self.execute([script.path])
            }.value
            isRunning = false
            let stamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
            lastRunDescription = stamp + (result.0 == 0 ? "" : "（失败）")
            if let report = try? JSONDecoder().decode(AgentAutoUpdateReport.self, from: result.1) {
                message = report.message + (result.0 == 0 ? "" : " · 退出码 \(result.0)")
                details = report.items.map { item in
                    let state = item.ok ? (item.changed ? "已更新" : "已是最新或无需操作") : "失败"
                    return "\(item.client) · \(item.target)：\(state)\n$ \(item.command)\n\(item.detail)"
                }.joined(separator: "\n\n")
            } else {
                message = result.0 == 0 ? "更新检测完成，但结果无法解析" : "更新检测失败 · 退出码 \(result.0)"
                details = String(decoding: result.1, as: UTF8.self)
            }
        }
    }

    nonisolated private static func execute(_ arguments: [String]) -> (Int32, Data) {
        let developerTools = Process()
        developerTools.executableURL = URL(fileURLWithPath: "/usr/bin/xcode-select")
        developerTools.arguments = ["-p"]
        developerTools.standardOutput = FileHandle.nullDevice
        developerTools.standardError = FileHandle.nullDevice
        do {
            try developerTools.run()
            developerTools.waitUntilExit()
            guard developerTools.terminationStatus == 0 else {
                return (1, Data("需要 Xcode Command Line Tools 提供 /usr/bin/python3。".utf8))
            }
            let process = Process()
            let pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            process.arguments = ["-B"] + arguments
            process.standardOutput = pipe
            process.standardError = pipe
            process.environment = ProcessInfo.processInfo.environment.merging(["PYTHONDONTWRITEBYTECODE": "1"]) { _, new in new }
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (process.terminationStatus, data)
        } catch {
            return (1, Data("无法运行自动更新脚本：\(error.localizedDescription)".utf8))
        }
    }
}
