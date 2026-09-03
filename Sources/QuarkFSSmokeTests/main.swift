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

print("PASS: QuarkFS 核心冒烟测试全部通过")
