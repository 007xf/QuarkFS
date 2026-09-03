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
        case .zeroResidual: "视频块不写入磁盘，使用 256 MB 内存预读"
        case .balanced: "最多约 5 GB 磁盘缓存，使用 512 MB 内存预读"
        case .performance: "最多约 20 GB 磁盘缓存，使用 1 GB 内存预读"
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

    public init(
        mountPath: String = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Quark", isDirectory: true).path,
        profile: CacheProfile = .zeroResidual,
        autoCleanup: Bool = true,
        cleanupDelaySeconds: Int = 60,
        openFinderAfterMount: Bool = true
    ) {
        self.mountPath = mountPath
        self.profile = profile
        self.autoCleanup = autoCleanup
        self.cleanupDelaySeconds = cleanupDelaySeconds
        self.openFinderAfterMount = openFinderAfterMount
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
        try manager.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
        try manager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        try manager.createDirectory(at: mountCacheDirectory, withIntermediateDirectories: true)
        try manager.createDirectory(at: infuseCacheDirectory, withIntermediateDirectories: true)
        try manager.createDirectory(at: runtimeDirectory, withIntermediateDirectories: true)
    }
}
