import Foundation
import ServiceManagement

final class FakeLoginItem: LoginItemManaging {
    var status: SMAppService.Status = .notRegistered
    var error: Error?
    var requiresApproval = false
    var calls: [String] = []
    func register() throws {
        calls.append("register")
        if let error { throw error }
        status = requiresApproval ? .requiresApproval : .enabled
    }
    func unregister() throws {
        calls.append("unregister")
        if let error { throw error }
        status = .notRegistered
    }
}

@main
struct LoginItemTests {
    @MainActor static func main() {
        let service = FakeLoginItem()
        let controller = LaunchAtLoginController(service: service)
        precondition(!controller.isRequested && service.calls.isEmpty, "Startup must not opt in")
        controller.setEnabled(true)
        precondition(controller.status == .enabled && controller.isRequested && controller.issue == nil)
        controller.setEnabled(true)
        precondition(service.calls == ["register"], "No duplicate registration")
        controller.setEnabled(false)
        precondition(!controller.isRequested && service.calls.last == "unregister")
        service.requiresApproval = true
        controller.setEnabled(true)
        precondition(controller.isRequested && controller.statusDescription.contains("待批准"))
        controller.setEnabled(false)
        precondition(!controller.isRequested, "Pending registrations can be cancelled")
        service.error = NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "denied"])
        controller.setEnabled(true)
        precondition(!controller.isRequested && controller.issue?.contains("denied") == true)
        service.status = .enabled
        controller.refresh()
        precondition(controller.isRequested, "External changes must be read from macOS, not preferences")
        controller.setEnabled(false)
        precondition(controller.isRequested && controller.issue != nil, "Failed unregister must not claim disabled")
        print("Login item tests passed: opt-in, enable/disable, pending approval, errors, external state.")
    }
}
