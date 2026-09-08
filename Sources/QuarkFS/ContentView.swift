import AppKit
import QuarkFSCore
import SwiftUI

struct ContentView: View {
    @ObservedObject var model: AppModel
    @StateObject private var draft = ConnectionDraft()
    @State private var showingComponents = false

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                header
                if case .failed(let message) = model.status {
                    warning(message)
                }
                connectionCard
                if model.preflight.needsSetup || showingComponents {
                    setupCard
                }
                cacheCard
                activityCard
            }
            .padding(24)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .frame(minWidth: 720, minHeight: 560)
        .task {
            draft.mountPathInput = model.settings.mountPath
            draft.infusePortInput = String(model.settings.infusePort)
            await model.bootstrap()
        }
        .onChange(of: model.settings) { _, _ in
            Task { await model.persistSettings() }
        }
        .onChange(of: model.settings.mountPath) { _, path in draft.mountPathInput = path }
        .onChange(of: model.settings.infusePort) { _, port in draft.infusePortInput = String(port) }
        .sheet(isPresented: $model.showingLogin) {
            QRLoginView { cookie in Task { await model.saveCookieFromQR(cookie) } }
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
                Text("Finder 本地磁盘 · Infuse 本机连接")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 8) {
                Label(model.status.title, systemImage: model.status.symbol)
                    .font(.headline)
                    .foregroundStyle(statusColor)
                    .padding(.horizontal, 13)
                    .padding(.vertical, 8)
                    .background(statusColor.opacity(0.12), in: Capsule())
                if !model.preflight.needsSetup {
                    Button(showingComponents ? "收起组件与账号" : "组件与账号") {
                        showingComponents.toggle()
                        if showingComponents { Task { await model.refreshPreflight() } }
                    }
                    .buttonStyle(.link)
                }
            }
        }
    }

    private var connectionCard: some View {
        GroupBox {
            VStack(spacing: 14) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("挂载位置")
                            .font(.headline)
                        TextField("挂载目录", text: $draft.mountPathInput)
                            .textFieldStyle(.roundedBorder)
                            .disabled(!model.canEditMountPath)
                            .onSubmit { Task { await model.applyMountPath(draft.mountPathInput) } }
                    }
                    Button("应用") { Task { await model.applyMountPath(draft.mountPathInput) } }
                        .disabled(!model.canEditMountPath || draft.mountPathInput == model.settings.mountPath)
                    Button("选择…") { model.chooseMountFolder() }
                        .disabled(!model.canEditMountPath)
                    Button("在 Finder 中打开") { model.openMountFolder() }
                        .disabled(!model.preflight.mountDirectoryReady)
                }

                if let problem = model.preflight.mountDirectoryProblem {
                    Text(problem)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .frame(maxWidth: .infinity, alignment: .leading)
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
                            .disabled(model.status == .unmounting || model.isBusy)
                    } else {
                        Button("挂载 Quark") { Task { await model.mount() } }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.large)
                            .disabled(!model.preflight.ready || model.mountOperationInProgress || model.isBusy || model.isChecking)
                    }
                }

                Divider()

                HStack(spacing: 10) {
                    Image(systemName: model.infuseBridgeRunning ? "play.circle.fill" : "pause.circle")
                        .foregroundStyle(model.infuseBridgeRunning ? .green : .secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Infuse 本机连接")
                            .font(.headline)
                        Text(model.infuseBridgeDetail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if model.isBusy { ProgressView().controlSize(.small) }
                    if model.infuseBridgeActive {
                        Button("停止") { Task { await model.disconnectInfuseBridge() } }
                            .disabled(model.isBusy)
                    }
                    Button(model.infuseBridgeActive ? "重新启动" : "启动连接") {
                        Task { await model.restartInfuseBridge() }
                    }
                    .disabled(!model.preflight.hasCredential || !model.preflight.engine.isQuarkCapable || model.isBusy || model.isChecking)
                }

                HStack {
                    Text("端口")
                    TextField("8686", text: $draft.infusePortInput)
                        .frame(width: 70)
                        .textFieldStyle(.roundedBorder)
                        .disabled(model.isBusy)
                        .onSubmit { Task { await model.applyInfusePort(draft.infusePortInput) } }
                    Button("应用端口") { Task { await model.applyInfusePort(draft.infusePortInput) } }
                        .disabled(model.isBusy || draft.infusePortInput == String(model.settings.infusePort))
                    Spacer()
                    Button("复制连接信息") { model.copyInfuseConnection() }
                    Button("打开 Infuse") { model.openInfuse() }
                }
                Text("Infuse 连接可独立使用，无需先挂载磁盘。更改端口后，请同步更新 Infuse 中的设置。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Toggle("挂载后自动打开 Finder", isOn: $model.settings.openFinderAfterMount)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .disabled(model.isBusy)
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
                    detail: engineDetail,
                    passed: model.preflight.engine.isQuarkCapable && model.preflight.engine.mountCommand == "cmount"
                )
                Divider()
                checkRow(
                    title: "macFUSE 文件系统",
                    detail: macFUSEDetail,
                    passed: model.preflight.macFUSEReady,
                    actionTitle: model.preflight.macFUSEReady ? nil : (model.preflight.macFUSEInstalled ? "重新检查" : "获取 macFUSE"),
                    action: {
                        if model.preflight.macFUSEInstalled { Task { await model.refreshPreflight() } }
                        else { model.openMacFUSEWebsite() }
                    }
                )
                Divider()
                checkRow(
                    title: "夸克账号",
                    detail: model.preflight.hasCredential ? "已由钥匙串保护；首次弹窗请选择“始终允许”" : "尚未登录",
                    passed: model.preflight.hasCredential,
                    actionTitle: model.preflight.hasCredential ? "退出登录" : "扫码登录",
                    action: {
                        if model.preflight.hasCredential { Task { await model.forgetCredential() } }
                        else { model.showingLogin = true }
                    }
                )
                .disabled(!model.canEditMountPath)

                if !model.preflight.hasCredential {
                    DisclosureGroup("无法扫码？使用 Cookie 登录") {
                        HStack {
                            SecureField("粘贴完整 Cookie", text: $model.cookieInput)
                                .textFieldStyle(.roundedBorder)
                            Button("保存到钥匙串") { Task { await model.saveCookie() } }
                                .disabled(model.isBusy || model.cookieInput.isEmpty)
                        }
                        .padding(.top, 8)
                    }
                    .font(.callout)
                }
            }
            .padding(6)
        } label: {
            HStack {
                Label(model.preflight.needsSetup ? "首次设置" : "组件与账号", systemImage: "checklist")
                Spacer()
                Button(model.isChecking ? "检查中…" : "重新检查") { Task { await model.refreshPreflight() } }
                    .disabled(model.isChecking)
            }
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
                    Button("清理全部缓存", role: .destructive) { Task { await model.clearCache() } }
                        .disabled(!model.canClearCache)
                }

                if model.settings.profile != .zeroResidual {
                    Text("磁盘挂载与 Infuse 分别计算缓存上限。正在播放的文件可能超过上限；清理缓存会短暂中断 Infuse 连接。最省空间请使用“零残留”。")
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
            Button(model.isChecking ? "检查中…" : "重新检查") { Task { await model.refreshPreflight() } }
                .disabled(model.isChecking)
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

    private var engineDetail: String {
        if model.preflight.engine.isQuarkCapable && model.preflight.engine.mountCommand != "cmount" {
            return "当前引擎缺少本地磁盘挂载功能，请重新安装 QuarkFS"
        }
        return model.preflight.engine.version ?? model.preflight.engine.problem ?? "未找到"
    }
}

private final class ConnectionDraft: ObservableObject {
    @Published var mountPathInput = ""
    @Published var infusePortInput = ""
}
