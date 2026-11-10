import Foundation

/// The engine configuration written for one app session. Both engines read
/// the `quark:` remote from it; it holds the obscured cookie and must never be
/// logged or kept after the app exits.
public enum RuntimeConfiguration {
    public static func text(obscuredCookie: String) throws -> String {
        guard !obscuredCookie.isEmpty,
              !obscuredCookie.contains(where: { $0.isNewline || $0.isWhitespace }) else {
            throw CocoaError(.fileWriteInvalidFileName, userInfo: [
                NSLocalizedDescriptionKey: "文件系统引擎返回了无法识别的登录信息"
            ])
        }
        return "[quark]\ntype = quark\ncookie = \(obscuredCookie)\n"
    }

    /// Writes the configuration readable only by the current user.
    public static func write(obscuredCookie: String, to url: URL) throws {
        try text(obscuredCookie: obscuredCookie).write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
