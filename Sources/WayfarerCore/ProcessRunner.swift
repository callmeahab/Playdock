import Foundation

public final class RunningLaunch {
    public let process: Process
    public let logURL: URL
    private let output: FileHandle

    fileprivate init(process: Process, logURL: URL, output: FileHandle) {
        self.process = process
        self.logURL = logURL
        self.output = output
    }

    deinit { try? output.close() }
}

public enum ProcessRunner {
    public static func start(_ command: LaunchCommand, logsDirectory: URL = AppPaths.logs,
                             completion: @escaping @Sendable (Int32) -> Void = { _ in }) throws -> RunningLaunch {
        let fm = FileManager.default
        try fm.createDirectory(at: logsDirectory, withIntermediateDirectories: true)
        let timestamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let log = logsDirectory.appendingPathComponent("\(timestamp)-\(UUID().uuidString.prefix(8)).log")
        let header = "Wayfarer macOS\n\(command.display)\n" + command.environment.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.key == "WAYFARER_DISPLAY_TOKEN" ? "<redacted>" : $0.value)" }.joined(separator: "\n") + "\n\n"
        try Data(header.utf8).write(to: log, options: .atomic)
        let output = try FileHandle(forWritingTo: log)
        try output.seekToEnd()
        let process = Process()
        process.executableURL = command.executable
        process.arguments = command.arguments
        var environment = ProcessInfo.processInfo.environment
        for (key, value) in command.environment { environment[key] = value }
        // Finder's PATH usually omits Homebrew. Preserve the user's PATH after the runtime's bin directory.
        let runtimeDirectory = command.executable.lastPathComponent == "arch" && command.arguments.count > 1
            ? URL(fileURLWithPath: command.arguments[1]).deletingLastPathComponent().path
            : command.executable.deletingLastPathComponent().path
        environment["PATH"] = [runtimeDirectory, "/opt/homebrew/bin", "/usr/local/bin", environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"].joined(separator: ":")
        process.environment = environment
        process.currentDirectoryURL = command.workingDirectory
        process.standardOutput = output
        process.standardError = output
        process.standardInput = FileHandle.nullDevice
        process.terminationHandler = { process in completion(process.terminationStatus) }
        do { try process.run() }
        catch { try? output.close(); throw error }
        return RunningLaunch(process: process, logURL: log, output: output)
    }
}
