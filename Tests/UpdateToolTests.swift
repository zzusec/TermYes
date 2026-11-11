import Foundation

@main
struct UpdateToolTests {
    @MainActor
    static func main() async throws {
        let files = FileManager.default
        let root = files.temporaryDirectory.appendingPathComponent("termyes-update-tool-tests-\(UUID().uuidString)")
        try files.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? files.removeItem(at: root) }
        let tool = root.appendingPathComponent("tool")
        let line = String(repeating: "diagnostic", count: 12)
        let body = """
        #!/bin/sh
        i=0
        while [ "$i" -lt 2000 ]; do
          printf '%s\\n' '\(line)'
          printf '%s\\n' '\(line)' >&2
          i=$((i+1))
        done
        printf '%s\\n' "$1"
        printf '%s\\n' 'failure detail' >&2
        exit 23
        """
        try body.write(to: tool, atomically: true, encoding: .utf8)
        try files.setAttributes([.posixPermissions: 0o700], ofItemAtPath: tool.path)
        let argument = "literal ; shell substitution $(false)"
        let started = Date()
        let result = await Task.detached(priority: .utility) {
            UpdateController.runTool(tool.path, [argument])
        }.value
        precondition(result.status == 23, "Nonzero tool exit status must remain visible")
        let expected = String(repeating: line + "\n", count: 2000)
        precondition(result.output == expected + argument + "\n", "Capture all stdout without interpreting arguments")
        precondition(result.error == expected + "failure detail", "Capture stderr separately, including output beyond a pipe buffer")
        precondition(Date().timeIntervalSince(started) < 10, "Large tool output must not deadlock")

        let success = await Task.detached {
            UpdateController.runTool("/bin/sh", ["-c", "printf 'ok'; printf '  warning\\n' >&2"])
        }.value
        precondition(success.status == 0 && success.output == "ok" && success.error == "warning")
        let missing = await Task.detached {
            UpdateController.runTool(root.appendingPathComponent("missing").path, [])
        }.value
        precondition(missing.status == 127 && !missing.error.isEmpty, "Launch failures must be visible")
        print("Update tool tests passed: large stdout/stderr, exact arguments, exit status, launch failure.")
    }
}
