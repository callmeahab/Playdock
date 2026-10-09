import Foundation

public struct LaunchReceipt: Sendable {
    public let id: UUID
    public let pid: Int32
    public let token: RuntimeProcessToken?
    public let logURL: URL
}

/// Retains early process exits until the caller registers for termination.
public actor ProcessService {
    private struct Entry {
        let launch: RunningLaunch
        var exit: Int32?
        var completion: (@Sendable (Int32) -> Void)?
    }
    private var launches: [UUID: Entry] = [:]
    public init() {}
    public func start(_ command: LaunchCommand, id: UUID, logsDirectory: URL = AppPaths.logs) throws -> LaunchReceipt {
        try Task.checkCancellation()
        guard launches[id] == nil else { throw PlaydockError.message("This launch has already started.") }
        let launch = try ProcessRunner.start(command, logsDirectory: logsDirectory) { [weak self] code in
            Task { await self?.finished(id, code: code) }
        }
        launches[id] = Entry(launch: launch)
        let pid = launch.process.processIdentifier
        return LaunchReceipt(id: id, pid: pid, token: RuntimeProcessIdentity.token(for: pid), logURL: launch.logURL)
    }
    public func observe(_ id: UUID, completion: @escaping @Sendable (Int32) -> Void) {
        guard var entry = launches[id] else { return }
        if let exit = entry.exit { launches[id] = nil; completion(exit) }
        else { entry.completion = completion; launches[id] = entry }
    }
    public func wait(_ id: UUID) async throws -> Int32 {
        guard launches[id] != nil else { throw PlaydockError.message("This launch has already finished or was not started.") }
        return await withCheckedContinuation { continuation in
            observe(id) { continuation.resume(returning: $0) }
        }
    }
    public func terminate(_ id: UUID) {
        guard let entry = launches[id], entry.exit == nil, entry.launch.process.isRunning else { return }
        entry.launch.process.terminate()
    }
    private func finished(_ id: UUID, code: Int32) {
        guard var entry = launches[id] else { return }
        if let completion = entry.completion { launches[id] = nil; completion(code) }
        else { entry.exit = code; launches[id] = entry }
    }
}

public actor FileService {
    public static let shared = FileService()
    public init() {}
    public func write(_ data: Data, to file: URL) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: file, options: .atomic)
    }
    public func read(_ file: URL, limit: Int = 16_000_000) throws -> Data {
        let size = (try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.intValue ?? 0
        guard size <= limit else { throw PlaydockError.message("The requested file is too large.") }
        return try Data(contentsOf: file)
    }
    public func validateApplication(_ url: URL) throws { try NativeGameLaunch.validateApplication(url) }
    public func validateSaveFolder(_ url: URL) throws { try SaveBackupStore.validateFolder(url) }
    public func isExecutable(_ url: URL) -> Bool { FileManager.default.isExecutableFile(atPath: url.path) }
    public func abnormalGameExit(root: URL, appID: String, since: Date) -> Int? { SteamGameExit.abnormalCode(root: root, appID: appID, since: since) }
    public func compatibilityLaunchFailure(prefix: URL, since: Date) -> String? { SteamGameExit.compatibilityFailure(prefix: prefix, since: since) }
}
