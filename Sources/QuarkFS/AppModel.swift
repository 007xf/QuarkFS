import AppKit
import Foundation
import QuarkFSCore

enum MountStatus: Equatable {
    case notMounted
    case mounting
    case mounted
    case unmounting
    case failed(String)

    var title: String {
        switch self {
        case .notMounted: "未挂载"
        case .mounting: "正在挂载"
        case .mounted: "已挂载"
        case .unmounting: "正在卸载"
        case .failed: "需要处理"
        }
    }

    var symbol: String {
        switch self {
        case .notMounted: "externaldrive"
        case .mounting, .unmounting: "arrow.triangle.2.circlepath"
        case .mounted: "externaldrive.fill.badge.checkmark"
        case .failed: "exclamationmark.triangle.fill"
        }
    }

}

struct PreflightState: Sendable {
    var hasCompletedCheck = false
    var engine = EngineInspection(
        path: nil,
        isQuarkCapable: false,
        mountCommand: nil,
        version: nil,
        problem: "正在检查"
    )
    var macFUSEInstalled = false
    var macFUSEReady = false
    var hasCredential = false
    var mountDirectoryReady = false
    var mountDirectoryProblem: String?

    var setupReady: Bool {
        engine.isQuarkCapable && engine.mountCommand == "cmount" && macFUSEReady && hasCredential
    }

    var needsSetup: Bool { hasCompletedCheck && !setupReady }

    var ready: Bool { setupReady && mountDirectoryReady }
}

@MainActor
final class AppModel: ObservableObject {
    @Published var settings: AppSettings
    @Published private(set) var status: MountStatus = .notMounted
    @Published private(set) var preflight = PreflightState()
    @Published private(set) var cacheBytes: Int64 = 0
    @Published private(set) var infuseBridgeRunning = false
    @Published private(set) var infuseBridgeActive = false
    @Published private(set) var hasActiveMount = false
    @Published private(set) var isBusy = false
    @Published private(set) var isChecking = false
    @Published private(set) var infuseBridgeDetail = "尚未运行"
    @Published private(set) var shortcuts: ShortcutPreferences
    @Published private(set) var logs: [String] = []
    @Published var cookieInput = ""
    @Published var showingLogin = false

    let paths: AppPaths

    private let credentialStore: any CredentialStoring
    private let defaults: UserDefaults
    private var engineProcess: Process?
    private var infuseBridgeProcess: Process?
    private var outputPipe: Pipe?
    private var errorPipe: Pipe?
    private var mountDiagnostics: MountAttemptDiagnostics?
    private var mountNeedsRecovery = false
    private var mayRetryBusyMount = true
    private var mountRetryTask: Task<Void, Never>?
    @Published private var mountStateKnown = true
    private var activeMountPath: String?
    private var infuseBridgeSettings: AppSettings?
    private var cachedObscuredCookie: String?
    private var hasBootstrapped = false
    private var isShuttingDown = false
    private var preflightRevision = 0
    private let settingsKey = "QuarkFS.settings.v1"
    private let shortcutsKey = "QuarkFS.shortcuts.v1"

    var mountOperationInProgress: Bool {
        status == .mounting || status == .unmounting || (engineProcess?.isRunning == true && !hasActiveMount)
    }

    var shouldOfferUnmount: Bool {
        hasActiveMount || mountOperationInProgress
    }

    var canEditMountPath: Bool {
        mountStateKnown && !hasActiveMount && !mountOperationInProgress && !isBusy
    }

    var canClearCache: Bool {
        mountStateKnown && !hasActiveMount && !mountOperationInProgress && !isBusy
    }

    init(
        credentialStore: any CredentialStoring = KeychainCredentialStore(),
        defaults: UserDefaults = .standard,
        paths: AppPaths = AppPaths()
    ) {
        self.credentialStore = credentialStore
        self.defaults = defaults
        self.paths = paths
        if let data = defaults.data(forKey: settingsKey),
           let decoded = try? JSONDecoder().decode(AppSettings.self, from: data) {
            settings = decoded
        } else {
            settings = AppSettings()
        }
        if let data = defaults.data(forKey: shortcutsKey),
           let decoded = try? JSONDecoder().decode(ShortcutPreferences.self, from: data) {
            shortcuts = decoded
        } else {
            shortcuts = ShortcutPreferences()
        }
    }

    func shortcut(for action: ShortcutAction) -> AppShortcut {
        shortcuts[action]
    }

    @discardableResult
    func setShortcut(_ shortcut: AppShortcut, for action: ShortcutAction) -> Bool {
        guard let key = shortcut.key?.lowercased(),
              key.count == 1,
              key.first?.isLetter == true || key.first?.isNumber == true,
              shortcut.control || shortcut.option || shortcut.shift || shortcut.command else {
            return false
        }

        var normalized = shortcut
        normalized.key = key
        guard !ShortcutAction.allCases.contains(where: {
            $0 != action && shortcuts[$0] == normalized
        }) else { return false }

        shortcuts[action] = normalized
        persistShortcuts()
        return true
    }

    func clearShortcut(for action: ShortcutAction) {
        shortcuts[action] = .disabled
        persistShortcuts()
    }

    func resetShortcuts() {
        shortcuts = ShortcutPreferences()
        persistShortcuts()
    }

    private func persistShortcuts() {
        if let data = try? JSONEncoder().encode(shortcuts) {
            defaults.set(data, forKey: shortcutsKey)
        }
    }

    func bootstrap() async {
        guard !hasBootstrapped else { return }
        hasBootstrapped = true
        do {
            try paths.prepare()
        } catch {
            status = .failed(error.localizedDescription)
            appendLog("初始化失败：\(error.localizedDescription)")
        }
        await refreshPreflight()
        refreshCacheUsage()
        await restartInfuseBridge()
    }

    func persistSettings() async {
        let shouldRestartBridge = infuseBridgeProcess?.isRunning == true && infuseBridgeSettings.map {
            $0.profile != settings.profile
                || $0.autoCleanup != settings.autoCleanup
                || $0.cleanupDelaySeconds != settings.cleanupDelaySeconds
                || $0.infusePort != settings.infusePort
        } == true
        if let data = try? JSONEncoder().encode(settings) {
            defaults.set(data, forKey: settingsKey)
        }
        if shouldRestartBridge {
            await restartInfuseBridge()
        }
    }

    func refreshPreflight() async {
        preflightRevision += 1
        let revision = preflightRevision
        isChecking = true
        let mountPath = activeMountPath ?? settings.mountPath
        let support = paths.supportDirectory
        let store = credentialStore
        let snapshot = await Task.detached {
            var result = PreflightState()
            result.engine = EngineLocator.inspect(EngineLocator.locate())
            result.macFUSEInstalled = EngineLocator.isMacFUSEInstalled
            result.macFUSEReady = EngineLocator.isMacFUSEReady
            result.hasCredential = (try? store.contains()) == true
            let mounts = try? ProcessRunner.run(executable: URL(fileURLWithPath: "/sbin/mount"), arguments: [])
            if mounts?.status != 0 {
                result.mountDirectoryProblem = "无法读取系统挂载状态，请重新检查；挂载和缓存清理已暂停"
            } else if MountDetector.presence(output: mounts?.standardOutput ?? "", path: mountPath) == .quark {
                result.mountDirectoryReady = true
            } else {
                do {
                    _ = try MountDirectory.validate(path: mountPath, supportDirectory: support)
                    result.mountDirectoryReady = true
                } catch {
                    result.mountDirectoryProblem = error.localizedDescription
                }
            }
            result.hasCompletedCheck = true
            return result
        }.value
        guard revision == preflightRevision else { return }
        preflight = snapshot
        isChecking = false
        refreshMountStatus()
    }

    func applyMountPath(_ path: String) async {
        guard canEditMountPath else { return }
        do {
            let url = try MountDirectory.validate(path: path, supportDirectory: paths.supportDirectory)
            settings.mountPath = url.path
            await persistSettings()
            status = .notMounted
            await refreshPreflight()
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    func chooseMountFolder() {
        guard canEditMountPath else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "设为挂载位置"
        panel.message = "选择个人文件夹内的空文件夹"
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor [weak self] in await self?.applyMountPath(url.path) }
        }
    }

    func applyInfusePort(_ text: String) async {
        guard !isBusy else { return }
        guard let port = Int(text), (1024...65535).contains(port) else {
            infuseBridgeDetail = "端口应为 1024–65535 之间的整数"
            return
        }
        settings.infusePort = port
        await persistSettings()
    }

    func copyInfuseConnection() {
        let text = "WebDAV\n服务器：127.0.0.1\n端口：\(settings.infusePort)\n路径：/\nHTTPS：关闭\n用户名和密码：留空"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        appendLog("Infuse 连接信息已复制")
    }

    func openInfuse() {
        let app = URL(fileURLWithPath: "/Applications/Infuse.app")
        if FileManager.default.fileExists(atPath: app.path) {
            NSWorkspace.shared.openApplication(at: app, configuration: .init()) { _, _ in }
        } else {
            NSWorkspace.shared.open(URL(string: "https://firecore.com/infuse")!)
        }
    }

    func disconnectInfuseBridge() async {
        guard !isBusy, !isShuttingDown else { return }
        isBusy = true
        defer { isBusy = false }
        _ = await stopInfuseBridge()
    }

    func saveCookie() async {
        let cookie = cookieInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cookie.isEmpty else {
            status = .failed("请粘贴完整的夸克 Cookie")
            return
        }
        await saveCredential(cookie, message: "登录信息已保存到 macOS 钥匙串")
    }

    func saveCookieFromQR(_ cookie: String) async {
        await saveCredential(cookie, message: "夸克扫码登录成功，凭据已写入钥匙串")
    }

    private func saveCredential(_ cookie: String, message: String) async {
        guard canEditMountPath else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            guard await stopInfuseBridge() else { return }
            try credentialStore.save(cookie)
            cachedObscuredCookie = nil
            cookieInput = ""
            showingLogin = false
            try? FileManager.default.removeItem(at: paths.runtimeConfig)
            appendLog(message)
            await startInfuseBridge()
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    func forgetCredential() async {
        guard canEditMountPath else {
            status = .failed("请先卸载 Quark")
            return
        }
        isBusy = true
        defer { isBusy = false }
        do {
            guard await stopInfuseBridge() else { return }
            try credentialStore.delete()
            cachedObscuredCookie = nil
            try? FileManager.default.removeItem(at: paths.runtimeConfig)
            appendLog("已从钥匙串删除夸克登录信息")
            await refreshPreflight()
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    func mount(retryBusyMount: Bool = true) async {
        guard !mountOperationInProgress, !hasActiveMount, !isBusy, !isChecking else { return }
        isBusy = true
        defer { isBusy = false }
        await refreshPreflight()
        if hasActiveMount { return }
        let presence = mountPresence(at: settings.mountPath)
        guard presence == .none else {
            refreshMountStatus()
            return
        }
        guard preflight.ready,
              let enginePath = preflight.engine.path,
              let command = preflight.engine.mountCommand else {
            status = .failed("请先完成下方所有运行条件")
            return
        }

        do {
            try prepareMountDirectory()
            let mountSettings = settings
            let mountPath = mountSettings.mountPath
            let engine = URL(fileURLWithPath: enginePath)
            try await prepareRuntimeConfig(engine: engine)
            let plan = MountPlanBuilder.make(settings: mountSettings, paths: paths, command: command)
            let process = Process()
            let stdout = Pipe()
            let stderr = Pipe()
            let diagnostics = MountAttemptDiagnostics(logFile: paths.logFile)
            process.executableURL = engine
            process.arguments = [plan.command] + plan.arguments
            process.standardOutput = stdout
            process.standardError = stderr

            // Reserve both readers before starting the child: a very short
            // failure may otherwise be classified before its stderr arrives.
            let readers = DispatchGroup()
            readers.enter()
            readers.enter()
            process.terminationHandler = { [weak self] terminated in
                DispatchQueue.global().async {
                    _ = readers.wait(timeout: .now() + 2)
                    Task { @MainActor [weak self] in
                        self?.handleTermination(process: terminated, status: terminated.terminationStatus)
                    }
                }
            }

            try process.run()
            engineProcess = process
            activeMountPath = mountPath
            outputPipe = stdout
            errorPipe = stderr
            mountDiagnostics = diagnostics
            mountNeedsRecovery = false
            mayRetryBusyMount = retryBusyMount
            status = .mounting
            appendLog("正在挂载 \(mountPath)")
            for pipe in [stdout, stderr] {
                DispatchQueue.global().async { [weak self] in
                    defer { readers.leave() }
                    let handle = pipe.fileHandleForReading
                    while true {
                        let data = handle.availableData
                        guard !data.isEmpty else { break }
                        diagnostics.append(data)
                        let line = String(decoding: data, as: UTF8.self)
                        Task { @MainActor [weak self] in self?.appendEngineOutput(line) }
                    }
                    try? handle.close()
                }
            }

            Task {
                await self.confirmMount(process: process, path: mountPath, openFinder: mountSettings.openFinderAfterMount)
            }
        } catch {
            status = .failed(error.localizedDescription)
            appendLog("挂载失败：\(error.localizedDescription)")
        }
    }

    func unmount() {
        guard status != .unmounting, !isBusy else { return }
        mountRetryTask?.cancel()
        mountRetryTask = nil
        let process = engineProcess
        let mountPath = activeMountPath ?? settings.mountPath
        let presence = mountPresence(at: mountPath)
        guard presence != .unknown else {
            mountStateKnown = false
            status = .failed("无法读取系统挂载状态，已保留文件系统引擎，请重新检查")
            return
        }
        guard presence != .conflict else {
            hasActiveMount = false
            status = .failed("挂载位置被其他磁盘占用，QuarkFS 不会卸载它")
            appendLog("拒绝卸载：挂载位置不是 Quark macFUSE 磁盘")
            return
        }
        guard process != nil || presence == .quark else {
            activeMountPath = nil
            hasActiveMount = false
            mountNeedsRecovery = false
            status = .notMounted
            return
        }
        status = .unmounting
        isBusy = true
        appendLog("正在卸载 Quark")

        Task { @MainActor [weak self, mountPath, process, presence] in
            guard let self else { return }
            defer { self.isBusy = false }
            if presence == .quark {
                let result = await Task.detached {
                    try? ProcessRunner.run(
                        executable: URL(fileURLWithPath: "/sbin/umount"),
                        arguments: [mountPath], timeout: 8
                    )
                }.value
                // An exit code alone does not establish that the mount is gone.
                let remaining = self.mountPresence(at: mountPath)
                guard remaining == .none else {
                    self.hasActiveMount = remaining == .quark
                    self.mountStateKnown = remaining != .unknown
                    let detail = result?.standardError.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    self.status = .failed(remaining == .unknown
                        ? "无法确认卸载结果，已保留文件系统引擎，请重新检查"
                        : "卸载未完成，请关闭正在使用磁盘的窗口或播放器后重试")
                    self.appendLog(detail.isEmpty ? "卸载未完成，已保留文件系统引擎" : "卸载未完成：\(detail)")
                    return
                }
            }
            if let process, process.isRunning {
                guard await ProcessRunner.stop(process) else {
                    self.status = .failed("文件系统引擎尚未停止，请稍后重试")
                    return
                }
            }
            let finalPresence = self.mountPresence(at: mountPath)
            guard finalPresence == .none else {
                self.mountStateKnown = finalPresence != .unknown
                self.hasActiveMount = finalPresence == .quark
                self.mountNeedsRecovery = finalPresence == .quark
                self.status = .failed("引擎已停止，但挂载状态仍需处理；请重新检查后安全卸载")
                return
            }
            self.activeMountPath = nil
            self.hasActiveMount = false
            self.mountNeedsRecovery = false
            self.status = .notMounted
            self.refreshMountStatus()
        }
    }

    func clearCache() async {
        guard canClearCache else {
            status = .failed("请先卸载，再清理磁盘缓存")
            return
        }
        isBusy = true
        defer { isBusy = false }
        let restartBridge = infuseBridgeProcess?.isRunning == true
        guard await stopInfuseBridge() else { return }
        do {
            let manager = SafeCacheManager(
                cacheRoot: paths.cacheDirectory,
                allowedParent: paths.supportDirectory
            )
            try await Task.detached { try manager.clear() }.value
            try paths.prepare()
            cacheBytes = 0
            appendLog("QuarkFS 磁盘缓存已清理")
        } catch {
            status = .failed(error.localizedDescription)
        }
        if restartBridge { await startInfuseBridge() }
    }

    func refreshCacheUsage() {
        let manager = SafeCacheManager(
            cacheRoot: paths.cacheDirectory,
            allowedParent: paths.supportDirectory
        )
        Task.detached {
            let bytes = manager.allocatedBytes()
            await MainActor.run { self.cacheBytes = bytes }
        }
    }

    func openMountFolder() {
        NSWorkspace.shared.open(URL(fileURLWithPath: activeMountPath ?? settings.mountPath))
    }

    func openMacFUSEWebsite() {
        NSWorkspace.shared.open(URL(string: "https://macfuse.github.io/")!)
    }

    func restartInfuseBridge() async {
        guard !isBusy, !isShuttingDown else { return }
        isBusy = true
        defer { isBusy = false }
        guard await stopInfuseBridge() else { return }
        await startInfuseBridge()
    }

    private func startInfuseBridge() async {
        guard infuseBridgeProcess?.isRunning != true else { return }

        await refreshPreflight()
        guard preflight.hasCredential,
              preflight.engine.isQuarkCapable,
              let enginePath = preflight.engine.path else {
            infuseBridgeRunning = false
            infuseBridgeDetail = preflight.hasCredential ? "未找到可用引擎" : "请先登录夸克账号"
            return
        }

        guard WebDAVHealth.isPortAvailable(settings.infusePort) else {
            infuseBridgeDetail = "端口 \(settings.infusePort) 不可用或已被占用，请更换端口"
            appendLog(infuseBridgeDetail)
            return
        }

        do {
            let engine = URL(fileURLWithPath: enginePath)
            try await prepareRuntimeConfig(engine: engine)
            let process = Process()
            process.executableURL = engine
            let bridgeSettings = settings
            process.arguments = InfusePlanBuilder.make(settings: bridgeSettings, paths: paths)

            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { [weak self] terminated in
                Task { @MainActor [weak self] in
                    guard let self, self.infuseBridgeProcess === terminated else { return }
                    self.infuseBridgeProcess = nil
                    self.infuseBridgeRunning = false
                    self.infuseBridgeActive = false
                    self.infuseBridgeSettings = nil
                    self.infuseBridgeDetail = "连接已停止（代码 \(terminated.terminationStatus)），请重新启动并检查端口或登录状态"
                    self.appendLog(self.infuseBridgeDetail)
                }
            }

            try process.run()
            infuseBridgeProcess = process
            infuseBridgeActive = true
            infuseBridgeSettings = bridgeSettings
            infuseBridgeDetail = "正在检查本机连接…"
            let configuration = URLSessionConfiguration.ephemeral
            configuration.connectionProxyDictionary = [:]
            let session = URLSession(configuration: configuration)
            defer { session.invalidateAndCancel() }
            for _ in 0..<10 {
                guard infuseBridgeProcess === process, process.isRunning else { return }
                let health = await WebDAVHealth.check(
                    url: URL(string: "http://127.0.0.1:\(bridgeSettings.infusePort)/")!, session: session
                )
                // Allow bind failures to surface before accepting a response
                // from an unrelated service using the configured port.
                try? await Task.sleep(for: .milliseconds(200))
                guard infuseBridgeProcess === process, process.isRunning else { return }
                if health == .ready {
                    infuseBridgeRunning = true
                    infuseBridgeDetail = "已就绪 · 127.0.0.1:\(bridgeSettings.infusePort)"
                    appendLog("Infuse 本机连接已通过目录读取检查")
                    return
                }
                if case .failed(let detail) = health {
                    _ = await stopInfuseBridge()
                    infuseBridgeDetail = detail
                    appendLog(detail)
                    return
                }
            }
            _ = await stopInfuseBridge()
            infuseBridgeDetail = "启动超时，请检查 \(bridgeSettings.infusePort) 端口和夸克登录状态后重试"
            appendLog(infuseBridgeDetail)
        } catch {
            infuseBridgeRunning = false
            infuseBridgeDetail = "启动失败：\(error.localizedDescription)"
            appendLog("Infuse 本机连接\(infuseBridgeDetail)")
        }
    }

    private func stopInfuseBridge() async -> Bool {
        guard let process = infuseBridgeProcess else {
            infuseBridgeRunning = false
            infuseBridgeActive = false
            return true
        }
        infuseBridgeDetail = "正在停止本机连接…"
        guard await ProcessRunner.stop(process) else {
            infuseBridgeDetail = "无法停止本机连接，已保留缓存，请重试"
            appendLog(infuseBridgeDetail)
            return false
        }
        infuseBridgeProcess = nil
        infuseBridgeRunning = false
        infuseBridgeActive = false
        infuseBridgeSettings = nil
        infuseBridgeDetail = "尚未运行"
        return true
    }

    private func prepareMountDirectory() throws {
        let url = try MountDirectory.validate(path: settings.mountPath, supportDirectory: paths.supportDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        settings.mountPath = url.path
    }

    private func prepareRuntimeConfig(engine: URL) async throws {
        let obscured = try await obscuredCookie(engine: engine)
        try paths.prepare()
        let config = "[quark]\ntype = quark\ncookie = \(obscured)\n"
        try config.write(to: paths.runtimeConfig, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: paths.runtimeConfig.path
        )
    }

    private func obscuredCookie(engine: URL) async throws -> String {
        if let cachedObscuredCookie {
            return cachedObscuredCookie
        }
        guard let cookie = try credentialStore.load(), !cookie.isEmpty else {
            throw QuarkLoginError.missingCookie
        }
        let result = try await Task.detached {
            try ProcessRunner.run(
                executable: engine,
                arguments: ["obscure", "-"],
                input: Data((cookie + "\n").utf8)
            )
        }.value
        guard result.status == 0 else {
            throw CocoaError(.executableLoad, userInfo: [
                NSLocalizedDescriptionKey: result.standardError.trimmingCharacters(in: .whitespacesAndNewlines)
            ])
        }
        let obscured = result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        cachedObscuredCookie = obscured
        return obscured
    }

    func shutdownNow() async -> Bool {
        guard !isBusy, !isShuttingDown else {
            appendLog("操作正在进行，请完成后再退出")
            return false
        }
        isShuttingDown = true
        isBusy = true
        mountRetryTask?.cancel()
        mountRetryTask = nil
        defer { isBusy = false; isShuttingDown = false }
        guard await stopInfuseBridge() else { return false }
        let mountPath = activeMountPath ?? settings.mountPath
        let presence = mountPresence(at: mountPath)
        guard presence != .unknown else {
            status = .failed("无法确认系统挂载状态，退出已取消；请重新检查")
            return false
        }
        var unmounted = presence != .quark

        if presence == .quark,
           let result = await Task.detached(operation: {
               try? ProcessRunner.run(
                   executable: URL(fileURLWithPath: "/sbin/umount"),
                   arguments: [mountPath], timeout: 8
               )
           }).value {
            unmounted = result.status == 0 && mountPresence(at: mountPath) == .none
            if !unmounted {
                status = .failed("磁盘正在使用，退出已取消；请关闭播放器后重试")
                appendLog("退出时卸载失败，已保留文件系统引擎")
            }
        }

        guard unmounted else { return false }

        if let process = engineProcess, process.isRunning {
            guard await ProcessRunner.stop(process) else { return false }
        }
        // A mount can finish between the first presence check and stopping a
        // starting engine. Do not exit or clear its cache on stale evidence.
        let finalPresence = mountPresence(at: mountPath)
        guard finalPresence == .none || finalPresence == .conflict else {
            mountStateKnown = finalPresence != .unknown
            hasActiveMount = finalPresence == .quark
            mountNeedsRecovery = finalPresence == .quark
            status = .failed("挂载状态仍需处理，退出已取消；请重新检查后安全卸载")
            return false
        }
        if unmounted {
            try? FileManager.default.removeItem(at: paths.runtimeConfig)
        }
        if settings.profile == .zeroResidual || settings.autoCleanup {
            let manager = SafeCacheManager(cacheRoot: paths.cacheDirectory, allowedParent: paths.supportDirectory)
            try? await Task.detached { try manager.clear() }.value
        }
        return true
    }

    private func confirmMount(process: Process, path: String, openFinder: Bool) async {
        for _ in 0..<120 {
            try? await Task.sleep(for: .milliseconds(250))
            guard engineProcess === process, process.isRunning, status == .mounting else { return }
            switch mountPresence(at: path) {
            case .unknown:
                // A transient mount-table read failure must not be treated as
                // success or trigger cleanup of a possibly active filesystem.
                continue
            case .quark:
                hasActiveMount = true
                activeMountPath = path
                status = .mounted
                appendLog("Quark 已作为本地磁盘挂载")
                if openFinder {
                    NSWorkspace.shared.open(URL(fileURLWithPath: path))
                }
                return
            case .conflict:
                hasActiveMount = false
                status = .failed("挂载位置被其他磁盘占用，请更换目录")
                appendLog("挂载失败：目标位置被非 Quark 磁盘占用")
                if process.isRunning { process.terminate() }
                return
            case .none:
                continue
            }
        }

        guard engineProcess === process, process.isRunning, status == .mounting else { return }
        let presence = mountPresence(at: path)
        if presence == .quark {
            hasActiveMount = true
            activeMountPath = path
            status = .mounted
            appendLog("Quark 已作为本地磁盘挂载")
            if openFinder { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }
            return
        }
        guard presence == .none else {
            mountStateKnown = presence != .unknown
            status = .failed("无法确认挂载是否完成，已保留文件系统引擎；请重新检查")
            return
        }
        status = .failed("挂载未在 30 秒内完成，请查看运行记录")
        appendLog("挂载超时，正在停止未完成的文件系统引擎")
        _ = await ProcessRunner.stop(process)
    }

    private func handleTermination(process: Process, status terminationStatus: Int32) {
        guard engineProcess === process else { return }
        let wasUnmounting = self.status == .unmounting
        let failedDuringStartup = self.status == .mounting
        let mountPath = activeMountPath ?? settings.mountPath
        let diagnosticOutput = mountDiagnostics?.text ?? ""
        outputPipe = nil
        errorPipe = nil
        mountDiagnostics = nil
        engineProcess = nil
        let presence = mountPresence(at: mountPath)
        mountStateKnown = presence != .unknown
        if infuseBridgeProcess?.isRunning != true {
            try? FileManager.default.removeItem(at: paths.runtimeConfig)
        }

        if presence == .none, settings.profile == .zeroResidual || settings.autoCleanup {
            try? SafeCacheManager(
                cacheRoot: paths.mountCacheDirectory,
                allowedParent: paths.supportDirectory
            ).clear()
            try? paths.prepare()
        }
        refreshCacheUsage()

        if presence == .none, failedDuringStartup, terminationStatus != 0,
           mayRetryBusyMount, !isShuttingDown,
           MountAttemptDiagnostics.isBusyFailure(output: diagnosticOutput) {
            hasActiveMount = false
            activeMountPath = nil
            appendLog("macFUSE 暂时忙碌；已确认旧引擎退出且没有挂载，稍候自动重试一次")
            mountRetryTask = Task { @MainActor [weak self] in
                do { try await Task.sleep(for: .milliseconds(900)) } catch { return }
                guard let self, !Task.isCancelled else { return }
                self.mountRetryTask = nil
                guard !self.isShuttingDown, !self.isBusy, !self.isChecking,
                      self.engineProcess == nil, self.settings.mountPath == mountPath,
                      self.mountPresence(at: mountPath) == .none else {
                    self.status = .failed("挂载资源仍需检查，自动重试已暂停；请重新检查后挂载")
                    self.refreshMountStatus()
                    return
                }
                self.status = .notMounted
                await self.mount(retryBusyMount: false)
            }
            return
        }

        if presence == .quark {
            hasActiveMount = true
            activeMountPath = mountPath
            mountNeedsRecovery = true
            self.status = .failed("文件系统引擎已停止，但 Quark 挂载仍在；请先卸载后重新挂载")
            appendLog("检测到残留 Quark 挂载，已保留缓存并等待安全卸载")
        } else if presence == .unknown {
            self.status = .failed("文件系统引擎已停止，无法确认挂载状态；已保留缓存，请重新检查")
        } else if presence == .conflict {
            hasActiveMount = false
            activeMountPath = nil
            self.status = .failed("挂载位置被其他磁盘占用，QuarkFS 不会卸载它")
        } else if wasUnmounting {
            hasActiveMount = false
            activeMountPath = nil
            self.status = .notMounted
        } else if terminationStatus == 0 {
            hasActiveMount = false
            activeMountPath = nil
            self.status = .notMounted
        } else if case .failed = self.status {
            hasActiveMount = false
            activeMountPath = nil
        } else {
            hasActiveMount = false
            activeMountPath = nil
            self.status = .failed(MountAttemptDiagnostics.failureMessage(status: terminationStatus, output: diagnosticOutput))
        }
        if case .failed(let detail) = self.status { appendLog(detail) }
        appendLog("文件系统引擎已停止")
    }

    private func refreshMountStatus() {
        let mountPath = activeMountPath ?? settings.mountPath
        let presence = mountPresence(at: mountPath)
        mountStateKnown = presence != .unknown
        switch presence {
        case .unknown:
            status = .failed("无法读取系统挂载状态，请重新检查；挂载和缓存清理已暂停")
        case .quark:
            let newlyAdopted = !hasActiveMount
            hasActiveMount = true
            activeMountPath = mountPath
            if mountNeedsRecovery {
                status = .failed("文件系统引擎已停止，但 Quark 挂载仍在；请先卸载后重新挂载")
            } else if status != .mounting && status != .unmounting {
                status = .mounted
            }
            if newlyAdopted {
                appendLog("检测到已有 Quark 挂载点，已接管状态")
            }
        case .conflict:
            hasActiveMount = false
            activeMountPath = nil
            if !mountOperationInProgress {
                status = .failed("挂载位置被其他磁盘占用，请更换目录")
            }
        case .none:
            hasActiveMount = false
            mountNeedsRecovery = false
            if status == .mounted || status == .unmounting {
                activeMountPath = nil
                status = .notMounted
            }
        }
    }

    private func mountPresence(at path: String) -> MountPresence {
        guard let result = try? ProcessRunner.run(
            executable: URL(fileURLWithPath: "/sbin/mount"),
            arguments: []
        ), result.status == 0 else {
            return .unknown
        }
        return MountDetector.presence(
            output: result.standardOutput + result.standardError,
            path: path
        )
    }

    private func appendEngineOutput(_ text: String) {
        for rawLine in text.split(whereSeparator: \.isNewline) {
            appendLog(String(rawLine))
        }
    }

    private func appendLog(_ line: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        logs.append("\(formatter.string(from: Date()))  \(line)")
        if logs.count > 120 {
            logs.removeFirst(logs.count - 120)
        }
    }
}
