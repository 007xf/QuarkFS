import AppKit
import QuarkFSCore
import SwiftUI

struct ContentView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                header
                if case .failed(let message) = model.status {
                    warning(message)
                }
                connectionCard
                setupCard
                cacheCard
                activityCard
            }
            .padding(24)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .frame(minWidth: 720, minHeight: 720)
        .onAppear { model.bootstrap() }
        .onChange(of: model.settings) { _, _ in model.persistSettings() }
        .sheet(isPresented: $model.showingLogin) {
            QRLoginView(onSuccess: model.saveCookieFromQR)
        }
    }

    private var header: some View {
        HStack(spacing: 16) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 64, height: 64)

            VStack(alignment: .leading, spacing: 4) {
                Text("QuarkFS")
                    .font(.largeTitle.bold())
                Text("把夸克网盘变成 Mac 本地磁盘，供 Infuse 直接读取")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Label(model.status.title, systemImage: model.status.symbol)
                .font(.headline)
                .foregroundStyle(statusColor)
                .padding(.horizontal, 13)
                .padding(.vertical, 8)
                .background(statusColor.opacity(0.12), in: Capsule())
        }
    }

    private var connectionCard: some View {
        GroupBox {
            VStack(spacing: 14) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("挂载位置")
                            .font(.headline)
                        TextField("挂载目录", text: $model.settings.mountPath)
                            .textFieldStyle(.roundedBorder)
                            .disabled(!model.canEditMountPath)
                    }
                    Button("在 Finder 中打开") { model.openMountFolder() }
                        .disabled(!model.preflight.mountDirectoryReady)
                }

                Divider()

                HStack {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(model.settings.profile.title + "模式")
                            .font(.headline)
                        Text(model.settings.profile.summary)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if model.shouldOfferUnmount {
                        Button("卸载", role: .destructive) { model.unmount() }
                            .controlSize(.large)
                            .disabled(model.status == .unmounting)
                    } else {
                        Button("挂载 Quark") { model.mount() }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.large)
                            .disabled(!model.preflight.ready || model.mountOperationInProgress)
                    }
                }

                Divider()

                HStack(spacing: 10) {
                    Image(systemName: model.infuseBridgeRunning ? "play.circle.fill" : "pause.circle")
                        .foregroundStyle(model.infuseBridgeRunning ? .green : .secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Infuse 本机连接")
                            .font(.headline)
                        Text(model.infuseBridgeRunning ? "已就绪 · 127.0.0.1:8686" : "尚未运行")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("重新启动") { model.restartInfuseBridge() }
                        .disabled(!model.preflight.hasCredential || !model.preflight.engine.isQuarkCapable)
                }
            }
            .padding(6)
        } label: {
            Label("连接", systemImage: "externaldrive.connected.to.line.below")
        }
    }

    private var setupCard: some View {
        GroupBox {
            VStack(spacing: 12) {
                checkRow(
                    title: "QuarkFS 引擎",
                    detail: model.preflight.engine.version ?? model.preflight.engine.problem ?? "未找到",
                    passed: model.preflight.engine.isQuarkCapable
                )
                Divider()
                checkRow(
                    title: "macFUSE 文件系统",
                    detail: macFUSEDetail,
                    passed: model.preflight.macFUSEReady,
                    actionTitle: model.preflight.macFUSEReady ? nil : (model.preflight.macFUSEInstalled ? "重新检查" : "获取 macFUSE"),
                    action: model.preflight.macFUSEInstalled ? model.refreshPreflight : model.openMacFUSEWebsite
                )
                Divider()
                checkRow(
                    title: "夸克账号",
                    detail: model.preflight.hasCredential ? "登录信息已由 macOS 钥匙串保护" : "尚未登录",
                    passed: model.preflight.hasCredential,
                    actionTitle: model.preflight.hasCredential ? "退出登录" : "扫码登录",
                    action: model.preflight.hasCredential ? model.forgetCredential : { model.showingLogin = true }
                )

                if !model.preflight.hasCredential {
                    DisclosureGroup("无法扫码？使用 Cookie 登录") {
                        HStack {
                            SecureField("粘贴完整 Cookie", text: $model.cookieInput)
                                .textFieldStyle(.roundedBorder)
                            Button("保存到钥匙串") { model.saveCookie() }
                        }
                        .padding(.top, 8)
                    }
                    .font(.callout)
                }
            }
            .padding(6)
        } label: {
            Label("首次设置", systemImage: "checklist")
        }
    }

    private var cacheCard: some View {
        GroupBox {
            VStack(spacing: 14) {
                Picker("缓存策略", selection: $model.settings.profile) {
                    ForEach(CacheProfile.allCases) { profile in
                        Text(profile.title).tag(profile)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(!model.canClearCache)

                HStack {
                    Toggle("关闭影片后自动清理", isOn: $model.settings.autoCleanup)
                        .disabled(model.settings.profile == .zeroResidual || !model.canClearCache)
                    Spacer()
                    Stepper(
                        "等待 \(model.settings.cleanupDelaySeconds) 秒",
                        value: $model.settings.cleanupDelaySeconds,
                        in: 15...600,
                        step: 15
                    )
                    .disabled(!model.settings.autoCleanup || model.settings.profile == .zeroResidual || !model.canClearCache)
                }

                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("当前磁盘缓存")
                            .font(.headline)
                        Text(ByteCountFormatter.string(fromByteCount: model.cacheBytes, countStyle: .file))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("刷新") { model.refreshCacheUsage() }
                    Button("清理全部缓存", role: .destructive) { model.clearCache() }
                        .disabled(!model.canClearCache)
                }

                if model.settings.profile != .zeroResidual {
                    Text("缓存上限仅对已关闭的文件严格生效；正在播放的文件可能短时超过上限。最省空间请使用“零残留”。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(6)
        } label: {
            Label("空间与缓存", systemImage: "internaldrive")
        }
    }

    private var activityCard: some View {
        GroupBox {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 5) {
                    if model.logs.isEmpty {
                        Text("等待操作…")
                            .foregroundStyle(.tertiary)
                    } else {
                        ForEach(Array(model.logs.enumerated()), id: \.offset) { _, log in
                            Text(log)
                                .textSelection(.enabled)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.system(.caption, design: .monospaced))
            .frame(height: 120)
            .padding(6)
        } label: {
            Label("运行记录", systemImage: "text.alignleft")
        }
    }

    private func warning(_ message: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
            Text(message)
            Spacer()
            Button("重新检查") { model.refreshPreflight() }
        }
        .foregroundStyle(.orange)
        .padding(12)
        .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
    }

    private func checkRow(
        title: String,
        detail: String,
        passed: Bool,
        actionTitle: String? = nil,
        action: (() -> Void)? = nil
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: passed ? "checkmark.circle.fill" : "circle.dashed")
                .foregroundStyle(passed ? .green : .secondary)
                .font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let actionTitle, let action {
                Button(actionTitle, action: action)
            }
        }
    }

    private var statusColor: Color {
        switch model.status {
        case .mounted: .green
        case .failed: .orange
        case .mounting, .unmounting: .blue
        case .notMounted: .secondary
        }
    }

    private var macFUSEDetail: String {
        if model.preflight.macFUSEReady { return "已安装，系统扩展已加载" }
        if model.preflight.macFUSEInstalled { return "已安装，但系统扩展尚未加载；请在隐私与安全性中允许后重启" }
        return "需要安装并在系统设置中允许"
    }
}
