import Darwin
import Foundation

@main
struct GitHubCLITests {
    static func main() throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("termyes-gh-tests-\(UUID().uuidString)")
        try manager.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? manager.removeItem(at: root) }
        let executable = root.appendingPathComponent("gh")
        let arguments = root.appendingPathComponent("arguments")
        func quoted(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        func script(_ body: String) throws {
            let text = "#!/bin/sh\nprintf '%s\\n' \"$@\" > \(quoted(arguments.path))\n" + body + "\n"
            try text.write(to: executable, atomically: true, encoding: .utf8)
            try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        }
        func recordedArguments() throws -> [String] {
            try String(contentsOf: arguments, encoding: .utf8).split(separator: "\n").map(String.init)
        }
        func failure(_ operation: () throws -> Void) -> String {
            do { try operation(); preconditionFailure("Expected operation to fail") }
            catch { return error.localizedDescription }
        }

        try script("printf '%s\\n' 'v1.6.30'")
        let cli = GitHubCLI(executable: executable)
        precondition(GitHubCLI.findExecutable(searchDirectories: ["", ".", root.path]) == executable)
        precondition(GitHubCLI.findExecutable(searchDirectories: ["", ".", "relative/bin"]) == nil)
        let tag = try cli.latestReleaseTag()
        precondition(tag == "v1.6.30")
        let latestArguments = try recordedArguments()
        precondition(latestArguments == ["api", "repos/zzusec/TermYes/releases/latest", "--jq", ".tag_name"])

        let download = root.appendingPathComponent("download with spaces")
        try script("printf 'dmg' > \(quoted(download.appendingPathComponent("TermYes-v1.6.30-macOS.dmg").path))\n"
                   + "printf 'checksum' > \(quoted(download.appendingPathComponent("TermYes-v1.6.30-macOS.dmg.sha256").path))")
        try cli.downloadRelease(tagName: "v1.6.30", directory: download)
        let downloadArguments = try recordedArguments()
        precondition(downloadArguments == ["release", "download", "v1.6.30", "--repo", "zzusec/TermYes",
                                           "--pattern", "TermYes-v1.6.30-macOS.dmg", "--pattern",
                                           "TermYes-v1.6.30-macOS.dmg.sha256", "--dir", download.path])
        precondition(manager.fileExists(atPath: download.appendingPathComponent("TermYes-v1.6.30-macOS.dmg").path))
        try manager.removeItem(at: arguments)
        for invalid in ["1.6.30", "v1.6.30-beta", "--help", "v1.6.30; touch /tmp/unsafe", "v1.6.30\n", "v1.6.30/extra"] {
            precondition(failure { try cli.downloadRelease(tagName: invalid, directory: download) }.contains("标签无效"))
            precondition(!manager.fileExists(atPath: arguments.path), "Invalid tags must never start a process")
        }

        for invalid in ["null", "v1.6.30-beta", "v1.6.30\nv1.6.31"] {
            try script("printf '%s\\n' \(quoted(invalid))")
            precondition(failure { _ = try cli.latestReleaseTag() }.contains("标签无效"))
        }
        let secret = "ghp_TEST_CREDENTIAL_NEVER_REPORT"
        try script("printf '%s' '\(secret)'\nprintf '%s' '\(secret)' >&2\nexit 23")
        let error = failure { _ = try cli.latestReleaseTag() }
        precondition(error.contains("23") && error.contains("gh auth status") && !error.contains(secret))
        let originalEnvironment = ProcessInfo.processInfo.environment
        let proxyFile = root.appendingPathComponent("proxy-environment")
        try script("printf '%s\\n' \"${HTTP_PROXY-}\" \"${HTTPS_PROXY-}\" \"$GH_HOST\" > \(quoted(proxyFile.path))\nprintf '%s\\n' 'v1.6.30'")
        for proxy in ["http://127.0.0.1:43123", "https://127.0.0.1:43123"] {
            let proxiedTag = try GitHubCLI(executable: executable, proxyURL: proxy).latestReleaseTag()
            precondition(proxiedTag == "v1.6.30")
            let childEnvironment = try String(contentsOf: proxyFile, encoding: .utf8)
            precondition(childEnvironment == proxy + "\n" + proxy + "\ngithub.com\n")
            precondition(ProcessInfo.processInfo.environment["HTTP_PROXY"] == originalEnvironment["HTTP_PROXY"])
            precondition(ProcessInfo.processInfo.environment["HTTPS_PROXY"] == originalEnvironment["HTTPS_PROXY"])
        }
        _ = try cli.latestReleaseTag()
        let inheritedProxy = try String(contentsOf: proxyFile, encoding: .utf8)
        precondition(inheritedProxy == (originalEnvironment["HTTP_PROXY"] ?? "") + "\n"
                     + (originalEnvironment["HTTPS_PROXY"] ?? "") + "\ngithub.com\n", "No explicit proxy must preserve proxy environment; GitHub host stays fixed")
        try manager.removeItem(at: arguments)
        for invalid in ["", "socks5://127.0.0.1:43123", "http://", "http://user:\(secret)@localhost:43123",
                        "https://\(secret)@localhost", "https://localhost/path?token=\(secret)"] {
            let proxyError = failure { _ = try GitHubCLI(executable: executable, proxyURL: invalid).latestReleaseTag() }
            precondition(proxyError.contains("代理配置无效") && !proxyError.contains(secret))
            precondition(!manager.fileExists(atPath: arguments.path), "An invalid explicit proxy must fail before starting gh, never silently connect directly")
        }
        try script("printf '%s' \"$HTTPS_PROXY \(secret)\" >&2\nexit 27")
        let proxy = "http://127.0.0.1:43123"
        let proxyFailure = failure { _ = try GitHubCLI(executable: executable, proxyURL: proxy).latestReleaseTag() }
        precondition(proxyFailure.contains("27") && !proxyFailure.contains(proxy) && !proxyFailure.contains(secret))
        try script("i=0; while [ \"$i\" -lt 10000 ]; do printf 'large stderr diagnostic line\\n' >&2; i=$((i+1)); done\nprintf '%s\\n' 'v1.6.30'")
        let largeOutputTag = try cli.latestReleaseTag()
        precondition(largeOutputTag == "v1.6.30", "Large stderr must not deadlock or contaminate the tag")

        let pidFile = root.appendingPathComponent("pid")
        try script("echo $$ > \(quoted(pidFile.path))\ntrap '' TERM\nwhile :; do :; done")
        let started = Date()
        let timeoutError = failure { _ = try GitHubCLI(executable: executable, timeout: 2).latestReleaseTag() }
        precondition(timeoutError.contains("超时") && Date().timeIntervalSince(started) < 5)
        let pid = try String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        precondition(Darwin.kill(Int32(pid)!, 0) == -1 && errno == ESRCH, "Timed-out child must be terminated")
        let launchError = failure { _ = try GitHubCLI(executable: root.appendingPathComponent("missing")).latestReleaseTag() }
        precondition(launchError.contains("无法启动"))
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: executable.path)
        precondition(GitHubCLI.findExecutable(searchDirectories: [root.path]) == nil)
        print("GitHub CLI tests passed: executable lookup, exact arguments, strict tags, download paths, child-only proxy, redacted errors, large output, timeout termination.")
    }
}
