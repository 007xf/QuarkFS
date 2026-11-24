import AppKit
import Darwin
import Foundation
import QuarkFSCore
import SwiftUI

private final class SnapshotCredentials: CredentialStoring, @unchecked Sendable {
    func save(_ value: String) throws {}
    func contains() throws -> Bool { true }
    func load() throws -> String? { "snapshot-only-cookie" }
    func delete() throws {}
}

private final class SnapshotTransport: @unchecked Sendable {
    enum Mode {
        case release(tag: String, publishedAt: String, body: String)
        case offline
        case hold
    }

    private let lock = NSLock()
    private var mode: Mode
    private var holdContinuation: CheckedContinuation<UpdateChecker.HTTPResponse, Error>?

    init(mode: Mode) {
        self.mode = mode
    }

    func setMode(_ mode: Mode) {
        lock.withLock { self.mode = mode }
    }

    func releaseHold(with tag: String = "v1.1.3") {
        let continuation: CheckedContinuation<UpdateChecker.HTTPResponse, Error>? = lock.withLock {
            let saved = holdContinuation
            holdContinuation = nil
            return saved
        }
        continuation?.resume(returning: Self.makeResponse(tag: tag, publishedAt: "2026-11-24T10:00:00Z", body: ""))
    }

    private static func makeResponse(tag: String, publishedAt: String, body: String) -> UpdateChecker.HTTPResponse {
        struct Payload: Encodable {
            let tag_name: String
            let html_url: String
            let published_at: String
            let body: String
        }
        let payload = Payload(
            tag_name: tag,
            html_url: "https://github.com/007xf/QuarkFS/releases/tag/\(tag)",
            published_at: publishedAt,
            body: body
        )
        let data = (try? JSONEncoder().encode(payload)) ?? Data()
        return UpdateChecker.HTTPResponse(statusCode: 200, data: data)
    }

    func makeTransport() -> UpdateChecker.Transport {
        { [self] _, _ in
            let current = self.lock.withLock { self.mode }
            switch current {
            case .release(let tag, let publishedAt, let body):
                return Self.makeResponse(tag: tag, publishedAt: publishedAt, body: body)
            case .offline:
                throw UpdateChecker.Failure.offline
            case .hold:
                return try await withCheckedThrowingContinuation { continuation in
                    self.lock.withLock {
                        self.holdContinuation = continuation
                    }
                }
            }
        }
    }
}

@main
struct RenderUpdateSnapshots {
    static let windowSize = NSSize(width: 780, height: 820)

    @MainActor
    static func main() async throws {
        let args = CommandLine.arguments
        let readmeMode: Bool
        let outputDir: URL
        if args.count == 3 && args[1] == "--readme" {
            readmeMode = true
            outputDir = URL(fileURLWithPath: args[2], isDirectory: true)
        } else if args.count == 2 && args[1] != "--readme" {
            readmeMode = false
            outputDir = URL(fileURLWithPath: args[1], isDirectory: true)
        } else {
            fputs("Usage: RenderUpdateSnapshots [--readme] <output-dir>\n", stderr)
            exit(2)
        }
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let iconURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Resources/AppIcon.icns")
        if let icon = NSImage(contentsOf: iconURL) {
            app.applicationIconImage = icon
        }

        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/UpdateSnapshots-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let fixedDate = Date(timeIntervalSince1970: 1_795_514_400) // 2026-11-24 18:00:00 +08:00

        if readmeMode {
            try await renderReadmePictures(root: root, clockDate: fixedDate, outputDir: outputDir)
            guard UpdateChecker.liveTransportConstructionCount == 0 && UpdateChecker.liveTransportCallCount == 0 else {
                throw NSError(domain: "Snapshots", code: 3, userInfo: [NSLocalizedDescriptionKey: "live transport was used during README rendering"])
            }
            print("PASS: rendered 6 README pictures to \(outputDir.path)")
            return
        }
        let multiLineNotes = [
            "## 新版本亮点（纯文本展示，不解析 Markdown）",
            "1. 新增版本更新检查：启动后按需自动检查，每 24 小时最多一次。",
            "2. 发现新版本时仅提示并打开官方 GitHub 发行页面 [查看仓库](https://github.com/007xf/QuarkFS)，不自动下载或安装。",
            "3. 主窗口新增「版本与更新」卡片，支持手动检查、开关自动检查与查看上次检查时间。",
            "4. 菜单栏与应用菜单均提供「检查更新…」入口，点击后直接定位到更新卡片。",
            "5. 每个新版本在自动检查中只以横幅提示一次，关闭或查看页面后不再重复打扰。",
            "6. 网络请求禁用 Cookie、缓存与重定向，并限制单次响应体积不超过 256 KB。",
            "7. 更新检查仅发送 QuarkFS 版本号作为 User-Agent，不上传账号或文件信息。",
            "8. 这一行是第九行，用于确认界面只展示前 8 行并以省略号截断。",
            "9. 这一行是第十行，不应超出 8 行显示范围。"
        ].joined(separator: "\n")

        // 1. Before any check (automatic check enabled, never checked yet).
        try await withModel(root: root, name: "before-check", clockDate: fixedDate, transport: SnapshotTransport(mode: .release(tag: "v1.1.3", publishedAt: "2026-11-24T10:00:00Z", body: "")), initialAutoCheck: false) { model in
            model.settings.automaticUpdateCheck = true
            try renderBothAppearances(model: model, name: "01-before-check", scrollToBottom: true, outputDir: outputDir)
        }

        // 2. Checking in progress.
        let holdTransport = SnapshotTransport(mode: .hold)
        try await withModel(root: root, name: "checking", clockDate: fixedDate, transport: holdTransport, initialAutoCheck: false) { model in
            model.settings.automaticUpdateCheck = true
            let task = Task { await model.checkForUpdatesManually() }
            guard await waitUntil({ model.isCheckingForUpdates }) else {
                throw NSError(domain: "Snapshots", code: 1, userInfo: [NSLocalizedDescriptionKey: "checking state did not start"])
            }
            try renderBothAppearances(model: model, name: "02-checking", scrollToBottom: true, outputDir: outputDir)
            holdTransport.releaseHold()
            await task.value
        }

        // 3. Up to date.
        let upToDateTransport = SnapshotTransport(mode: .release(tag: "v1.1.3", publishedAt: "2026-11-24T10:00:00Z", body: ""))
        try await withModel(root: root, name: "up-to-date", clockDate: fixedDate, transport: upToDateTransport, initialAutoCheck: false) { model in
            model.settings.automaticUpdateCheck = true
            await model.checkForUpdatesManually()
            try renderBothAppearances(model: model, name: "03-up-to-date", scrollToBottom: true, outputDir: outputDir)
        }

        // 4. Newer version found manually (with notes) — both scrolled to update card and top-scrolled (showing no banner).
        let newerTransport = SnapshotTransport(mode: .release(tag: "v1.2.0", publishedAt: "2026-11-24T10:00:00Z", body: multiLineNotes))
        try await withModel(root: root, name: "newer-manual", clockDate: fixedDate, transport: newerTransport, initialAutoCheck: false) { model in
            model.settings.automaticUpdateCheck = true
            await model.checkForUpdatesManually()
            try renderBothAppearances(model: model, name: "04-newer-manual", scrollToBottom: true, outputDir: outputDir)
            try renderBothAppearances(model: model, name: "04-newer-manual-top", scrollToBottom: false, outputDir: outputDir)
        }

        // 5. Automatic banner showing (at top of window).
        let autoBannerTransport = SnapshotTransport(mode: .release(tag: "v1.2.0", publishedAt: "2026-11-24T10:00:00Z", body: multiLineNotes))
        try await withModel(root: root, name: "automatic-banner", clockDate: fixedDate, transport: autoBannerTransport, initialAutoCheck: true) { model in
            guard await waitUntil({ model.automaticUpdateBanner?.version == "1.2.0" }) else {
                throw NSError(domain: "Snapshots", code: 2, userInfo: [NSLocalizedDescriptionKey: "automatic banner did not appear"])
            }
            try renderBothAppearances(model: model, name: "05-automatic-banner", scrollToBottom: false, outputDir: outputDir)
        }

        // 6. Check failed (offline) — both scrolled to update card and top-scrolled.
        let offlineTransport = SnapshotTransport(mode: .offline)
        try await withModel(root: root, name: "failed-offline", clockDate: fixedDate, transport: offlineTransport, initialAutoCheck: false) { model in
            model.settings.automaticUpdateCheck = true
            await model.checkForUpdatesManually()
            try renderBothAppearances(model: model, name: "06-failed-offline", scrollToBottom: true, outputDir: outputDir)
            try renderBothAppearances(model: model, name: "06-failed-offline-top", scrollToBottom: false, outputDir: outputDir)
        }

        // 7. Automatic check switch off.
        let offTransport = SnapshotTransport(mode: .release(tag: "v1.1.3", publishedAt: "2026-11-24T10:00:00Z", body: ""))
        try await withModel(root: root, name: "switch-off", clockDate: fixedDate, transport: offTransport, initialAutoCheck: false) { model in
            try renderBothAppearances(model: model, name: "07-switch-off", scrollToBottom: true, outputDir: outputDir)
        }

        // 8. Automatic banner coexisting with a warning banner.
        let bothBannersTransport = SnapshotTransport(mode: .release(tag: "v1.2.0", publishedAt: "2026-11-24T10:00:00Z", body: multiLineNotes))
        try await withModel(root: root, name: "banner-with-warning", clockDate: fixedDate, transport: bothBannersTransport, initialAutoCheck: true) { model in
            guard await waitUntil({ model.automaticUpdateBanner?.version == "1.2.0" }) else {
                throw NSError(domain: "Snapshots", code: 2, userInfo: [NSLocalizedDescriptionKey: "automatic banner did not appear"])
            }
            model.cookieInput = ""
            await model.saveCookie()
            try renderBothAppearances(model: model, name: "08-banner-and-warning", scrollToBottom: false, outputDir: outputDir)
        }

        // 9. Menu-bar glyph sheets (4 states: 10x enlargement, true-size 1x and 2x on light & dark bars).
        try renderGlyphSheets(outputDir: outputDir)

        guard UpdateChecker.liveTransportConstructionCount == 0 && UpdateChecker.liveTransportCallCount == 0 else {
            throw NSError(domain: "Snapshots", code: 3, userInfo: [NSLocalizedDescriptionKey: "live transport was used during snapshot rendering"])
        }
        print("PASS: rendered 20 update UI snapshots + 2 menu-bar glyph sheets to \(outputDir.path)")
    }

    @MainActor
    private static func withModel(
        root: URL,
        name: String,
        clockDate: Date,
        transport: SnapshotTransport,
        initialAutoCheck: Bool,
        body: (AppModel) async throws -> Void
    ) async throws {
        let paths = AppPaths(baseDirectory: root.appendingPathComponent("Support-\(name)", isDirectory: true))
        let suite = "QuarkFS.Snapshots.\(name).\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let system = SystemServices(
            mountTable: URL(fileURLWithPath: "/usr/bin/true"),
            unmount: URL(fileURLWithPath: "/usr/bin/true"),
            macFUSEStatus: { (true, true) }
        )
        let model = AppModel(
            credentialStore: SnapshotCredentials(),
            defaults: defaults,
            paths: paths,
            system: system,
            runningVersion: "1.1.3",
            updateClock: { clockDate },
            openURL: { _ in },
            updateTransport: transport.makeTransport()
        )
        model.settings.mountPath = root.appendingPathComponent("Mount-\(name)", isDirectory: true).path
        model.settings.infusePort = try freePort()
        model.settings.openFinderAfterMount = false
        model.settings.automaticUpdateCheck = initialAutoCheck
        defer {
            defaults.removePersistentDomain(forName: suite)
        }
        do {
            await model.bootstrap()
            try await body(model)
            _ = await model.shutdownNow()
        } catch {
            _ = await model.shutdownNow()
            throw error
        }
    }

    @MainActor
    private static func renderBothAppearances(
        model: AppModel,
        name: String,
        scrollToBottom: Bool,
        outputDir: URL
    ) throws {
        try renderSnapshot(model: model, dark: false, scrollToBottom: scrollToBottom,
                           destination: outputDir.appendingPathComponent("\(name)-light.png"))
        try renderSnapshot(model: model, dark: true, scrollToBottom: scrollToBottom,
                           destination: outputDir.appendingPathComponent("\(name)-dark.png"))
    }

    @MainActor
    private static func renderSnapshot(
        model: AppModel,
        dark: Bool,
        scrollToBottom: Bool,
        destination: URL
    ) throws {
        let appearanceName: NSAppearance.Name = dark ? .darkAqua : .aqua
        guard let appearance = NSAppearance(named: appearanceName) else {
            throw NSError(domain: "Snapshots", code: 10, userInfo: [NSLocalizedDescriptionKey: "missing appearance"])
        }

        let rootView = ContentView(model: model)
            .frame(width: windowSize.width, height: windowSize.height)
            .environment(\.colorScheme, dark ? .dark : .light)

        let hosting = NSHostingView(rootView: rootView)
        hosting.frame = NSRect(origin: .zero, size: windowSize)
        hosting.appearance = appearance

        let window = NSWindow(
            contentRect: NSRect(x: -10_000, y: -10_000, width: windowSize.width, height: windowSize.height),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.appearance = appearance
        window.backgroundColor = .windowBackgroundColor
        window.contentView = hosting
        window.layoutIfNeeded()
        hosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))

        if let scrollView = findOuterScrollView(in: hosting), let document = scrollView.documentView {
            let maxY = max(0, document.frame.height - scrollView.contentView.bounds.height)
            let targetY: CGFloat = scrollToBottom ? maxY : 0
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: targetY))
            scrollView.reflectScrolledClipView(scrollView.contentView)
            hosting.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        }

        let scale = 2
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(windowSize.width) * scale,
            pixelsHigh: Int(windowSize.height) * scale,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            throw NSError(domain: "Snapshots", code: 11, userInfo: [NSLocalizedDescriptionKey: "failed to allocate bitmap"])
        }
        rep.size = windowSize

        appearance.performAsCurrentDrawingAppearance {
            hosting.cacheDisplay(in: hosting.bounds, to: rep)
        }
        window.contentView = nil

        guard let png = rep.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "Snapshots", code: 12, userInfo: [NSLocalizedDescriptionKey: "failed to encode PNG"])
        }
        try png.write(to: destination, options: .atomic)
    }

    @MainActor
    private static func renderReadmePictures(
        root: URL,
        clockDate: Date,
        outputDir: URL
    ) async throws {
        // Fake /sbin/mount script reporting /Users/you/Quark as an active macFUSE Quark mount.
        let fakeMountTable = root.appendingPathComponent("readme-mount-table.zsh")
        let mountScript = "#!/bin/zsh\nprint -r -- 'quark{fixture}: on /Users/you/Quark (macfuse, nodev, nosuid, read-only)'\n"
        try mountScript.write(to: fakeMountTable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeMountTable.path)

        // 1 & 2. Main window (light & dark), scrolled to the top, in a normal mounted + Infuse-ready state.
        do {
            let paths = AppPaths(baseDirectory: root.appendingPathComponent("Support-readme-window", isDirectory: true))
            let suite = "QuarkFS.ReadmeWindow.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }

            let system = SystemServices(
                mountTable: fakeMountTable,
                unmount: URL(fileURLWithPath: "/usr/bin/true"),
                macFUSEStatus: { (true, true) }
            )
            let transport = SnapshotTransport(mode: .release(tag: "v1.2.0", publishedAt: "2026-11-24T10:00:00Z", body: ""))
            let model = AppModel(
                credentialStore: SnapshotCredentials(),
                defaults: defaults,
                paths: paths,
                system: system,
                runningVersion: "1.2.0",
                updateClock: { clockDate },
                openURL: { _ in },
                updateTransport: transport.makeTransport()
            )
            model.settings.mountPath = "/Users/you/Quark"
            model.settings.infusePort = 8686
            model.settings.profile = .balanced
            model.settings.openFinderAfterMount = true
            model.settings.automaticUpdateCheck = true

            await model.bootstrapReadmeFixture(
                cacheBytes: 128_450_560,
                logs: [
                    "09:15:02  检测到已有 Quark 挂载点，已接管状态",
                    "09:15:03  Infuse 本机连接已通过目录读取检查"
                ]
            )
            await model.checkForUpdatesManually()

            guard model.status == .mounted,
                  model.hasActiveMount,
                  model.infuseBridgeRunning,
                  !model.preflight.needsSetup,
                  model.automaticUpdateBanner == nil,
                  model.readIssue == nil else {
                throw NSError(domain: "Snapshots", code: 30, userInfo: [NSLocalizedDescriptionKey: "README window fixture did not reach clean mounted state"])
            }

            try renderSnapshot(model: model, dark: false, scrollToBottom: false,
                               destination: outputDir.appendingPathComponent("window-light.png"))
            try renderSnapshot(model: model, dark: true, scrollToBottom: false,
                               destination: outputDir.appendingPathComponent("window-dark.png"))
        }

        // 3 & 4. Update card cropped tightly with window-background margin (light & dark), showing newer release found.
        do {
            let paths = AppPaths(baseDirectory: root.appendingPathComponent("Support-readme-update", isDirectory: true))
            let suite = "QuarkFS.ReadmeUpdate.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }

            let notes = [
                "- 恢复大文件读取（运行期配置使用夸克桌面客户端身份）",
                "- 新增版本更新检查：默认每 24 小时检查一次，仅提示并打开官方发行页面",
                "- 更换菜单栏单色模板图标，以形状区分未挂载、挂载中、已挂载和需要处理状态"
            ].joined(separator: "\n")
            let transport = SnapshotTransport(mode: .release(tag: "v1.2.0", publishedAt: "2026-11-24T10:00:00Z", body: notes))
            let system = SystemServices(
                mountTable: fakeMountTable,
                unmount: URL(fileURLWithPath: "/usr/bin/true"),
                macFUSEStatus: { (true, true) }
            )
            let model = AppModel(
                credentialStore: SnapshotCredentials(),
                defaults: defaults,
                paths: paths,
                system: system,
                runningVersion: "1.1.3",
                updateClock: { clockDate },
                openURL: { _ in },
                updateTransport: transport.makeTransport()
            )
            model.settings.mountPath = "/Users/you/Quark"
            model.settings.infusePort = 8686
            model.settings.automaticUpdateCheck = true
            await model.bootstrapReadmeFixture(cacheBytes: 0, logs: [])
            await model.checkForUpdatesManually()

            guard model.availableUpdate?.version == "1.2.0" else {
                throw NSError(domain: "Snapshots", code: 31, userInfo: [NSLocalizedDescriptionKey: "README update card fixture did not find v1.2.0"])
            }

            let cardView = ContentView(model: model)
                .updateCard
                .padding(20)
                .frame(width: windowSize.width)
                .background(Color(nsColor: .windowBackgroundColor))

            try renderFittedSwiftUIView(cardView, width: windowSize.width, scale: 2, dark: false,
                                        destination: outputDir.appendingPathComponent("update-light.png"))
            try renderFittedSwiftUIView(cardView, width: windowSize.width, scale: 2, dark: true,
                                        destination: outputDir.appendingPathComponent("update-dark.png"))
        }

        // 5 & 6. Four-state menu-bar glyph illustration strip (light & dark).
        try renderFittedSwiftUIView(
            ReadmeMenuBarStrip(dark: false),
            width: windowSize.width,
            scale: 2,
            dark: false,
            destination: outputDir.appendingPathComponent("menubar-light.png")
        )
        try renderFittedSwiftUIView(
            ReadmeMenuBarStrip(dark: true),
            width: windowSize.width,
            scale: 2,
            dark: true,
            destination: outputDir.appendingPathComponent("menubar-dark.png")
        )
    }

    @MainActor
    private static func renderFittedSwiftUIView<V: View>(
        _ view: V,
        width: CGFloat,
        scale: Int,
        dark: Bool,
        destination: URL
    ) throws {
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
        let themedView = view
            .frame(width: width)
            .environment(\.colorScheme, dark ? .dark : .light)
        let hosting = NSHostingView(rootView: themedView)
        hosting.appearance = appearance
        hosting.frame = NSRect(x: 0, y: 0, width: width, height: 1000)

        let window = NSWindow(
            contentRect: NSRect(x: -10_000, y: -10_000, width: width, height: 1000),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.appearance = appearance
        window.backgroundColor = .windowBackgroundColor
        window.contentView = hosting
        window.layoutIfNeeded()
        hosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))

        let measuredHeight = ceil(hosting.fittingSize.height)
        let finalHeight = max(120, measuredHeight.truncatingRemainder(dividingBy: 2) == 0 ? measuredHeight : measuredHeight + 1)
        let size = NSSize(width: width, height: finalHeight)
        window.setContentSize(size)
        hosting.frame = NSRect(origin: .zero, size: size)
        window.layoutIfNeeded()
        hosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))

        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(size.width) * scale,
            pixelsHigh: Int(size.height) * scale,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            throw NSError(domain: "Snapshots", code: 22, userInfo: [NSLocalizedDescriptionKey: "failed to allocate fitted bitmap"])
        }
        rep.size = size
        appearance.performAsCurrentDrawingAppearance {
            hosting.cacheDisplay(in: hosting.bounds, to: rep)
        }
        window.contentView = nil

        guard let png = rep.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "Snapshots", code: 23, userInfo: [NSLocalizedDescriptionKey: "failed to encode fitted PNG"])
        }
        try png.write(to: destination, options: .atomic)
    }

    @MainActor
    private static func renderGlyphSheets(outputDir: URL) throws {
        // Sheet 1: 2x Retina comparison sheet with 10x enlargement (220x220 pt) on checkerboard + true-size 1x and 2x light/dark bars.
        let sheetView = GlyphPreviewSheet()
        let sheetSize = NSSize(width: 960, height: 1320)
        try renderSwiftUIView(sheetView, size: sheetSize, scale: 2, dark: false,
                              destination: outputDir.appendingPathComponent("glyph-states.png"))

        // Sheet 2: Native 1x pixel-exact menu-bar strips (1 pixel = 1 pt) for light and dark bars.
        let native1xView = GlyphNative1xStrip()
        let native1xSize = NSSize(width: 460, height: 150)
        try renderSwiftUIView(native1xView, size: native1xSize, scale: 1, dark: false,
                              destination: outputDir.appendingPathComponent("glyph-1x.png"))
    }

    @MainActor
    private static func renderSwiftUIView<V: View>(
        _ view: V,
        size: NSSize,
        scale: Int,
        dark: Bool,
        destination: URL
    ) throws {
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
        let hosting = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        hosting.frame = NSRect(origin: .zero, size: size)
        hosting.appearance = appearance

        let window = NSWindow(
            contentRect: NSRect(x: -10_000, y: -10_000, width: size.width, height: size.height),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.appearance = appearance
        window.backgroundColor = .white
        window.contentView = hosting
        window.layoutIfNeeded()
        hosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))

        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(size.width) * scale,
            pixelsHigh: Int(size.height) * scale,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            throw NSError(domain: "Snapshots", code: 20, userInfo: [NSLocalizedDescriptionKey: "failed to allocate glyph bitmap"])
        }
        rep.size = size
        appearance.performAsCurrentDrawingAppearance {
            hosting.cacheDisplay(in: hosting.bounds, to: rep)
        }
        window.contentView = nil
        guard let png = rep.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "Snapshots", code: 21, userInfo: [NSLocalizedDescriptionKey: "failed to encode glyph PNG"])
        }
        try png.write(to: destination, options: .atomic)
    }

    @MainActor
    private static func findOuterScrollView(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView {
            return scroll
        }
        for child in view.subviews {
            if let found = findOuterScrollView(in: child) {
                return found
            }
        }
        return nil
    }

    @MainActor
    private static func waitUntil(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<80 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return condition()
    }

    private static func freePort() throws -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard result == 0 else { throw POSIXError(.EADDRINUSE) }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &length)
            }
        }
        return Int(UInt16(bigEndian: addr.sin_port))
    }
}

/// Rasterizes the template `NSImage` into a fixed-scale tinted bitmap so 1x
/// pixel output can be inspected explicitly alongside crisp 2x vector output.
@MainActor
private func rasterizedGlyph(_ state: MenuBarGlyphState, pixelSize: Int, tint: NSColor) -> NSImage {
    let template = MenuBarGlyph.image(for: state)
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixelSize,
        pixelsHigh: pixelSize,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    )!
    rep.size = NSSize(width: 22, height: 22)
    NSGraphicsContext.saveGraphicsState()
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = ctx
    ctx.imageInterpolation = .high
    template.draw(in: NSRect(x: 0, y: 0, width: 22, height: 22))
    tint.setFill()
    NSRect(x: 0, y: 0, width: 22, height: 22).fill(using: .sourceIn)
    NSGraphicsContext.restoreGraphicsState()
    let out = NSImage(size: NSSize(width: 22, height: 22))
    out.addRepresentation(rep)
    return out
}

private struct CheckerboardGrid: View {
    let cell: CGFloat
    var body: some View {
        Canvas { context, size in
            let cols = Int(ceil(size.width / cell))
            let rows = Int(ceil(size.height / cell))
            for row in 0..<rows {
                for col in 0..<cols {
                    let rect = CGRect(x: CGFloat(col) * cell, y: CGFloat(row) * cell, width: cell, height: cell)
                    let isLight = (row + col).isMultiple(of: 2)
                    context.fill(Path(rect), with: .color(isLight ? Color(white: 0.95) : Color(white: 0.87)))
                }
            }
        }
    }
}

private struct MenuBarStripRow: View {
    let state: MenuBarGlyphState
    let pixelSize: Int
    let darkBar: Bool
    let label: String

    var body: some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 78, alignment: .leading)

            bar(pressed: false)
            bar(pressed: true)
        }
    }

    private func bar(pressed: Bool) -> some View {
        let fg: Color = darkBar ? .white : .black
        let tint: NSColor = darkBar ? .white : .black
        let barBG: Color = darkBar ? Color(white: 0.14) : Color(white: 0.90)
        let pressedPill: Color = darkBar ? Color.white.opacity(0.22) : Color.black.opacity(0.14)
        return HStack(spacing: 8) {
            Image(systemName: "clock")
                .font(.system(size: 13))
                .foregroundStyle(fg.opacity(0.85))
            Image(nsImage: rasterizedGlyph(state, pixelSize: pixelSize, tint: tint))
                .interpolation(pixelSize == 22 ? .none : .high)
                .frame(width: 22, height: 22)
                .padding(.horizontal, 4)
                .background(
                    pressed ? pressedPill : Color.clear,
                    in: RoundedRectangle(cornerRadius: 4)
                )
            Image(systemName: "wifi")
                .font(.system(size: 13))
                .foregroundStyle(fg.opacity(0.85))
            Image(systemName: "battery.100")
                .font(.system(size: 13))
                .foregroundStyle(fg.opacity(0.85))
            Text("周二 14:30")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(fg.opacity(0.9))
        }
        .padding(.horizontal, 8)
        .frame(height: 26)
        .background(barBG, in: RoundedRectangle(cornerRadius: 6))
    }
}

private struct GlyphPreviewSheet: View {
    private static func title(for state: MenuBarGlyphState) -> String {
        switch state {
        case .idle: "未挂载"
        case .busy: "正在挂载 / 卸载"
        case .mounted: "已挂载"
        case .attention: "需要处理"
        }
    }

    private static func specName(for state: MenuBarGlyphState) -> String {
        switch state {
        case .idle: "A-0-not-mounted"
        case .busy: "A-1-mounting"
        case .mounted: "A-2-mounted"
        case .attention: "A-3-needs-attention"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text("QuarkFS 菜单栏模板图标 · 候选 A 四种状态验证")
                    .font(.title3.bold())
                Text("左侧 10× 放大叠加透明棋盘格（验证镂空真正透明）；右侧真实尺寸 1x（22px）与 2x（44px）浅色/深色菜单栏及按下高亮")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ForEach(MenuBarGlyphState.allCases, id: \.self) { state in
                HStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(Self.title(for: state))
                            .font(.headline)
                        Text(Self.specName(for: state))
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                        ZStack {
                            CheckerboardGrid(cell: 10)
                            Image(nsImage: rasterizedGlyph(state, pixelSize: 440, tint: .black))
                                .resizable()
                                .frame(width: 220, height: 220)
                        }
                        .frame(width: 220, height: 220)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.black.opacity(0.15), lineWidth: 1))
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        MenuBarStripRow(state: state, pixelSize: 22, darkBar: false, label: "1x 浅色")
                        MenuBarStripRow(state: state, pixelSize: 22, darkBar: true, label: "1x 深色")
                        MenuBarStripRow(state: state, pixelSize: 44, darkBar: false, label: "2x 浅色")
                        MenuBarStripRow(state: state, pixelSize: 44, darkBar: true, label: "2x 深色")
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(white: 0.97), in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.black.opacity(0.08), lineWidth: 1))
            }
        }
        .padding(20)
        .background(Color.white)
    }
}

private struct GlyphNative1xStrip: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Native 1x (22×22 px) Light & Dark Bar")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.black)

            HStack(spacing: 14) {
                ForEach(MenuBarGlyphState.allCases, id: \.self) { state in
                    Image(nsImage: MenuBarGlyph.image(for: state))
                        .renderingMode(.template)
                        .foregroundStyle(.black)
                        .frame(width: 22, height: 22)
                }
                Image(systemName: "wifi").font(.system(size: 13)).foregroundStyle(.black)
                Image(systemName: "battery.100").font(.system(size: 13)).foregroundStyle(.black)
                Text("周二 14:30").font(.system(size: 12, weight: .medium)).foregroundStyle(.black)
            }
            .padding(.horizontal, 12)
            .frame(height: 28)
            .background(Color(white: 0.90), in: RoundedRectangle(cornerRadius: 6))

            HStack(spacing: 14) {
                ForEach(MenuBarGlyphState.allCases, id: \.self) { state in
                    Image(nsImage: MenuBarGlyph.image(for: state))
                        .renderingMode(.template)
                        .foregroundStyle(.white)
                        .frame(width: 22, height: 22)
                }
                Image(systemName: "wifi").font(.system(size: 13)).foregroundStyle(.white)
                Image(systemName: "battery.100").font(.system(size: 13)).foregroundStyle(.white)
                Text("周二 14:30").font(.system(size: 12, weight: .medium)).foregroundStyle(.white)
            }
            .padding(.horizontal, 12)
            .frame(height: 28)
            .background(Color(white: 0.14), in: RoundedRectangle(cornerRadius: 6))
        }
        .padding(16)
        .background(Color.white)
    }
}

private struct ReadmeMenuBarStrip: View {
    let dark: Bool

    private static func chineseTitle(for state: MenuBarGlyphState) -> String {
        switch state {
        case .idle: "未挂载"
        case .busy: "正在挂载 / 卸载"
        case .mounted: "已挂载"
        case .attention: "需要处理"
        }
    }

    private static func englishTitle(for state: MenuBarGlyphState) -> String {
        switch state {
        case .idle: "Not mounted"
        case .busy: "Mounting / Unmounting"
        case .mounted: "Mounted"
        case .attention: "Needs attention"
        }
    }

    var body: some View {
        let barFill = dark ? Color(white: 0.16) : Color(white: 0.91)
        let barBorder = dark ? Color.white.opacity(0.10) : Color.black.opacity(0.08)
        let glyphTint: NSColor = dark ? .white : .black

        VStack(spacing: 14) {
            HStack(spacing: 0) {
                ForEach(MenuBarGlyphState.allCases, id: \.self) { state in
                    Image(nsImage: rasterizedGlyph(state, pixelSize: 176, tint: glyphTint))
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 88, height: 88)
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(height: 116)
            .background(barFill, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(barBorder, lineWidth: 1))

            HStack(alignment: .top, spacing: 0) {
                ForEach(MenuBarGlyphState.allCases, id: \.self) { state in
                    VStack(spacing: 3) {
                        Text(Self.chineseTitle(for: state))
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.primary)
                        Text(Self.englishTitle(for: state))
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .padding(20)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}
