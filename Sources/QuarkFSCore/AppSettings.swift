import Foundation

public enum CacheProfile: String, Codable, CaseIterable, Identifiable, Sendable {
    case zeroResidual
    case balanced
    case performance

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .zeroResidual: "零残留"
        case .balanced: "平衡"
        case .performance: "高性能"
        }
    }

    public var summary: String {
        switch self {
        case .zeroResidual: "视频块不写入磁盘，每个打开文件使用 256 MB 内存预读"
        case .balanced: "每条连接约 5 GB 磁盘缓存，每个打开文件使用 512 MB 内存预读"
        case .performance: "每条连接约 20 GB 磁盘缓存，每个打开文件使用 1 GB 内存预读"
        }
    }

    public var bufferSize: String {
        switch self {
        case .zeroResidual: "256M"
        case .balanced: "512M"
        case .performance: "1G"
        }
    }

    public var vfsCacheMode: String {
        switch self {
        case .zeroResidual: "off"
        case .balanced, .performance: "full"
        }
    }

    public var diskCacheLimit: String? {
        switch self {
        case .zeroResidual: nil
        case .balanced: "5G"
        case .performance: "20G"
        }
    }
}

public struct AppSettings: Codable, Equatable, Sendable {
    public var mountPath: String
    public var profile: CacheProfile
    public var autoCleanup: Bool
    public var cleanupDelaySeconds: Int
    public var openFinderAfterMount: Bool
    public var infusePort: Int

    public init(
        mountPath: String = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Quark", isDirectory: true).path,
        profile: CacheProfile = .zeroResidual,
        autoCleanup: Bool = true,
        cleanupDelaySeconds: Int = 60,
        openFinderAfterMount: Bool = true,
        infusePort: Int = 8686
    ) {
        self.mountPath = mountPath
        self.profile = profile
        self.autoCleanup = autoCleanup
        self.cleanupDelaySeconds = cleanupDelaySeconds
        self.openFinderAfterMount = openFinderAfterMount
        self.infusePort = (1024...65535).contains(infusePort) ? infusePort : 8686
    }

    private enum CodingKeys: String, CodingKey {
        case mountPath, profile, autoCleanup, cleanupDelaySeconds, openFinderAfterMount, infusePort
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = AppSettings()
        self.init(
            mountPath: try values.decodeIfPresent(String.self, forKey: .mountPath) ?? defaults.mountPath,
            profile: try values.decodeIfPresent(CacheProfile.self, forKey: .profile) ?? defaults.profile,
            autoCleanup: try values.decodeIfPresent(Bool.self, forKey: .autoCleanup) ?? defaults.autoCleanup,
            cleanupDelaySeconds: min(600, max(15, try values.decodeIfPresent(Int.self, forKey: .cleanupDelaySeconds) ?? 60)),
            openFinderAfterMount: try values.decodeIfPresent(Bool.self, forKey: .openFinderAfterMount) ?? true,
            infusePort: try values.decodeIfPresent(Int.self, forKey: .infusePort) ?? 8686
        )
    }
}

public struct AppPaths: Sendable {
    public let supportDirectory: URL
    public let cacheDirectory: URL
    public let mountCacheDirectory: URL
    public let infuseCacheDirectory: URL
    public let runtimeDirectory: URL
    public let runtimeConfig: URL
    public let logFile: URL

    public init(baseDirectory: URL? = nil) {
        let base = baseDirectory ?? FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!.appendingPathComponent("com.holmes.QuarkFS", isDirectory: true)

        supportDirectory = base
        cacheDirectory = base.appendingPathComponent("Cache", isDirectory: true)
        mountCacheDirectory = cacheDirectory.appendingPathComponent("Mount", isDirectory: true)
        infuseCacheDirectory = cacheDirectory.appendingPathComponent("Infuse", isDirectory: true)
        runtimeDirectory = base.appendingPathComponent("Runtime", isDirectory: true)
        runtimeConfig = runtimeDirectory.appendingPathComponent("rclone.conf")
        logFile = base.appendingPathComponent("QuarkFS.log")
    }

    public func prepare() throws {
        let manager = FileManager.default
        guard (try? manager.destinationOfSymbolicLink(atPath: supportDirectory.path)) == nil else {
            throw SafeCacheError.unsafePath
        }
        for directory in [cacheDirectory, mountCacheDirectory, infuseCacheDirectory, runtimeDirectory] {
            try SafeCacheManager(cacheRoot: directory, allowedParent: supportDirectory).validateRoot()
        }
        try manager.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
        try manager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        try manager.createDirectory(at: mountCacheDirectory, withIntermediateDirectories: true)
        try manager.createDirectory(at: infuseCacheDirectory, withIntermediateDirectories: true)
        try manager.createDirectory(at: runtimeDirectory, withIntermediateDirectories: true)
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: supportDirectory.path)
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: runtimeDirectory.path)
    }
}
