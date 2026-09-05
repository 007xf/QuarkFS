import Foundation

public enum MountDirectoryError: LocalizedError {
    case outsideHome
    case appData
    case notEmpty
    case notDirectory

    public var errorDescription: String? {
        switch self {
        case .outsideHome: "请选择个人文件夹内的挂载目录，不能使用个人文件夹本身"
        case .appData: "挂载目录不能覆盖 QuarkFS 的缓存或运行配置目录"
        case .notEmpty: "挂载目录包含文件，请选择空文件夹，避免遮挡已有文件"
        case .notDirectory: "挂载位置必须是文件夹"
        }
    }
}

public enum MountDirectory {
    public static func validate(
        path: String,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        supportDirectory: URL
    ) throws -> URL {
        let url = try resolveExistingParents(URL(fileURLWithPath: (path as NSString).expandingTildeInPath))
        let home = home.standardizedFileURL.resolvingSymlinksInPath()
        let support = supportDirectory.standardizedFileURL.resolvingSymlinksInPath()
        guard (path as NSString).expandingTildeInPath.hasPrefix("/"),
              SafeCacheManager.isDescendant(url, of: home) else {
            throw MountDirectoryError.outsideHome
        }
        guard url != support,
              !SafeCacheManager.isDescendant(url, of: support),
              !SafeCacheManager.isDescendant(support, of: url) else {
            throw MountDirectoryError.appData
        }
        var directory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &directory) {
            guard directory.boolValue else { throw MountDirectoryError.notDirectory }
            guard try FileManager.default.contentsOfDirectory(atPath: url.path).isEmpty else {
                throw MountDirectoryError.notEmpty
            }
        }
        return url
    }

    // resolvingSymlinksInPath alone may leave a path unchanged when its final
    // folder does not exist yet. Resolve the existing ancestor first.
    private static func resolveExistingParents(_ path: URL) throws -> URL {
        var existing = path.standardizedFileURL
        var missing: [String] = []
        while !FileManager.default.fileExists(atPath: existing.path), existing.path != "/" {
            guard (try? FileManager.default.destinationOfSymbolicLink(atPath: existing.path)) == nil else {
                throw MountDirectoryError.outsideHome
            }
            missing.append(existing.lastPathComponent)
            existing.deleteLastPathComponent()
        }
        return missing.reversed().reduce(existing.resolvingSymlinksInPath()) {
            $0.appendingPathComponent($1)
        }.standardizedFileURL
    }
}
