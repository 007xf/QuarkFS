import Darwin
import Foundation

/// Identifies an engine this app started. macOS does not stop child processes
/// when their parent crashes or is force-quit, so the next launch uses the
/// record to stop a leftover engine that still serves the drive and holds the
/// port. A process ID alone could have been reused; the start time cannot.
public struct EngineProcessRecord: Codable, Equatable, Sendable {
    public let pid: Int32
    public let startSeconds: UInt64
    public let startMicroseconds: UInt64

    public init?(runningProcess pid: Int32) {
        guard let info = Self.bsdInfo(pid) else { return nil }
        self.pid = pid
        startSeconds = info.pbi_start_tvsec
        startMicroseconds = info.pbi_start_tvusec
    }

    public func save(to url: URL) throws {
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    public static func load(from url: URL) -> EngineProcessRecord? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(EngineProcessRecord.self, from: data)
    }

    /// Stops the recorded engine only when it is still the recorded process,
    /// its app is gone (launchd adopted it) and its arguments contain
    /// `requiredArgument`, such as this app's runtime config path. Returns true
    /// when a leftover engine was stopped. An engine still owned by a running
    /// app is never touched.
    public static func stopOrphan(recordAt url: URL, requiredArgument: String) async -> Bool {
        guard let record = load(from: url) else {
            try? FileManager.default.removeItem(at: url)
            return false
        }
        guard let info = bsdInfo(record.pid), record.matches(info), info.pbi_status != UInt32(SZOMB) else {
            try? FileManager.default.removeItem(at: url)
            return false
        }
        guard info.pbi_ppid == 1 else { return false }
        guard arguments(of: record.pid)?.contains(requiredArgument) == true else {
            try? FileManager.default.removeItem(at: url)
            return false
        }
        kill(record.pid, SIGTERM)
        for attempt in 0..<80 {
            if !record.isAlive { break }
            if attempt == 60 { kill(record.pid, SIGKILL) }
            try? await Task.sleep(for: .milliseconds(50))
        }
        let stopped = !record.isAlive
        if stopped { try? FileManager.default.removeItem(at: url) }
        return stopped
    }

    var isAlive: Bool {
        guard let info = Self.bsdInfo(pid), matches(info) else { return false }
        return info.pbi_status != UInt32(SZOMB)
    }

    func matches(_ info: proc_bsdinfo) -> Bool {
        info.pbi_start_tvsec == startSeconds && info.pbi_start_tvusec == startMicroseconds
    }

    static func bsdInfo(_ pid: Int32) -> proc_bsdinfo? {
        guard pid > 0 else { return nil }
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return info
    }

    /// The process's arguments, readable only for the current user's processes.
    static func arguments(of pid: Int32) -> [String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        let count = buffer.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        var index = MemoryLayout<Int32>.size
        // Skip the executable path and its padding.
        while index < size, buffer[index] != 0 { index += 1 }
        while index < size, buffer[index] == 0 { index += 1 }
        var arguments: [String] = []
        while arguments.count < Int(count), index < size {
            let start = index
            while index < size, buffer[index] != 0 { index += 1 }
            arguments.append(String(decoding: buffer[start..<index], as: UTF8.self))
            index += 1
        }
        return arguments
    }
}
