import Foundation

@main
struct AgentGuardReadinessTests {
    @MainActor
    static func main() async throws {
        if CommandLine.arguments.contains("--controller-fixture") {
            try await testControllerFailuresAndStop()
            return
        }
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
        try runControllerFixtureBundle()
    }

    // Exercise the real Process/Bundle path without loading the bundled manager or any real Agent.
    private static func runControllerFixtureBundle() throws {
        let files = FileManager.default
        let root = files.temporaryDirectory.appendingPathComponent("termyes-guard-tests-" + UUID().uuidString)
        defer { try? files.removeItem(at: root) }
        let contents = root.appendingPathComponent("GuardFixture.app/Contents")
        let executable = contents.appendingPathComponent("MacOS/GuardFixture")
        let resources = contents.appendingPathComponent("Resources/AgentGuard")
        let home = root.appendingPathComponent("home")
        try files.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        try files.createDirectory(at: resources, withIntermediateDirectories: true)
        try files.createDirectory(at: home, withIntermediateDirectories: true)
        try files.copyItem(at: Bundle.main.executableURL!, to: executable)
        try fixtureScript.write(to: resources.appendingPathComponent("manage.py"), atomically: true, encoding: .utf8)
        let info = ["CFBundleExecutable": "GuardFixture", "CFBundleIdentifier": "tests.termyes.guard-fixture",
                    "CFBundlePackageType": "APPL"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
        let process = Process()
        process.executableURL = executable
        process.arguments = ["--controller-fixture"]
        process.currentDirectoryURL = home
        process.environment = ["HOME": home.path, "CFFIXED_USER_HOME": home.path,
                               "PATH": "/usr/bin:/bin", "PYTHONDONTWRITEBYTECODE": "1",
                               "TERMYES_GUARD_FIXTURE_ROOT": home.path]
        try process.run()
        process.waitUntilExit()
        precondition(process.terminationReason == .exit && process.terminationStatus == 0,
                     "Isolated controller regression failed: \(process.terminationStatus)")
    }

    @MainActor
    private static func waitUntil(_ condition: () -> Bool, _ label: String) async throws {
        for _ in 0..<500 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        preconditionFailure("Timed out waiting for \(label)")
    }

    @MainActor
    private static func testControllerFailuresAndStop() async throws {
        let files = FileManager.default
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["TERMYES_GUARD_FIXTURE_ROOT"]!)
        precondition(ProcessInfo.processInfo.environment["HOME"] == root.path)
        let controller = AgentGuardController()
        defer { controller.stop() }
        func mode(_ value: String) throws {
            try value.write(to: root.appendingPathComponent("mode"), atomically: true, encoding: .utf8)
        }
        func actions() throws -> [String] {
            try String(contentsOf: root.appendingPathComponent("actions"), encoding: .utf8)
                .split(separator: "\n").map(String.init)
        }
        func resetActions() throws {
            try "".write(to: root.appendingPathComponent("actions"), atomically: true, encoding: .utf8)
        }
        func expectActions(_ expected: [String], _ message: String) throws {
            let recorded = try actions()
            precondition(recorded == expected, "\(message): \(recorded)")
        }
        func refreshPassed() async throws {
            try mode("passed")
            controller.refresh()
            try await waitUntil({ !controller.isWorking }, "successful status")
            precondition(!controller.lastCheckFailed && controller.clients.first?.isVerified == true)
            precondition(controller.diagnosticDetails.contains("端到端实测通过"))
        }

        try await refreshPassed()
        try mode("process-failure")
        controller.refresh()
        try await waitUntil({ !controller.isWorking }, "failed process")
        precondition(controller.lastCheckFailed && controller.clients.isEmpty,
                     "A failed manager must invalidate the previous verified snapshot")
        precondition(controller.diagnosticDetails.contains("FIXTURE PROCESS FAILURE"))
        precondition(controller.message.contains("退出码 7"))
        precondition(controller.diagnosticDetails.contains("退出码：7"))
        precondition(!controller.diagnosticDetails.contains("端到端实测通过"))

        try await refreshPassed()
        precondition(!controller.diagnosticDetails.contains("FIXTURE PROCESS FAILURE"),
                     "A successful refresh must replace the previous error")
        try mode("malformed")
        controller.refresh()
        try await waitUntil({ !controller.isWorking }, "invalid manager JSON")
        precondition(controller.lastCheckFailed && controller.clients.isEmpty)
        precondition(controller.diagnosticDetails.contains("FIXTURE INVALID JSON"))
        precondition(controller.message.contains("无法解析"))
        precondition(controller.diagnosticDetails.contains("解析错误："))

        try await refreshPassed()
        try mode("nonzero-json")
        controller.refresh()
        try await waitUntil({ !controller.isWorking }, "nonzero result with JSON")
        precondition(controller.lastCheckFailed && controller.clients.count == 1)
        precondition(controller.clients.first?.guardReason == "FRESH FAILURE SNAPSHOT")
        precondition(controller.diagnosticDetails.contains("退出码：9"),
                     "Raw operation diagnostics must remain visible even with decoded clients")
        precondition(!controller.diagnosticDetails.contains("端到端实测通过"))

        try await refreshPassed()
        let script = Bundle.main.url(forResource: "manage", withExtension: "py", subdirectory: "AgentGuard")!
        let scriptData = try Data(contentsOf: script)
        try files.removeItem(at: script)
        controller.refresh()
        try await waitUntil({ !controller.isWorking }, "missing resource")
        precondition(controller.lastCheckFailed && controller.clients.isEmpty)
        precondition(!controller.diagnosticDetails.contains("端到端实测通过"))
        precondition(!controller.diagnosticDetails.contains("FRESH FAILURE SNAPSHOT"))
        try scriptData.write(to: script)

        // A monitor failure must neither reuse a stale untested snapshot nor hide its error with verification.
        try mode("untested")
        controller.refresh()
        try await waitUntil({ !controller.isWorking }, "initial untested snapshot")
        precondition(controller.clients.first?.needsAutomaticVerification == true)
        try mode("process-failure")
        try resetActions()
        controller.start()
        try await waitUntil({ !controller.isWorking }, "failed monitor")
        precondition(controller.lastCheckFailed && controller.clients.isEmpty)
        try expectActions(["monitor"], "A failed monitor must not enqueue verification")
        controller.stop()

        try mode("monitor-failure-json")
        try resetActions()
        controller.start()
        try await waitUntil({ !controller.isWorking }, "failed monitor with clients")
        precondition(controller.lastCheckFailed && controller.clients.first?.needsAutomaticVerification == true)
        try expectActions(["monitor"], "A failed monitor must not enqueue a model request")
        controller.stop()

        try mode("blocked-monitor")
        try resetActions()
        controller.start()
        try await waitUntil({ files.fileExists(atPath: root.appendingPathComponent("entered").path) }, "monitor entry")
        controller.stop()
        // Restarting the timer must not revive work that was already stopped.
        controller.start()
        try "release".write(to: root.appendingPathComponent("release"), atomically: true, encoding: .utf8)
        try await waitUntil({ !controller.isWorking }, "stopped monitor completion")
        try expectActions(["monitor"], "stop() must prevent automatic verification from in-flight work")
        controller.stop()

        try mode("untested")
        try resetActions()
        controller.start()
        try await waitUntil({ !controller.isWorking }, "automatic verification")
        try expectActions(["monitor", "verify-pending"], "Successful monitoring must still verify")
        precondition(!controller.lastCheckFailed && controller.clients.first?.isVerified == true)
        controller.stop()

        try resetActions()
        controller.repairUnready()
        try await waitUntil({ !controller.isWorking }, "explicit repair verification")
        try expectActions(["repair-unready", "verify-pending"],
                          "New explicit operations must still verify after a previous stop")
        precondition(controller.clients.first?.isVerified == true)
        print("Agent controller regression passed: failed/invalid/missing results, visible diagnostics, recovery, stop/restart and follow-up verification.")
    }

    private static let fixtureScript = """
    import json
    import os
    from pathlib import Path
    import sys
    import time

    root = Path(os.environ['TERMYES_GUARD_FIXTURE_ROOT'])
    assert os.environ['HOME'] == str(root)
    action = sys.argv[1]
    with (root / 'actions').open('a') as log:
        log.write(action + '\\n')
    mode = (root / 'mode').read_text()
    if mode == 'process-failure':
        print('FIXTURE PROCESS FAILURE', file=sys.stderr)
        sys.exit(7)
    if mode == 'malformed':
        print('FIXTURE INVALID JSON')
        sys.exit(0)
    if mode == 'blocked-monitor' and action == 'monitor':
        (root / 'entered').write_text('entered')
        deadline = time.monotonic() + 8
        while not (root / 'release').exists():
            if time.monotonic() >= deadline:
                raise RuntimeError('fixture monitor was not released')
            time.sleep(0.01)
    pending = mode in ('untested', 'blocked-monitor', 'monitor-failure-json') and action != 'verify-pending'
    status = 'untested' if pending else 'passed'
    print(json.dumps([{
        'id': 'fixture', 'name': 'Fixture', 'guardReady': True, 'guardConfigured': True,
        'guardReason': 'FRESH FAILURE SNAPSHOT' if mode == 'nonzero-json' else 'installed',
        'policyVersion': 3, 'policyStatus': 'current', 'policyError': False,
        'approvalReason': 'bypass', 'detected': True, 'permissionMode': 'bypassPermissions',
        'permissionReady': True, 'permissionReason': 'configured',
        'liveStatus': status, 'requestStatus': status, 'guardLiveStatus': status
    }]))
    sys.exit(9 if mode in ('nonzero-json', 'monitor-failure-json') else 0)
    """
}
