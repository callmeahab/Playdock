import Foundation

public enum PrefixTool: String, CaseIterable, Identifiable, Sendable {
    case configuration, registry
    public var id: String { rawValue }
    public var name: String { self == .configuration ? "Wine configuration" : "Registry editor" }
    public var program: String { self == .configuration ? "winecfg.exe" : "regedit.exe" }
}

public struct GamePrefixSnapshot: Sendable {
    public let prefix: URL
    public let exists: Bool
    public let initialized: Bool
    public let drive: URL?
    public let userFiles: URL?
    public let log: URL?
}

public actor GamePrefixService {
    private let processes = RuntimeProcessService()
    public init() {}

    public func snapshot(_ profile: RuntimeProfile) -> GamePrefixSnapshot {
        let fm = FileManager.default, prefix = profile.prefix
        func directory(_ url: URL) -> URL? {
            var isDirectory: ObjCBool = false
            return fm.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue ? url : nil
        }
        let drive = directory(prefix.appendingPathComponent("drive_c"))
        let users = prefix.appendingPathComponent("drive_c/users")
        let user = directory(users.appendingPathComponent("steamuser")) ?? directory(users.appendingPathComponent("crossover")) ?? directory(users)
        let log = profile.nativeSteamBridge ? prefix.deletingLastPathComponent().appendingPathComponent("wayfarer-run.log") : nil
        return GamePrefixSnapshot(prefix: prefix, exists: directory(prefix) != nil,
            initialized: drive != nil && fm.fileExists(atPath: prefix.appendingPathComponent("system.reg").path),
            drive: drive, userFiles: user, log: log.flatMap { fm.fileExists(atPath: $0.path) ? $0 : nil })
    }

    public func command(_ tool: PrefixTool, profile: RuntimeProfile) async throws -> LaunchCommand {
        guard try await processes.windowsApps(prefix: profile.prefix).isEmpty else {
            throw WayfarerError.message("Close games and Windows tools in this prefix before changing its configuration.")
        }
        try Task.checkCancellation()
        return try PrefixCommandBuilder.command(tool, profile: profile)
    }
}

public enum PrefixCommandBuilder {
    public static func command(_ tool: PrefixTool, profile: RuntimeProfile, appleSilicon: Bool = RuntimeDiscovery.isAppleSilicon) throws -> LaunchCommand {
        let fm = FileManager.default, prefix = profile.prefix.standardizedFileURL
        let canonical = prefix.resolvingSymlinksInPath()
        guard canonical.path != "/", canonical != fm.homeDirectoryForCurrentUser.resolvingSymlinksInPath(),
              fm.fileExists(atPath: prefix.appendingPathComponent("system.reg").path),
              fm.fileExists(atPath: prefix.appendingPathComponent("drive_c").path) else {
            throw WayfarerError.message("This prefix has not been initialized. Launch the game once to create its Windows files.")
        }
        var environment = ["WINEPREFIX": prefix.path]
        if profile.nativeSteamBridge {
            let root = profile.runtime.executable.deletingLastPathComponent().deletingLastPathComponent()
            var unix = root.appendingPathComponent("lib/wine/aarch64-unix")
            var loader = unix.appendingPathComponent("wine.app/Contents/MacOS/wine")
            var server = root.appendingPathComponent("bin/wineserver-arm64")
            let arm = fm.isExecutableFile(atPath: loader.path) && fm.isExecutableFile(atPath: server.path)
            if !arm {
                unix = root.appendingPathComponent("lib/wine/x86_64-unix")
                loader = unix.appendingPathComponent("wine")
                server = root.appendingPathComponent("bin/wineserver")
                if !fm.isExecutableFile(atPath: server.path) { server = root.appendingPathComponent("bin/wineserver-x86") }
            }
            guard fm.isExecutableFile(atPath: loader.path), fm.isExecutableFile(atPath: server.path) else {
                throw WayfarerError.message("Set up the Steam–CrossOver runtime before opening Windows tools.")
            }
            guard try machine(prefix.appendingPathComponent("drive_c/windows/system32/ntdll.dll")) == (arm ? 0xaa64 : 0x8664) else {
                throw WayfarerError.message("This prefix was created with a different runtime architecture. Select its original CrossOver runtime in setup.")
            }
            environment["CX_ROOT"] = root.path
            environment["CX_HOME"] = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/CrossOver").path
            environment["WINELOADER"] = loader.path
            environment["WINESERVER"] = server.path
            environment["WINEDLLPATH"] = root.appendingPathComponent("lib/wine/x86_64-windows").path + ":" + unix.path
            environment["PATH"] = root.appendingPathComponent("bin").path + ":" + (ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin")
            let sync = prefix.deletingLastPathComponent().appendingPathComponent("wayfarer-msync")
            let value = (try? String(contentsOf: sync, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
            environment["WINEMSYNC"] = value == "1" ? "1" : "0"
            return LaunchCommand(executable: loader, arguments: [tool.program], environment: environment, workingDirectory: prefix)
        }
        guard fm.isExecutableFile(atPath: profile.runtime.executable.path) else { throw WayfarerError.message("This prefix's runtime is unavailable.") }
        switch profile.runtime.kind {
        case .crossOver:
            guard fm.fileExists(atPath: prefix.appendingPathComponent("cxbottle.conf").path) else { throw WayfarerError.message("This CrossOver bottle needs to be created in CrossOver first.") }
            environment["CX_BOTTLE_PATH"] = prefix.deletingLastPathComponent().path
            return LaunchCommand(executable: profile.runtime.executable, arguments: ["--bottle", prefix.lastPathComponent, "--wait-children", "--cx-app", tool.program], environment: environment)
        case .gptk:
            guard appleSilicon else { throw WayfarerError.message("GPTK requires Apple silicon.") }
            return LaunchCommand(executable: URL(fileURLWithPath: "/usr/bin/arch"), arguments: ["-x86_64", profile.runtime.executable.path] + (profile.runtime.toolkitWrapper ? [prefix.path] : []) + [tool.program], environment: environment)
        case .wine:
            return LaunchCommand(executable: profile.runtime.executable, arguments: [tool.program], environment: environment)
        }
    }

    private static func machine(_ dll: URL) throws -> UInt16? {
        let file = try FileHandle(forReadingFrom: dll)
        defer { try? file.close() }
        guard let header = try file.read(upToCount: 64), header.count == 64, header[0] == 0x4d, header[1] == 0x5a else { return nil }
        let offset = header[60..<64].enumerated().reduce(UInt64(0)) { $0 | UInt64($1.element) << (8 * $1.offset) }
        guard offset <= 1_000_000 else { return nil }
        try file.seek(toOffset: offset)
        guard let pe = try file.read(upToCount: 6), pe.count == 6, Array(pe.prefix(4)) == [0x50, 0x45, 0, 0] else { return nil }
        return UInt16(pe[4]) | UInt16(pe[5]) << 8
    }
}
