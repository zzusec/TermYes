import Darwin
import Foundation

@main
struct TermYesUpdateInstaller {
    static func main() {
        let arguments = CommandLine.arguments
        guard arguments.count == 6,
              let parentPID = Int32(arguments[1]) else { exit(64) }

        let staged = URL(fileURLWithPath: arguments[2], isDirectory: true)
        let installed = URL(fileURLWithPath: arguments[3], isDirectory: true)
        let backup = URL(fileURLWithPath: arguments[4], isDirectory: true)
        let logURL = URL(fileURLWithPath: arguments[5])
        var logLines: [String] = []
        let skipLaunch = ProcessInfo.processInfo.environment["TERMOSAIC_UPDATE_SKIP_LAUNCH"] == "1"
        var backedUp = false

        func log(_ message: String) {
            logLines.append("\(ISO8601DateFormatter().string(from: Date())) \(message)")
            try? logLines.joined(separator: "\n").appending("\n").write(to: logURL, atomically: true, encoding: .utf8)
        }

        for _ in 0..<300 where kill(parentPID, 0) == 0 { usleep(100_000) }
        if kill(parentPID, 0) == 0 {
            log("Timed out waiting for TermYes to exit")
            exit(1)
        }

        let fileManager = FileManager.default
        do {
            guard !fileManager.fileExists(atPath: backup.path) else {
                throw InstallerError.backupExists
            }
            guard fileManager.fileExists(atPath: staged.path), fileManager.fileExists(atPath: installed.path) else {
                throw InstallerError.missingApplication
            }

            try fileManager.moveItem(at: installed, to: backup)
            backedUp = true
            log("Backed up existing application")

            let copy = run("/usr/bin/ditto", [staged.path, installed.path])
            guard copy == 0 else { throw InstallerError.copyFailed(copy) }

            let verify = run("/usr/bin/codesign", ["--verify", "--deep", "--strict", installed.path])
            guard verify == 0 else { throw InstallerError.signatureFailed(verify) }

            if !skipLaunch {
                let openStatus = run("/usr/bin/open", [installed.path])
                guard openStatus == 0 else { throw InstallerError.launchFailed(openStatus) }
            }
        } catch {
            log("Update failed: \(error.localizedDescription)")
            var canRelaunch = !backedUp && fileManager.fileExists(atPath: installed.path)
            if backedUp {
                do {
                    if fileManager.fileExists(atPath: installed.path) { try fileManager.removeItem(at: installed) }
                    try fileManager.moveItem(at: backup, to: installed)
                    log("Restored existing application")
                    canRelaunch = true
                } catch {
                    log("Rollback failed: \(error.localizedDescription); backup retained at \(backup.path)")
                }
            }
            // The controller already exited, even if a precondition or the first move failed.
            if canRelaunch && !skipLaunch {
                let status = run("/usr/bin/open", [installed.path])
                if status == 0 { log("Relaunched existing application") }
                else { log("Existing application launch failed with status \(status)") }
            }
            exit(1)
        }

        // The new app is verified and may already be running. Cleanup can partially
        // delete a backup, so a cleanup error must never enter the rollback path.
        var cleanupFailed = false
        for path in [backup, staged] {
            do {
                try fileManager.removeItem(at: path)
            } catch {
                cleanupFailed = true
                log("Update failed: installed application retained; cleanup failed at \(path.path): \(error.localizedDescription)")
            }
        }
        if cleanupFailed { exit(1) }
        log(skipLaunch ? "Update installed (launch skipped)" : "Update installed and application relaunched")
        exit(0)
    }

    private static func run(_ path: String, _ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        } catch {
            return 127
        }
    }

    private enum InstallerError: LocalizedError {
        case missingApplication, backupExists, copyFailed(Int32), signatureFailed(Int32), launchFailed(Int32)
        var errorDescription: String? {
            switch self {
            case .backupExists: return "A previous update backup exists; recover or remove it before retrying"
            case .missingApplication: return "Staged or installed application is missing"
            case .copyFailed(let code): return "ditto failed with status \(code)"
            case .signatureFailed(let code): return "codesign verification failed with status \(code)"
            case .launchFailed(let code): return "open failed with status \(code)"
            }
        }
    }
}
