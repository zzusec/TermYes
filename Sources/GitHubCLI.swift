import Darwin
import Foundation

struct GitHubCLI: Sendable {
    private let executable: URL
    private let timeout: TimeInterval
    private let proxyURL: String?

    nonisolated init(executable: URL, timeout: TimeInterval = 177, proxyURL: String? = nil) {
        self.executable = executable
        self.timeout = min(177, max(0.05, timeout))
        self.proxyURL = proxyURL
    }

    nonisolated static func findExecutable(searchDirectories: [String]? = nil) -> URL? {
        let directories = searchDirectories ?? [
            "/opt/homebrew/bin", "/usr/local/bin",
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin").path
        ] + (ProcessInfo.processInfo.environment["PATH"] ?? "").components(separatedBy: ":")
        for directory in directories where directory.hasPrefix("/") {
            let candidate = URL(fileURLWithPath: directory, isDirectory: true).appendingPathComponent("gh")
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory),
               !isDirectory.boolValue, FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    nonisolated static func latestReleaseTag() throws -> String {
        try installed().latestReleaseTag()
    }

    nonisolated static func downloadRelease(tagName: String, directory: URL) throws {
        try installed().downloadRelease(tagName: tagName, directory: directory)
    }

    nonisolated func latestReleaseTag() throws -> String {
        let data = try run(["api", "repos/zzusec/TermYes/releases/latest", "--jq", ".tag_name"])
        guard let output = String(data: data, encoding: .utf8) else { throw CLIError.invalidTag }
        let tag = output.trimmingCharacters(in: .whitespacesAndNewlines)
        try Self.validate(tag)
        return tag
    }

    nonisolated func downloadRelease(tagName: String, directory: URL) throws {
        try Self.validate(tagName)
        guard directory.isFileURL else { throw CLIError.invalidDirectory }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let filename = "TermYes-\(tagName)-macOS.dmg"
        _ = try run(["release", "download", tagName, "--repo", "zzusec/TermYes",
                     "--pattern", filename, "--pattern", filename + ".sha256", "--dir", directory.path])
    }

    nonisolated private static func installed() throws -> GitHubCLI {
        guard let executable = findExecutable() else { throw CLIError.unavailable }
        return GitHubCLI(executable: executable, proxyURL: UserDefaults.standard.string(forKey: "githubUpdateProxyURL"))
    }

    nonisolated private static func validate(_ tag: String) throws {
        guard tag.range(of: #"^v[0-9]+\.[0-9]+\.[0-9]+$"#, options: .regularExpression)
                == tag.startIndex..<tag.endIndex else { throw CLIError.invalidTag }
    }

    nonisolated private func run(_ arguments: [String]) throws -> Data {
        var environment = ProcessInfo.processInfo.environment
        if let proxyURL {
            guard let proxy = URLComponents(string: proxyURL),
                  let scheme = proxy.scheme?.lowercased(), ["http", "https"].contains(scheme),
                  let host = proxy.host, !host.isEmpty, proxy.user == nil, proxy.password == nil,
                  proxy.query == nil, proxy.fragment == nil, proxy.path.isEmpty || proxy.path == "/",
                  proxy.url != nil else { throw CLIError.invalidProxy }
            environment["HTTP_PROXY"] = proxyURL
            environment["HTTPS_PROXY"] = proxyURL
        }
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("TermYes-gh-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: temporary) }
        let outputURL = temporary.appendingPathComponent("stdout")
        let errorURL = temporary.appendingPathComponent("stderr")
        for file in [outputURL, errorURL] {
            guard FileManager.default.createFile(atPath: file.path, contents: nil,
                                                  attributes: [.posixPermissions: 0o600]) else {
                throw CLIError.captureFailed
            }
        }
        let output = try FileHandle(forWritingTo: outputURL)
        defer { try? output.close() }
        let error = try FileHandle(forWritingTo: errorURL)
        defer { try? error.close() }
        let process = Process()
        let completed = DispatchSemaphore(value: 0)
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = error
        environment["GH_HOST"] = "github.com"
        environment["GH_PROMPT_DISABLED"] = "1"
        environment["GH_NO_UPDATE_NOTIFIER"] = "1"
        environment["GH_NO_EXTENSION_UPDATE_NOTIFIER"] = "1"
        environment.removeValue(forKey: "GH_DEBUG")
        process.environment = environment
        process.terminationHandler = { _ in completed.signal() }
        do { try process.run() } catch { throw CLIError.launchFailed }
        if completed.wait(timeout: .now() + timeout) == .timedOut {
            if process.isRunning { process.terminate() }
            if completed.wait(timeout: .now() + 1) == .timedOut {
                if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
                _ = completed.wait(timeout: .now() + 1)
            }
            throw CLIError.timedOut
        }
        guard process.terminationStatus == 0 else { throw CLIError.commandFailed(process.terminationStatus) }
        // Files avoid pipe deadlocks. Never include raw CLI output in errors: it may contain credentials.
        let reader = try FileHandle(forReadingFrom: outputURL)
        defer { try? reader.close() }
        return try reader.read(upToCount: 4097) ?? Data()
    }

    private enum CLIError: LocalizedError {
        case unavailable, invalidTag, invalidDirectory, invalidProxy, captureFailed, launchFailed, timedOut
        case commandFailed(Int32)

        var errorDescription: String? {
            switch self {
            case .unavailable: return "此仓库需要 GitHub 授权；未找到 GitHub CLI。请安装 gh，并在终端使用 gh auth login 登录有仓库权限的账户。"
            case .invalidTag: return "GitHub CLI 返回的发布标签无效；仅接受 vN.N.N 正式版本。"
            case .invalidDirectory: return "GitHub 更新下载目录必须是本机文件目录。"
            case .invalidProxy: return "GitHub 更新代理配置无效；请使用包含主机的 http/https 代理地址，不允许账户、密码、路径或查询参数。未尝试直连。"
            case .captureFailed: return "无法创建 GitHub CLI 的私有输出文件。"
            case .launchFailed: return "无法启动 GitHub CLI，请检查 gh 是否可执行。"
            case .timedOut: return "GitHub CLI 操作超时，已终止更新请求；请检查网络后重试。"
            case .commandFailed(let code):
                return "GitHub CLI 请求失败（退出码 \(code)）；请运行 gh auth status，确认已登录且有权读取 zzusec/TermYes，并检查网络。"
            }
        }
    }
}
