import Foundation

/// The engine configuration written for one app session. Both engines read
/// the `quark:` remote from it; it holds the obscured cookie and must never be
/// logged or kept after the app exits.
public enum RuntimeConfiguration {
    /// Quark refuses large downloads requested by its web page with code
    /// 23018 ("download file size limit"). Clients that stream large files
    /// identify as the Quark PC client. The engine uses one HTTP client for the
    /// download-link request and the CDN transfer, so this covers both.
    public static let quarkClientUserAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) quark-cloud-drive/2.5.20 Chrome/100.0.4896.160 Electron/18.3.5.4-b478491100 Safari/537.36 Channel/pckk_other_ch"

    public static func text(obscuredCookie: String) throws -> String {
        guard !obscuredCookie.isEmpty,
              !obscuredCookie.contains(where: { $0.isNewline || $0.isWhitespace }) else {
            throw CocoaError(.fileWriteInvalidFileName, userInfo: [
                NSLocalizedDescriptionKey: "文件系统引擎返回了无法识别的登录信息"
            ])
        }
        return "[quark]\ntype = quark\ncookie = \(obscuredCookie)\nuser_agent = \(quarkClientUserAgent)\n"
    }

    /// Writes the configuration readable only by the current user.
    public static func write(obscuredCookie: String, to url: URL) throws {
        try text(obscuredCookie: obscuredCookie).write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
