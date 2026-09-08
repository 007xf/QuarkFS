import Darwin
import Foundation
import QuarkFSCore

@main
enum InstanceLockChecks {
    static func main() throws {
        if CommandLine.arguments.count == 4, CommandLine.arguments[1] == "--race" {
            let directory = URL(fileURLWithPath: CommandLine.arguments[2])
            let identifier = CommandLine.arguments[3]
            try Data().write(to: directory.appendingPathComponent("\(identifier).ready"))
            while !FileManager.default.fileExists(atPath: directory.appendingPathComponent("start").path) { usleep(10_000) }
            let lock = try ApplicationInstanceLock.acquire(at: directory.appendingPathComponent("race.lock"))
            try Data((lock == nil ? "blocked" : "owner").utf8)
                .write(to: directory.appendingPathComponent("\(identifier).result"), options: .atomic)
            if let lock {
                withExtendedLifetime(lock) {
                    while !FileManager.default.fileExists(atPath: directory.appendingPathComponent("finish").path) { usleep(10_000) }
                }
            }
            return
        }
        if CommandLine.arguments.count == 4, CommandLine.arguments[1] == "--hold" {
            guard let lock = try ApplicationInstanceLock.acquire(at: URL(fileURLWithPath: CommandLine.arguments[2])) else {
                exit(10)
            }
            try Data("ready".utf8).write(to: URL(fileURLWithPath: CommandLine.arguments[3]))
            withExtendedLifetime(lock) { while true { sleep(1) } }
            return
        }

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("QuarkFS-lock-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let lockURL = root.appendingPathComponent("Application.lock")
        let readyURL = root.appendingPathComponent("ready")
        let holder = Process()
        holder.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        holder.arguments = ["--hold", lockURL.path, readyURL.path]
        try holder.run()
        defer {
            if holder.isRunning { kill(holder.processIdentifier, SIGKILL); holder.waitUntilExit() }
        }
        let deadline = Date().addingTimeInterval(5)
        while !FileManager.default.fileExists(atPath: readyURL.path), Date() < deadline, holder.isRunning {
            usleep(20_000)
        }
        try expect(FileManager.default.fileExists(atPath: readyURL.path), "owner process acquired its lock")
        try expect(try ApplicationInstanceLock.acquire(at: lockURL) == nil, "a second process cannot acquire the owner's lock")

        kill(holder.processIdentifier, SIGKILL)
        holder.waitUntilExit()
        var recovered = try ApplicationInstanceLock.acquire(at: lockURL)
        try expect(recovered != nil, "a crashed owner releases the lock without deleting its file")
        try expect(try ApplicationInstanceLock.acquire(at: lockURL) == nil, "repeated opens still cannot bypass the recovered lock")
        recovered = nil
        let afterRelease = try ApplicationInstanceLock.acquire(at: lockURL)
        try expect(afterRelease != nil, "normal object release permits the next owner")
        withExtendedLifetime(afterRelease) {}

        let sentinel = root.appendingPathComponent("sentinel")
        try Data("preserve me".utf8).write(to: sentinel)
        let symlink = root.appendingPathComponent("unsafe.lock")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: sentinel)
        do {
            _ = try ApplicationInstanceLock.acquire(at: symlink)
            throw Failure(message: "symlink lock must be refused")
        } catch is POSIXError {}
        try expect(try String(contentsOf: sentinel) == "preserve me", "refused symlink leaves its target unchanged")
        for round in 0..<6 { try concurrentLaunches(in: root.appendingPathComponent("round-\(round)")) }
        print("PASS: single-instance contention, 6 rounds of 8 concurrent launches, crash recovery, normal release and symlink refusal")
    }

    private static func concurrentLaunches(in directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var children: [Process] = []
        defer {
            for child in children where child.isRunning { kill(child.processIdentifier, SIGKILL); child.waitUntilExit() }
        }
        for index in 0..<8 {
            let child = Process()
            child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
            child.arguments = ["--race", directory.path, String(index)]
            try child.run()
            children.append(child)
        }
        try waitUntil {
            try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasSuffix(".ready") }.count == 8
        }
        try Data().write(to: directory.appendingPathComponent("start"))
        try waitUntil {
            try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasSuffix(".result") }.count == 8
        }
        let owners = try (0..<8).filter {
            try String(contentsOf: directory.appendingPathComponent("\($0).result")) == "owner"
        }
        try expect(owners.count == 1, "exactly one of eight simultaneous processes must survive as owner")
        try Data().write(to: directory.appendingPathComponent("finish"))
        for child in children {
            child.waitUntilExit()
            try expect(child.terminationStatus == 0, "concurrent child completed without error")
        }
    }

    private static func waitUntil(_ condition: () throws -> Bool) throws {
        let deadline = Date().addingTimeInterval(8)
        while !(try condition()) {
            try expect(Date() < deadline, "concurrent launch did not complete before its deadline")
            usleep(20_000)
        }
    }

    private static func expect(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure(message: message) }
    }

    private struct Failure: Error { let message: String }
}
