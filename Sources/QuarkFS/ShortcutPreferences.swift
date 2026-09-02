import Foundation

enum ShortcutAction: String, CaseIterable, Identifiable {
    case showWindow
    case toggleMount
    case openFinder
    case refresh
    case clearCache

    var id: String { rawValue }

    var title: String {
        switch self {
        case .showWindow: "显示 QuarkFS"
        case .toggleMount: "挂载或卸载 Quark"
        case .openFinder: "在 Finder 中打开"
        case .refresh: "重新检查"
        case .clearCache: "清理磁盘缓存"
        }
    }

    var defaultKey: String {
        switch self {
        case .showWindow: "o"
        case .toggleMount: "e"
        case .openFinder: "f"
        case .refresh: "r"
        case .clearCache: "k"
        }
    }
}

struct AppShortcut: Codable, Equatable, Hashable {
    var key: String?
    var control: Bool
    var option: Bool
    var shift: Bool
    var command: Bool

    static func defaultShortcut(key: String) -> AppShortcut {
        AppShortcut(
            key: key,
            control: false,
            option: true,
            shift: false,
            command: true
        )
    }

    static let disabled = AppShortcut(
        key: nil,
        control: false,
        option: false,
        shift: false,
        command: false
    )
}

struct ShortcutPreferences: Codable, Equatable {
    var showWindow = AppShortcut.defaultShortcut(key: ShortcutAction.showWindow.defaultKey)
    var toggleMount = AppShortcut.defaultShortcut(key: ShortcutAction.toggleMount.defaultKey)
    var openFinder = AppShortcut.defaultShortcut(key: ShortcutAction.openFinder.defaultKey)
    var refresh = AppShortcut.defaultShortcut(key: ShortcutAction.refresh.defaultKey)
    var clearCache = AppShortcut.defaultShortcut(key: ShortcutAction.clearCache.defaultKey)

    subscript(action: ShortcutAction) -> AppShortcut {
        get {
            switch action {
            case .showWindow: showWindow
            case .toggleMount: toggleMount
            case .openFinder: openFinder
            case .refresh: refresh
            case .clearCache: clearCache
            }
        }
        set {
            switch action {
            case .showWindow: showWindow = newValue
            case .toggleMount: toggleMount = newValue
            case .openFinder: openFinder = newValue
            case .refresh: refresh = newValue
            case .clearCache: clearCache = newValue
            }
        }
    }
}
