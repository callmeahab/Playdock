import Foundation
import Darwin

/// Process queries use a separate mailbox from discovery; recheck identity before termination.
public actor RuntimeProcessService {
    public init() {}
    public func mainSteamProcesses(pids: [pid_t], root: URL) -> [pid_t: RuntimeProcessToken] {
        var tokens: [pid_t: RuntimeProcessToken] = [:]
        for pid in pids {
            guard !Task.isCancelled else { return [:] }
            guard RuntimeProcessIdentity.isSteamClient(pid: pid, root: root),
                  let token = RuntimeProcessIdentity.token(for: pid) else { continue }
            tokens[pid] = token
        }
        return tokens
    }
    public func steamProcesses(root: URL) throws -> [RuntimeProcessToken] {
        try Task.checkCancellation()
        return try RuntimeProcessIdentity.steamProcesses(root: root)
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
    public func gameProcesses(pids: [pid_t], bundlePaths: [pid_t: URL], location: URL, steamRoot: URL) -> [RuntimeProcessToken] {
        let canonical = location.resolvingSymlinksInPath()
        return pids.compactMap { pid in
            guard !RuntimeProcessIdentity.isSteamClient(pid: pid, root: steamRoot),
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
    public func controlPort(root: URL) -> UInt16? { SteamControlEndpoint.runningMacPort(root: root) }
    public func verified(_ tokens: [RuntimeProcessToken]) -> [RuntimeProcessToken] {
        tokens.filter { RuntimeProcessIdentity.token(for: $0.pid) == $0 }
    }
}
