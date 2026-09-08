import Foundation

/// Captures only one mount attempt. The engine writes most errors to its log
/// file, while mount_macfuse can write the actionable cause to stderr instead.
public final class MountAttemptDiagnostics: @unchecked Sendable {
    private let lock = NSLock()
    private var captured = Data()
    private let logFile: URL
    private let initialLogSize: UInt64
    private static let limit = 64 * 1024

    public init(logFile: URL) {
        self.logFile = logFile
        initialLogSize = (try? FileManager.default.attributesOfItem(atPath: logFile.path)[.size] as? NSNumber)?.uint64Value ?? 0
    }

    public func append(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        captured.append(data)
        if captured.count > Self.limit { captured.removeFirst(captured.count - Self.limit) }
    }

    public var text: String {
        lock.lock()
        let output = String(decoding: captured, as: UTF8.self)
        lock.unlock()
        guard let handle = try? FileHandle(forReadingFrom: logFile) else { return output }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return output }
        // Never classify a new failure using an older attempt's log entries.
        let start = size < initialLogSize ? 0 : initialLogSize
        let boundedStart = max(start, size > UInt64(Self.limit) ? size - UInt64(Self.limit) : 0)
        guard (try? handle.seek(toOffset: boundedStart)) != nil,
              let data = try? handle.read(upToCount: Self.limit) else { return output }
        return output + "\n" + String(decoding: data, as: UTF8.self)
    }

    public static func isBusyFailure(output: String) -> Bool {
        output.lowercased().split(whereSeparator: \.isNewline).contains(where: {
            ($0.contains("mount_macfuse") || $0.contains("fuse"))
                && ($0.contains("resource busy") || $0.contains("error 16") || $0.contains("error: 16"))
        })
    }

    public static func failureMessage(status: Int32, output: String) -> String {
        let lines = output.lowercased().split(whereSeparator: \.isNewline)
        if isBusyFailure(output: output) {
            return "macFUSE 挂载失败：挂载位置或文件系统资源正被占用（错误 16）。请关闭重复的 QuarkFS 后重试；若仍失败，请重启 Mac。"
        }
        if lines.contains(where: { $0.contains("mountpoint is not empty") || $0.contains("mount point is not empty") }) {
            return "挂载目录包含文件；请选择空文件夹，原有文件已保留"
        }
        if lines.contains(where: { $0.contains("mount_macfuse") && ($0.contains("permission denied") || $0.contains("operation not permitted")) }) {
            return "macFUSE 未获准挂载，请检查系统设置中的文件系统扩展授权后重试"
        }
        if lines.contains(where: { $0.contains("cookie") && ($0.contains("expired") || $0.contains("invalid")) }) {
            return "夸克登录信息已失效，请重新登录后挂载"
        }
        return "文件系统引擎已退出（代码 \(status)），请查看运行记录中的具体原因"
    }
}
