import AppKit
import SwiftUI

@main
struct QuarkFSApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup("QuarkFS", id: "main") {
            ContentView(model: model)
                .onAppear { appDelegate.model = model }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 780, height: 820)

        MenuBarExtra {
            MenuBarContent(model: model)
        } label: {
            Image(systemName: "atom")
                .symbolRenderingMode(.monochrome)
                .font(.system(size: 16, weight: .medium))
                .frame(width: 18, height: 17)
                .padding(.horizontal, 3)
                .accessibilityLabel("QuarkFS · \(model.status.title)")
        }
        .menuBarExtraStyle(.menu)

        Settings {
            ShortcutSettingsView(model: model)
        }

        .commands {
            QuarkFSCommands(model: model)
        }
    }
}

/// All shortcuts are app-scoped menu commands. They never register global
/// event taps, so another foreground app keeps full ownership of its keys.
private struct QuarkFSCommands: Commands {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandMenu("QuarkFS 操作") {
            Button("显示 QuarkFS") {
                openWindow(id: "main")
                NSApplication.shared.activate(ignoringOtherApps: true)
            }
            .appShortcut(model.shortcut(for: .showWindow))

            Divider()

            Button(isConnected ? "卸载 Quark" : "挂载 Quark") {
                if isConnected {
                    model.unmount()
                } else {
                    model.mount()
                }
            }
            .appShortcut(model.shortcut(for: .toggleMount))
            .disabled(isConnected ? model.status == .unmounting : !model.preflight.ready)

            Button("在 Finder 中打开") {
                model.openMountFolder()
            }
            .appShortcut(model.shortcut(for: .openFinder))
            .disabled(!model.preflight.mountDirectoryReady)

            Button("重新检查") {
                model.refreshPreflight()
                model.refreshCacheUsage()
            }
            .appShortcut(model.shortcut(for: .refresh))

            Button("清理全部缓存") {
                model.clearCache()
            }
            .appShortcut(model.shortcut(for: .clearCache))
            .disabled(model.status == .mounted || model.status == .mounting)
        }
    }

    private var isConnected: Bool {
        model.status == .mounted || model.status == .mounting
    }
}

private struct ShortcutSettingsView: View {
    @ObservedObject var model: AppModel
    @StateObject private var localState = ShortcutSettingsState()

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 4) {
                Text("自定义快捷键")
                    .font(.title2.bold())
                Text("点击快捷键框后直接按下新组合；Esc 取消，Delete 清除。")
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 0) {
                ForEach(ShortcutAction.allCases) { action in
                    shortcutRow(action)
                    if action != ShortcutAction.allCases.last {
                        Divider()
                    }
                }
            }
            .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 10))

            if let validationMessage = localState.validationMessage {
                Label(validationMessage, systemImage: "exclamationmark.circle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }

            HStack {
                Text("仅在 QuarkFS 激活时生效；重复组合不会保存。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("恢复默认") {
                    model.resetShortcuts()
                    localState.validationMessage = nil
                }
            }
        }
        .padding(24)
        .frame(width: 520)
    }

    private func shortcutRow(_ action: ShortcutAction) -> some View {
        HStack(spacing: 18) {
            Text(action.title)
                .frame(maxWidth: .infinity, alignment: .leading)
            Spacer()
            ShortcutRecorderView(shortcut: model.shortcut(for: action)) { captured in
                if let captured {
                    if model.setShortcut(captured, for: action) {
                        localState.validationMessage = nil
                    } else {
                        localState.validationMessage = "这个组合已被其他 QuarkFS 操作占用，或缺少修饰键。"
                    }
                } else {
                    model.clearShortcut(for: action)
                    localState.validationMessage = nil
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }
}

private final class ShortcutSettingsState: ObservableObject {
    @Published var validationMessage: String?
}

private struct ShortcutRecorderView: View {
    let shortcut: AppShortcut
    let onCapture: (AppShortcut?) -> Void
    @StateObject private var state = ShortcutRecorderState()

    var body: some View {
        HStack(spacing: 0) {
            ZStack {
                HStack(spacing: 8) {
                    modifier("⌃", active: shortcut.control)
                    modifier("⌥", active: shortcut.option)
                    modifier("⇧", active: shortcut.shift)
                    modifier("⌘", active: shortcut.command)

                    if state.isRecording {
                        Text("请按快捷键")
                            .font(.callout)
                            .foregroundStyle(.blue)
                    } else if let key = shortcut.key {
                        Text(key.uppercased())
                            .font(.system(.body, design: .rounded).weight(.semibold))
                            .foregroundStyle(.blue)
                    } else {
                        Text("未设置")
                            .font(.callout)
                            .foregroundStyle(.tertiary)
                    }

                    Spacer(minLength: 4)
                }
                .padding(.leading, 13)

                ShortcutCaptureView(isRecording: $state.isRecording, onCapture: onCapture)
            }

            Button {
                onCapture(nil)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 11)
            .accessibilityLabel("清除快捷键")
        }
        .frame(width: 270, height: 38)
        .background(
            RoundedRectangle(cornerRadius: 9)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9)
                .stroke(state.isRecording ? Color.accentColor : Color.secondary.opacity(0.24), lineWidth: 1)
        )
    }

    private func modifier(_ symbol: String, active: Bool) -> some View {
        Text(symbol)
            .font(.system(size: 18, weight: .semibold, design: .rounded))
            .foregroundStyle(active ? Color.accentColor : Color.secondary)
    }
}

private final class ShortcutRecorderState: ObservableObject {
    @Published var isRecording = false
}

private struct ShortcutCaptureView: NSViewRepresentable {
    @Binding var isRecording: Bool
    let onCapture: (AppShortcut?) -> Void

    func makeNSView(context: Context) -> ShortcutCaptureNSView {
        ShortcutCaptureNSView()
    }

    func updateNSView(_ view: ShortcutCaptureNSView, context: Context) {
        view.onRecordingChanged = { isRecording = $0 }
        view.onCapture = onCapture
    }
}

private final class ShortcutCaptureNSView: NSView {
    var onRecordingChanged: ((Bool) -> Void)?
    var onCapture: ((AppShortcut?) -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        onRecordingChanged?(true)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            window?.makeFirstResponder(nil)
            return
        }
        if event.keyCode == 51 || event.keyCode == 117 {
            onCapture?(nil)
            window?.makeFirstResponder(nil)
            return
        }

        let flags = event.modifierFlags.intersection([.control, .option, .shift, .command])
        guard !flags.isEmpty,
              let raw = event.charactersIgnoringModifiers?.lowercased(),
              raw.count == 1,
              let character = raw.first,
              character.isLetter || character.isNumber else {
            NSSound.beep()
            return
        }

        onCapture?(AppShortcut(
            key: raw,
            control: flags.contains(.control),
            option: flags.contains(.option),
            shift: flags.contains(.shift),
            command: flags.contains(.command)
        ))
        window?.makeFirstResponder(nil)
    }

    override func resignFirstResponder() -> Bool {
        onRecordingChanged?(false)
        return super.resignFirstResponder()
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }
}

private struct MenuBarContent: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text("QuarkFS · \(model.status.title)")

        Divider()

        Button("打开 QuarkFS") {
            openWindow(id: "main")
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
        .appShortcut(model.shortcut(for: .showWindow))

        if model.status == .mounted || model.status == .mounting {
            Button("卸载 Quark") {
                model.unmount()
            }
            .appShortcut(model.shortcut(for: .toggleMount))
        } else {
            Button("挂载 Quark") {
                model.mount()
            }
            .appShortcut(model.shortcut(for: .toggleMount))
            .disabled(!model.preflight.ready)
        }

        Button("在 Finder 中打开") {
            model.openMountFolder()
        }
        .appShortcut(model.shortcut(for: .openFinder))
        .disabled(!model.preflight.mountDirectoryReady)

        Button("重新检查") {
            model.refreshPreflight()
            model.refreshCacheUsage()
        }
        .appShortcut(model.shortcut(for: .refresh))

        Button("清理磁盘缓存") {
            model.clearCache()
        }
        .appShortcut(model.shortcut(for: .clearCache))
        .disabled(model.status == .mounted || model.status == .mounting)

        Divider()

        SettingsLink {
            Text("自定义快捷键…")
        }

        Divider()

        Button("退出 QuarkFS") {
            model.shutdownNow()
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}

private extension AppShortcut {
    var keyEquivalent: KeyEquivalent? {
        guard let key, let character = key.first else { return nil }
        return KeyEquivalent(character)
    }

    var eventModifiers: EventModifiers {
        var result: EventModifiers = []
        if control { result.insert(.control) }
        if option { result.insert(.option) }
        if shift { result.insert(.shift) }
        if command { result.insert(.command) }
        return result
    }
}

private extension View {
    @ViewBuilder
    func appShortcut(_ shortcut: AppShortcut) -> some View {
        if let key = shortcut.keyEquivalent {
            keyboardShortcut(key, modifiers: shortcut.eventModifiers)
        } else {
            self
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?

    func applicationWillTerminate(_ notification: Notification) {
        model?.shutdownNow()
    }
}
