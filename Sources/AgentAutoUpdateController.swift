import AppKit
import Combine
import Foundation

struct AgentAutoUpdateReport: Decodable {
    struct Item: Decodable, Identifiable {
        let client: String
        let target: String
        let command: String
        let ok: Bool
        let changed: Bool
        let detail: String
        let currentVersion: String?
        let latestVersion: String?
        let status: String?
        let source: String?
        let sourceLabel: String?

        var id: String { client + ":" + target }
        var stateDescription: String {
            switch status {
            case "upToDate": return "已是最新"
            case "updated": return "已自动升级"
            case "updateAvailable": return "有官方更新"
            case "ahead": return "本机版本高于稳定版"
            case "unsupported": return "暂不支持自动升级"
            case "failed": return "检查或升级失败"
            default: return ok ? (changed ? "已更新" : "已完成") : "失败"
            }
        }
        var versionDescription: String {
            let current = currentVersion.flatMap { $0.isEmpty ? nil : $0 } ?? "未知"
            let latest = latestVersion.flatMap { $0.isEmpty ? nil : $0 } ?? "未知"
            return "本机 \(current) / \(sourceLabel ?? "官方") \(latest)"
        }
        var diagnosticDetails: String {
            "\(client) · \(target)：\(stateDescription)\n\(versionDescription)\n来源：\(source ?? "未确认")\n$ \(command)\n\(detail)"
        }
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
    @Published private(set) var items: [AgentAutoUpdateReport.Item] = []
    private var timer: Timer?

    var cliItems: [AgentAutoUpdateReport.Item] { items.filter { $0.target == "CLI" } }

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
                items = report.items
                message = report.message + (result.0 == 0 ? "" : " · 退出码 \(result.0)")
                details = report.items.map(\.diagnosticDetails).joined(separator: "\n\n")
            } else {
                items = []
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
