import Foundation
import Darwin

public enum ProcessRunnerError: LocalizedError {
    case timedOut

    public var errorDescription: String? { "后台命令响应超时，请重试或检查文件系统引擎" }
}

private final class ProcessOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func store(_ value: Data) {
        lock.lock()
        defer { lock.unlock() }
        data = value
    }

    var text: String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: data, as: UTF8.self)
    }
}

public struct ProcessResult: Sendable {
    public let status: Int32
    public let standardOutput: String
    public let standardError: String

    public init(status: Int32, standardOutput: String, standardError: String) {
        self.status = status
        self.standardOutput = standardOutput
        self.standardError = standardError
    }
}

public enum ProcessRunner {
    public static func run(
        executable: URL,
        arguments: [String],
        input: Data? = nil,
        environment: [String: String]? = nil,
        timeout: TimeInterval = 15
    ) throws -> ProcessResult {
        let process = Process()
        let output = Pipe()
        let error = Pipe()
        let inputPipe = Pipe()

        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = error
        if input != nil {
            process.standardInput = inputPipe
        }
        if let environment {
            process.environment = environment
        }

        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        try process.run()

        // Drain both pipes while the child runs: waiting first deadlocks once
        // either pipe fills (for example a long engine help/error response).
        let readers = DispatchGroup()
        let stdout = ProcessOutput()
        let stderr = ProcessOutput()
        for (pipe, captured) in [(output, stdout), (error, stderr)] {
            readers.enter()
            DispatchQueue.global().async {
                captured.store(pipe.fileHandleForReading.readDataToEndOfFile())
                try? pipe.fileHandleForReading.close()
                readers.leave()
            }
        }
        if let input {
            DispatchQueue.global().async {
                try? inputPipe.fileHandleForWriting.write(contentsOf: input)
                try? inputPipe.fileHandleForWriting.close()
            }
        }
        if finished.wait(timeout: .now() + max(0.1, timeout)) == .timedOut {
            if process.isRunning { process.terminate() }
            if finished.wait(timeout: .now() + 1) == .timedOut, process.isRunning {
                kill(process.processIdentifier, SIGKILL)
                _ = finished.wait(timeout: .now() + 1)
            }
            throw ProcessRunnerError.timedOut
        }
        guard readers.wait(timeout: .now() + 1) == .success else {
            throw ProcessRunnerError.timedOut
        }
        return ProcessResult(
            status: process.terminationStatus,
            standardOutput: stdout.text,
            standardError: stderr.text
        )
    }

    /// Stop only a process owned by this app, without blocking the UI thread.
    public static func stop(_ process: Process) async -> Bool {
        guard process.isRunning else { return true }
        process.terminate()
        for _ in 0..<60 {
            if !process.isRunning { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        for _ in 0..<20 {
            if !process.isRunning { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return !process.isRunning
    }
}
