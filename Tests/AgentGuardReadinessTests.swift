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
        let paused = try client(["guardPaused": true, "guardConfigured": true, "guardReady": false,
                                 "guardPausedUntil": "2099-01-01T12:00:00Z"])
        precondition(paused.configurationReady && !paused.isVerified && paused.isGuardPaused)
        precondition(paused.pauseDescription.contains("审查暂停至"))
        let expired = try client(["guardPaused": true, "guardPausedUntil": "2000-01-01T12:00:00Z",
                                  "liveStatus": "paused", "guardLiveStatus": "paused"])
        precondition(!expired.isGuardPaused && !expired.isVerified)
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
        precondition(verified.needsAutomaticVerification == false)
        let untested = try client(["liveStatus": "untested"])
        let stale = try client(["liveStatus": "stale"])
        let unsupported = try client(["liveStatus": "unsupported"])
        precondition(untested.needsAutomaticVerification && stale.needsAutomaticVerification)
        precondition(unsupported.needsAutomaticVerification == false)
        precondition(paused.needsAutomaticVerification == false)
        let recentFail = ISO8601DateFormatter()
        recentFail.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let tenMinutesAgo = try client(["liveStatus": "failed", "liveCheckedAt": recentFail.string(from: Date().addingTimeInterval(-10 * 60))])
        let twoHoursAgo = try client(["liveStatus": "failed", "liveCheckedAt": recentFail.string(from: Date().addingTimeInterval(-2 * 60 * 60))])
        precondition(tenMinutesAgo.needsAutomaticVerification == false)
        precondition(twoHoursAgo.needsAutomaticVerification)
        let pythonStamp = DateFormatter()
        pythonStamp.locale = Locale(identifier: "en_US_POSIX")
        pythonStamp.timeZone = TimeZone(secondsFromGMT: 0)
        pythonStamp.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSSSSXXXXX"
        let pythonRecent = try client(["liveStatus": "failed", "liveCheckedAt": pythonStamp.string(from: Date().addingTimeInterval(-10 * 60))])
        let pythonOld = try client(["liveStatus": "failed", "liveCheckedAt": "2026-11-02T15:27:08.928854+00:00"])
        let undetected = try client(["detected": false, "liveStatus": "untested"])
        precondition(pythonRecent.needsAutomaticVerification == false)
        precondition(pythonOld.needsAutomaticVerification)
        precondition(undetected.needsAutomaticVerification == false)
        print("Agent readiness regression passed: config alone never certifies a running YOLO Agent.")
    }
}
