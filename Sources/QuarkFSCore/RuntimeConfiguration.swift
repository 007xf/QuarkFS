import Darwin
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

    /// Writes the configuration atomically via a temporary file created with
    /// mode 0600 up front (O_CREAT|O_EXCL|O_NOFOLLOW), so it never exists with
    /// wider umask permissions.
    public static func write(obscuredCookie: String, to url: URL) throws {
        let data = Data(try text(obscuredCookie: obscuredCookie).utf8)
        let directory = url.deletingLastPathComponent()
        let tempURL = directory.appendingPathComponent(".rclone-\(UUID().uuidString).tmp")
        let fd = Darwin.open(
            tempURL.path,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            0o600
        )
        guard fd >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        var closed = false
        do {
            try data.withUnsafeBytes { rawBuffer in
                guard let base = rawBuffer.baseAddress else { return }
                var written = 0
                while written < rawBuffer.count {
                    let count = Darwin.write(fd, base.advanced(by: written), rawBuffer.count - written)
                    if count < 0 {
                        if errno == EINTR { continue }
                        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                    }
                    written += count
                }
            }
            guard Darwin.close(fd) == 0 else {
                closed = true
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            closed = true
            guard Darwin.rename(tempURL.path, url.path) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        } catch {
            if !closed { _ = Darwin.close(fd) }
            _ = Darwin.unlink(tempURL.path)
            throw error
        }
    }

    /// Removes `url` and any leftover `.rclone-*.tmp` temporary files in the
    /// same runtime directory (for example after a crash between open and rename).
    public static func remove(at url: URL) {
        _ = Darwin.unlink(url.path)
        let directory = url.deletingLastPathComponent()
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else {
            return
        }
        for name in entries where name.hasPrefix(".rclone-") && name.hasSuffix(".tmp") {
            _ = Darwin.unlink(directory.appendingPathComponent(name).path)
        }
    }
}
