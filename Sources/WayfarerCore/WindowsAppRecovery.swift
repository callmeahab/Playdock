import Foundation
import Darwin

/// Process management is confined to reviewed apps in one Windows environment.
/// Steam and Wine services are never offered as apps to quit.
public enum WindowsAppRecovery {
    private static let infrastructure: Set<String> = [
        "steam.exe", "steamwebhelper.exe", "steamerrorreporter.exe", "steamservice.exe",
        "services.exe", "svchost.exe", "winedevice.exe", "rpcss.exe", "explorer.exe",
        "winewrapper.exe", "plugplay.exe"
    ]
    public static func isInfrastructure(_ program: String) -> Bool {
        infrastructure.contains(program.lowercased())
    }
    public static func apps(prefix: URL) throws -> [RuntimeProcessIdentity.WindowsProcess] {
        try RuntimeProcessIdentity.windowsProcesses(prefix: prefix)
            .filter { !isInfrastructure($0.program) }
            .sorted { $0.program == $1.program ? $0.token.pid < $1.token.pid : $0.program < $1.program }
    }
    public static func isCurrent(_ app: RuntimeProcessIdentity.WindowsProcess, prefix: URL) -> Bool {
        RuntimeProcessIdentity.token(for: app.token.pid) == app.token &&
        RuntimeProcessIdentity.belongsToPrefix(pid: app.token.pid, prefix: prefix) &&
        RuntimeProcessIdentity.windowsProgram(for: app.token.pid)?.lowercased() == app.program.lowercased() &&
        !isInfrastructure(app.program)
    }
    /// Requires a separate user confirmation. Recheck identity and prefix at the
    /// moment of signaling; an exited app's PID may already belong to another app.
    @discardableResult public static func forceQuit(_ app: RuntimeProcessIdentity.WindowsProcess, prefix: URL) throws -> Bool {
        guard RuntimeProcessIdentity.token(for: app.token.pid) == app.token else { return false }
        guard isCurrent(app, prefix: prefix) else {
            throw WayfarerError.message("This process is no longer an application in the selected Windows environment.")
        }
        guard Darwin.kill(app.token.pid, SIGKILL) == 0 else {
            if errno == ESRCH { return false }
            throw WayfarerError.message("Could not force quit \(app.program).")
        }
        return true
    }
}
