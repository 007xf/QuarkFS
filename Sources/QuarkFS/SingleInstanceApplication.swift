import AppKit
import QuarkFSCore

@MainActor
enum SingleInstanceApplication {
    static let bundleIdentifier = "com.holmes.QuarkFS"

    /// Called before AppModel can read credentials, rewrite rclone.conf, or
    /// launch an engine. Copies at other paths share the same per-user lock.
    static func acquireOrActivateExisting() -> ApplicationInstanceLock {
        do {
            let directory = AppPaths().supportDirectory
            let manager = FileManager.default
            guard (try? manager.destinationOfSymbolicLink(atPath: directory.path)) == nil else {
                throw POSIXError(.ELOOP)
            }
            try manager.createDirectory(at: directory, withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])
            let lock = try ApplicationInstanceLock.acquire(
                at: directory.appendingPathComponent("Application.lock")
            )
            let current = NSRunningApplication.current
            let legacyInstance = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
                .filter { app in
                    guard app.processIdentifier != current.processIdentifier, !app.isTerminated else { return false }
                    // Only pre-lock releases may override the OS lock. Looking
                    // at launch order for two lock-aware instances could make
                    // both exit while the losing process is still registered.
                    guard let url = app.bundleURL,
                          let version = Bundle(url: url)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
                    else { return false }
                    return version.compare("1.1.1", options: .numeric) == .orderedAscending
                }
                .min { ($0.launchDate ?? .distantPast) < ($1.launchDate ?? .distantPast) }

            if lock == nil || legacyInstance != nil {
                let owner = legacyInstance ?? NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
                    .first { $0.processIdentifier != current.processIdentifier && !$0.isTerminated }
                owner?.activate(options: [.activateAllWindows])
                exit(EXIT_SUCCESS)
            }
            return lock!
        } catch {
            let alert = NSAlert()
            alert.messageText = "无法安全启动 QuarkFS"
            alert.informativeText = "无法取得应用运行锁。请确认应用数据目录可访问后重试。\n\(error.localizedDescription)"
            alert.alertStyle = .warning
            alert.addButton(withTitle: "退出")
            alert.runModal()
            exit(EXIT_FAILURE)
        }
    }
}
