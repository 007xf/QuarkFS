import Foundation

/// A read failure that the engine only writes to its log. Without it a player
/// fails while QuarkFS still reports the connection as ready.
public enum EngineIssue: Hashable, Sendable {
    case downloadSizeLimit(file: String?)
    case loginExpired
    case repeatedReadFailures(file: String?)

    public var message: String {
        switch self {
        case .downloadSizeLimit(let file):
            "夸克拒绝下载\(file.map { "“\($0)”" } ?? "该文件")：网页端下载大小限制（代码 23018）"
        case .loginExpired:
            "夸克登录已失效，请在“组件与账号”中退出登录后重新扫码"
        case .repeatedReadFailures(let file):
            "读取\(file.map { "“\($0)”" } ?? "文件")连续失败，播放可能中断；原因见运行记录"
        }
    }

    public static func classify(_ line: String) -> EngineIssue? {
        let lowercased = line.lowercased()
        if lowercased.contains("code=23018") || lowercased.contains("download file size limit") {
            return .downloadSizeLimit(file: fileName(in: line))
        }
        // Quark rejects an expired session with HTTP 401 / code 31001.
        if lowercased.contains("require login") || lowercased.contains("http_status=401")
            || lowercased.contains("code=31001") {
            return .loginExpired
        }
        if lowercased.contains("too many errors") {
            return .repeatedReadFailures(file: fileName(in: line))
        }
        return nil
    }

    /// The engine logs `<date> <time> LEVEL : <object>: <message>`. Only an
    /// object that ends in a file extension is reported, by its last component.
    static func fileName(in line: String) -> String? {
        guard let marker = line.range(of: " : ") else { return nil }
        let rest = line[marker.upperBound...]
        guard let end = rest.range(of: ": ") else { return nil }
        let name = (String(rest[..<end.lowerBound]) as NSString).lastPathComponent
        let fileExtension = (name as NSString).pathExtension
        guard name.count <= 255, (1...5).contains(fileExtension.count),
              fileExtension.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else { return nil }
        return name
    }
}

/// Follows an engine log from the size it had when the engine started, so an
/// earlier session's errors are never reported again. A shrinking file means
/// the log was rotated or truncated, and reading restarts at its beginning.
public final class EngineLogTail: @unchecked Sendable {
    private let lock = NSLock()
    private let url: URL
    private var offset: UInt64
    private var partialLine = Data()
    private static let readLimit = 256 * 1024

    public init(url: URL) {
        self.url = url
        offset = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.uint64Value ?? 0
    }

    /// Complete lines appended since the previous call. A burst larger than
    /// the read limit is skipped up to its most recent part.
    public func readNewLines() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return [] }
        if size < offset {
            offset = 0
            partialLine.removeAll()
        }
        guard size > offset else { return [] }
        let start = max(offset, size > UInt64(Self.readLimit) ? size - UInt64(Self.readLimit) : 0)
        if start > offset { partialLine.removeAll() }
        guard (try? handle.seek(toOffset: start)) != nil,
              let data = try? handle.read(upToCount: Int(size - start)) else { return [] }
        offset = start + UInt64(data.count)

        let buffer = partialLine + data
        guard let lastNewline = buffer.lastIndex(of: UInt8(ascii: "\n")) else {
            partialLine = buffer.count > Self.readLimit ? Data() : buffer
            return []
        }
        partialLine = Data(buffer[buffer.index(after: lastNewline)...])
        return String(decoding: buffer[..<lastNewline], as: UTF8.self)
            .split(whereSeparator: \.isNewline)
            .map(String.init)
    }
}
