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

func value(after flag: String, in arguments: [String]) -> String? {
    guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
    return arguments[index + 1]
}

func enginePlans(_ settings: AppSettings) -> [(name: String, arguments: [String])] {
    [("磁盘挂载", MountPlanBuilder.make(settings: settings, paths: paths).arguments),
     ("Infuse", InfusePlanBuilder.make(settings: settings, paths: paths))]
}

// Every profile and cleanup choice must reach both engines as exact options:
// a missing size limit or a wrong buffer silently changes disk and memory use.
let expectedProfiles: [(profile: CacheProfile, mode: String, buffer: String, limit: String?)] = [
    (.zeroResidual, "off", "256M", nil),
    (.balanced, "full", "512M", "5G"),
    (.performance, "full", "1G", "20G")
]
check(expectedProfiles.map(\.profile) == CacheProfile.allCases, "每个缓存策略都必须有参数检查")
for expected in expectedProfiles {
    for autoCleanup in [true, false] {
        let settings = AppSettings(
            mountPath: temporaryRoot.appendingPathComponent("Mount").path,
            profile: expected.profile,
            autoCleanup: autoCleanup,
            cleanupDelaySeconds: 90
        )
        for plan in enginePlans(settings) {
            let label = "\(plan.name) \(expected.profile.title) 自动清理=\(autoCleanup)"
            let arguments = plan.arguments
            check(value(after: "--vfs-cache-mode", in: arguments) == expected.mode, "\(label) 缓存模式应为 \(expected.mode)")
            check(value(after: "--buffer-size", in: arguments) == expected.buffer, "\(label) 内存预读应为 \(expected.buffer)")
            check(value(after: "--vfs-cache-max-size", in: arguments) == expected.limit, "\(label) 磁盘缓存上限不正确")
            check(value(after: "--vfs-cache-poll-interval", in: arguments) == expected.limit.map { _ in "15s" },
                  "\(label) 缓存清理检查间隔不正确")
            let expectedAge = expected.limit.map { _ in autoCleanup ? "90s" : "24h" }
            check(value(after: "--vfs-cache-max-age", in: arguments) == expectedAge, "\(label) 缓存保留时间不正确")
            check(arguments.filter { $0 == "--vfs-cache-max-size" }.count <= 1, "\(label) 不能重复传入缓存上限")
        }
    }
}

// Engine logs live in Application Support across sessions. They must rotate
// and must not record the cache cleaner's routine INFO line every 15 seconds.
for plan in enginePlans(balancedSettings) {
    check(value(after: "--log-level", in: plan.arguments) == "NOTICE", "\(plan.name) 引擎日志不应记录例行 INFO 信息")
    check(value(after: "--log-file-max-size", in: plan.arguments) == "10M", "\(plan.name) 引擎日志必须限制单个文件大小")
    check(value(after: "--log-file-max-backups", in: plan.arguments) == "1", "\(plan.name) 引擎日志只保留一个轮换备份")
}

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
// Quark rejects an expired session with HTTP 401 / code 31001 "require login";
// the engine never prints the words "cookie expired".
let expiredSession = "2026/11/09 10:00:00 CRITICAL: Failed to create file system: quark HTTP error: http_status=401 status=401 code=31001 message=\"require login [guest]\""
check(MountAttemptDiagnostics.failureMessage(status: 1, output: expiredSession).contains("重新登录"),
      "夸克登录失效必须提示重新登录")

// Read failures that only reach the engine log must be recognised and named.
let sizeLimitLine = "2026/09/02 22:39:19 ERROR : Movies/4K Film.mkv: vfs cache: failed to download: quark HTTP error: http_status=400 status=400 code=23018 message=\"download file size limit[1]\""
check(EngineIssue.classify(sizeLimitLine) == .downloadSizeLimit(file: "4K Film.mkv"), "必须识别夸克下载大小限制（23018）及文件名")
check(EngineIssue.classify(sizeLimitLine)?.message.contains("23018") == true, "大小限制提示必须包含错误代码")
check(EngineIssue.classify(expiredSession) == .loginExpired, "必须识别夸克登录失效")
check(EngineIssue.classify("2026/09/02 22:39:20 ERROR : Movies/clip.webm: vfs cache: too many errors 11/10: last error: EOF")
      == .repeatedReadFailures(file: "clip.webm"), "必须识别连续读取失败")
check(EngineIssue.classify("2026/09/02 22:39:21 ERROR : Failed to webdav with 232 errors: last error was: x") == nil,
      "没有已知原因的汇总错误不能误报")
check(EngineIssue.classify("2026/09/02 22:39:21 INFO  : vfs cache: cleaned: objects 1 (was 1)") == nil, "例行日志不能误报")

let engineLog = paths.supportDirectory.appendingPathComponent("Engine-tail-test.log")
try Data((sizeLimitLine + "\n").utf8).write(to: engineLog)
let tail = EngineLogTail(url: engineLog)
check(tail.readNewLines().isEmpty, "不能报告引擎启动前的旧日志")
let tailWriter = try FileHandle(forWritingTo: engineLog)
try tailWriter.seekToEnd()
try tailWriter.write(contentsOf: Data("first new line\nincomplete".utf8))
check(tail.readNewLines() == ["first new line"], "必须只返回新增的完整日志行")
try tailWriter.write(contentsOf: Data(" line\n".utf8))
try tailWriter.close()
check(tail.readNewLines() == ["incomplete line"], "跨两次读取的日志行必须拼接完整")
try Data("rotated\n".utf8).write(to: engineLog)
check(tail.readNewLines() == ["rotated"], "日志轮换或截断后必须从头读取")

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

// Quark refuses large files to the web page (code 23018); the engine must
// identify as the PC client for the download link and the CDN transfer.
let quarkPCUserAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) quark-cloud-drive/2.5.20 Chrome/100.0.4896.160 Electron/18.3.5.4-b478491100 Safari/537.36 Channel/pckk_other_ch"
let runtimeConfigText = try RuntimeConfiguration.text(obscuredCookie: "obscured-value")
check(runtimeConfigText
      == "[quark]\ntype = quark\ncookie = obscured-value\nuser_agent = \(quarkPCUserAgent)\n",
      "运行配置必须包含 quark 远端、登录信息和夸克 PC 客户端标识")
check(RuntimeConfiguration.quarkClientUserAgent == quarkPCUserAgent, "夸克 PC 客户端标识必须与预期一致")
for invalid in ["", "line\nuser_agent = other", "with space"] {
    do {
        _ = try RuntimeConfiguration.text(obscuredCookie: invalid)
        check(false, "无效的登录信息不能写入运行配置")
    } catch {}
}
// The local WebDAV server requires a random per-install password that
// survives restarts, is readable only by the user, and never follows a link.
let firstSecret = try WebDAVCredentials.generate()
let secondSecret = try WebDAVCredentials.generate()
check(firstSecret.password != secondSecret.password && firstSecret.password.count >= 32,
      "本机连接密码必须随机生成且足够长")
check(firstSecret.password.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" },
      "本机连接密码只能使用可直接填写的字符")
check(firstSecret.engineEnvironment == ["RCLONE_USER": "quarkfs", "RCLONE_PASS": firstSecret.password],
      "本机连接凭据必须通过环境变量传给引擎")
check(WebDAVCredentials(username: "user", password: "pass").authorization == "Basic dXNlcjpwYXNz",
      "本机连接必须使用标准 Basic 认证")
let savedSecret = try WebDAVCredentials.loadOrCreate(at: paths.webDAVCredentials)
let reloadedSecret = try WebDAVCredentials.loadOrCreate(at: paths.webDAVCredentials)
check(reloadedSecret == savedSecret, "本机连接密码在重启后必须保持不变")
let secretMode = (try FileManager.default.attributesOfItem(atPath: paths.webDAVCredentials.path)[.posixPermissions] as? NSNumber)?.intValue
check(secretMode == 0o600, "本机连接密码只能由当前用户读取")
try Data("{\"username\":\"quarkfs\",\"password\":\"short\"}".utf8).write(to: paths.webDAVCredentials)
let regeneratedSecret = try WebDAVCredentials.loadOrCreate(at: paths.webDAVCredentials)
check(regeneratedSecret.password.count >= 32, "损坏或过短的本机连接密码必须重新生成")
let secretTarget = outside.appendingPathComponent("secret-target.json")
try Data("{\"username\":\"quarkfs\",\"password\":\"\(String(repeating: "a", count: 40))\"}".utf8).write(to: secretTarget)
try FileManager.default.removeItem(at: paths.webDAVCredentials)
try FileManager.default.createSymbolicLink(at: paths.webDAVCredentials, withDestinationURL: secretTarget)
let relinked = try WebDAVCredentials.loadOrCreate(at: paths.webDAVCredentials)
check(relinked.password != String(repeating: "a", count: 40), "本机连接密码不能通过符号链接读取")
check((try? FileManager.default.destinationOfSymbolicLink(atPath: paths.webDAVCredentials.path)) == nil,
      "符号链接必须被替换为普通文件")
let secretTargetText = try String(contentsOf: secretTarget, encoding: .utf8)
check(secretTargetText.contains(String(repeating: "a", count: 40)), "替换链接不能修改链接目标")

// A leftover engine from a crashed app is stopped only when the record still
// names the same process, launchd adopted it and its arguments are ours.
func orphanedSleep(_ seconds: String) throws -> Int32 {
    let result = try ProcessRunner.run(executable: URL(fileURLWithPath: "/bin/sh"),
                                       arguments: ["-c", "/bin/sleep \(seconds) >/dev/null 2>&1 & echo $!"])
    return Int32(result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)) ?? -1
}
func waitForExit(_ pid: Int32) async -> Bool {
    for _ in 0..<40 where kill(pid, 0) == 0 { try? await Task.sleep(for: .milliseconds(50)) }
    return kill(pid, 0) != 0
}
let recordURL = paths.webDAVEngineRecord
let orphan = try orphanedSleep("41")
defer { kill(orphan, SIGKILL) }
check(orphan > 0, "测试用遗留进程必须启动")
try EngineProcessRecord(runningProcess: orphan)!.save(to: recordURL)
let stoppedForeign = await EngineProcessRecord.stopOrphan(recordAt: recordURL, requiredArgument: "/other/rclone.conf")
check(!stoppedForeign && kill(orphan, 0) == 0, "参数不属于本应用的进程不能被停止")
check(!FileManager.default.fileExists(atPath: recordURL.path), "不匹配的进程记录必须删除")
let staleRecord = EngineProcessRecord(runningProcess: orphan)!
try Data(String(decoding: try JSONEncoder().encode(staleRecord), as: UTF8.self)
    .replacingOccurrences(of: "\"startSeconds\":\(staleRecord.startSeconds)", with: "\"startSeconds\":\(staleRecord.startSeconds - 1)").utf8)
    .write(to: recordURL)
let stoppedReused = await EngineProcessRecord.stopOrphan(recordAt: recordURL, requiredArgument: "41")
check(!stoppedReused && kill(orphan, 0) == 0, "进程号被复用时不能停止新进程")
let ownChild = Process()
ownChild.executableURL = URL(fileURLWithPath: "/bin/sleep")
ownChild.arguments = ["42"]
try ownChild.run()
defer { ownChild.terminate() }
try EngineProcessRecord(runningProcess: ownChild.processIdentifier)!.save(to: recordURL)
let stoppedOwned = await EngineProcessRecord.stopOrphan(recordAt: recordURL, requiredArgument: "42")
check(!stoppedOwned && ownChild.isRunning && FileManager.default.fileExists(atPath: recordURL.path),
      "仍属于运行中应用的引擎不能被停止")
try EngineProcessRecord(runningProcess: orphan)!.save(to: recordURL)
let stoppedOrphan = await EngineProcessRecord.stopOrphan(recordAt: recordURL, requiredArgument: "41")
let orphanExited = await waitForExit(orphan)
check(stoppedOrphan && orphanExited, "本应用遗留的引擎必须被停止")
check(!FileManager.default.fileExists(atPath: recordURL.path), "停止遗留引擎后必须删除记录")
let stoppedMissing = await EngineProcessRecord.stopOrphan(recordAt: recordURL, requiredArgument: "41")
check(!stoppedMissing, "没有记录时不能停止任何进程")

let configURL = paths.runtimeConfig
try RuntimeConfiguration.write(obscuredCookie: "obscured-value", to: configURL)
let configMode = (try FileManager.default.attributesOfItem(atPath: configURL.path)[.posixPermissions] as? NSNumber)?.intValue
check(configMode == 0o600, "运行配置只能由当前用户读取")
try RuntimeConfiguration.write(obscuredCookie: "second-obscured-value", to: configURL)
let overwrittenMode = (try FileManager.default.attributesOfItem(atPath: configURL.path)[.posixPermissions] as? NSNumber)?.intValue
let runtimeDirItems = try FileManager.default.contentsOfDirectory(atPath: paths.runtimeDirectory.path)
check(overwrittenMode == 0o600 && runtimeDirItems == ["rclone.conf"],
      "原子覆盖运行配置必须保持 0600 权限且不遗留临时文件")
// A planted symlink at rclone.conf must be replaced atomically, never followed.
let symlinkConfigTarget = outside.appendingPathComponent("runtime-config-target.txt")
try Data("keep-external-config".utf8).write(to: symlinkConfigTarget)
try FileManager.default.removeItem(at: configURL)
try FileManager.default.createSymbolicLink(at: configURL, withDestinationURL: symlinkConfigTarget)
try RuntimeConfiguration.write(obscuredCookie: "third-obscured-value", to: configURL)
let replacedMode = (try FileManager.default.attributesOfItem(atPath: configURL.path)[.posixPermissions] as? NSNumber)?.intValue
check((try? FileManager.default.destinationOfSymbolicLink(atPath: configURL.path)) == nil && replacedMode == 0o600,
      "预埋在 rclone.conf 的符号链接必须被 0600 普通文件安全替换")
let preservedTarget = try String(contentsOf: symlinkConfigTarget, encoding: .utf8)
check(preservedTarget == "keep-external-config",
      "写入运行配置不得沿着符号链接覆盖外部文件")
// Leftover temp files from a crash must be cleaned alongside rclone.conf.
let leftoverTemp = paths.runtimeDirectory.appendingPathComponent(".rclone-crash-leftover.tmp")
try Data("leftover".utf8).write(to: leftoverTemp)
RuntimeConfiguration.remove(at: configURL)
check(!FileManager.default.fileExists(atPath: configURL.path) && !FileManager.default.fileExists(atPath: leftoverTemp.path),
      "清理运行配置时必须一并删除遗留的 .rclone-*.tmp 临时文件")

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

// MARK: - Update check settings migration, SemVer precedence, HTTP hygiene, validation & schedule

check(migrated.automaticUpdateCheck == true, "升级旧设置必须默认开启自动检查更新")
let disabledAutoSettings = AppSettings(automaticUpdateCheck: false)
let decodedDisabledAuto = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(disabledAutoSettings))
check(decodedDisabledAuto.automaticUpdateCheck == false, "关闭自动检查更新的设置必须可持久化")

enum VersionOrder { case less, equal, greater }
let versionTable: [(String, VersionOrder, String)] = [
    ("v1.1.3", .equal, "1.1.3"),
    ("v1.1.3", .less, "1.2.0"),
    ("1.1.3", .less, "v1.2.0"),
    ("1.2", .equal, "1.2.0"),
    ("1.2", .equal, "1.2.0.0"),
    ("0", .equal, "0.0.0"),
    ("1.2", .less, "1.2.1"),
    ("1.2.0", .less, "1.2.0.1"),
    ("1.2.9", .less, "1.2.10"),
    ("1.9.9", .less, "1.10.0"),
    ("1.10.0", .less, "2.0.0"),
    ("1.0.0-alpha", .less, "1.0.0-alpha.1"),
    ("1.0.0-alpha.1", .less, "1.0.0-alpha.beta"),
    ("1.0.0-alpha.beta", .less, "1.0.0-beta"),
    ("1.0.0-beta", .less, "1.0.0-beta.2"),
    ("1.0.0-beta.2", .less, "1.0.0-beta.11"),
    ("1.0.0-beta.11", .less, "1.0.0-rc.1"),
    ("1.0.0-rc.1", .less, "1.0.0"),
    ("1.0.0-1", .less, "1.0.0-alpha"),
    ("1.0.0-2", .less, "1.0.0-11"),
    ("1.0.0-0a", .less, "1.0.0-1a"),
    ("1.0.0+001", .equal, "1.0.0"),
    ("1.0.0-999999999999999999999", .less, "1.0.0-1000000000000000000000"),
    ("1.2.0-rc.1", .less, "1.2"),
    ("1.2.0+build.1", .equal, "1.2.0+build.2"),
    ("1.2.0+20261124", .equal, "1.2.0"),
    ("1.2.0-beta.1+exp.sha", .equal, "1.2.0-beta.1"),
    ("v2.0.0", .greater, "1.99.99"),
    ("1.2.0-rc.2", .greater, "1.2.0-rc.1"),
    ("1.2.0-alpha.beta", .greater, "1.2.0-alpha.1")
]
check(versionTable.count >= 25, "版本比较表应至少覆盖 25 组用例")
for (lhsText, order, rhsText) in versionTable {
    guard let lhs = ReleaseVersion(lhsText), let rhs = ReleaseVersion(rhsText) else {
        check(false, "合法版本号应能解析：\(lhsText) / \(rhsText)")
        fatalError()
    }
    switch order {
    case .less:
        check(lhs < rhs && !(rhs < lhs) && lhs != rhs, "\(lhsText) 应小于 \(rhsText)")
    case .equal:
        check(lhs == rhs && !(lhs < rhs) && !(rhs < lhs), "\(lhsText) 应等于 \(rhsText)")
    case .greater:
        check(rhs < lhs && !(lhs < rhs) && lhs != rhs, "\(lhsText) 应大于 \(rhsText)")
    }
}
check(ReleaseVersion("v1.2.0-rc.1+build.9")?.withoutBuildMetadata == "1.2.0-rc.1", "withoutBuildMetadata 应移除构建元数据")
check(ReleaseVersion("v1.2.0")?.display == "1.2.0", "display 应去掉前导 v")

let refusedVersions = [
    "", "v", "V1.2.0", "1.2.", ".1.2", "1..2", "1.2.a", "1.2.0-", "1.2.0+",
    "1.2.0-alpha..1", "1.2.0-alpha_1", "1.2.0+bad_meta", " 1.2.0", "1.2.0\n",
    String(repeating: "1", count: 129), "99999999999999999999999999999.0.0",
    "v1.2.0-beta!1", "1.2.0+build..1",
    "01.2.3", "1.02.3", "1.2.03", "1.0.0-01", "1.0.0-00", "1.0.0-alpha.02"
]
for invalid in refusedVersions {
    check(ReleaseVersion(invalid) == nil, "非法版本号必须被拒绝：\(invalid.debugDescription)")
}

// Release page validation: allowed repository paths and >= 15 refused addresses.
let allowedReleasePages = [
    "https://github.com/007xf/QuarkFS",
    "https://github.com/007xf/QuarkFS/releases/tag/v1.2.0",
    "HTTPS://GITHUB.COM/007XF/QUARKFS/releases/tag/v1.2.0"
]
for validURL in allowedReleasePages {
    check(UpdateChecker.validateReleasePage(validURL) != nil, "合法发行页面地址应允许：\(validURL)")
}
let refusedReleasePages = [
    "https://evil.example/007xf/QuarkFS/releases/tag/v1.2.0",
    "https://api.github.com/007xf/QuarkFS/releases/tag/v1.2.0",
    "https://github.com.evil.example/007xf/QuarkFS",
    "http://github.com/007xf/QuarkFS/releases/tag/v1.2.0",
    "javascript:alert(1)",
    "file:///Applications/QuarkFS.app",
    "https://github.com/007xf/QuarkFS-evil/releases/tag/v1.2.0",
    "https://github.com/007xf/Flayer/releases/tag/v1.2.0",
    "https://user@github.com/007xf/QuarkFS/releases/tag/v1.2.0",
    "https://user:pass@github.com/007xf/QuarkFS/releases/tag/v1.2.0",
    "https://github.com:443/007xf/QuarkFS/releases/tag/v1.2.0",
    "https://github.com/007xf/QuarkFS/releases/tag/v1.2.0?download=1",
    "https://github.com/007xf/QuarkFS?",
    "https://github.com/007xf/QuarkFS/releases/tag/v1.2.0#top",
    "https://github.com/007xf/QuarkFS/../other",
    "https://github.com/007xf/QuarkFS/./releases",
    "https://github.com/007xf/QuarkFS/%2e%2e/other",
    "https://github.com/007xf/QuarkFS/releases%2f..",
    "https://github.com/007xf/QuarkFS/releases%5cevil",
    "https://github.com/007xf/QuarkFS/releases/tag/v1.2.0%0a",
    "https://github.com/007xf/QuarkFS/releases/tag/v1.2.0\n",
    "https://github.com/007xf/QuarkFS/releases/tag/v1.2.0%252f",
    "https://github.com/007xf/QuarkFS//evil.com",
    "https://github.com/007xf/QuarkFS/releases//x",
    "https://github.com/007xf/QuarkFS/",
    "https://git%68ub.com/007xf/QuarkFS",
    "https://github.com:/007xf/QuarkFS",
    "https://github.com/007xf/QuarkFS/releases/tag/" + String(repeating: "a", count: 2_050)
]
check(refusedReleasePages.count >= 15, "发行页面拒绝列表应至少覆盖 15 个非法地址")
for badURL in refusedReleasePages {
    check(UpdateChecker.validateReleasePage(badURL) == nil, "非法发行页面地址必须被拒绝：\(badURL.debugDescription)")
}

// Notes cleaning & scalar cap.
let dirtyNotes = "第一行\r\n\t缩进\u{0000}\u{0007}\u{001B}[31m正常\u{007F}"
check(UpdateChecker.cleanNotes(dirtyNotes) == "第一行\n\t缩进[31m正常", "更新说明必须移除换行与制表符之外的控制字符")
let longNotes = String(repeating: "更", count: 1_500)
let cleanedLong = UpdateChecker.cleanNotes(longNotes)
check(cleanedLong.unicodeScalars.count == 1_200, "更新说明必须截断到最多 1200 个标量")
check(UpdateChecker.cleanNotes(nil) == "", "空更新说明应返回空字符串")

// Payload parsing checks.
let validPayloadJSON = Data("""
{
  "tag_name": "v1.2.0",
  "html_url": "https://github.com/007xf/QuarkFS/releases/tag/v1.2.0",
  "published_at": "2026-11-24T10:00:00Z",
  "body": "新增更新检查\\r\\n\\t仅提示不自动下载\\u0007"
}
""".utf8)
let parsedRelease = try UpdateChecker.parseRelease(validPayloadJSON)
check(parsedRelease.version == "1.2.0"
      && parsedRelease.pageURL.absoluteString == "https://github.com/007xf/QuarkFS/releases/tag/v1.2.0"
      && parsedRelease.notes == "新增更新检查\n\t仅提示不自动下载",
      "合法发行版 JSON 必须正确解析并清理更新说明")
for badJSON in [
    Data("not json".utf8),
    Data("{\"tag_name\":\"bad\",\"html_url\":\"https://github.com/007xf/QuarkFS/releases/tag/v1.2.0\",\"published_at\":\"2026-11-24T10:00:00Z\"}".utf8),
    Data("{\"tag_name\":\"v1.2.0\",\"html_url\":\"https://evil.example/007xf/QuarkFS\",\"published_at\":\"2026-11-24T10:00:00Z\"}".utf8),
    Data("{\"tag_name\":\"v1.2.0\",\"html_url\":\"https://github.com/007xf/QuarkFS\",\"published_at\":\"not-a-date\"}".utf8)
] {
    do {
        _ = try UpdateChecker.parseRelease(badJSON)
        check(false, "损坏或非法发行页面地址的响应必须失败")
    } catch UpdateChecker.Failure.invalidResponse {}
}

// Hardened URLSession configuration checks.
let hardenedConfig = UpdateChecker.hardenedConfiguration(from: .ephemeral)
check(hardenedConfig.httpCookieStorage == nil && !hardenedConfig.httpShouldSetCookies
      && hardenedConfig.httpCookieAcceptPolicy == .never
      && hardenedConfig.urlCache == nil && hardenedConfig.urlCredentialStorage == nil
      && hardenedConfig.httpAdditionalHeaders == nil
      && hardenedConfig.requestCachePolicy == .reloadIgnoringLocalCacheData
      && hardenedConfig.timeoutIntervalForRequest == 15
      && hardenedConfig.timeoutIntervalForResource == 30,
      "更新检查会话必须关闭 Cookie、缓存与凭据存储，并设置 15s/30s 超时")

// End-to-end HTTP transport checks via URLProtocol (headers, status mapping, body cap, redirect refusal).
let updateURLConfig = URLSessionConfiguration.ephemeral
updateURLConfig.protocolClasses = [UpdateStubProtocol.self]
let protocolTransport = UpdateChecker.transport(configuration: updateURLConfig)

@MainActor func makeProtocolChecker(runningVersion: String? = "1.1.3") -> UpdateChecker {
    UpdateChecker(
        runningVersion: runningVersion,
        readSchedule: { .init(automaticEnabled: true, lastCheck: nil, lastAnnouncedVersion: nil) },
        recordCheck: { _ in },
        recordAnnouncement: { _ in },
        transport: protocolTransport
    )
}

UpdateStubProtocol.configure { _ in
    .response(statusCode: 200, headers: ["Content-Type": "application/json"], chunks: [validPayloadJSON])
}
let newerResult = await makeProtocolChecker(runningVersion: "1.1.3").checkManually()
check(newerResult == .newerAvailable(parsedRelease) && newerResult.message == "发现新版本 1.2.0",
      "检测到更高版本应返回 newerAvailable")
check(UpdateStubProtocol.capturedRequests.count == 1, "单次手动检查应发送一次请求")
if let sent = UpdateStubProtocol.capturedRequests.first {
    check(sent.httpMethod == "GET" && sent.url == UpdateChecker.endpoint, "请求必须 GET 官方 latest API")
    check(sent.timeoutInterval == 15, "URLRequest 自身超时也必须为 15 秒")
    check(sent.value(forHTTPHeaderField: "User-Agent") == "QuarkFS/1.1.3", "User-Agent 必须只包含 QuarkFS/<version>")
    check(sent.value(forHTTPHeaderField: "Accept") == "application/vnd.github+json", "Accept 必须为 GitHub JSON")
    check(sent.value(forHTTPHeaderField: "Accept-Language") == "*", "Accept-Language 必须为 *")
    check(sent.httpShouldHandleCookies == false, "请求必须禁用 Cookie")
    check(sent.value(forHTTPHeaderField: "Cookie") == nil && sent.value(forHTTPHeaderField: "Authorization") == nil,
          "请求不得携带 Cookie 或认证头")
}

// Same or older release -> upToDate.
UpdateStubProtocol.configure { _ in
    .response(statusCode: 200, headers: ["Content-Type": "application/json"], chunks: [validPayloadJSON])
}
let upToDateResult = await makeProtocolChecker(runningVersion: "1.2.0").checkManually()
check(upToDateResult == .upToDate && upToDateResult.message == "已是最新版本", "同版本或更高运行版本应返回已是最新版本")
let newerRunningResult = await makeProtocolChecker(runningVersion: "1.3.0").checkManually()
check(newerRunningResult == .upToDate, "高于远端的运行版本应返回已是最新版本")

// Every failure status mapping & exact Chinese message.
let statusCases: [(Int, [String: String], UpdateChecker.Failure, String)] = [
    (404, [:], .noPublicRelease, "未找到 QuarkFS 的公开发行版"),
    (429, [:], .rateLimited, "更新检查请求过于频繁，请稍后再试"),
    (403, ["X-RateLimit-Remaining": "0"], .rateLimited, "更新检查请求过于频繁，请稍后再试"),
    (403, ["Retry-After": "120"], .rateLimited, "更新检查请求过于频繁，请稍后再试"),
    (403, ["X-RateLimit-Remaining": "59"], .repositoryUnavailable, "暂时无法访问 QuarkFS 的发行仓库"),
    (500, [:], .repositoryUnavailable, "暂时无法访问 QuarkFS 的发行仓库"),
    (503, [:], .repositoryUnavailable, "暂时无法访问 QuarkFS 的发行仓库")
]
for (code, headers, expectedFailure, expectedMessage) in statusCases {
    UpdateStubProtocol.configure { _ in .response(statusCode: code, headers: headers, chunks: [Data("{}".utf8)]) }
    let result = await makeProtocolChecker().checkManually()
    check(result == .couldNotCheck(expectedFailure) && result.message == expectedMessage,
          "HTTP \(code) \(headers) 应映射为 \(expectedFailure)：实际 \(result)")
}

// Offline error.
UpdateStubProtocol.configure { _ in .error(URLError(.notConnectedToInternet)) }
let offlineResult = await makeProtocolChecker().checkManually()
check(offlineResult == .couldNotCheck(.offline) && offlineResult.message == "网络连接失败", "网络断开应返回离线失败")

// Unreadable JSON.
UpdateStubProtocol.configure { _ in .response(statusCode: 200, headers: [:], chunks: [Data("{bad".utf8)]) }
let unreadableResult = await makeProtocolChecker().checkManually()
check(unreadableResult == .couldNotCheck(.invalidResponse) && unreadableResult.message == "服务器返回了无法识别的响应",
      "无法解析的 JSON 应返回 invalidResponse")

// Invalid running version.
let invalidRunningResult = await makeProtocolChecker(runningVersion: "not-a-version").checkManually()
check(invalidRunningResult == .couldNotCheck(.invalidRunningVersion)
      && invalidRunningResult.message == "无法识别当前 QuarkFS 的版本",
      "无法识别当前版本应返回 invalidRunningVersion")

// Redirect refused without following the target.
UpdateStubProtocol.configure { _ in .redirect(to: URL(string: "https://evil.example/redirected")!) }
let redirectResult = await makeProtocolChecker().checkManually()
check(redirectResult == .couldNotCheck(.repositoryUnavailable), "重定向必须被拒绝")
check(UpdateStubProtocol.capturedRequests.count == 1, "重定向后不得发起第二个请求")

// Body larger than 256 KB cap: both Content-Length header and streamed chunks.
UpdateStubProtocol.configure { _ in
    .response(statusCode: 200, headers: ["Content-Length": "\(UpdateChecker.maximumResponseBytes + 1)"], chunks: [Data(repeating: 0x41, count: 1024)])
}
let headerTooLarge = await makeProtocolChecker().checkManually()
check(headerTooLarge == .couldNotCheck(.responseTooLarge) && headerTooLarge.message == "下载内容超过允许的大小",
      "超过 256 KB 的 Content-Length 必须直接拒绝")

let chunk64K = Data(repeating: 0x41, count: 64 * 1024)
let gatedProtocolTransport = UpdateChecker.transport(
    configuration: updateURLConfig,
    onChunkAccepted: { UpdateStubProtocol.releaseNextChunk() }
)
@MainActor func makeGatedProtocolChecker() -> UpdateChecker {
    UpdateChecker(
        runningVersion: "1.1.3",
        readSchedule: { .init(automaticEnabled: true, lastCheck: nil, lastAnnouncedVersion: nil) },
        recordCheck: { _ in },
        recordAnnouncement: { _ in },
        transport: gatedProtocolTransport
    )
}
UpdateStubProtocol.configure { _ in
    // 12 chunks = 768 KB > 256 KB; gate-driven so chunk N+1 is only sent after
    // chunk N is accepted, deterministically stopping on chunk 5 with no timing.
    .gatedStream(statusCode: 200, headers: [:], chunks: Array(repeating: chunk64K, count: 12))
}
let streamedTooLarge = await makeGatedProtocolChecker().checkManually()
check(streamedTooLarge == .couldNotCheck(.responseTooLarge) && streamedTooLarge.message == "下载内容超过允许的大小",
      "流式响应超过 256 KB 必须中止读取并失败")
check(UpdateStubProtocol.chunksSentBeforeStop == 5,
      "流式响应超限时必须在第 5 块提前停止读取，不能读完整个响应（实际读取块数：\(UpdateStubProtocol.chunksSentBeforeStop)）")

// Schedule, interval, announcement once-per-version, and concurrent request sharing.
final class ScheduleTransportStub: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var payload: Data
    private var failOffline = false

    init(payload: Data) {
        self.payload = payload
    }

    var requestCount: Int { lock.withLock { count } }

    func setPayload(_ data: Data) { lock.withLock { payload = data } }
    func setFailOffline(_ flag: Bool) { lock.withLock { failOffline = flag } }

    func respond() throws -> UpdateChecker.HTTPResponse {
        try lock.withLock {
            count += 1
            if failOffline { throw UpdateChecker.Failure.offline }
            return UpdateChecker.HTTPResponse(statusCode: 200, data: payload)
        }
    }
}

@MainActor func runScheduleAndConcurrencyChecks() async {
    var now = Date(timeIntervalSince1970: 1_764_000_000)
    var schedule = UpdateChecker.Schedule(automaticEnabled: true, lastCheck: nil, lastAnnouncedVersion: nil)
    let stub = ScheduleTransportStub(payload: validPayloadJSON)

    let checker = UpdateChecker(
        runningVersion: "1.1.3",
        readSchedule: { schedule },
        recordCheck: {
            schedule.lastCheck = $0
            schedule.lastOfflineAutomaticAttempt = nil
            schedule.offlineAutomaticRetryCount = 0
        },
        recordOfflineAutomaticAttempt: { date, count in
            schedule.lastOfflineAutomaticAttempt = date
            schedule.offlineAutomaticRetryCount = count
        },
        recordAnnouncement: { schedule.lastAnnouncedVersion = $0 },
        clock: { now },
        transport: { _, _ in try stub.respond() }
    )

    // Switch off -> no automatic request.
    schedule.automaticEnabled = false
    let skippedOff = await checker.checkAutomaticallyIfDue()
    check(skippedOff == nil && stub.requestCount == 0, "关闭自动检查时不得发送自动请求")

    // Manual bypasses switch off.
    stub.setFailOffline(true)
    let manualFailed = await checker.checkManually()
    check(manualFailed == .couldNotCheck(.offline) && stub.requestCount == 1 && schedule.lastCheck == now,
          "手动检查必须忽略开关并记录检查时间")

    // Re-enable switch: failed check already started the 24h interval.
    schedule.automaticEnabled = true
    stub.setFailOffline(false)
    now = now.addingTimeInterval(24 * 60 * 60 - 1)
    let notDueYet = await checker.checkAutomaticallyIfDue()
    check(notDueYet == nil && stub.requestCount == 1, "失败的检查也必须开始 24 小时间隔")

    // At 24h: due -> finds 1.2.0 and prepares one automatic notice.
    now = now.addingTimeInterval(1)
    let autoFound = await checker.checkAutomaticallyIfDue()
    check(autoFound == .newerAvailable(parsedRelease) && stub.requestCount == 2, "满 24 小时后自动检查必须执行")
    let firstNotice = checker.takeAutomaticNotice()
    check(firstNotice?.version == "1.2.0" && schedule.lastAnnouncedVersion == "1.2.0", "自动发现的新版本应提示一次并记住版本号")
    check(checker.takeAutomaticNotice() == nil, "同一提示被消费后不得重复返回")

    // Another 24h later: same version (even with different build metadata) is not announced again.
    now = now.addingTimeInterval(24 * 60 * 60)
    stub.setPayload(Data("""
    {"tag_name":"v1.2.0+build.2","html_url":"https://github.com/007xf/QuarkFS/releases/tag/v1.2.0","published_at":"2026-11-24T10:00:00Z","body":"notes"}
    """.utf8))
    let autoRepeat = await checker.checkAutomaticallyIfDue()
    check(autoRepeat != nil && checker.takeAutomaticNotice() == nil, "已提示过的版本不得再次自动提示")

    // Newer version 1.3.0 after announced 1.2.0 IS announced again.
    now = now.addingTimeInterval(24 * 60 * 60)
    stub.setPayload(Data("""
    {"tag_name":"v1.3.0","html_url":"https://github.com/007xf/QuarkFS/releases/tag/v1.3.0","published_at":"2026-11-26T10:00:00Z","body":"1.3"}
    """.utf8))
    _ = await checker.checkAutomaticallyIfDue()
    let secondNotice = checker.takeAutomaticNotice()
    check(secondNotice?.version == "1.3.0" && schedule.lastAnnouncedVersion == "1.3.0", "更高的版本必须再次自动提示")

    // Manual check discovering 1.4.0 counts as announcement -> later automatic check does not announce 1.4.0.
    stub.setPayload(Data("""
    {"tag_name":"v1.4.0","html_url":"https://github.com/007xf/QuarkFS/releases/tag/v1.4.0","published_at":"2026-11-27T10:00:00Z","body":"1.4"}
    """.utf8))
    let manualNewer = await checker.checkManually()
    if case .newerAvailable(let release14) = manualNewer {
        check(release14.version == "1.4.0" && schedule.lastAnnouncedVersion == "1.4.0", "手动检查报告新版本应记为已提示")
    } else {
        check(false, "手动检查应报告 1.4.0")
    }
    now = now.addingTimeInterval(24 * 60 * 60)
    _ = await checker.checkAutomaticallyIfDue()
    check(checker.takeAutomaticNotice() == nil, "手动检查报告过的版本不得再次自动提示")

    // Future lastCheck (wrong clock jumped back) must be treated as due (C2).
    schedule.lastCheck = now.addingTimeInterval(10 * 24 * 60 * 60)
    let beforeFutureCheck = stub.requestCount
    let futureDue = await checker.checkAutomaticallyIfDue()
    check(futureDue != nil && stub.requestCount == beforeFutureCheck + 1 && schedule.lastCheck == now,
          "上次检查时间晚于当前时间时必须立即视为到期")

    // Automatic offline failure retries at the next hourly tick without a tight
    // loop, caps retries per day, and then starts the 24h interval (C1).
    now = now.addingTimeInterval(24 * 60 * 60)
    stub.setFailOffline(true)
    let offlineStartCalls = stub.requestCount
    let offline1 = await checker.checkAutomaticallyIfDue()
    check(offline1 == .couldNotCheck(.offline) && stub.requestCount == offlineStartCalls + 1
          && schedule.offlineAutomaticRetryCount == 1,
          "首次离线自动检查失败应记录离线重试次数而非锁死 24 小时")
    // 10 minutes later: skipped (no tight retry loop).
    now = now.addingTimeInterval(10 * 60)
    let tightSkip = await checker.checkAutomaticallyIfDue()
    check(tightSkip == nil && stub.requestCount == offlineStartCalls + 1, "离线重试冷却期内不得高频重试")
    // 1 hour after attempt 1: retry #2 runs.
    now = now.addingTimeInterval(50 * 60)
    let offline2 = await checker.checkAutomaticallyIfDue()
    check(offline2 == .couldNotCheck(.offline) && stub.requestCount == offlineStartCalls + 2
          && schedule.offlineAutomaticRetryCount == 2,
          "离线自动检查失败满 1 小时后应重试")
    // 1 hour after attempt 2: retry #3 hits cap and enters 24h cooldown.
    now = now.addingTimeInterval(60 * 60)
    let offline3 = await checker.checkAutomaticallyIfDue()
    check(offline3 == .couldNotCheck(.offline) && stub.requestCount == offlineStartCalls + 3
          && schedule.offlineAutomaticRetryCount == 0 && schedule.lastCheck == now,
          "达到每日离线重试上限后应进入 24 小时间隔")
    now = now.addingTimeInterval(60 * 60)
    let cappedSkip = await checker.checkAutomaticallyIfDue()
    check(cappedSkip == nil && stub.requestCount == offlineStartCalls + 3,
          "超过离线重试上限后 1 小时内不得继续重试")
    stub.setFailOffline(false)

    // Concurrent callers share one in-flight request.
    final class ConcurrentGate: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        var callCount: Int { lock.withLock { count } }
        private func recordCall() { lock.withLock { count += 1 } }
        func enter() async -> UpdateChecker.HTTPResponse {
            recordCall()
            try? await Task.sleep(for: .milliseconds(120))
            return UpdateChecker.HTTPResponse(statusCode: 200, data: validPayloadJSON)
        }
    }
    let gate = ConcurrentGate()
    let sharedChecker = UpdateChecker(
        runningVersion: "1.1.3",
        readSchedule: { .init(automaticEnabled: true, lastCheck: nil, lastAnnouncedVersion: nil) },
        recordCheck: { _ in },
        recordAnnouncement: { _ in },
        transport: { _, _ in await gate.enter() }
    )
    async let firstCall = sharedChecker.checkManually()
    async let secondCall = sharedChecker.checkManually()
    let (r1, r2) = await (firstCall, secondCall)
    check(gate.callCount == 1 && r1 == r2 && r1 == .newerAvailable(parsedRelease),
          "并发的两次更新检查必须共享同一次请求")
}
await runScheduleAndConcurrencyChecks()
check(UpdateChecker.liveTransportConstructionCount == 0 && UpdateChecker.liveTransportCallCount == 0,
      "冒烟测试期间不得构造或调用真实更新网络传输")

print("PASS: QuarkFS 核心回归测试全部通过（挂载、缓存边界、进程、登录、设置迁移、WebDAV、更新检查）")
