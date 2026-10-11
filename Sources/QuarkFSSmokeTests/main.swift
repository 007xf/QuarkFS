import Darwin
import Foundation
import QuarkFSCore

private func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
        exit(1)
    }
}

let temporaryRoot = FileManager.default.temporaryDirectory
    .appendingPathComponent("QuarkFS-Smoke-\(UUID().uuidString)", isDirectory: true)
defer { try? FileManager.default.removeItem(at: temporaryRoot) }

let paths = AppPaths(baseDirectory: temporaryRoot)
try paths.prepare()

let zeroSettings = AppSettings(
    mountPath: temporaryRoot.appendingPathComponent("Mount").path,
    profile: .zeroResidual,
    autoCleanup: true
)
let zeroPlan = MountPlanBuilder.make(settings: zeroSettings, paths: paths)
check(zeroPlan.command == "cmount", "默认挂载命令应为 cmount")
check(zeroPlan.arguments.contains("off"), "零残留模式必须关闭磁盘视频缓存")
check(!zeroPlan.arguments.contains("--vfs-cache-max-size"), "零残留模式不应配置磁盘缓存上限")
check(zeroPlan.arguments.contains("--read-only"), "挂载必须只读")
check(zeroPlan.arguments.contains(paths.mountCacheDirectory.path), "磁盘挂载必须使用独立缓存目录")

let zeroInfusePlan = InfusePlanBuilder.make(settings: zeroSettings, paths: paths)
check(zeroInfusePlan.contains("off"), "Infuse 零残留模式必须关闭磁盘视频缓存")
check(!zeroInfusePlan.contains("--vfs-cache-max-size"), "Infuse 零残留模式不应配置磁盘缓存上限")
check(zeroInfusePlan.contains(paths.infuseCacheDirectory.path), "Infuse 必须使用独立缓存目录")

let balancedSettings = AppSettings(
    mountPath: temporaryRoot.appendingPathComponent("Mount").path,
    profile: .balanced,
    autoCleanup: true,
    cleanupDelaySeconds: 60
)
let balancedPlan = MountPlanBuilder.make(settings: balancedSettings, paths: paths)
let sizeIndex = balancedPlan.arguments.firstIndex(of: "--vfs-cache-max-size")
let ageIndex = balancedPlan.arguments.firstIndex(of: "--vfs-cache-max-age")
check(sizeIndex != nil && balancedPlan.arguments[sizeIndex! + 1] == "5G", "平衡模式应使用 5 GB 上限")
check(ageIndex != nil && balancedPlan.arguments[ageIndex! + 1] == "60s", "平衡模式应在 60 秒后清理")

let balancedInfusePlan = InfusePlanBuilder.make(settings: balancedSettings, paths: paths)
let infuseSizeIndex = balancedInfusePlan.firstIndex(of: "--vfs-cache-max-size")
let infuseAgeIndex = balancedInfusePlan.firstIndex(of: "--vfs-cache-max-age")
check(infuseSizeIndex != nil && balancedInfusePlan[infuseSizeIndex! + 1] == "5G", "Infuse 平衡模式应使用 5 GB 上限")
check(infuseAgeIndex != nil && balancedInfusePlan[infuseAgeIndex! + 1] == "60s", "Infuse 平衡模式应在 60 秒后清理")

let cacheFile = paths.cacheDirectory.appendingPathComponent("sample.bin")
try Data(repeating: 0x41, count: 4096).write(to: cacheFile)
let cacheManager = SafeCacheManager(cacheRoot: paths.cacheDirectory, allowedParent: paths.supportDirectory)
check(cacheManager.allocatedBytes() > 0, "缓存占用应可统计")
try cacheManager.clear()
let remainingCacheItems = try FileManager.default.contentsOfDirectory(atPath: paths.cacheDirectory.path)
check(remainingCacheItems.isEmpty, "缓存目录应被清空")
check(!SafeCacheManager.isDescendant(temporaryRoot, of: temporaryRoot), "不允许清理父目录本身")
check(
    !SafeCacheManager.isDescendant(
        URL(fileURLWithPath: temporaryRoot.path + "-Other"),
        of: temporaryRoot
    ),
    "不允许清理相邻目录"
)

let mountSample = "quark{example}: on \(zeroSettings.mountPath) (macfuse, nodev, nosuid, read-only)"
check(
    MountDetector.isMounted(output: mountSample, path: zeroSettings.mountPath),
    "应能识别已经存在的 Quark 挂载"
)
check(
    !MountDetector.isMounted(output: mountSample, path: temporaryRoot.appendingPathComponent("Other").path),
    "不应把其他挂载点误判为 Quark"
)
check(
    !MountDetector.isMounted(output: mountSample, path: zeroSettings.mountPath + "2"),
    "不应把相似前缀目录误判为 Quark"
)

// Diagnose the current attempt only: historical EBUSY must not contaminate
// an unrelated new failure, and a remote "busy" response is not a FUSE error.
let diagnosticLog = paths.supportDirectory.appendingPathComponent("Diagnostic-test.log")
let busyError = "mount_macfuse: mount failed /Users/test/Quark@/dev/macfuse1: Resource busy\n"
try Data(busyError.utf8).write(to: diagnosticLog)
let diagnostic = MountAttemptDiagnostics(logFile: diagnosticLog)
check(!MountAttemptDiagnostics.isBusyFailure(output: diagnostic.text), "不能把历史挂载忙碌日志用于当前失败")
let diagnosticWriter = try FileHandle(forWritingTo: diagnosticLog)
try diagnosticWriter.seekToEnd()
try diagnosticWriter.write(contentsOf: Data("CRITICAL: mountpoint is not empty\n".utf8))
try diagnosticWriter.close()
check(MountAttemptDiagnostics.failureMessage(status: 1, output: diagnostic.text).contains("包含文件"), "必须读取当前尝试新增的日志")
diagnostic.append(Data(busyError.utf8))
check(MountAttemptDiagnostics.isBusyFailure(output: diagnostic.text), "必须识别 stderr 中的 macFUSE EBUSY")
check(!MountAttemptDiagnostics.isBusyFailure(output: "quark API: Resource busy"), "远端忙碌不能触发本机挂载重试")
check(MountAttemptDiagnostics.failureMessage(status: 7, output: "").contains("代码 7"), "未知错误必须保留退出码")

let spacedPath = temporaryRoot.appendingPathComponent("Quark Drive").path
let escapedMountSample = "quark{example}: on \(spacedPath.replacingOccurrences(of: " ", with: "\\040")) (macfuse, read-only)"
check(
    MountDetector.isMounted(output: escapedMountSample, path: spacedPath),
    "应能识别 mount 输出中的转义空格"
)

let smbSample = "//server/share on \(zeroSettings.mountPath) (smbfs, nodev, nosuid)"
check(
    MountDetector.presence(output: smbSample, path: zeroSettings.mountPath) == .conflict,
    "同一路径的其他文件系统必须报告冲突"
)
let unrelatedFuseSample = "other: on \(zeroSettings.mountPath) (macfuse, nodev, nosuid)"
check(
    MountDetector.presence(output: unrelatedFuseSample, path: zeroSettings.mountPath) == .conflict,
    "同一路径的其他 macFUSE 磁盘不能被当作 Quark"
)
check(
    EngineLocator.macFUSEIsLoaded(
        kmutilOutput: "io.macfuse.filesystems.macfuse.25 (5.3.3)",
        mountOutput: ""
    ),
    "应能识别已加载的 macFUSE 内核扩展"
)
check(
    !EngineLocator.macFUSEIsLoaded(kmutilOutput: "", mountOutput: ""),
    "未加载 macFUSE 时不应报告就绪"
)

// Large writes to both pipes must finish without waiting for a full pipe.
let noisy = try ProcessRunner.run(
    executable: URL(fileURLWithPath: "/bin/zsh"),
    arguments: ["-c", "for i in {1..6000}; do print 'abcdefghijklmnopqrstuvwxyz0123456789'; print -u2 'abcdefghijklmnopqrstuvwxyz0123456789'; done"],
    timeout: 10
)
check(noisy.status == 0 && noisy.standardOutput.utf8.count > 200_000 && noisy.standardError.utf8.count > 200_000,
      "大量标准输出和错误输出不能让进程死锁")
let echoInput = Data(repeating: 0x41, count: 200_000)
let echoed = try ProcessRunner.run(executable: URL(fileURLWithPath: "/bin/cat"), arguments: [], input: echoInput)
check(Data(echoed.standardOutput.utf8) == echoInput, "子进程输入与输出必须可同时排空")
let started = Date()
do {
    _ = try ProcessRunner.run(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["20"], timeout: 0.1)
    check(false, "无响应命令必须超时")
} catch ProcessRunnerError.timedOut {}
check(Date().timeIntervalSince(started) < 4, "超时不能无限等待子进程")

let outside = temporaryRoot.appendingPathComponent("Outside")
try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
let sentinel = outside.appendingPathComponent("keep.txt")
try Data("keep".utf8).write(to: sentinel)
let linkedCache = temporaryRoot.appendingPathComponent("LinkedCache")
try FileManager.default.createSymbolicLink(at: linkedCache, withDestinationURL: outside)
for root in [linkedCache, linkedCache.appendingPathComponent("Child")] {
    do {
        try SafeCacheManager(cacheRoot: root, allowedParent: temporaryRoot).clear()
        check(false, "缓存根目录及祖先链接必须拒绝清理")
    } catch SafeCacheError.unsafePath {}
}
check(FileManager.default.fileExists(atPath: sentinel.path), "符号链接不能导致外部文件被删除")
let externalCache = outside.appendingPathComponent("Cache")
try FileManager.default.createDirectory(at: externalCache, withIntermediateDirectories: true)
let externalCacheSentinel = externalCache.appendingPathComponent("keep.txt")
try Data("keep external cache".utf8).write(to: externalCacheSentinel)
let linkedSupport = temporaryRoot.appendingPathComponent("LinkedSupport")
try AppPaths(baseDirectory: linkedSupport).prepare()
let parentLinkedManager = SafeCacheManager(
    cacheRoot: linkedSupport.appendingPathComponent("Cache"), allowedParent: linkedSupport
)
try parentLinkedManager.validateRoot()
try FileManager.default.removeItem(at: linkedSupport)
try FileManager.default.createSymbolicLink(at: linkedSupport, withDestinationURL: outside)
do {
    try parentLinkedManager.clear()
    check(false, "应用数据父目录为链接时也必须拒绝清理")
} catch SafeCacheError.unsafePath {}
let preservedExternalCache = try Data(contentsOf: externalCacheSentinel)
check(preservedExternalCache == Data("keep external cache".utf8),
      "应用数据父目录的链接不能导致外部缓存文件被删除")
check(parentLinkedManager.allocatedBytes() == 0, "缓存统计不得通过应用数据父目录的链接读取外部目录")
let nestedLink = paths.cacheDirectory.appendingPathComponent("ExternalLink")
try FileManager.default.createSymbolicLink(at: nestedLink, withDestinationURL: outside)
try cacheManager.clear()
check(FileManager.default.fileExists(atPath: sentinel.path), "缓存内链接只能删除链接本身")
try SafeCacheManager(cacheRoot: paths.cacheDirectory, allowedParent: URL(fileURLWithPath: temporaryRoot.path, isDirectory: false)).validateRoot()
let hiddenCache = paths.cacheDirectory.appendingPathComponent(".hidden.bin")
try Data(repeating: 0x42, count: 8192).write(to: hiddenCache)
check(cacheManager.allocatedBytes() > 0, "隐藏文件也应计入磁盘缓存")

let sandboxHome = temporaryRoot.appendingPathComponent("Home")
let support = sandboxHome.appendingPathComponent("Library/Application Support/QuarkFS")
try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
let newMount = sandboxHome.appendingPathComponent("New Mount")
_ = try MountDirectory.validate(path: newMount.path, home: sandboxHome, supportDirectory: support)
check(!FileManager.default.fileExists(atPath: newMount.path), "检查挂载路径不得创建目录")
for badPath in [sandboxHome.path, outside.path, support.path, sandboxHome.appendingPathComponent("Library").path] {
    do {
        _ = try MountDirectory.validate(path: badPath, home: sandboxHome, supportDirectory: support)
        check(false, "不能覆盖个人目录、外部目录或应用数据")
    } catch is MountDirectoryError {}
}
let nonempty = sandboxHome.appendingPathComponent("Documents")
try FileManager.default.createDirectory(at: nonempty, withIntermediateDirectories: true)
try Data("keep".utf8).write(to: nonempty.appendingPathComponent("existing.txt"))
do {
    _ = try MountDirectory.validate(path: nonempty.path, home: sandboxHome, supportDirectory: support)
    check(false, "不能挂载到包含文件的目录")
} catch MountDirectoryError.notEmpty {}
let escape = sandboxHome.appendingPathComponent("Escape")
try FileManager.default.createSymbolicLink(at: escape, withDestinationURL: outside)
do {
    _ = try MountDirectory.validate(path: escape.appendingPathComponent("Mount").path, home: sandboxHome, supportDirectory: support)
    check(false, "挂载路径不能通过符号链接越过个人目录")
} catch MountDirectoryError.outsideHome {}
let dangling = sandboxHome.appendingPathComponent("Dangling")
try FileManager.default.createSymbolicLink(at: dangling, withDestinationURL: outside.appendingPathComponent("Missing"))
do {
    _ = try MountDirectory.validate(path: dangling.appendingPathComponent("Mount").path, home: sandboxHome, supportDirectory: support)
    check(false, "不存在目标的符号链接也必须拒绝")
} catch MountDirectoryError.outsideHome {}

let oldSettings = Data("{\"mountPath\":\"/Users/example/Quark\",\"profile\":\"balanced\",\"autoCleanup\":false,\"cleanupDelaySeconds\":120,\"openFinderAfterMount\":false}".utf8)
let migrated = try JSONDecoder().decode(AppSettings.self, from: oldSettings)
check(migrated.infusePort == 8686 && migrated.profile == .balanced && !migrated.autoCleanup,
      "升级旧设置必须保留缓存偏好并补充默认端口")
let custom = AppSettings(infusePort: 9999)
check(InfusePlanBuilder.make(settings: custom, paths: paths).contains("127.0.0.1:9999"), "自定义端口必须始终绑定回环地址")
let roundtrip = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(custom))
check(roundtrip == custom, "自定义连接设置应可持久化")
check(AppSettings(infusePort: 0).infusePort == 8686, "无效端口不能传入引擎")

let validDAV = Data("<D:multistatus xmlns:D=\"DAV:\"><D:response><D:propstat><D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response></D:multistatus>".utf8)
check(WebDAVHealth.evaluate(status: 207, data: validDAV) == .ready, "成功的 WebDAV 目录响应应通过检查")
check(WebDAVHealth.evaluate(status: 200, data: Data("<html>other server</html>".utf8)) != .ready, "其他 HTTP 服务不能被误报为 Infuse 已就绪")
check(WebDAVHealth.evaluate(status: 207, data: Data("error".utf8)) != .ready, "无效的目录响应不能报就绪")
check(WebDAVHealth.evaluate(status: 403, data: Data()) != .ready, "账号认证失败不能报就绪")
let failedDAV = Data("<D:multistatus xmlns:D=\"DAV:\"><D:response><D:propstat><D:prop><D:displayname>200 OK.mkv</D:displayname></D:prop><D:status>HTTP/1.1 403 Forbidden</D:status></D:propstat></D:response></D:multistatus>".utf8)
check(WebDAVHealth.evaluate(status: 207, data: failedDAV) != .ready,
      "文件名中的成功文本不能覆盖 WebDAV 属性读取失败")
let truncatedDAV = validDAV.dropLast(10)
check(WebDAVHealth.evaluate(status: 207, data: Data(truncatedDAV)) != .ready,
      "未完整接收的 WebDAV XML 不能报就绪")
let unrelatedXML = Data("<multistatus><response><propstat><status>HTTP/1.1 200 OK</status></propstat></response></multistatus>".utf8)
check(WebDAVHealth.evaluate(status: 207, data: unrelatedXML) != .ready,
      "没有 DAV 命名空间的 XML 不能被误报为 WebDAV")
let defaultNamespaceDAV = Data("<multistatus xmlns=\"DAV:\"><response><propstat><status>HTTP/1.1 200 Success</status></propstat></response></multistatus>".utf8)
check(WebDAVHealth.evaluate(status: 207, data: defaultNamespaceDAV) == .ready,
      "DAV 默认命名空间及合法的成功原因短语应通过检查")

let loginConfiguration = URLSessionConfiguration.ephemeral
loginConfiguration.protocolClasses = [LoginFailureProtocol.self]
let loginClient = QuarkLoginClient(configuration: loginConfiguration)
do {
    _ = try await loginClient.finish(serviceTicket: "test-only")
    check(false, "网盘返回业务错误时不能把扫码登录报告为成功")
} catch QuarkLoginError.provider(let status, _) {
    check(status == 31001, "登录失败应保留业务错误码")
}

let zeroStatusConfiguration = URLSessionConfiguration.ephemeral
zeroStatusConfiguration.protocolClasses = [LoginZeroStatusProtocol.self]
do {
    _ = try await QuarkLoginClient(configuration: zeroStatusConfiguration).finish(serviceTicket: "test-only")
    check(false, "没有 Cookie 时不能完成登录")
} catch QuarkLoginError.missingCookie {
    // The upstream API also accepts status 0. It must reach the cookie check.
}

print("PASS: QuarkFS 核心回归测试全部通过（挂载、缓存边界、进程、登录、设置迁移、WebDAV）")
