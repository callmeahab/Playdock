import Foundation
import Darwin

/// Process queries use a separate mailbox from discovery; recheck identity before termination.
public actor RuntimeProcessService {
    public init() {}
    public func mainSteamProcesses(pids: [pid_t], root: URL, prefix: URL?, windows: Bool) -> [pid_t: RuntimeProcessToken] {
        var tokens: [pid_t: RuntimeProcessToken] = [:]
        for pid in pids {
            guard !Task.isCancelled else { return [:] }
            guard RuntimeProcessIdentity.isSteamClient(pid: pid, root: root, prefix: prefix),
                  !windows || RuntimeProcessIdentity.windowsProgram(for: pid)?.lowercased() == "steam.exe",
                  let token = RuntimeProcessIdentity.token(for: pid) else { continue }
            tokens[pid] = token
        }
        return tokens
    }
    public func steamProcesses(root: URL, prefix: URL?) throws -> [RuntimeProcessToken] {
        try Task.checkCancellation()
        return try RuntimeProcessIdentity.steamProcesses(root: root, prefix: prefix)
    }
    public func windowsProcesses(prefix: URL) throws -> [RuntimeProcessIdentity.WindowsProcess] {
        try Task.checkCancellation()
        return try RuntimeProcessIdentity.windowsProcesses(prefix: prefix)
    }
    public func windowsApps(prefix: URL) throws -> [RuntimeProcessIdentity.WindowsProcess] {
        try Task.checkCancellation()
        return try WindowsAppRecovery.apps(prefix: prefix)
    }
    public func forceQuit(_ app: RuntimeProcessIdentity.WindowsProcess, prefix: URL) throws -> Bool {
        try Task.checkCancellation()
        return try WindowsAppRecovery.forceQuit(app, prefix: prefix)
    }
    public func isCurrent(_ app: RuntimeProcessIdentity.WindowsProcess, prefix: URL) -> Bool {
        WindowsAppRecovery.isCurrent(app, prefix: prefix)
    }
    public func gameProcesses(pids: [pid_t], bundlePaths: [pid_t: URL], location: URL, steamRoot: URL, prefix: URL?) -> [RuntimeProcessToken] {
        let canonical = location.resolvingSymlinksInPath()
        return pids.compactMap { pid in
            guard !RuntimeProcessIdentity.isSteamClient(pid: pid, root: steamRoot, prefix: prefix),
                  bundlePaths[pid]?.resolvingSymlinksInPath() == canonical || RuntimeProcessIdentity.belongsToPrefix(pid: pid, prefix: location) else { return nil }
            return RuntimeProcessIdentity.token(for: pid)
        }
    }
    public func nativeGameProcesses(pids: [pid_t], bundlePaths: [pid_t: URL], location: URL) -> [RuntimeProcessToken] {
        let canonical = location.resolvingSymlinksInPath()
        return pids.compactMap { pid in
            guard bundlePaths[pid]?.resolvingSymlinksInPath() == canonical else { return nil }
            return RuntimeProcessIdentity.token(for: pid)
        }
    }
    public func matchingGameProcesses(_ processes: [RuntimeProcessIdentity.WindowsProcess], executable: URL) -> [RuntimeProcessToken] {
        processes.filter { $0.program == executable.lastPathComponent.lowercased() && RuntimeProcessIdentity.belongsToPrefix(pid: $0.token.pid, prefix: executable.deletingLastPathComponent()) }.map(\.token)
    }
    public func hasWineServer(prefix: URL) throws -> Bool { try RuntimeProcessIdentity.hasWineServer(prefix: prefix) }
    public func terminateOrphanSteam(root: URL, prefix: URL) throws {
        let steam: Set<String> = ["steam.exe", "steamwebhelper.exe", "steamerrorreporter.exe"]
        for process in try windowsProcesses(prefix: prefix) {
            try Task.checkCancellation()
            if steam.contains(process.program), RuntimeProcessIdentity.token(for: process.token.pid) == process.token,
               RuntimeProcessIdentity.isSteamClient(pid: process.token.pid, root: root, prefix: prefix) {
                _ = Darwin.kill(process.token.pid, SIGTERM)
            }
        }
    }
    public func controlPort(root: URL, prefix: URL?) -> UInt16? {
        if let prefix { return SteamControlEndpoint.runningWindowsPort(root: root, prefix: prefix) }
        return SteamControlEndpoint.runningMacPort(root: root)
    }
    public func discoverControlPort(profile: RuntimeProfile) -> UInt16? {
        guard let steam = profile.steamExecutable else { return nil }
        return controlPort(root: steam.deletingLastPathComponent(), prefix: profile.prefix)
    }
    public func verified(_ tokens: [RuntimeProcessToken]) -> [RuntimeProcessToken] {
        tokens.filter { RuntimeProcessIdentity.token(for: $0.pid) == $0 }
    }
}
