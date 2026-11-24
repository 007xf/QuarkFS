import AppKit
import Darwin
import Foundation
import QuarkFSCore

private final class StubUpdateTransport: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var response: UpdateChecker.HTTPResponse
    private var failOffline = false

    init(tag: String = "v1.1.3", body: String = "stub notes") {
        let json = """
        {"tag_name":"\(tag)","html_url":"https://github.com/007xf/QuarkFS/releases/tag/\(tag)","published_at":"2026-11-24T10:00:00Z","body":"\(body)"}
        """
        self.response = UpdateChecker.HTTPResponse(statusCode: 200, data: Data(json.utf8))
    }

    var callCount: Int { lock.withLock { count } }

    func setFailOffline(_ flag: Bool) {
        lock.withLock { failOffline = flag }
    }

    func setRelease(tag: String, body: String = "stub notes") {
        let json = """
        {"tag_name":"\(tag)","html_url":"https://github.com/007xf/QuarkFS/releases/tag/\(tag)","published_at":"2026-11-24T10:00:00Z","body":"\(body)"}
        """
        lock.withLock {
            failOffline = false
            response = UpdateChecker.HTTPResponse(statusCode: 200, data: Data(json.utf8))
        }
    }

    func makeTransport() -> UpdateChecker.Transport {
        { [self] _, _ in
            try self.lock.withLock {
                self.count += 1
                if self.failOffline { throw UpdateChecker.Failure.offline }
                return self.response
            }
        }
    }
}

private final class TestCredentials: CredentialStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var value: String? = "test-only-cookie"
    private var reads = 0
    func save(_ value: String) throws { lock.lock(); defer { lock.unlock() }; self.value = value }
    func contains() throws -> Bool { lock.lock(); defer { lock.unlock() }; return value != nil }
    func load() throws -> String? { lock.lock(); defer { lock.unlock() }; reads += 1; return value }
    func delete() throws { lock.lock(); defer { lock.unlock() }; value = nil }
    var loadCount: Int { lock.lock(); defer { lock.unlock() }; return reads }
    var current: String? { lock.lock(); defer { lock.unlock() }; return value }
}

/// Replaces /sbin/mount and /sbin/umount with scripts backed by a table file in
/// a test support directory, so busy or unreadable mounts can be exercised
/// without macFUSE. EngineFixture.py simulates cmount against the same table.
private struct FakeSystem {
    let table: URL
    let busyMarker: URL
    let unreadableMarker: URL
    let services: SystemServices

    init(supportDirectory: URL) throws {
        table = supportDirectory.appendingPathComponent("fake-mount-table")
        busyMarker = supportDirectory.appendingPathComponent("fake-umount-busy")
        unreadableMarker = supportDirectory.appendingPathComponent("fake-mount-unreadable")
        let mountTool = supportDirectory.appendingPathComponent("fake-mount")
        let unmountTool = supportDirectory.appendingPathComponent("fake-umount")
        try """
        #!/bin/zsh
        [[ -e '\(unreadableMarker.path)' ]] && { print -u2 'mount: cannot read the mount table'; exit 1 }
        [[ -f '\(table.path)' ]] && cat '\(table.path)'
        exit 0
        """.write(to: mountTool, atomically: true, encoding: .utf8)
        try """
        #!/bin/zsh
        [[ -e '\(busyMarker.path)' ]] && { print -u2 "umount($1): Resource busy -- try 'diskutil unmount'"; exit 1 }
        [[ -f '\(table.path)' ]] || exit 1
        grep -vF " on ${1// /\\040} (" '\(table.path)' > '\(table.path).new'
        mv '\(table.path).new' '\(table.path)'
        exit 0
        """.write(to: unmountTool, atomically: true, encoding: .utf8)
        for tool in [mountTool, unmountTool] {
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: tool.path)
        }
        services = SystemServices(mountTable: mountTool, unmount: unmountTool, macFUSEStatus: { (true, true) })
        try Data().write(to: table)
    }

    func addQuarkMount(at path: String) throws {
        let line = "quark{fixture}: on \(path.replacingOccurrences(of: " ", with: "\\040")) (macfuse, nodev, nosuid, read-only)\n"
        let handle = try FileHandle(forWritingTo: table)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(line.utf8))
    }

    func set(_ marker: URL, _ enabled: Bool) throws {
        if enabled { try Data().write(to: marker) } else { try? FileManager.default.removeItem(at: marker) }
    }
}

@main
struct AppBehaviorChecks {
    @MainActor static func main() async throws {
        if CommandLine.arguments.count == 5, CommandLine.arguments[1] == "--crash-after-bootstrap" {
            try await crashAfterBootstrap(support: URL(fileURLWithPath: CommandLine.arguments[2]),
                                          port: Int(CommandLine.arguments[3])!, suite: CommandLine.arguments[4])
            return
        }
        var setup = PreflightState()
        try require(!setup.needsSetup, "unresolved initial checks do not flash the setup card")
        setup.hasCompletedCheck = true
        try require(setup.needsSetup, "completed checks show missing setup requirements")
        setup.engine = EngineInspection(path: "fixture", isQuarkCapable: true, mountCommand: "cmount", version: nil, problem: nil)
        setup.macFUSEReady = true
        setup.hasCredential = true
        try require(!setup.needsSetup && !setup.ready, "healthy setup stays hidden even when the mount directory needs attention")
        setup.hasCredential = false
        try require(setup.needsSetup, "logout restores the setup card")
        setup.hasCredential = true
        setup.macFUSEReady = false
        try require(setup.needsSetup, "a missing macFUSE extension restores the setup card")
        setup.macFUSEReady = true
        setup.engine = EngineInspection(path: "fixture", isQuarkCapable: true, mountCommand: "nfsmount", version: nil, problem: nil)
        try require(setup.needsSetup, "an engine without cmount is not considered fully configured")

        try checkMenuBarGlyph()

        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/AppBehavior-\(UUID().uuidString)")
        let paths = AppPaths(baseDirectory: root.appendingPathComponent("Support"))
        let suite = "QuarkFS.Tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let credentials = TestCredentials()
        let stubUpdates = StubUpdateTransport(tag: "v1.1.3")
        let model = AppModel(
            credentialStore: credentials,
            defaults: defaults,
            paths: paths,
            runningVersion: "1.1.3",
            openURL: { _ in },
            updateTransport: stubUpdates.makeTransport()
        )
        model.settings.mountPath = root.appendingPathComponent("Mount").path
        model.settings.infusePort = try freePort()
        model.settings.openFinderAfterMount = false
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }

        do {
            try paths.prepare()
            let bootLeftover = paths.runtimeDirectory.appendingPathComponent(".rclone-boot-leftover.tmp")
            try Data("leftover-secret".utf8).write(to: bootLeftover)
            await model.bootstrap()
            try require(!FileManager.default.fileExists(atPath: bootLeftover.path),
                        "bootstrap removes leftover .rclone-*.tmp files from a prior crash")
            try require(model.infuseBridgeRunning && !model.isBusy, "bootstrap checks an actual HTTP response")
            try require(credentials.loadCount == 1, "credentials read once")
            try require(await anonymousConnection(port: model.settings.infusePort) != .ready,
                        "the bridge rejects requests without the WebDAV password (other users, sandboxed apps, DNS rebinding)")
            let bridgeCredentials = try model.webDAVCredentials()
            let bridgeAuthorization = bridgeCredentials.authorization
            try require(await connection(port: model.settings.infusePort, authorization: bridgeAuthorization) == .ready,
                        "the bridge accepts the generated WebDAV credentials")
            let wrongPassword = WebDAVCredentials(username: bridgeCredentials.username, password: String(repeating: "x", count: 32))
            try require(await connection(port: model.settings.infusePort, authorization: wrongPassword.authorization) != .ready,
                        "the bridge rejects a wrong WebDAV password")
            let connectionText = try model.infuseConnectionText()
            try require(connectionText.contains("用户名：\(bridgeCredentials.username)") && connectionText.contains("密码：\(bridgeCredentials.password)"),
                        "copied connection details include the WebDAV credentials")
            try require(!(ProcessInfo.processInfo.environment["RCLONE_PASS"] ?? "").contains(bridgeCredentials.password),
                        "the WebDAV password is passed only to the engine, not to the app's own environment")
            try require(try permissions(of: paths.webDAVCredentials) == 0o600, "WebDAV credentials are readable only by the user")
            let clipboard = NSPasteboard(name: NSPasteboard.Name("QuarkFS.Tests.\(UUID().uuidString)"))
            defer { clipboard.releaseGlobally() }
            model.copyInfuseConnection(to: clipboard)
            let clipboardTypes = clipboard.types ?? []
            try require(clipboard.string(forType: .string) == connectionText, "copy connection info puts the connection text on the pasteboard")
            try require(clipboardTypes.contains(NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
                        && clipboardTypes.contains(NSPasteboard.PasteboardType("org.nspasteboard.TransientType")),
                        "the copied WebDAV password is marked concealed and transient so clipboard managers skip it")

            // A player reads a large file that Quark refuses to the web client.
            _ = await get(port: model.settings.infusePort, path: "/Movies/QuarkFS-size-limit.mkv", authorization: bridgeAuthorization)
            try require(await waitUntil { model.logs.contains { $0.contains("23018") && $0.contains("QuarkFS-size-limit.mkv") } },
                        "an engine read refused by Quark (code 23018) is reported in the activity log")
            try require(model.readIssue?.contains("23018") == true && model.infuseBridgeRunning,
                        "the refused read is shown in the window and menu while the bridge keeps serving")
            try require(model.logs.filter { $0.contains("23018") }.count == 1, "repeated engine errors for one file are reported once")
            _ = await get(port: model.settings.infusePort, path: "/many-size-limits-then-expired", authorization: bridgeAuthorization)
            try require(await waitUntil { model.readIssue?.contains("登录已失效") == true && model.infuseBridgeDetail.contains("登录已失效") },
                        "an expired session is still reported after 20 other engine issues have been shown")
            let configLines = try runtimeConfigLines(paths)
            try require(configLines.first == "[quark]" && configLines.contains("type = quark")
                        && configLines.contains("cookie = \(fixtureObscured("test-only-cookie"))"),
                        "runtime config names the quark remote and carries the obscured Keychain cookie")
            try require(try permissions(of: paths.runtimeConfig) == 0o600, "runtime config is readable only by the user")
            try require(configLines.contains("user_agent = \(quarkClientUserAgent)"),
                        "engine requests download links as the Quark PC client, not as the web page")
            try require(configLines.count == 4, "runtime config contains only the remote type, cookie and user agent")
            try require(model.preflight.hasCompletedCheck, "the first live preflight resolves setup visibility")
            let oldPort = model.settings.infusePort
            let newPort = try freePort()
            await model.applyInfusePort(String(newPort))
            try require(model.infuseBridgeRunning && model.settings.infusePort == newPort, "port change restarts the bridge")
            try require(await connection(port: newPort, authorization: bridgeAuthorization) == .ready, "new port accepts WebDAV")
            try require(await connection(port: oldPort, authorization: bridgeAuthorization) != .ready, "old port is closed")
            try require(credentials.loadCount == 1, "restart reuses the credential")

            let conflict = AppModel(credentialStore: TestCredentials(), defaults: UserDefaults(suiteName: suite + ".conflict")!,
                                    paths: AppPaths(baseDirectory: root.appendingPathComponent("ConflictSupport")),
                                    runningVersion: "1.1.3", openURL: { _ in }, updateTransport: StubUpdateTransport().makeTransport())
            conflict.settings.mountPath = originalSafeMount(root)
            conflict.settings.infusePort = newPort
            await conflict.bootstrap()
            let conflictPassed = !conflict.infuseBridgeRunning && !conflict.infuseBridgeActive
            _ = await conflict.shutdownNow()
            UserDefaults.standard.removePersistentDomain(forName: suite + ".conflict")
            try require(conflictPassed, "occupied WebDAV port cannot be mistaken for our running bridge")
            try require(model.infuseBridgeRunning, "port conflict must not stop the existing bridge")

            // The engine starts but its directory check fails (an expired
            // session answering 403, or a non-DAV response).
            for mode in ["403", "html"] {
                let failingPaths = AppPaths(baseDirectory: root.appendingPathComponent("FailingSupport-\(mode)"))
                try failingPaths.prepare()
                try Data(mode.utf8).write(to: failingPaths.supportDirectory.appendingPathComponent("webdav-failure-mode"))
                let failingSuite = suite + ".failing-\(mode)"
                let failing = AppModel(credentialStore: TestCredentials(), defaults: UserDefaults(suiteName: failingSuite)!,
                                       paths: failingPaths, runningVersion: "1.1.3", openURL: { _ in },
                                       updateTransport: StubUpdateTransport().makeTransport())
                failing.settings.mountPath = root.appendingPathComponent("FailingMount").path
                failing.settings.infusePort = try freePort()
                await failing.bootstrap()
                let reported = !failing.infuseBridgeRunning && !failing.infuseBridgeActive
                    && failing.infuseBridgeDetail.contains("检查") && !failing.infuseBridgeDetail.contains("已就绪")
                let listenerClosed = WebDAVHealth.isPortAvailable(failing.settings.infusePort)
                _ = await failing.shutdownNow()
                UserDefaults.standard.removePersistentDomain(forName: failingSuite)
                try require(reported && listenerClosed,
                            "a bridge whose directory check fails (\(mode)) is stopped and reported, never shown as ready")
            }

            // Another local service already listens on the requested port.
            let listener = try listeningSocket()
            await model.applyInfusePort(String(listener.port))
            let keptRunning = model.infuseBridgeRunning && model.settings.infusePort == newPort
            let keptServing = await connection(port: newPort, authorization: bridgeAuthorization) == .ready
            let savedPort = defaults.data(forKey: "QuarkFS.settings.v1")
                .flatMap { try? JSONDecoder().decode(AppSettings.self, from: $0) }?.infusePort
            close(listener.descriptor)
            try require(keptRunning && keptServing && savedPort == newPort,
                        "an occupied port is rejected before the working bridge is stopped, and is not saved")
            try require(model.infuseBridgeDetail.contains(String(listener.port)), "the rejected port is explained")
            // A free port on which the engine still fails to serve.
            let refusedPort = try freePort()
            let refusedMarker = paths.supportDirectory.appendingPathComponent("webdav-failure-port")
            try Data(String(refusedPort).utf8).write(to: refusedMarker)
            await model.applyInfusePort(String(refusedPort))
            try FileManager.default.removeItem(at: refusedMarker)
            let rolledBackServing = await connection(port: newPort, authorization: bridgeAuthorization) == .ready
            try require(model.infuseBridgeRunning && model.settings.infusePort == newPort && rolledBackServing,
                        "a port change whose restart fails is rolled back to the working port")
            try require(model.logs.contains { $0.contains("已恢复端口 \(newPort)") }, "the rollback is explained")

            await model.disconnectInfuseBridge()
            try require(!model.infuseBridgeActive && !model.infuseBridgeRunning, "stop updates state")
            try require(!model.logs.contains { $0.contains("连接已停止（代码") },
                        "deliberate stops and restarts are not reported as an unexpected bridge exit")
            try require(await connection(port: newPort, authorization: bridgeAuthorization) != .ready, "stop closes the listener")
            await model.bootstrap()
            try require(!model.infuseBridgeActive, "reopening the window does not undo an explicit stop")
            await model.restartInfuseBridge()
            try require(model.infuseBridgeRunning, "stopped bridge can restart")
            if let pid = model.infuseBridgeProcessIdentifier { kill(pid, SIGKILL) }
            try require(await waitUntil { !model.infuseBridgeRunning && model.logs.contains { $0.contains("连接已停止（代码") } },
                        "an unexpected bridge exit is still reported")
            await model.restartInfuseBridge()
            try require(model.infuseBridgeRunning, "the bridge restarts after an unexpected exit")

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
                let busyModel = AppModel(credentialStore: TestCredentials(), defaults: busyDefaults, paths: busyPaths,
                                         runningVersion: "1.1.3", openURL: { _ in },
                                         updateTransport: StubUpdateTransport().makeTransport())
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
            let stopObservation = paths.supportDirectory.appendingPathComponent("webdav-stop-observation")
            try? FileManager.default.removeItem(at: stopObservation)
            let bridgeBeforeCleanup = model.infuseBridgeProcessIdentifier
            await model.clearCache()
            try require(model.infuseBridgeRunning, "cache cleanup restarts the bridge")
            try require(!FileManager.default.fileExists(atPath: paths.infuseCacheDirectory.appendingPathComponent("sample").path), "cache data is removed after stopping the process")
            try require((try? String(contentsOf: stopObservation, encoding: .utf8)) == "cache-present",
                        "the serving bridge is stopped before its cache is deleted")
            try require(bridgeBeforeCleanup != nil && model.infuseBridgeProcessIdentifier != nil
                        && model.infuseBridgeProcessIdentifier != bridgeBeforeCleanup,
                        "cache cleanup replaces the bridge process instead of keeping the old one")

            try await checkCancelledQuit(root: root, suite: suite)
            try await checkLoginDuringOtherWork(root: root, suite: suite)
            try await checkUnmountOutcomes(root: root, suite: suite)
            try await checkRelaunchAfterCrash(root: root, suite: suite)
            try await checkRelaunchAfterCrash(root: root, suite: suite, loggedOut: true)
            try await checkUpdateLifecycle(root: root, suite: suite)

            let forgetLeftover = paths.runtimeDirectory.appendingPathComponent(".rclone-forget-leftover.tmp")
            try Data("leftover-secret".utf8).write(to: forgetLeftover)
            await model.forgetCredential()
            try require(!model.infuseBridgeActive && !model.preflight.hasCredential, "logout stops the bridge")
            try require(model.preflight.needsSetup, "logout refreshes the visible setup requirement")
            try require(!FileManager.default.fileExists(atPath: paths.runtimeConfig.path), "logout removes runtime credentials")
            try require(!FileManager.default.fileExists(atPath: forgetLeftover.path),
                        "logout removes leftover .rclone-*.tmp files alongside rclone.conf")
            model.cookieInput = "replacement-test-only-cookie"
            await model.saveCookie()
            try require(model.infuseBridgeRunning && credentials.loadCount == 2, "new login invalidates cached credentials")
            try require(try runtimeConfigLines(paths).contains("cookie = \(fixtureObscured("replacement-test-only-cookie"))"),
                        "the runtime config uses the cookie of the new login")
            model.cookieInput = "second-test-only-cookie"
            await model.saveCookie() // A login without logging out first.
            try require(model.infuseBridgeRunning && credentials.loadCount == 3,
                        "a login while still logged in re-reads the new credential instead of the cached one")
            try require(try runtimeConfigLines(paths).contains("cookie = \(fixtureObscured("second-test-only-cookie"))"),
                        "a login while still logged in writes the new cookie to the runtime config")
            let quitLeftover = paths.runtimeDirectory.appendingPathComponent(".rclone-quit-leftover.tmp")
            try Data("leftover-secret".utf8).write(to: quitLeftover)
            try require(await model.shutdownNow(), "application can shut down cleanly")
            try require(await connection(port: newPort, authorization: bridgeAuthorization) != .ready, "quit leaves no listener")
            try require(!FileManager.default.fileExists(atPath: paths.runtimeConfig.path), "quit removes runtime credentials")
            try require(!FileManager.default.fileExists(atPath: quitLeftover.path),
                        "quit removes leftover .rclone-*.tmp files alongside rclone.conf")
            try require(UpdateChecker.liveTransportConstructionCount == 0 && UpdateChecker.liveTransportCallCount == 0,
                        "no live update transport may be constructed or called during application behavior checks")
            print("PASS: application startup, readiness, WebDAV authentication, runtime config, read-error reporting, port change and rollback, stop/restart, crash recovery, window reopening, cache cleanup, cancelled quit, login during other work, unmount outcomes, update checks, logout/login and shutdown")
        } catch {
            _ = await model.shutdownNow()
            throw error
        }
    }

    /// A quit that cannot unmount is cancelled; the WebDAV bridge must keep
    /// serving rather than being stopped before the mount was checked.
    @MainActor static func checkCancelledQuit(root: URL, suite: String) async throws {
        let paths = AppPaths(baseDirectory: root.appendingPathComponent("FakeSystemSupport"))
        try paths.prepare()
        let fake = try FakeSystem(supportDirectory: paths.supportDirectory)
        let defaultsSuite = suite + ".fake-system"
        defer { UserDefaults.standard.removePersistentDomain(forName: defaultsSuite) }
        let model = AppModel(credentialStore: TestCredentials(), defaults: UserDefaults(suiteName: defaultsSuite)!,
                             paths: paths, system: fake.services, runningVersion: "1.1.3", openURL: { _ in },
                             updateTransport: StubUpdateTransport().makeTransport())
        model.settings.mountPath = root.appendingPathComponent("FakeMount").path
        model.settings.infusePort = try freePort()
        model.settings.openFinderAfterMount = false
        do {
            await model.bootstrap()
            try require(model.infuseBridgeRunning, "fake-system model starts its bridge")
            let authorization = try model.webDAVCredentials().authorization
            let port = model.settings.infusePort

            // A local player keeps the mounted volume busy.
            try fake.addQuarkMount(at: model.settings.mountPath)
            try fake.set(fake.busyMarker, true)
            await model.refreshPreflight()
            try require(model.hasActiveMount, "the fake Quark mount is adopted")
            let busyQuit = await model.shutdownNow()
            let servingAfterBusyQuit = await connection(port: port, authorization: authorization) == .ready
            try require(!busyQuit && model.infuseBridgeRunning && servingAfterBusyQuit,
                        "a quit cancelled by a busy mount leaves the WebDAV bridge serving")

            // The mount table cannot be read.
            try fake.set(fake.unreadableMarker, true)
            let unreadableQuit = await model.shutdownNow()
            let servingAfterUnreadableQuit = await connection(port: port, authorization: authorization) == .ready
            try require(!unreadableQuit && model.infuseBridgeRunning && servingAfterUnreadableQuit,
                        "a quit cancelled by an unreadable mount table leaves the WebDAV bridge serving")

            try fake.set(fake.unreadableMarker, false)
            try fake.set(fake.busyMarker, false)
            await model.refreshPreflight()
            try require(await model.shutdownNow(), "the quit succeeds once the mount is released")
            try require(WebDAVHealth.isPortAvailable(port) && !model.infuseBridgeRunning, "the completed quit stops the bridge")
            try require(!FileManager.default.fileExists(atPath: paths.runtimeConfig.path), "the completed quit removes runtime credentials")
        } catch {
            try? fake.set(fake.unreadableMarker, false)
            try? fake.set(fake.busyMarker, false)
            try? Data().write(to: fake.table)
            _ = await model.shutdownNow()
            throw error
        }
    }

    /// A scan confirmed on the phone while another operation runs must not be
    /// dropped silently with the login sheet left waiting.
    @MainActor static func checkLoginDuringOtherWork(root: URL, suite: String) async throws {
        let paths = AppPaths(baseDirectory: root.appendingPathComponent("LoginRaceSupport"))
        try paths.prepare()
        let fake = try FakeSystem(supportDirectory: paths.supportDirectory)
        let credentials = TestCredentials()
        let defaultsSuite = suite + ".login-race"
        defer { UserDefaults.standard.removePersistentDomain(forName: defaultsSuite) }
        let model = AppModel(credentialStore: credentials, defaults: UserDefaults(suiteName: defaultsSuite)!,
                             paths: paths, system: fake.services, runningVersion: "1.1.3", openURL: { _ in },
                             updateTransport: StubUpdateTransport().makeTransport())
        model.settings.mountPath = root.appendingPathComponent("LoginRaceMount").path
        model.settings.infusePort = try freePort()
        do {
            await model.bootstrap()
            try require(model.infuseBridgeRunning, "login-race model starts its bridge")

            // The mount table is briefly unreadable when the scan completes.
            try fake.set(fake.unreadableMarker, true)
            await model.refreshPreflight()
            model.showingLogin = true
            let acceptedWhileUnknown = await model.saveCookieFromQR("unsaved-test-only-cookie")
            var explained = false
            if case .failed(let detail) = model.status { explained = detail.contains("登录") }
            try require(!acceptedWhileUnknown && explained && credentials.current == "test-only-cookie",
                        "a login that cannot be saved now is reported instead of being dropped silently")
            try fake.set(fake.unreadableMarker, false)
            await model.refreshPreflight()

            // Cache cleanup is still running when the scan completes.
            try Data().write(to: paths.supportDirectory.appendingPathComponent("webdav-slow-stop"))
            let cleanup = Task { await model.clearCache() }
            try require(await waitUntil { model.isBusy }, "cache cleanup is in progress")
            let acceptedAfterWaiting = await model.saveCookieFromQR("qr-test-only-cookie")
            await cleanup.value
            try FileManager.default.removeItem(at: paths.supportDirectory.appendingPathComponent("webdav-slow-stop"))
            try require(acceptedAfterWaiting && credentials.current == "qr-test-only-cookie" && !model.showingLogin,
                        "a login completed during cache cleanup is saved once the cleanup finishes")
            try require(model.infuseBridgeRunning, "the bridge runs with the new login")
            try require(await model.shutdownNow(), "login-race model shuts down")
        } catch {
            try? fake.set(fake.unreadableMarker, false)
            _ = await model.shutdownNow()
            throw error
        }
    }

    /// The engine's termination can be processed after unmount() has already
    /// finished, for example while macFUSE helpers still hold its output open.
    /// A deliberate unmount or cancel must still end as 未挂载.
    @MainActor static func checkUnmountOutcomes(root: URL, suite: String) async throws {
        let paths = AppPaths(baseDirectory: root.appendingPathComponent("UnmountSupport"))
        try paths.prepare()
        let fake = try FakeSystem(supportDirectory: paths.supportDirectory)
        let neverReady = paths.supportDirectory.appendingPathComponent("fake-mount-never-ready")
        try Data().write(to: paths.supportDirectory.appendingPathComponent("fake-mount-pipe-holder"))
        let defaultsSuite = suite + ".unmount"
        defer { UserDefaults.standard.removePersistentDomain(forName: defaultsSuite) }
        let model = AppModel(credentialStore: TestCredentials(), defaults: UserDefaults(suiteName: defaultsSuite)!,
                             paths: paths, system: fake.services, runningVersion: "1.1.3", openURL: { _ in },
                             updateTransport: StubUpdateTransport().makeTransport())
        model.settings.mountPath = root.appendingPathComponent("UnmountMount").path
        model.settings.infusePort = try freePort()
        model.settings.openFinderAfterMount = false
        do {
            await model.bootstrap()
            try require(model.preflight.ready, "fake-system model is ready to mount")

            // Cancel a mount that has not appeared yet.
            try Data().write(to: neverReady)
            let started = paths.supportDirectory.appendingPathComponent("fake-mount-started")
            await model.mount()
            try require(await waitUntil { model.status == .mounting && FileManager.default.fileExists(atPath: started.path) },
                        "the simulated mount starts")
            model.unmount()
            try require(await waitUntil { !model.isBusy && model.status != .unmounting }, "the cancel finishes")
            try await Task.sleep(for: .milliseconds(2500))
            try require(model.status == .notMounted && !model.mountOperationInProgress,
                        "cancelling a starting mount ends as not mounted, not as an engine failure")

            // A normal mount and unmount.
            try FileManager.default.removeItem(at: neverReady)
            await model.mount()
            try require(await waitUntil { model.status == .mounted }, "the simulated mount becomes ready")
            model.unmount()
            try require(await waitUntil { !model.isBusy && model.status != .unmounting }, "the unmount finishes")
            try await Task.sleep(for: .milliseconds(2500))
            try require(model.status == .notMounted && !model.hasActiveMount,
                        "a completed unmount ends as not mounted")
            try require(await model.shutdownNow(), "unmount model shuts down")
        } catch {
            try? Data().write(to: fake.table)
            _ = await model.shutdownNow()
            throw error
        }
    }

    /// Runs in a child process: start the bridge, then die like a crash or a
    /// force quit, leaving the WebDAV engine running without its app.
    @MainActor static func crashAfterBootstrap(support: URL, port: Int, suite: String) async throws {
        let model = AppModel(credentialStore: TestCredentials(), defaults: UserDefaults(suiteName: suite)!,
                             paths: AppPaths(baseDirectory: support), runningVersion: "1.1.3", openURL: { _ in },
                             updateTransport: StubUpdateTransport().makeTransport())
        model.settings.mountPath = support.deletingLastPathComponent().appendingPathComponent("CrashMount").path
        model.settings.infusePort = port
        await model.bootstrap()
        guard model.infuseBridgeRunning, let pid = model.infuseBridgeProcessIdentifier else { exit(3) }
        try Data(String(pid).utf8).write(to: support.appendingPathComponent("crash-helper-engine"))
        kill(getpid(), SIGKILL)
    }

    /// After a crash the engine keeps serving the port; the next launch must
    /// stop that leftover engine instead of reporting the port as occupied.
    @MainActor static func checkRelaunchAfterCrash(root: URL, suite: String, loggedOut: Bool = false) async throws {
        let support = root.appendingPathComponent(loggedOut ? "LoggedOutCrashSupport" : "CrashSupport")
        let port = try freePort()
        let defaultsSuite = suite + (loggedOut ? ".crash-logged-out" : ".crash")
        defer { UserDefaults.standard.removePersistentDomain(forName: defaultsSuite) }
        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        helper.arguments = ["--crash-after-bootstrap", support.path, String(port), defaultsSuite]
        try helper.run()
        helper.waitUntilExit()
        let recorded = try? String(contentsOf: support.appendingPathComponent("crash-helper-engine"), encoding: .utf8)
        guard let leftover = recorded.flatMap({ Int32($0) }) else {
            throw NSError(domain: "QuarkFS.BehaviorTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "crash helper did not start its bridge"])
        }
        defer { kill(leftover, SIGKILL) } // Never leave the fixture behind, even when a check fails.
        try require(helper.terminationReason == .uncaughtSignal && kill(leftover, 0) == 0,
                    "the crashed app left its WebDAV engine running")

        let relaunchCredentials = TestCredentials()
        if loggedOut { try relaunchCredentials.delete() }
        let model = AppModel(credentialStore: relaunchCredentials, defaults: UserDefaults(suiteName: defaultsSuite)!,
                             paths: AppPaths(baseDirectory: support), runningVersion: "1.1.3", openURL: { _ in },
                             updateTransport: StubUpdateTransport().makeTransport())
        model.settings.mountPath = root.appendingPathComponent("CrashMount").path
        model.settings.infusePort = port
        await model.bootstrap()
        if loggedOut {
            // The leftover engine still holds the old cookie in memory; a
            // relaunch without a login must stop it, not leave it serving.
            let stopped = await waitUntil { kill(leftover, 0) != 0 }
            let notStarted = !model.infuseBridgeRunning
            _ = await model.shutdownNow()
            try require(stopped, "a relaunch while logged out still stops the leftover engine of the crashed app")
            try require(notStarted, "a relaunch while logged out does not start a new bridge")
            return
        }
        let recovered = model.infuseBridgeRunning && model.infuseBridgeProcessIdentifier != leftover
            && model.logs.contains { $0.contains("遗留") }
        let leftoverStopped = await waitUntil { kill(leftover, 0) != 0 }
        _ = await model.shutdownNow()
        try require(recovered, "a relaunch after a crash recovers the port held by the app's own leftover engine")
        try require(leftoverStopped, "the leftover engine is stopped, not left serving beside the new one")
    }

    /// Menu-bar glyph mapping covers every MountStatus case plus read issues,
    /// builds accurate VoiceOver labels, caches 22x22 pt template images, keeps
    /// cut-outs transparent beside solid ink, and differentiates all four states.
    @MainActor static func checkMenuBarGlyph() throws {
        let allStatuses: [(MountStatus, MenuBarGlyphState, String, String)] = [
            (.notMounted, .idle, "QuarkFS · 未挂载", "QuarkFS · 未挂载 · 需要处理"),
            (.mounting, .busy, "QuarkFS · 正在挂载", "QuarkFS · 正在挂载 · 需要处理"),
            (.unmounting, .busy, "QuarkFS · 正在卸载", "QuarkFS · 正在卸载 · 需要处理"),
            (.mounted, .mounted, "QuarkFS · 已挂载", "QuarkFS · 已挂载 · 需要处理"),
            (.failed("err"), .attention, "QuarkFS · 需要处理", "QuarkFS · 需要处理")
        ]
        for (status, expectedState, normalLabel, readIssueLabel) in allStatuses {
            try require(MenuBarGlyphState.from(status: status, hasReadIssue: false) == expectedState,
                        "status \(status) maps to \(expectedState)")
            try require(MenuBarGlyphState.from(status: status, hasReadIssue: true) == .attention,
                        "status \(status) with read issue maps to attention")
            try require(MenuBarGlyph.accessibilityLabel(for: status, hasReadIssue: false) == normalLabel,
                        "accessibility label for \(status) must be \(normalLabel)")
            try require(MenuBarGlyph.accessibilityLabel(for: status, hasReadIssue: true) == readIssueLabel,
                        "accessibility label for \(status) with read issue must be \(readIssueLabel)")
        }

        var bitmaps: [MenuBarGlyphState: Data] = [:]
        for state in MenuBarGlyphState.allCases {
            let image = MenuBarGlyph.image(for: state)
            try require(image === MenuBarGlyph.image(for: state), "menu-bar glyph \(state) must be cached")
            try require(image.isTemplate, "menu-bar glyph \(state) must be a template image")
            try require(image.size == NSSize(width: 22, height: 22), "menu-bar glyph \(state) must be 22x22 pt")

            // Rasterize at 2x into an RGBA bitmap and verify ink coverage, positive controls & transparent cut-outs.
            let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: 44, pixelsHigh: 44,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
            )!
            rep.size = NSSize(width: 22, height: 22)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            image.draw(in: NSRect(x: 0, y: 0, width: 22, height: 22))
            NSGraphicsContext.restoreGraphicsState()

            var opaquePixels = 0
            var alphaBytes: [UInt8] = []
            alphaBytes.reserveCapacity(44 * 44)
            for y in 0..<44 {
                for x in 0..<44 {
                    let alpha = rep.colorAt(x: x, y: y)?.alphaComponent ?? 0
                    alphaBytes.append(UInt8(min(255, max(0, Int((alpha * 255).rounded())))))
                    if alpha > 0.5 { opaquePixels += 1 }
                }
            }
            try require(opaquePixels > 100, "menu-bar glyph \(state) draws visible strokes")
            bitmaps[state] = Data(alphaBytes)

            switch state {
            case .idle:
                // Positive control on drive top stroke (11, 13) -> (22, 26) and LED dot (15.4, 16) -> (31, 32).
                let strokeAlpha = rep.colorAt(x: 22, y: 26)?.alphaComponent ?? 0
                let ledAlpha = rep.colorAt(x: 31, y: 32)?.alphaComponent ?? 0
                try require(strokeAlpha > 0.9 && ledAlpha > 0.9, "idle glyph draws opaque drive stroke and LED")
            case .busy:
                // Positive control on centre dot (11, 16) -> (22, 32) and stream curve (11.1, 9.5) -> (22, 19).
                let centerDotAlpha = rep.colorAt(x: 22, y: 32)?.alphaComponent ?? 0
                let streamAlpha = rep.colorAt(x: 22, y: 19)?.alphaComponent ?? 0
                try require(centerDotAlpha > 0.9 && streamAlpha > 0.9, "busy glyph draws opaque stream and dots")
            case .mounted:
                // Cut-outs: slot (8.45, 16) -> (17, 32) and LED (15.4, 16) -> (31, 32).
                // Positive controls right beside cut-outs on solid drive body: (8.45, 13.8) -> (17, 28) and (13.0, 16) -> (26, 32).
                let slotAlpha = rep.colorAt(x: 17, y: 32)?.alphaComponent ?? 1
                let ledAlpha = rep.colorAt(x: 31, y: 32)?.alphaComponent ?? 1
                let bodyAboveSlot = rep.colorAt(x: 17, y: 28)?.alphaComponent ?? 0
                let bodyBetween = rep.colorAt(x: 26, y: 32)?.alphaComponent ?? 0
                try require(slotAlpha < 0.05 && ledAlpha < 0.05 && bodyAboveSlot > 0.9 && bodyBetween > 0.9,
                            "mounted drive cut-outs must be transparent beside opaque solid body")
            case .attention:
                // Cut-outs: stem (17, 15.6) -> (34, 31), dot (17, 18.75) -> (34, 37), clear ring (12.4, 16.6) -> (25, 33).
                // Positive controls on badge disc beside '!' at (14.5, 16.6) -> (29, 33) and (19.5, 16.6) -> (39, 33).
                let stemAlpha = rep.colorAt(x: 34, y: 31)?.alphaComponent ?? 1
                let dotAlpha = rep.colorAt(x: 34, y: 37)?.alphaComponent ?? 1
                let ringAlpha = rep.colorAt(x: 25, y: 33)?.alphaComponent ?? 1
                let discLeft = rep.colorAt(x: 29, y: 33)?.alphaComponent ?? 0
                let discRight = rep.colorAt(x: 39, y: 33)?.alphaComponent ?? 0
                try require(stemAlpha < 0.05 && dotAlpha < 0.05 && ringAlpha < 0.05 && discLeft > 0.9 && discRight > 0.9,
                            "attention badge cut-outs and clear ring must be transparent beside opaque badge disc")
            }
        }

        let states = MenuBarGlyphState.allCases
        for i in 0..<states.count {
            for j in (i + 1)..<states.count {
                try require(bitmaps[states[i]] != bitmaps[states[j]],
                            "menu-bar glyphs \(states[i]) and \(states[j]) must differ visually")
            }
        }
    }

    /// Automatic update checks persist their toggle and record without touching
    /// the WebDAV bridge, announce each version once across restarts, and never
    /// leak response bodies into the activity log.
    @MainActor static func checkUpdateLifecycle(root: URL, suite: String) async throws {
        let paths = AppPaths(baseDirectory: root.appendingPathComponent("UpdateSupport"))
        try paths.prepare()
        let defaultsSuite = suite + ".updates"
        let defaults = UserDefaults(suiteName: defaultsSuite)!
        defer { defaults.removePersistentDomain(forName: defaultsSuite) }

        // Seed legacy settings without `automaticUpdateCheck`: must decode to true.
        let mountPath = root.appendingPathComponent("UpdateMount").path
        let port = try freePort()
        let legacyJSON = """
        {"mountPath":"\(mountPath)","profile":"zeroResidual","autoCleanup":true,"cleanupDelaySeconds":60,"openFinderAfterMount":false,"infusePort":\(port)}
        """
        defaults.set(Data(legacyJSON.utf8), forKey: "QuarkFS.settings.v1")

        var now = Date(timeIntervalSince1970: 1_764_000_000)
        var openedURLs: [URL] = []
        let stub = StubUpdateTransport(tag: "v1.2.0", body: "secret-release-body-marker")

        let first = AppModel(
            credentialStore: TestCredentials(),
            defaults: defaults,
            paths: paths,
            runningVersion: "1.1.3",
            updateClock: { now },
            openURL: { openedURLs.append($0) },
            updateTransport: stub.makeTransport()
        )
        do {
            try require(first.settings.automaticUpdateCheck == true,
                        "legacy settings without automaticUpdateCheck decode with automatic checks enabled")
            await first.bootstrap()
            try require(first.infuseBridgeRunning, "update-check test model starts its bridge")
            try require(await waitUntil { first.automaticUpdateBanner?.version == "1.2.0" },
                        "automatic check at launch announces a newer release once")
            try require(first.logs.contains { $0.contains("更新检查：发现新版本 1.2.0") },
                        "finished update check writes one summary line to the activity log")
            try require(!first.logs.contains { $0.contains("secret-release-body-marker") },
                        "activity log never includes the response body")

            // Toggling automaticUpdateCheck must persist and never restart the WebDAV bridge.
            let startCountFile = paths.supportDirectory.appendingPathComponent("webdav-start-count")
            let startsBeforeToggle = try Int(String(contentsOf: startCountFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines))
            let pidBeforeToggle = first.infuseBridgeProcessIdentifier
            first.settings.automaticUpdateCheck = false
            await first.persistSettings()
            let savedOff = defaults.data(forKey: "QuarkFS.settings.v1")
                .flatMap { try? JSONDecoder().decode(AppSettings.self, from: $0) }?.automaticUpdateCheck
            first.settings.automaticUpdateCheck = true
            await first.persistSettings()
            let savedOn = defaults.data(forKey: "QuarkFS.settings.v1")
                .flatMap { try? JSONDecoder().decode(AppSettings.self, from: $0) }?.automaticUpdateCheck
            let startsAfterToggle = try Int(String(contentsOf: startCountFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines))
            try require(savedOff == false && savedOn == true,
                        "automaticUpdateCheck toggle persists across saves")
            try require(startsBeforeToggle == startsAfterToggle && first.infuseBridgeProcessIdentifier == pidBeforeToggle && first.infuseBridgeRunning,
                        "toggling automaticUpdateCheck must not restart the WebDAV bridge or touch the engine")

            // One-shot update card focus resets after consumption (U5).
            try require(!first.pendingUpdateCardFocus && !first.consumeUpdateCardFocus(),
                        "update card focus starts inactive")
            first.requestUpdateCardFocus()
            try require(first.pendingUpdateCardFocus && first.consumeUpdateCardFocus()
                        && !first.pendingUpdateCardFocus && !first.consumeUpdateCardFocus(),
                        "update card focus is one-shot and never replays on later window openings")

            // Dismissing the banner hides it.
            first.dismissAutomaticUpdateBanner()
            try require(first.automaticUpdateBanner == nil, "dismissing the automatic update banner hides it")
            try require(await first.shutdownNow(), "first update-check model shuts down cleanly")
        } catch {
            _ = await first.shutdownNow()
            throw error
        }

        // Immediate relaunch within 24h (no new check): remembers 1.2.0 in card/menu
        // without re-showing the automatic banner (C3).
        let rememberedCalls = stub.callCount
        let remembered = AppModel(
            credentialStore: TestCredentials(),
            defaults: defaults,
            paths: paths,
            runningVersion: "1.1.3",
            updateClock: { now },
            openURL: { openedURLs.append($0) },
            updateTransport: stub.makeTransport()
        )
        try require(remembered.availableUpdate?.version == "1.2.0" && remembered.automaticUpdateBanner == nil,
                    "relaunch restores the last known newer release without re-showing the banner")
        try require(stub.callCount == rememberedCalls, "restoring known release requires no network call")

        // Launching as the upgraded version 1.2.0 drops the saved known release (C3).
        let upgradedDefaultsSuite = suite + ".updates-upgraded"
        let upgradedDefaults = UserDefaults(suiteName: upgradedDefaultsSuite)!
        defer { upgradedDefaults.removePersistentDomain(forName: upgradedDefaultsSuite) }
        if let savedUpdateData = defaults.data(forKey: "QuarkFS.update.v1") {
            upgradedDefaults.set(savedUpdateData, forKey: "QuarkFS.update.v1")
        }
        let upgraded = AppModel(
            credentialStore: TestCredentials(),
            defaults: upgradedDefaults,
            paths: paths,
            runningVersion: "1.2.0",
            updateClock: { now },
            openURL: { _ in },
            updateTransport: stub.makeTransport()
        )
        try require(upgraded.availableUpdate == nil && upgraded.updateResult == nil,
                    "saved newer release is dropped once the running version reaches it")

        // Tampered saved releases (external URL, non-newer version, or invalid version) must be dropped on init.
        let tamperedCases: [(name: String, version: String, url: String)] = [
            ("external-url", "1.9.0", "https://evil.example/007xf/QuarkFS/releases/tag/v1.9.0"),
            ("older-version", "1.0.0", "https://github.com/007xf/QuarkFS/releases/tag/v1.0.0"),
            ("invalid-version", "not-a-version", "https://github.com/007xf/QuarkFS/releases/tag/v1.9.0")
        ]
        for tampered in tamperedCases {
            let tamperedSuite = suite + ".tampered-\(tampered.name)"
            let tamperedDefaults = UserDefaults(suiteName: tamperedSuite)!
            defer { tamperedDefaults.removePersistentDomain(forName: tamperedSuite) }
            let record = UpdateRecord(
                lastCheck: now,
                latestKnownRelease: .init(version: tampered.version, pageURL: tampered.url, publishedAt: now)
            )
            tamperedDefaults.set(try JSONEncoder().encode(record), forKey: "QuarkFS.update.v1")
            let checked = AppModel(
                credentialStore: TestCredentials(),
                defaults: tamperedDefaults,
                paths: paths,
                runningVersion: "1.1.3",
                updateClock: { now },
                openURL: { _ in },
                updateTransport: stub.makeTransport()
            )
            let reloadedRecord = tamperedDefaults.data(forKey: "QuarkFS.update.v1")
                .flatMap { try? JSONDecoder().decode(UpdateRecord.self, from: $0) }
            try require(checked.availableUpdate == nil && checked.updateResult == nil
                        && reloadedRecord?.latestKnownRelease == nil,
                        "tampered saved release (\(tampered.name)) must be dropped and purged from defaults")
        }

        // Known newer release stays available in card/menu even after a subsequent offline failure.
        let rememberedFailStub = StubUpdateTransport(tag: "v1.2.0")
        rememberedFailStub.setFailOffline(true)
        let rememberedFailSuite = suite + ".remembered-fail"
        let rememberedFailDefaults = UserDefaults(suiteName: rememberedFailSuite)!
        defer { rememberedFailDefaults.removePersistentDomain(forName: rememberedFailSuite) }
        if let savedUpdateData = defaults.data(forKey: "QuarkFS.update.v1") {
            rememberedFailDefaults.set(savedUpdateData, forKey: "QuarkFS.update.v1")
        }
        let rememberedFail = AppModel(
            credentialStore: TestCredentials(),
            defaults: rememberedFailDefaults,
            paths: paths,
            runningVersion: "1.1.3",
            updateClock: { now },
            openURL: { _ in },
            updateTransport: rememberedFailStub.makeTransport()
        )
        await rememberedFail.checkForUpdatesManually()
        try require(rememberedFail.updateResult == .couldNotCheck(.offline)
                    && rememberedFail.availableUpdate?.version == "1.2.0",
                    "remembered newer release remains available in card and menu when a later check fails offline")

        // Restart with the same UserDefaults 25 hours later: 1.2.0 was already announced,
        // so the automatic check runs again without re-showing the banner.
        now = now.addingTimeInterval(25 * 60 * 60)
        let callsBeforeSecond = stub.callCount
        let second = AppModel(
            credentialStore: TestCredentials(),
            defaults: defaults,
            paths: paths,
            runningVersion: "1.1.3",
            updateClock: { now },
            openURL: { openedURLs.append($0) },
            updateTransport: stub.makeTransport()
        )
        do {
            await second.bootstrap()
            try require(await waitUntil { stub.callCount > callsBeforeSecond && second.updateResult != nil },
                        "restarted model runs the due automatic update check")
            try require(second.automaticUpdateBanner == nil,
                        "an already-announced version does not show the automatic banner again after restart")
            try require(await second.shutdownNow(), "second update-check model shuts down cleanly")
        } catch {
            _ = await second.shutdownNow()
            throw error
        }

        // A newer release 1.3.0 another 25 hours later DOES announce again, and opening
        // its release page validates the URL and dismisses the banner.
        now = now.addingTimeInterval(25 * 60 * 60)
        stub.setRelease(tag: "v1.3.0", body: "third-release")
        let third = AppModel(
            credentialStore: TestCredentials(),
            defaults: defaults,
            paths: paths,
            runningVersion: "1.1.3",
            updateClock: { now },
            openURL: { openedURLs.append($0) },
            updateTransport: stub.makeTransport()
        )
        do {
            await third.bootstrap()
            try require(await waitUntil { third.automaticUpdateBanner?.version == "1.3.0" },
                        "a newer release after an announced version shows the automatic banner again")
            if let release = third.automaticUpdateBanner {
                third.openReleasePage(release)
            }
            try require(third.automaticUpdateBanner == nil
                        && openedURLs.last?.absoluteString == "https://github.com/007xf/QuarkFS/releases/tag/v1.3.0",
                        "opening the release page opens the validated GitHub URL and dismisses the banner")
            try require(await third.shutdownNow(), "third update-check model shuts down cleanly")
        } catch {
            _ = await third.shutdownNow()
            throw error
        }

        // Switch off = no automatic request at launch, at a tick, or at wake (T4);
        // turning the switch on with a stale lastCheck evaluates promptly (C4).
        let offSuite = suite + ".updates-off"
        let offDefaults = UserDefaults(suiteName: offSuite)!
        defer { offDefaults.removePersistentDomain(forName: offSuite) }
        let offSettings = AppSettings(mountPath: mountPath, openFinderAfterMount: false, infusePort: try freePort(), automaticUpdateCheck: false)
        offDefaults.set(try JSONEncoder().encode(offSettings), forKey: "QuarkFS.settings.v1")
        let offStub = StubUpdateTransport(tag: "v1.4.0")
        var offNow = Date(timeIntervalSince1970: 1_765_000_000)
        let offModel = AppModel(
            credentialStore: TestCredentials(),
            defaults: offDefaults,
            paths: paths,
            runningVersion: "1.1.3",
            updateClock: { offNow },
            updateReevaluationInterval: 1,
            wakeGracePeriod: 0.05,
            openURL: { _ in },
            updateTransport: offStub.makeTransport()
        )
        do {
            await offModel.bootstrap()
            offModel.handleSystemWake()
            offNow = offNow.addingTimeInterval(120)
            await offModel.checkForUpdatesAutomaticallyIfDue()
            try? await Task.sleep(for: .milliseconds(200))
            try require(offStub.callCount == 0,
                        "with automaticUpdateCheck off, no automatic request runs at launch, wake, or tick")
            // Turning the switch on with a stale/missing lastCheck triggers a check promptly (C4).
            offModel.settings.automaticUpdateCheck = true
            await offModel.persistSettings()
            try require(await waitUntil { offStub.callCount == 1 },
                        "turning automaticUpdateCheck on with a stale lastCheck evaluates promptly")
            try require(await offModel.shutdownNow(), "switch-off model shuts down cleanly")
        } catch {
            _ = await offModel.shutdownNow()
            throw error
        }

        // Wake grace period & offline automatic retry without tight loop (C1).
        let wakeSuite = suite + ".updates-wake"
        let wakeDefaults = UserDefaults(suiteName: wakeSuite)!
        defer { wakeDefaults.removePersistentDomain(forName: wakeSuite) }
        var wakeNow = Date(timeIntervalSince1970: 1_766_000_000)
        let staleRecord = UpdateRecord(lastCheck: wakeNow.addingTimeInterval(-25 * 60 * 60))
        wakeDefaults.set(try JSONEncoder().encode(staleRecord), forKey: "QuarkFS.update.v1")
        let wakeStub = StubUpdateTransport(tag: "v1.5.0")
        wakeStub.setFailOffline(true)
        let wakeModel = AppModel(
            credentialStore: TestCredentials(),
            defaults: wakeDefaults,
            paths: paths,
            runningVersion: "1.1.3",
            updateClock: { wakeNow },
            wakeGracePeriod: 60,
            openURL: { _ in },
            updateTransport: wakeStub.makeTransport()
        )
        // Wake fires while due: ticks inside the 60s grace period must make no request,
        // while a manual check during the grace period runs immediately.
        wakeModel.handleSystemWake()
        wakeNow = wakeNow.addingTimeInterval(30)
        await wakeModel.checkForUpdatesAutomaticallyIfDue()
        try require(wakeStub.callCount == 0, "no automatic check runs inside the 60s post-wake grace period")
        // Verify a separate due model lets a manual check run immediately inside the grace period.
        let manualWakeSuite = suite + ".updates-wake-manual"
        let manualWakeDefaults = UserDefaults(suiteName: manualWakeSuite)!
        defer { manualWakeDefaults.removePersistentDomain(forName: manualWakeSuite) }
        let manualWakeStub = StubUpdateTransport(tag: "v1.5.0")
        let manualWakeModel = AppModel(
            credentialStore: TestCredentials(),
            defaults: manualWakeDefaults,
            paths: paths,
            runningVersion: "1.1.3",
            updateClock: { wakeNow },
            wakeGracePeriod: 60,
            openURL: { _ in },
            updateTransport: manualWakeStub.makeTransport()
        )
        manualWakeModel.handleSystemWake()
        await manualWakeModel.checkForUpdatesManually()
        try require(manualWakeStub.callCount == 1 && manualWakeModel.availableUpdate?.version == "1.5.0",
                    "manual check runs immediately even inside the post-wake grace period")
        _ = await manualWakeModel.shutdownNow()

        // Verify the delayed wake task itself fires automatically once the grace period elapses.
        let delayedWakeSuite = suite + ".updates-wake-delayed"
        let delayedWakeDefaults = UserDefaults(suiteName: delayedWakeSuite)!
        defer { delayedWakeDefaults.removePersistentDomain(forName: delayedWakeSuite) }
        let delayedWakeStub = StubUpdateTransport(tag: "v1.5.0")
        let delayedWakeModel = AppModel(
            credentialStore: TestCredentials(),
            defaults: delayedWakeDefaults,
            paths: paths,
            runningVersion: "1.1.3",
            wakeGracePeriod: 0.15,
            openURL: { _ in },
            updateTransport: delayedWakeStub.makeTransport()
        )
        delayedWakeModel.handleSystemWake()
        try require(delayedWakeStub.callCount == 0, "delayed wake task does not fire before the grace period ends")
        try require(await waitUntil { delayedWakeStub.callCount == 1 && delayedWakeModel.availableUpdate?.version == "1.5.0" },
                    "delayed wake task fires automatically once the post-wake grace period ends")
        _ = await delayedWakeModel.shutdownNow()

        // Past the 60s grace period: automatic check runs and fails offline.
        wakeNow = wakeNow.addingTimeInterval(35)
        await wakeModel.checkForUpdatesAutomaticallyIfDue()
        try require(wakeStub.callCount == 1 && wakeModel.updateResult == .couldNotCheck(.offline),
                    "due automatic check runs once the post-wake grace period has passed")
        // 10 minutes later: skipped (no tight retry loop).
        wakeNow = wakeNow.addingTimeInterval(10 * 60)
        await wakeModel.checkForUpdatesAutomaticallyIfDue()
        try require(wakeStub.callCount == 1, "offline automatic failure does not retry in a tight loop")
        // Next hourly tick: retries and succeeds when back online.
        wakeStub.setRelease(tag: "v1.5.0")
        wakeNow = wakeNow.addingTimeInterval(50 * 60)
        await wakeModel.checkForUpdatesAutomaticallyIfDue()
        try require(wakeStub.callCount == 2 && wakeModel.availableUpdate?.version == "1.5.0",
                    "offline automatic failure retries at the next hourly tick instead of waiting 24h")
        _ = await wakeModel.shutdownNow()
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

    /// The literal identity the engine must send; kept here so a change to
    /// the production value is a deliberate, reviewed test change.
    static let quarkClientUserAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) quark-cloud-drive/2.5.20 Chrome/100.0.4896.160 Electron/18.3.5.4-b478491100 Safari/537.36 Channel/pckk_other_ch"

    /// Mirrors EngineFixture.py `obscure -`.
    static func fixtureObscured(_ cookie: String) -> String {
        "fixture-obscured-" + cookie.utf8.map { String(format: "%02x", $0) }.joined()
    }

    static func runtimeConfigLines(_ paths: AppPaths) throws -> [String] {
        try String(contentsOf: paths.runtimeConfig, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .dropLast() // The file ends with a newline.
            .map(String.init)
    }

    static func permissions(of url: URL) throws -> Int {
        (try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    static func get(port: Int, path: String, authorization: String) async -> Int? {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!, timeoutInterval: 2)
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        return ((try? await session.data(for: request))?.1 as? HTTPURLResponse)?.statusCode
    }

    static func anonymousConnection(port: Int) async -> WebDAVHealth {
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        return await WebDAVHealth.check(url: URL(string: "http://127.0.0.1:\(port)/")!, session: session)
    }

    static func connection(port: Int, authorization: String) async -> WebDAVHealth {
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        return await WebDAVHealth.check(url: URL(string: "http://127.0.0.1:\(port)/")!, session: session,
                                        authorization: authorization)
    }

    /// A loopback listener that occupies a port, like another local service.
    static func listeningSocket() throws -> (descriptor: Int32, port: Int) {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, listen(fd, 4) == 0 else { close(fd); throw POSIXError(.EADDRINUSE) }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        return (fd, Int(UInt16(bigEndian: addr.sin_port)))
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
