import Foundation

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
        environment: [String: String]? = nil
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

        try process.run()
        if let input {
            inputPipe.fileHandleForWriting.write(input)
            try? inputPipe.fileHandleForWriting.close()
        }
        process.waitUntilExit()

        let outputData = output.fileHandleForReading.readDataToEndOfFile()
        let errorData = error.fileHandleForReading.readDataToEndOfFile()
        return ProcessResult(
            status: process.terminationStatus,
            standardOutput: String(decoding: outputData, as: UTF8.self),
            standardError: String(decoding: errorData, as: UTF8.self)
        )
    }
}
