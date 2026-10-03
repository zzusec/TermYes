import AppKit
import Combine
import Foundation

struct AgentGuardClient: Decodable, Identifiable {
    let id: String
    let name: String
    let guardReady: Bool
    let guardReason: String
    let policyVersion: Int
    let policyStatus: String
    let policyError: Bool
    let serviceError: String?
    let approvalReason: String
    let detected: Bool
    let permissionMode: String
    let permissionReady: Bool
    let permissionReason: String
    let liveStatus: String?
    let liveReason: String?
    let liveCheckedAt: String?
    let requestStatus: String?
    let requestReason: String?
    let guardLiveStatus: String?
    let guardLiveReason: String?

    var configurationReady: Bool {
        detected && permissionReady && guardReady && serviceError == nil
    }

    var isVerified: Bool {
        configurationReady && liveStatus == "passed" && requestStatus == "passed"
            && guardLiveStatus == "passed"
    }
}

@MainActor
final class AgentGuardController: ObservableObject {
    static let shared = AgentGuardController()
    @Published private(set) var clients: [AgentGuardClient] = []
    @Published private(set) var isWorking = false
    @Published private(set) var lastCheckFailed = false
    @Published private(set) var message = "正在检测 Agent YOLO 模式与命令守卫"
    private var details = ""
    private var timer: Timer?

    func refresh() { run("status") }
    func start() {
        run("monitor")
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 300, target: self, selector: #selector(checkAgain), userInfo: nil, repeats: true)
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }
    func stop() { timer?.invalidate(); timer = nil }
    func repairUnready() { run("repair-unready") }
    func repair(_ client: AgentGuardClient) { run("repair-client", client: client.id) }
    func checkPolicy() { run("policy-update") }
    func verifyAll() { run("verify") }
    func verify(_ client: AgentGuardClient) { run("verify-client", client: client.id) }

    @objc private func checkAgain() { run("monitor") }

    var diagnosticDetails: String {
        guard !clients.isEmpty else { return details.isEmpty ? message : details }
        let reports = clients.filter(\.detected).map { client in
            """
            \(client.name)：\(client.isVerified ? "端到端实测通过" : "未就绪")
            YOLO：\(client.permissionReason)
            守卫配置：\(client.guardReason)
            请求/免确认：\(client.requestReason ?? "尚未实测")
            守卫加载：\(client.guardLiveReason ?? "尚未实测")
            实测时间：\(client.liveCheckedAt ?? "无")
            \(client.serviceError.map { "修复错误：" + $0 } ?? "")
            """
        }
        return ([message, "危险清单：" + policyDetails] + reports).joined(separator: "\n\n")
    }

    var policyDetails: String { clients.first?.policyStatus ?? message }

    private func run(_ action: String, client: String? = nil) {
        guard !isWorking else { return }
        guard let script = Bundle.main.url(forResource: "manage", withExtension: "py", subdirectory: "AgentGuard") else {
            message = "守卫资源缺失，请重新构建或安装 TermYes"
            lastCheckFailed = true
            return
        }
        isWorking = true
        message = action == "status"
            ? "正在检测 Agent 权限与守卫配置…"
            : action == "verify" || action == "verify-client"
                ? "正在真实请求 Agent 并验证免确认与命令守卫…"
                : action == "monitor" || action == "repair-unready" || action == "repair-client"
                    ? "正在检查并修复 Agent YOLO 与命令守卫…"
                    : "正在处理守卫文件，请稍候…"
        let arguments = [script.path, action] + (client.map { [$0] } ?? [])
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                Self.execute(arguments)
            }.value
            details = String(decoding: result.1, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            let statusActions = ["status", "monitor", "policy-update", "repair-unready", "repair-client", "verify", "verify-client"]
            if statusActions.contains(action) {
                do {
                    clients = try JSONDecoder().decode([AgentGuardClient].self, from: result.1)
                    let detected = clients.filter(\.detected)
                    let ready = detected.filter(\.permissionReady).count
                    let guarded = detected.filter(\.guardReady).count
                    let failed = detected.first { candidate in
                        (action != "repair-client" || candidate.id == client) &&
                            (!candidate.permissionReady || !candidate.guardReady || candidate.serviceError != nil)
                    }
                    let verificationFailed = (action == "verify" || action == "verify-client") && detected.contains {
                        (action != "verify-client" || $0.id == client) && $0.liveStatus != "passed"
                    }
                    lastCheckFailed = result.0 != 0 || clients.first?.policyError == true || failed != nil || verificationFailed
                    let repaired = action == "repair-client" ? detected.first(where: { $0.id == client }) : nil
                    let repairSucceeded = result.0 == 0 && repaired.map {
                        $0.permissionReady && $0.guardReady && $0.serviceError == nil
                    } == true
                    if let repaired, repairSucceeded {
                        message = "\(repaired.name) 配置已修复，待实测"
                    } else if result.0 != 0, let failed {
                        message = "\(failed.name) 未修复：\(failed.serviceError ?? (failed.permissionReady ? failed.guardReason : failed.permissionReason))"
                    } else if action == "repair-client" {
                        message = "\(repaired?.name ?? client ?? "Agent") 未修复：\(failed?.serviceError ?? failed?.guardReason ?? "未获取到就绪状态")"
                    } else if action == "verify" || action == "verify-client" {
                        let tested = action == "verify-client"
                            ? detected.filter { $0.id == client }
                            : detected
                        let passed = tested.filter(\.isVerified).count
                        message = "Agent 端到端实测通过 \(passed)/\(tested.count)"
                    } else {
                        message = "已检测 \(detected.count) 个 Agent：YOLO \(ready)，守卫配置 \(guarded)" +
                            (result.0 == 0 ? "（客户端加载需验证）" : "；部分修复失败，请查看客户端详情")
                    }
                    if action == "repair-client" {
                        showRepairResult(name: repaired?.name ?? client ?? "Agent", success: repairSucceeded,
                                         detail: repairSucceeded
                                            ? "请重启对应 Agent，以加载新的命令守卫。" : message)
                    }
                } catch {
                    lastCheckFailed = true
                    message = "Agent 权限状态无法解析；请复制详情检查"
                    if action == "repair-client" {
                        showRepairResult(name: client ?? "Agent", success: false, detail: message)
                    }
                }
            } else {
                message = String(details.prefix(120))
            }
            if result.0 == 0, !statusActions.contains(action) {
                // Refresh counts without replacing the actionable install/restore result.
                let status = await Task.detached(priority: .userInitiated) {
                    Self.execute([script.path, "status"])
                }.value
                if status.0 == 0, let value = try? JSONDecoder().decode([AgentGuardClient].self, from: status.1) {
                    clients = value
                }
            }
            isWorking = false
        }
    }

    private func showRepairResult(name: String, success: Bool, detail: String) {
        let alert = NSAlert()
        alert.messageText = "\(name) \(success ? "配置已修复，待实测" : "未修复")"
        alert.informativeText = detail
        alert.alertStyle = success ? .informational : .warning
        alert.addButton(withTitle: "好")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    nonisolated private static func execute(_ arguments: [String]) -> (Int32, Data) {
        // /usr/bin/python3 may otherwise open the macOS developer-tools installer.
        let developerTools = Process()
        developerTools.executableURL = URL(fileURLWithPath: "/usr/bin/xcode-select")
        developerTools.arguments = ["-p"]
        developerTools.standardOutput = FileHandle.nullDevice
        developerTools.standardError = FileHandle.nullDevice
        do {
            try developerTools.run()
            developerTools.waitUntilExit()
            guard developerTools.terminationStatus == 0 else {
                return (1, Data("守卫需要可用的 /usr/bin/python3（Xcode Command Line Tools）；未自动安装依赖。".utf8))
            }
            let process = Process()
            let pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            process.arguments = arguments
            process.standardOutput = pipe
            process.standardError = pipe
            process.environment = ProcessInfo.processInfo.environment.merging(["PYTHONDONTWRITEBYTECODE": "1"]) { _, new in new }
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (process.terminationStatus, data)
        } catch {
            return (1, Data("无法运行守卫管理器：\(error.localizedDescription)".utf8))
        }
    }
}
