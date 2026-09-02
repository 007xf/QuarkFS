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

struct PreflightState {
    var engine = EngineInspection(
        path: nil,
        isQuarkCapable: false,
        mountCommand: nil,
        version: nil,
        problem: "正在检查"
    )
    var macFUSEInstalled = false
    var hasCredential = false
    var mountDirectoryReady = false

    var ready: Bool {
        engine.isQuarkCapable && engine.mountCommand == "cmount" && macFUSEInstalled && hasCredential && mountDirectoryReady
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published var settings: AppSettings
    @Published private(set) var status: MountStatus = .notMounted
    @Published private(set) var preflight = PreflightState()
    @Published private(set) var cacheBytes: Int64 = 0
    @Published private(set) var infuseBridgeRunning = false
    @Published private(set) var shortcuts: ShortcutPreferences
    @Published private(set) var logs: [String] = []
    @Published var cookieInput = ""
    @Published var showingLogin = false

    let paths = AppPaths()

    private let credentialStore: any CredentialStoring
    private let defaults: UserDefaults
    private var engineProcess: Process?
    private var infuseBridgeProcess: Process?
    private var outputPipe: Pipe?
    private var errorPipe: Pipe?
    private let settingsKey = "QuarkFS.settings.v1"
    private let shortcutsKey = "QuarkFS.shortcuts.v1"

    init(
        credentialStore: any CredentialStoring = KeychainCredentialStore(),
        defaults: UserDefaults = .standard
    ) {
        self.credentialStore = credentialStore
        self.defaults = defaults
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

    func bootstrap() {
        do {
            try paths.prepare()
            try prepareMountDirectory()
        } catch {
            status = .failed(error.localizedDescription)
            appendLog("初始化失败：\(error.localizedDescription)")
        }
        refreshPreflight()
        refreshCacheUsage()
        startInfuseBridge()
    }

    func persistSettings() {
        if let data = try? JSONEncoder().encode(settings) {
            defaults.set(data, forKey: settingsKey)
        }
        do {
            try prepareMountDirectory()
        } catch {
            status = .failed(error.localizedDescription)
        }
        refreshPreflight()
    }

    func refreshPreflight() {
        let engineURL = EngineLocator.locate()
        preflight.engine = EngineLocator.inspect(engineURL)
        preflight.macFUSEInstalled = EngineLocator.isMacFUSEInstalled
        preflight.hasCredential = (try? credentialStore.contains()) == true
        var isDirectory: ObjCBool = false
        preflight.mountDirectoryReady = FileManager.default.fileExists(
            atPath: settings.mountPath,
            isDirectory: &isDirectory
        ) && isDirectory.boolValue
    }

    func saveCookie() {
        let cookie = cookieInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cookie.isEmpty else {
            status = .failed("请粘贴完整的夸克 Cookie")
            return
        }
        do {
            try credentialStore.save(cookie)
            cookieInput = ""
            try? FileManager.default.removeItem(at: paths.runtimeConfig)
            appendLog("登录信息已保存到 macOS 钥匙串")
            refreshPreflight()
            startInfuseBridge()
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    func saveCookieFromQR(_ cookie: String) {
        do {
            try credentialStore.save(cookie)
            showingLogin = false
            try? FileManager.default.removeItem(at: paths.runtimeConfig)
            appendLog("夸克扫码登录成功，凭据已写入钥匙串")
            refreshPreflight()
            startInfuseBridge()
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    func forgetCredential() {
        guard status != .mounted else {
            status = .failed("请先卸载 Quark")
            return
        }
        do {
            stopInfuseBridge()
            try credentialStore.delete()
            try? FileManager.default.removeItem(at: paths.runtimeConfig)
            appendLog("已从钥匙串删除夸克登录信息")
            refreshPreflight()
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    func mount() {
        guard status != .mounting, status != .mounted else { return }
        refreshPreflight()
        guard preflight.ready,
              let enginePath = preflight.engine.path,
              let command = preflight.engine.mountCommand else {
            status = .failed("请先完成下方所有运行条件")
            return
        }

        do {
            let engine = URL(fileURLWithPath: enginePath)
            try prepareRuntimeConfig(engine: engine)
            let plan = MountPlanBuilder.make(settings: settings, paths: paths, command: command)
            let process = Process()
            let stdout = Pipe()
            let stderr = Pipe()
            process.executableURL = engine
            process.arguments = [plan.command] + plan.arguments
            process.standardOutput = stdout
            process.standardError = stderr

            stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                guard !data.isEmpty else { return }
                let line = String(decoding: data, as: UTF8.self)
                Task { @MainActor in self?.appendEngineOutput(line) }
            }
            stderr.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                guard !data.isEmpty else { return }
                let line = String(decoding: data, as: UTF8.self)
                Task { @MainActor in self?.appendEngineOutput(line) }
            }
            process.terminationHandler = { [weak self] terminated in
                Task { @MainActor in
                    self?.handleTermination(status: terminated.terminationStatus)
                }
            }

            try process.run()
            engineProcess = process
            outputPipe = stdout
            errorPipe = stderr
            status = .mounting
            appendLog("正在挂载 \(settings.mountPath)")

            Task {
                try? await Task.sleep(for: .seconds(1.2))
                guard self.engineProcess?.isRunning == true else { return }
                self.status = .mounted
                self.appendLog("Quark 已作为本地磁盘挂载")
                if self.settings.openFinderAfterMount {
                    NSWorkspace.shared.open(URL(fileURLWithPath: self.settings.mountPath))
                }
            }
        } catch {
            status = .failed(error.localizedDescription)
            appendLog("挂载失败：\(error.localizedDescription)")
        }
    }

    func unmount() {
        guard let process = engineProcess, process.isRunning else {
            status = .notMounted
            return
        }
        status = .unmounting
        appendLog("正在卸载 Quark")

        Task.detached { [mountPath = settings.mountPath] in
            _ = try? ProcessRunner.run(
                executable: URL(fileURLWithPath: "/sbin/umount"),
                arguments: [mountPath]
            )
            try? await Task.sleep(for: .milliseconds(400))
            if process.isRunning { process.terminate() }
        }
    }

    func clearCache() {
        guard status != .mounted, status != .mounting else {
            status = .failed("请先卸载，再清理磁盘缓存")
            return
        }
        do {
            try SafeCacheManager(
                cacheRoot: paths.cacheDirectory,
                allowedParent: paths.supportDirectory
            ).clear()
            cacheBytes = 0
            appendLog("QuarkFS 磁盘缓存已清理")
        } catch {
            status = .failed(error.localizedDescription)
        }
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
        NSWorkspace.shared.open(URL(fileURLWithPath: settings.mountPath))
    }

    func openMacFUSEWebsite() {
        NSWorkspace.shared.open(URL(string: "https://macfuse.github.io/")!)
    }

    func restartInfuseBridge() {
        stopInfuseBridge()
        startInfuseBridge()
    }

    func startInfuseBridge() {
        guard infuseBridgeProcess?.isRunning != true else {
            infuseBridgeRunning = true
            return
        }

        refreshPreflight()
        guard preflight.hasCredential,
              preflight.engine.isQuarkCapable,
              let enginePath = preflight.engine.path else {
            infuseBridgeRunning = false
            return
        }

        do {
            let engine = URL(fileURLWithPath: enginePath)
            if !FileManager.default.fileExists(atPath: paths.runtimeConfig.path) {
                try prepareRuntimeConfig(engine: engine)
            }
            let process = Process()
            process.executableURL = engine
            process.arguments = [
                "--config", paths.runtimeConfig.path,
                "serve", "webdav", "quark:",
                "--addr", "127.0.0.1:8686",
                "--read-only",
                "--cache-dir", paths.cacheDirectory.path,
                "--vfs-cache-mode", "full",
                "--vfs-cache-max-size", "5G",
                "--vfs-cache-max-age", "24h",
                "--log-file", paths.supportDirectory.appendingPathComponent("Infuse-WebDAV.log").path,
                "--log-level", "INFO"
            ]

            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.infuseBridgeProcess === process else { return }
                    self.infuseBridgeProcess = nil
                    self.infuseBridgeRunning = false
                    self.appendLog("Infuse 本机连接已停止")
                }
            }

            try process.run()
            infuseBridgeProcess = process
            Task {
                try? await Task.sleep(for: .milliseconds(350))
                guard self.infuseBridgeProcess === process else { return }
                self.infuseBridgeRunning = process.isRunning
                if process.isRunning {
                    self.appendLog("Infuse 本机连接已就绪：127.0.0.1:8686")
                } else {
                    self.appendLog("Infuse 本机连接启动失败")
                }
            }
        } catch {
            infuseBridgeRunning = false
            appendLog("Infuse 本机连接启动失败：\(error.localizedDescription)")
        }
    }

    private func stopInfuseBridge() {
        guard let process = infuseBridgeProcess else {
            infuseBridgeRunning = false
            return
        }
        infuseBridgeProcess = nil
        infuseBridgeRunning = false
        if process.isRunning { process.terminate() }
    }

    private func prepareMountDirectory() throws {
        let url = URL(fileURLWithPath: settings.mountPath, isDirectory: true).standardizedFileURL
        guard url.path.hasPrefix(FileManager.default.homeDirectoryForCurrentUser.path + "/") else {
            throw CocoaError(.fileWriteNoPermission, userInfo: [
                NSLocalizedDescriptionKey: "当前版本只允许把挂载目录放在你的个人文件夹内"
            ])
        }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    private func prepareRuntimeConfig(engine: URL) throws {
        let obscured = try obscuredCookie(engine: engine)
        let config = "[quark]\ntype = quark\ncookie = \(obscured)\n"
        try config.write(to: paths.runtimeConfig, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: paths.runtimeConfig.path
        )
    }

    private func obscuredCookie(engine: URL) throws -> String {
        guard let cookie = try credentialStore.load(), !cookie.isEmpty else {
            throw QuarkLoginError.missingCookie
        }
        let result = try ProcessRunner.run(
            executable: engine,
            arguments: ["obscure", "-"],
            input: Data((cookie + "\n").utf8)
        )
        guard result.status == 0 else {
            throw CocoaError(.executableLoad, userInfo: [
                NSLocalizedDescriptionKey: result.standardError.trimmingCharacters(in: .whitespacesAndNewlines)
            ])
        }
        return result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func shutdownNow() {
        stopInfuseBridge()
        if let process = engineProcess, process.isRunning {
            _ = try? ProcessRunner.run(
                executable: URL(fileURLWithPath: "/sbin/umount"),
                arguments: [settings.mountPath]
            )
            if process.isRunning { process.terminate() }
        }
        try? FileManager.default.removeItem(at: paths.runtimeConfig)
    }

    private func handleTermination(status terminationStatus: Int32) {
        let wasUnmounting = self.status == .unmounting
        outputPipe?.fileHandleForReading.readabilityHandler = nil
        errorPipe?.fileHandleForReading.readabilityHandler = nil
        outputPipe = nil
        errorPipe = nil
        engineProcess = nil
        try? FileManager.default.removeItem(at: paths.runtimeConfig)

        if settings.profile == .zeroResidual || settings.autoCleanup {
            try? SafeCacheManager(
                cacheRoot: paths.cacheDirectory,
                allowedParent: paths.supportDirectory
            ).clear()
        }
        refreshCacheUsage()

        if wasUnmounting {
            self.status = .notMounted
        } else if terminationStatus == 0 {
            self.status = .notMounted
        } else {
            self.status = .failed("文件系统引擎已退出（代码 \(terminationStatus)）")
        }
        appendLog("文件系统引擎已停止")
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
