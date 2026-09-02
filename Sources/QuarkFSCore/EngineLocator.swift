import Foundation

public struct EngineInspection: Equatable, Sendable {
    public let path: String?
    public let isQuarkCapable: Bool
    public let mountCommand: String?
    public let version: String?
    public let problem: String?

    public init(
        path: String?,
        isQuarkCapable: Bool,
        mountCommand: String?,
        version: String?,
        problem: String?
    ) {
        self.path = path
        self.isQuarkCapable = isQuarkCapable
        self.mountCommand = mountCommand
        self.version = version
        self.problem = problem
    }
}

public enum EngineLocator {
    public static func candidates(
        bundleResourceURL: URL? = Bundle.main.resourceURL,
        currentDirectory: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [URL] {
        var urls: [URL] = []
        if let override = environment["QUARKFS_ENGINE_PATH"], !override.isEmpty {
            urls.append(URL(fileURLWithPath: override))
        }
        if let bundleResourceURL {
            urls.append(bundleResourceURL.appendingPathComponent("Engine/rclone"))
        }
        urls.append(currentDirectory.appendingPathComponent(".build/engine/rclone"))
        urls.append(URL(fileURLWithPath: "/opt/homebrew/bin/rclone"))
        urls.append(URL(fileURLWithPath: "/usr/local/bin/rclone"))
        return urls
    }

    public static func locate(candidates: [URL]? = nil) -> URL? {
        let manager = FileManager.default
        return (candidates ?? self.candidates()).first {
            manager.isExecutableFile(atPath: $0.path)
        }
    }

    public static func inspect(_ executable: URL?) -> EngineInspection {
        guard let executable else {
            return EngineInspection(
                path: nil,
                isQuarkCapable: false,
                mountCommand: nil,
                version: nil,
                problem: "尚未找到 QuarkFS 文件系统引擎"
            )
        }

        do {
            let versionResult = try ProcessRunner.run(executable: executable, arguments: ["version"])
            let backendResult = try ProcessRunner.run(executable: executable, arguments: ["help", "backends"])
            let backendText = backendResult.standardOutput + backendResult.standardError
            let quarkCapable = backendResult.status == 0 && backendText.localizedCaseInsensitiveContains("quark")
            let cmountResult = try ProcessRunner.run(executable: executable, arguments: ["cmount", "--help"])
            let nfsmountResult = try ProcessRunner.run(executable: executable, arguments: ["nfsmount", "--help"])
            let mountCommand: String? = cmountResult.status == 0
                ? "cmount"
                : (nfsmountResult.status == 0 ? "nfsmount" : nil)

            let firstVersionLine = versionResult.standardOutput
                .split(whereSeparator: \.isNewline)
                .first.map(String.init)

            return EngineInspection(
                path: executable.path,
                isQuarkCapable: quarkCapable,
                mountCommand: mountCommand,
                version: firstVersionLine,
                problem: quarkCapable ? nil : "当前 rclone 不包含 Quark Drive 后端"
            )
        } catch {
            return EngineInspection(
                path: executable.path,
                isQuarkCapable: false,
                mountCommand: nil,
                version: nil,
                problem: error.localizedDescription
            )
        }
    }

    public static var isMacFUSEInstalled: Bool {
        FileManager.default.fileExists(atPath: "/Library/Filesystems/macfuse.fs")
    }
}
