@preconcurrency import AppKit
import Combine
import CryptoKit
import Foundation

@MainActor
final class UpdateController: NSObject, ObservableObject {
    static let shared = UpdateController()

    @Published private(set) var isUpToDate = false
    @Published private(set) var isChecking = false
    @Published private(set) var isDownloading = false
    @Published private(set) var availableVersion: String?
    @Published private(set) var statusMessage = "尚未检查更新"
    @Published private(set) var updateIssue: String?
    @Published private(set) var isInstallingUpdate = false

    private let bundleIdentifier = "io.github.zzusec.termosaic"
    private let checkInterval: TimeInterval = 2 * 60 * 60
    private var timer: Timer?
    private var availableRelease: GitHubReleaseLocation?
    private var started = false

    override private init() {
        super.init()
    }

    func start() {
        guard !started else { return }
        started = true
        scheduleTimer()
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            self?.checkForUpdates(userInitiated: false)
        }
    }

    func checkForUpdates(userInitiated: Bool = true) {
        guard !isChecking, !isDownloading, !isInstallingUpdate else { return }
        isChecking = true
        isUpToDate = false
        updateIssue = nil
        statusMessage = "正在检查 GitHub 更新…"

        Task {
            defer { isChecking = false }
            do {
                let release = try await fetchLatestRelease()
                guard let remoteVersion = SemanticVersion(release.tagName),
                      let currentVersion = currentSemanticVersion else {
                    statusMessage = "无法解析版本号"
                    updateIssue = statusMessage
                    return
                }

                if remoteVersion > currentVersion {
                    availableRelease = release
                    availableVersion = remoteVersion.description
                    statusMessage = "发现新版本 v\(remoteVersion)"
                    installAvailableUpdate()
                } else {
                    availableRelease = nil
                    availableVersion = nil
                    isUpToDate = true
                    statusMessage = userInitiated ? "当前已是最新版本 v\(currentVersion)" : "已是最新版本"
                }
            } catch {
                statusMessage = "检查更新失败：\(error.localizedDescription)"
                updateIssue = statusMessage
            }
        }
    }

    func installAvailableUpdate() {
        guard !isDownloading, !isInstallingUpdate, let release = availableRelease else { return }
        isDownloading = true
        updateIssue = nil
        statusMessage = "正在下载 v\(availableVersion ?? release.tagName)…"

        Task {
            defer { isDownloading = false }
            do {
                let stagedApp = try await downloadAndStage(release: release)
                try launchInstaller(stagedApp: stagedApp)
            } catch {
                statusMessage = "安装更新失败：\(error.localizedDescription)"
                updateIssue = statusMessage
            }
        }
    }

    private var currentSemanticVersion: SemanticVersion? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String else { return nil }
        return SemanticVersion(value)
    }

    @objc private func timerFired() {
        checkForUpdates(userInitiated: false)
    }

    private func scheduleTimer() {
        timer?.invalidate()
        timer = nil
        let timer = Timer(timeInterval: checkInterval, target: self, selector: #selector(timerFired), userInfo: nil, repeats: true)
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func fetchLatestRelease() async throws -> GitHubReleaseLocation {
        let url = URL(string: "https://github.com/zzusec/TermYes/releases/latest")!
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("TermYes/\(currentSemanticVersion?.description ?? "unknown")", forHTTPHeaderField: "User-Agent")
        let (_, response) = try await URLSession.shared.data(for: request)
        try validateHTTP(response)
        guard let finalURL = response.url,
              let release = GitHubReleaseLocation(redirectedURL: finalURL) else {
            throw UpdateError.invalidReleaseURL
        }
        return release
    }

    private func downloadAndStage(release: GitHubReleaseLocation) async throws -> URL {
        guard let version = SemanticVersion(release.tagName) else { throw UpdateError.invalidVersion }
        let expectedDMGName = "TermYes-v\(version)-macOS.dmg"

        statusMessage = "正在下载更新包…"
        let (temporaryDMG, dmgResponse) = try await URLSession.shared.download(from: release.dmgURL)
        try validateHTTP(dmgResponse)
        let (checksumData, checksumResponse) = try await URLSession.shared.data(from: release.checksumURL)
        try validateHTTP(checksumResponse)

        guard let checksumText = String(data: checksumData, encoding: .utf8),
              let expectedHash = checksumText.split(whereSeparator: { $0.isWhitespace }).first.map(String.init),
              expectedHash.count == 64 else {
            throw UpdateError.invalidChecksumFile
        }

        let cacheDirectory = try updateCacheDirectory()
        let cachedDMG = cacheDirectory.appendingPathComponent(expectedDMGName)
        try replaceItem(at: cachedDMG, with: temporaryDMG)

        statusMessage = "正在校验 SHA-256…"
        let actualHash = try sha256(of: cachedDMG)
        guard actualHash.caseInsensitiveCompare(expectedHash) == .orderedSame else {
            throw UpdateError.checksumMismatch
        }

        statusMessage = "正在验证应用包…"
        return try stageApplication(from: cachedDMG, version: version, cacheDirectory: cacheDirectory)
    }

    private func stageApplication(from dmgURL: URL, version: SemanticVersion, cacheDirectory: URL) throws -> URL {
        let mountPoint = FileManager.default.temporaryDirectory
            .appendingPathComponent("TermYesUpdate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: mountPoint, withIntermediateDirectories: true)

        let attach = runTool("/usr/bin/hdiutil", [
            "attach", dmgURL.path, "-readonly", "-nobrowse", "-mountpoint", mountPoint.path
        ])
        guard attach.status == 0 else { throw UpdateError.mountFailed(attach.error) }
        defer {
            _ = runTool("/usr/bin/hdiutil", ["detach", mountPoint.path, "-quiet"])
            try? FileManager.default.removeItem(at: mountPoint)
        }

        let sourceApp = mountPoint.appendingPathComponent("TermYes.app", isDirectory: true)
        guard FileManager.default.fileExists(atPath: sourceApp.path) else { throw UpdateError.appMissingFromDMG }

        let stagedApp = cacheDirectory.appendingPathComponent("TermYes-v\(version).app", isDirectory: true)
        if FileManager.default.fileExists(atPath: stagedApp.path) { try FileManager.default.removeItem(at: stagedApp) }
        let copy = runTool("/usr/bin/ditto", [sourceApp.path, stagedApp.path])
        guard copy.status == 0 else { throw UpdateError.stagingFailed(copy.error) }

        guard let stagedBundle = Bundle(url: stagedApp),
              stagedBundle.bundleIdentifier == bundleIdentifier,
              let stagedVersionString = stagedBundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
              let stagedVersion = SemanticVersion(stagedVersionString),
              stagedVersion == version,
              let currentVersion = currentSemanticVersion,
              stagedVersion > currentVersion else {
            throw UpdateError.invalidApplication
        }

        let signature = runTool("/usr/bin/codesign", ["--verify", "--deep", "--strict", stagedApp.path])
        guard signature.status == 0 else { throw UpdateError.signatureInvalid(signature.error) }
        return stagedApp
    }

    private func launchInstaller(stagedApp: URL) throws {
        let installedApp = Bundle.main.bundleURL
        guard installedApp.path.hasPrefix("/Applications/") else { throw UpdateError.notInstalledInApplications }
        guard FileManager.default.isWritableFile(atPath: installedApp.deletingLastPathComponent().path) else {
            throw UpdateError.applicationsNotWritable
        }

        let helper = installedApp.appendingPathComponent("Contents/Helpers/TermYesUpdateInstaller")
        guard FileManager.default.isExecutableFile(atPath: helper.path) else { throw UpdateError.helperMissing }

        let backup = installedApp.deletingLastPathComponent().appendingPathComponent(".TermYes.app.backup")
        let log = try updateCacheDirectory().appendingPathComponent("update-installer.log")
        let process = Process()
        process.executableURL = helper
        process.arguments = [
            String(ProcessInfo.processInfo.processIdentifier),
            stagedApp.path,
            installedApp.path,
            backup.path,
            log.path
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()

        isInstallingUpdate = true
        statusMessage = "正在安装更新并重新启动…"
        NSApplication.shared.terminate(nil)
    }

    private func updateCacheDirectory() throws -> URL {
        let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(bundleIdentifier, isDirectory: true)
            .appendingPathComponent("Updates", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func replaceItem(at destination: URL, with source: URL) throws {
        if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
        try FileManager.default.moveItem(at: source, to: destination)
    }

    private func sha256(of url: URL) throws -> String {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func validateHTTP(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw UpdateError.httpFailure((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
    }

    private func runTool(_ path: String, _ arguments: [String]) -> (status: Int32, output: String, error: String) {
        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardOutput = stdout
        process.standardError = stderr
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return (127, "", error.localizedDescription)
        }
        let output = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let error = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return (process.terminationStatus, output, error.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private enum UpdateError: LocalizedError {
        case invalidReleaseURL, invalidVersion, invalidChecksumFile, checksumMismatch
        case mountFailed(String), appMissingFromDMG, stagingFailed(String), invalidApplication
        case signatureInvalid(String), notInstalledInApplications, applicationsNotWritable, helperMissing
        case httpFailure(Int)

        var errorDescription: String? {
            switch self {
            case .invalidReleaseURL: return "GitHub Release 跳转地址或版本无效"
            case .invalidVersion: return "Release 版本号无效"
            case .invalidChecksumFile: return "SHA-256 文件格式无效"
            case .checksumMismatch: return "下载文件的 SHA-256 不匹配"
            case .mountFailed(let message): return "无法挂载 DMG：\(message)"
            case .appMissingFromDMG: return "DMG 中没有 TermYes.app"
            case .stagingFailed(let message): return "无法准备更新：\(message)"
            case .invalidApplication: return "更新包的 Bundle ID 或版本无效"
            case .signatureInvalid(let message): return "更新包签名校验失败：\(message)"
            case .notInstalledInApplications: return "请先将 TermYes 安装到 /Applications"
            case .applicationsNotWritable: return "/Applications 当前不可写，无法自动替换"
            case .helperMissing: return "更新助手缺失"
            case .httpFailure(let code): return "GitHub 请求失败（HTTP \(code)）"
            }
        }
    }
}
