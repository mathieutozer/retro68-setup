import Foundation

enum ShellError: Error, LocalizedError {
    case commandFailed(command: String, exitCode: Int32, stderr: String)
    case commandNotFound(String)

    var errorDescription: String? {
        switch self {
        case .commandFailed(let command, let exitCode, let stderr):
            return "Command '\(command)' failed with exit code \(exitCode): \(stderr)"
        case .commandNotFound(let command):
            return "Command not found: \(command)"
        }
    }
}

struct ShellResult {
    let exitCode: Int32
    let stdout: String
    let stderr: String

    var succeeded: Bool { exitCode == 0 }
}

actor ShellRunner {
    static let shared = ShellRunner()

    private init() {}

    func run(_ command: String, at directory: URL? = nil, environment: [String: String]? = nil) async throws -> ShellResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", command]

        if let directory = directory {
            process.currentDirectoryURL = directory
        }

        if let environment = environment {
            var env = ProcessInfo.processInfo.environment
            for (key, value) in environment {
                env[key] = value
            }
            process.environment = env
        }

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()
        process.waitUntilExit()

        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()

        let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
        let stderr = String(data: stderrData, encoding: .utf8) ?? ""

        return ShellResult(
            exitCode: process.terminationStatus,
            stdout: stdout.trimmingCharacters(in: .whitespacesAndNewlines),
            stderr: stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    func runOrThrow(_ command: String, at directory: URL? = nil, environment: [String: String]? = nil) async throws -> String {
        let result = try await run(command, at: directory, environment: environment)
        guard result.succeeded else {
            throw ShellError.commandFailed(command: command, exitCode: result.exitCode, stderr: result.stderr)
        }
        return result.stdout
    }

    func runStreaming(
        _ command: String,
        at directory: URL? = nil,
        environment: [String: String]? = nil,
        onOutput: @escaping @Sendable (String) -> Void
    ) async throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", command]

        if let directory = directory {
            process.currentDirectoryURL = directory
        }

        if let environment = environment {
            var env = ProcessInfo.processInfo.environment
            for (key, value) in environment {
                env[key] = value
            }
            process.environment = env
        }

        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = outputPipe

        outputPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if let str = String(data: data, encoding: .utf8), !str.isEmpty {
                onOutput(str)
            }
        }

        try process.run()
        process.waitUntilExit()

        outputPipe.fileHandleForReading.readabilityHandler = nil

        return process.terminationStatus
    }

    func commandExists(_ command: String) async -> Bool {
        let result = try? await run("which \(command)")
        return result?.succeeded ?? false
    }
}
