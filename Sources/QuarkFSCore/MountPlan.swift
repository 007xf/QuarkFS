import Foundation

public struct MountPlan: Equatable, Sendable {
    public let command: String
    public let arguments: [String]

    public init(command: String, arguments: [String]) {
        self.command = command
        self.arguments = arguments
    }
}

public enum MountPlanBuilder {
    public static func make(
        settings: AppSettings,
        paths: AppPaths,
        command: String = "cmount"
    ) -> MountPlan {
        var arguments = [
            "quark:",
            settings.mountPath,
            "--config", paths.runtimeConfig.path,
            "--read-only",
            "--volname", "Quark",
            "--cache-dir", paths.mountCacheDirectory.path,
            "--vfs-cache-mode", settings.profile.vfsCacheMode,
            "--buffer-size", settings.profile.bufferSize,
            "--dir-cache-time", "10m",
            "--poll-interval", "0",
            "--vfs-read-chunk-size", "64M",
            "--vfs-read-chunk-size-limit", "512M",
            "--log-file", paths.logFile.path,
            "--log-level", "INFO"
        ]

        if let limit = settings.profile.diskCacheLimit {
            arguments.append(contentsOf: [
                "--vfs-cache-max-size", limit,
                "--vfs-cache-poll-interval", "15s",
                "--vfs-cache-max-age",
                settings.autoCleanup ? "\(max(15, settings.cleanupDelaySeconds))s" : "24h"
            ])
        }

        return MountPlan(command: command, arguments: arguments)
    }
}

public enum InfusePlanBuilder {
    public static func make(settings: AppSettings, paths: AppPaths) -> [String] {
        var arguments = [
            "--config", paths.runtimeConfig.path,
            "serve", "webdav", "quark:",
            "--addr", "127.0.0.1:8686",
            "--read-only",
            "--cache-dir", paths.infuseCacheDirectory.path,
            "--vfs-cache-mode", settings.profile.vfsCacheMode,
            "--buffer-size", settings.profile.bufferSize,
            "--log-file", paths.supportDirectory.appendingPathComponent("Infuse-WebDAV.log").path,
            "--log-level", "INFO"
        ]

        if let limit = settings.profile.diskCacheLimit {
            arguments.append(contentsOf: [
                "--vfs-cache-max-size", limit,
                "--vfs-cache-poll-interval", "15s",
                "--vfs-cache-max-age",
                settings.autoCleanup ? "\(max(15, settings.cleanupDelaySeconds))s" : "24h"
            ])
        }

        return arguments
    }
}
