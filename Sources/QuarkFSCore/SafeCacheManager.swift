import Foundation

public enum SafeCacheError: LocalizedError {
    case unsafePath

    public var errorDescription: String? {
        "拒绝清理不属于 QuarkFS 的目录"
    }
}

public struct SafeCacheManager: Sendable {
    public let cacheRoot: URL
    public let allowedParent: URL

    public init(cacheRoot: URL, allowedParent: URL) {
        self.cacheRoot = cacheRoot.standardizedFileURL
        self.allowedParent = allowedParent.standardizedFileURL
    }

    public func allocatedBytes() -> Int64 {
        guard (try? validateRoot()) != nil else { return 0 }
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileAllocatedSizeKey, .totalFileAllocatedSizeKey]
        guard let enumerator = FileManager.default.enumerator(
            at: cacheRoot,
            includingPropertiesForKeys: Array(keys),
            options: []
        ) else { return 0 }

        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: keys), values.isRegularFile == true else {
                continue
            }
            total += Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
        }
        return total
    }

    public func clear() throws {
        try validateRoot()

        let manager = FileManager.default
        guard manager.fileExists(atPath: cacheRoot.path) else {
            try manager.createDirectory(at: cacheRoot, withIntermediateDirectories: true)
            return
        }

        for item in try manager.contentsOfDirectory(
            at: cacheRoot,
            includingPropertiesForKeys: nil,
            options: []
        ) {
            try manager.removeItem(at: item)
        }
    }

    public func validateRoot() throws {
        guard Self.isDescendant(cacheRoot, of: allowedParent), cacheRoot != allowedParent else {
            throw SafeCacheError.unsafePath
        }
        // A lexical prefix alone permits Cache (or one of its parents) to be
        // a symlink into another folder. Never traverse such a link to delete.
        var current = cacheRoot
        while current.path != allowedParent.path {
            guard current.path != "/" else { throw SafeCacheError.unsafePath }
            if (try? FileManager.default.destinationOfSymbolicLink(atPath: current.path)) != nil {
                throw SafeCacheError.unsafePath
            }
            current.deleteLastPathComponent()
        }
    }

    public static func isDescendant(_ candidate: URL, of parent: URL) -> Bool {
        let candidatePath = candidate.standardizedFileURL.path
        let parentPath = parent.standardizedFileURL.path
        return candidatePath.hasPrefix(parentPath.hasSuffix("/") ? parentPath : parentPath + "/")
    }
}
