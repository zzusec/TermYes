import Combine
import Foundation
import ServiceManagement

protocol LoginItemManaging {
    var status: SMAppService.Status { get }
    func register() throws
    func unregister() throws
}

extension SMAppService: LoginItemManaging {}

@MainActor
final class LaunchAtLoginController: ObservableObject {
    static let shared = LaunchAtLoginController()
    @Published private(set) var status: SMAppService.Status = .notRegistered
    @Published private(set) var issue: String?
    private let service: any LoginItemManaging

    init(service: any LoginItemManaging = SMAppService.mainApp) {
        self.service = service
        refresh()
    }

    var isRequested: Bool { status == .enabled || status == .requiresApproval }

    var statusDescription: String {
        switch status {
        case .enabled: return "登录时自动启动已开启"
        case .requiresApproval: return "自启动待批准，请在系统设置中允许"
        case .notFound: return "登录项不可用，请将 TermYes 安装到 Applications"
        case .notRegistered: return "登录时自动启动未开启"
        @unknown default: return "登录项状态未知，请检查系统设置"
        }
    }

    func refresh() { status = service.status }

    func setEnabled(_ enabled: Bool) {
        refresh()
        issue = nil
        guard enabled != isRequested else { return }
        do {
            if enabled { try service.register() } else { try service.unregister() }
            refresh()
            if enabled && !isRequested || !enabled && isRequested {
                issue = "系统未应用登录项变更：\(statusDescription)"
            }
        } catch {
            refresh()
            issue = "无法\(enabled ? "开启" : "关闭")登录时自启动：\(error.localizedDescription)"
        }
    }

    func openSettings() { SMAppService.openSystemSettingsLoginItems() }
}
