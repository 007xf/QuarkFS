import Foundation
import Security

/// Per-install credentials for the local WebDAV server. Binding to 127.0.0.1
/// does not keep out other macOS users, sandboxed apps with network access or
/// a DNS-rebinding web page; Basic authentication with a random password does.
/// The file lives in the user-only support directory so players keep working
/// across launches.
public struct WebDAVCredentials: Codable, Equatable, Sendable {
    public static let defaultUsername = "quarkfs"

    public let username: String
    public let password: String

    public init(username: String, password: String) {
        self.username = username
        self.password = password
    }

    /// The value of an HTTP `Authorization` header for these credentials.
    public var authorization: String {
        "Basic " + Data("\(username):\(password)".utf8).base64EncodedString()
    }

    /// Passed to the engine through its environment, never its arguments:
    /// any local process can read another process's command line.
    public var engineEnvironment: [String: String] {
        ["RCLONE_USER": username, "RCLONE_PASS": password]
    }

    var isValid: Bool {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        return !username.isEmpty && password.count >= 32
            && username.unicodeScalars.allSatisfy(allowed.contains)
            && password.unicodeScalars.allSatisfy(allowed.contains)
    }

    public static func generate() throws -> WebDAVCredentials {
        var bytes = [UInt8](repeating: 0, count: 24)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw CocoaError(.fileWriteUnknown, userInfo: [
                NSLocalizedDescriptionKey: "无法生成本机连接密码"
            ])
        }
        let password = Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return WebDAVCredentials(username: defaultUsername, password: password)
    }

    /// Returns the saved credentials, or creates them. A link or a damaged
    /// file is replaced, never followed.
    public static func loadOrCreate(at url: URL) throws -> WebDAVCredentials {
        let manager = FileManager.default
        if let attributes = try? manager.attributesOfItem(atPath: url.path),
           attributes[.type] as? FileAttributeType == .typeRegular,
           let data = try? Data(contentsOf: url),
           let saved = try? JSONDecoder().decode(WebDAVCredentials.self, from: data),
           saved.isValid {
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            return saved
        }
        let created = try generate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        // An atomic write renames over the path, replacing a link itself.
        try encoder.encode(created).write(to: url, options: .atomic)
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return created
    }
}
