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

print("PASS: QuarkFS 核心冒烟测试全部通过")
