import Foundation

public struct ProcessResult: Sendable {
    public let status: Int32
    public let output: String
    public let error: String
}

public struct ProcessFailure: LocalizedError, Sendable {
    public let command: String
    public let status: Int32
    public let message: String

    public var errorDescription: String? {
        let detail = message.trimmingCharacters(in: .whitespacesAndNewlines)
        return detail.isEmpty ? "\(command) failed (exit \(status))." : detail
    }
}

public enum ProcessRunner {
    /// Runs a tool to completion off the calling thread. Output is read concurrently with the
    /// process so a large JSON listing cannot fill the pipe and stall it.
    public static func run(
        _ executable: String,
        _ arguments: [String],
        input: Data? = nil,
        environment: [String: String]? = nil
    ) async throws -> ProcessResult {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    continuation.resume(returning: try runSync(executable, arguments, input: input, environment: environment))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    public static func runSync(
        _ executable: String,
        _ arguments: [String],
        input: Data? = nil,
        environment: [String: String]? = nil
    ) throws -> ProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let environment {
            process.environment = ProcessInfo.processInfo.environment.merging(environment) { $1 }
        }
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        let stdin = input.map { _ in Pipe() }
        if let stdin { process.standardInput = stdin }

        try process.run()
        if let input, let stdin {
            stdin.fileHandleForWriting.write(input)
            try? stdin.fileHandleForWriting.close()
        }

        var errorData = Data()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            errorData = stderr.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        let outputData = stdout.fileHandleForReading.readDataToEndOfFile()
        group.wait()
        process.waitUntilExit()

        return ProcessResult(
            status: process.terminationStatus,
            output: String(decoding: outputData, as: UTF8.self),
            error: String(decoding: errorData, as: UTF8.self)
        )
    }
}
