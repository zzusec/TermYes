import Foundation

@main
struct AgentGuardReadinessTests {
    static func main() throws {
        let fields: [String: Any] = [
            "id": "claude", "name": "Claude Code", "guardReady": true,
            "guardReason": "installed", "policyVersion": 2, "policyStatus": "current",
            "policyError": false, "approvalReason": "bypass", "detected": true,
            "permissionMode": "bypassPermissions", "permissionReady": true,
            "permissionReason": "configured", "liveStatus": "passed", "requestStatus": "passed",
            "guardLiveStatus": "passed"
        ]
        func client(_ changes: [String: Any]) throws -> AgentGuardClient {
            let value = fields.merging(changes) { _, new in new }
            return try JSONDecoder().decode(AgentGuardClient.self, from: JSONSerialization.data(withJSONObject: value))
        }
        let verified = try client([:])
        precondition(verified.isVerified)
        for (key, value) in [("liveStatus", "untested"), ("liveStatus", "stale"),
                             ("liveStatus", "failed"), ("liveStatus", "unsupported"),
                             ("requestStatus", "failed"), ("guardLiveStatus", "failed"),
                             ("serviceError", "broken startup")] {
            let item = try client([key: value])
            precondition(!item.isVerified, "\(key)=\(value) cannot be checked")
        }
        for key in ["detected", "permissionReady", "guardReady"] {
            let item = try client([key: false])
            precondition(!item.isVerified, "\(key)=false cannot be checked")
        }
        var legacy = fields
        for key in ["liveStatus", "requestStatus", "guardLiveStatus"] { legacy.removeValue(forKey: key) }
        let item = try JSONDecoder().decode(AgentGuardClient.self, from: JSONSerialization.data(withJSONObject: legacy))
        precondition(item.configurationReady && !item.isVerified)
        print("Agent readiness regression passed: config alone never certifies a running YOLO Agent.")
    }
}
