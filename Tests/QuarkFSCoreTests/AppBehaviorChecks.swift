import AppKit
import Darwin
import Foundation
import QuarkFSCore

private final class TestCredentials: CredentialStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var value: String? = "test-only-cookie"
    private var reads = 0
    func save(_ value: String) throws { lock.lock(); defer { lock.unlock() }; self.value = value }
    func contains() throws -> Bool { lock.lock(); defer { lock.unlock() }; return value != nil }
    func load() throws -> String? { lock.lock(); defer { lock.unlock() }; reads += 1; return value }
    func delete() throws { lock.lock(); defer { lock.unlock() }; value = nil }
    var loadCount: Int { lock.lock(); defer { lock.unlock() }; return reads }
}

@main
struct AppBehaviorChecks {
    @MainActor static func main() async throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/AppBehavior-\(UUID().uuidString)")
        let paths = AppPaths(baseDirectory: root.appendingPathComponent("Support"))
        let suite = "QuarkFS.Tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let credentials = TestCredentials()
        let model = AppModel(credentialStore: credentials, defaults: defaults, paths: paths)
        model.settings.mountPath = root.appendingPathComponent("Mount").path
        model.settings.infusePort = try freePort()
        model.settings.openFinderAfterMount = false
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }

        do {
            await model.bootstrap()
            try require(model.infuseBridgeRunning && !model.isBusy, "bootstrap checks an actual HTTP response")
            try require(credentials.loadCount == 1, "credentials read once")
            let oldPort = model.settings.infusePort
            let newPort = try freePort()
            await model.applyInfusePort(String(newPort))
            try require(model.infuseBridgeRunning && model.settings.infusePort == newPort, "port change restarts the bridge")
            try require(await connection(port: newPort) == .ready, "new port accepts WebDAV")
            try require(await connection(port: oldPort) != .ready, "old port is closed")
            try require(credentials.loadCount == 1, "restart reuses the credential")

            let conflict = AppModel(credentialStore: TestCredentials(), defaults: UserDefaults(suiteName: suite + ".conflict")!,
                                    paths: AppPaths(baseDirectory: root.appendingPathComponent("ConflictSupport")))
            conflict.settings.mountPath = originalSafeMount(root)
            conflict.settings.infusePort = newPort
            await conflict.bootstrap()
            let conflictPassed = !conflict.infuseBridgeRunning && !conflict.infuseBridgeActive
            _ = await conflict.shutdownNow()
            UserDefaults.standard.removePersistentDomain(forName: suite + ".conflict")
            try require(conflictPassed, "occupied WebDAV port cannot be mistaken for our running bridge")
            try require(model.infuseBridgeRunning, "port conflict must not stop the existing bridge")

            await model.disconnectInfuseBridge()
            try require(!model.infuseBridgeActive && !model.infuseBridgeRunning, "stop updates state")
            try require(await connection(port: newPort) != .ready, "stop closes the listener")
            await model.bootstrap()
            try require(!model.infuseBridgeActive, "reopening the window does not undo an explicit stop")
            await model.restartInfuseBridge()
            try require(model.infuseBridgeRunning, "stopped bridge can restart")

            if ProcessInfo.processInfo.environment["QUARKFS_TEST_REAL_ENGINE_PATH"] != nil {
                let source = paths.supportDirectory.appendingPathComponent("FixtureRemote")
                try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
                let sentinel = Data("local-only-mount-regression".utf8)
                try sentinel.write(to: source.appendingPathComponent("Sentinel.txt"))
                await model.mount()
                await model.mount() // Repeated clicks must not create another engine.
                try require(await waitUntil { model.status == .mounted }, "real local mount becomes ready, including bounded EBUSY retry")
                let mountedFile = URL(fileURLWithPath: model.settings.mountPath).appendingPathComponent("Sentinel.txt")
                try require(try Data(contentsOf: mountedFile) == sentinel, "the mounted local source is readable")
                let expectedAttempts = ProcessInfo.processInfo.environment["QUARKFS_TEST_BUSY_FIRST"] == "1" ? "2" : "1"
                let counter = paths.supportDirectory.appendingPathComponent("mount-attempt-count")
                try require(try String(contentsOf: counter) == expectedAttempts, "duplicate mount click is ignored and EBUSY retries only once")
                model.unmount()
                await model.mount() // Block remount until normal unmount and exit finish.
                try require(await waitUntil { model.status == .notMounted && !model.isBusy }, "unmount waits for the actual mount and owned engine to stop")
                try require(try String(contentsOf: counter) == expectedAttempts, "remount during unmount is blocked")
                await model.mount()
                try require(await waitUntil { model.status == .mounted }, "mount can restart after the previous engine has exited")
                model.unmount()
                try require(await waitUntil { model.status == .notMounted && !model.isBusy }, "second mount cleans up normally")
                let busyPaths = AppPaths(baseDirectory: root.appendingPathComponent("BusySupport"))
                try busyPaths.prepare()
                try Data("busy-always".utf8).write(to: busyPaths.supportDirectory.appendingPathComponent("mount-failure-mode"))
                let busySuite = suite + ".busy"
                let busyDefaults = UserDefaults(suiteName: busySuite)!
                defer { busyDefaults.removePersistentDomain(forName: busySuite) }
                let busyModel = AppModel(credentialStore: TestCredentials(), defaults: busyDefaults, paths: busyPaths)
                busyModel.settings.mountPath = root.appendingPathComponent("BusyMount").path
                busyModel.settings.openFinderAfterMount = false
                for cycle in 1...3 {
                    await busyModel.mount()
                    try require(await waitUntil {
                        if case .failed(let detail) = busyModel.status {
                            return detail.contains("macFUSE") && !busyModel.mountOperationInProgress
                        }
                        return false
                    }, "immediate stderr EBUSY retains its precise diagnosis after exit")
                    let attempts = try String(contentsOf: busyPaths.supportDirectory.appendingPathComponent("mount-attempt-count"))
                    try require(attempts == String(cycle * 2), "a persistent EBUSY retries at most once per user request")
                }
                try require(await busyModel.shutdownNow(), "persistent failure leaves no mount or owned process")
                print("PASS: real local macFUSE mount/read/unmount/remount, repeated-click exclusion and bounded EBUSY recovery across six immediate failures")
            }

            let originalMount = model.settings.mountPath
            await model.applyMountPath(paths.supportDirectory.path)
            try require(model.settings.mountPath == originalMount, "application data cannot become the mount directory")
            await model.applyInfusePort("70000")
            try require(model.settings.infusePort == newPort, "invalid port is rejected")
            try Data("cache".utf8).write(to: paths.infuseCacheDirectory.appendingPathComponent("sample"))
            await model.clearCache()
            try require(model.infuseBridgeRunning, "cache cleanup restarts the bridge")
            try require(!FileManager.default.fileExists(atPath: paths.infuseCacheDirectory.appendingPathComponent("sample").path), "cache data is removed after stopping the process")

            await model.forgetCredential()
            try require(!model.infuseBridgeActive && !model.preflight.hasCredential, "logout stops the bridge")
            try require(!FileManager.default.fileExists(atPath: paths.runtimeConfig.path), "logout removes runtime credentials")
            model.cookieInput = "replacement-test-only-cookie"
            await model.saveCookie()
            try require(model.infuseBridgeRunning && credentials.loadCount == 2, "new login invalidates cached credentials")
            try require(await model.shutdownNow(), "application can shut down cleanly")
            try require(await connection(port: newPort) != .ready, "quit leaves no listener")
            try require(!FileManager.default.fileExists(atPath: paths.runtimeConfig.path), "quit removes runtime credentials")
            print("PASS: application startup, readiness, port change, stop/restart, window reopening, cache cleanup, logout/login and shutdown")
        } catch {
            _ = await model.shutdownNow()
            throw error
        }
    }

    @MainActor static func waitUntil(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<80 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(125))
        }
        return condition()
    }

    static func require(_ condition: Bool, _ message: String) throws {
        guard condition else { throw NSError(domain: "QuarkFS.BehaviorTests", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    }

    static func originalSafeMount(_ root: URL) -> String { root.appendingPathComponent("ConflictMount").path }

    static func connection(port: Int) async -> WebDAVHealth {
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        return await WebDAVHealth.check(url: URL(string: "http://127.0.0.1:\(port)/")!, session: session)
    }

    static func freePort() throws -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard result == 0 else { throw POSIXError(.EADDRINUSE) }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        return Int(UInt16(bigEndian: addr.sin_port))
    }
}
