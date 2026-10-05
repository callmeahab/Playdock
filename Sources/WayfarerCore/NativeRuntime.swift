import Foundation
import CryptoKit

/// App-owned loaders retain the selected engine's libraries. Provider installations
/// are read only. Copying ntdll is necessary: Wine derives child-loader paths from it.
public enum NativeRuntime {
    /// Running Steam clients and games must not map a dylib that Xcode can overwrite.
    public static func prepareAdapter(source: URL, cache: URL = AppPaths.support.appendingPathComponent("NativeAdapters")) throws -> URL {
        let binary = try Data(contentsOf: source)
        guard !binary.isEmpty, binary.count < 32_000_000 else { throw WayfarerError.message("The native presentation adapter is invalid.") }
        let hash = SHA256.hash(data: binary).map { String(format: "%02x", $0) }.joined()
        let fm = FileManager.default
        try fm.createDirectory(at: cache, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard cache.resolvingSymlinksInPath().standardizedFileURL == cache.standardizedFileURL else {
            throw WayfarerError.message("The native adapter cache must be a local folder.")
        }
        let root = cache.appendingPathComponent(hash)
        let target = root.appendingPathComponent("libWayfarerWineDisplay.dylib")
        if fm.fileExists(atPath: target.path) {
            guard try Data(contentsOf: target) == binary else { throw WayfarerError.message("The saved native adapter is damaged.") }
            return target
        }
        let staging = cache.appendingPathComponent(".prepare-\(UUID().uuidString)")
        try fm.createDirectory(at: staging, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: staging) }
        try binary.write(to: staging.appendingPathComponent(target.lastPathComponent), options: .atomic)
        try fm.moveItem(at: staging, to: root)
        return target
    }
    /// Wine keeps its server and child environment alive after a launcher exits.
    /// A new display connection must start a fresh server in Wayfarer's own prefix.
    public static func stopCommand(for profile: RuntimeProfile, home: URL = FileManager.default.homeDirectoryForCurrentUser) throws -> LaunchCommand {
        let owned = RuntimeDiscovery.managedProfile(for: profile.runtime, home: home).prefix.standardizedFileURL
        guard profile.prefix.standardizedFileURL == owned,
              owned.resolvingSymlinksInPath().standardizedFileURL == owned else {
            throw WayfarerError.message("Wayfarer can stop only its own Windows environment. A redirected or external prefix cannot be used for native display.")
        }
        let source = try loaderSource(for: profile.runtime)
        let root = source.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let candidates = [profile.runtime.executable.deletingLastPathComponent().appendingPathComponent("wineserver"), root.appendingPathComponent("bin/wineserver")]
        guard let server = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) else {
            throw WayfarerError.message("This runtime has no wineserver utility to manage Wayfarer's session.")
        }
        var environment = ["WINEPREFIX": owned.path]
        if profile.runtime.kind == .crossOver { environment["CX_BOTTLE_PATH"] = owned.deletingLastPathComponent().path }
        return LaunchCommand(executable: server, arguments: ["-k"], environment: environment)
    }

    public static func stopOwnedEnvironment(_ profile: RuntimeProfile) throws {
        let command = try stopCommand(for: profile)
        // Do not inherit a previous display endpoint or DYLD injection.
        var environment = ProcessInfo.processInfo.environment
        for key in ["DYLD_INSERT_LIBRARIES", "WAYFARER_DISPLAY_SOCKET", "WAYFARER_DISPLAY_TOKEN", "WINELOADER", "CX_WINELOADER"] { environment.removeValue(forKey: key) }
        for (key, value) in command.environment { environment[key] = value }
        func execute(_ arguments: [String]) throws -> (Int32, String) {
            let process = Process()
            process.executableURL = command.executable; process.arguments = arguments
            process.environment = environment
            let errors = Pipe()
            process.standardOutput = FileHandle.nullDevice; process.standardError = errors
            let finished = DispatchSemaphore(value: 0)
            process.terminationHandler = { _ in finished.signal() }
            try process.run()
            guard finished.wait(timeout: .now() + 5) == .success else {
                if process.isRunning { process.terminate() }
                throw WayfarerError.message("The previous Windows session did not stop. Close it and try opening Steam again.")
            }
            let detail = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return (process.terminationStatus, String(detail.prefix(512)))
        }
        let (code, detail) = try execute(command.arguments)
        // Wine exits 1 without stderr when there is no server to kill. -k exits
        // immediately, so a separate -w is required to confirm the lock is free.
        guard code == 0 || (code == 1 && detail.isEmpty) else {
            throw WayfarerError.message("Could not stop Wayfarer's previous Windows session (\(code)). \(detail)")
        }
        let (waitCode, waitDetail) = try execute(["-w"])
        guard waitCode == 0 else { throw WayfarerError.message("Could not finish stopping the Windows session (\(waitCode)). \(waitDetail)") }
    }

    public static func loaderSource(for runtime: RuntimeInstallation) throws -> URL {
        let fm = FileManager.default
        var roots = [runtime.executable.deletingLastPathComponent().deletingLastPathComponent(),
                     runtime.executable.resolvingSymlinksInPath().deletingLastPathComponent().deletingLastPathComponent()]
        roots += roots.map { $0.appendingPathComponent("libexec") }
        for root in roots {
            let file = root.appendingPathComponent("lib/wine/x86_64-unix/wine")
            let ntdll = file.deletingLastPathComponent().appendingPathComponent("ntdll.so")
            let driver = file.deletingLastPathComponent().appendingPathComponent("winemac.so")
            if fm.isExecutableFile(atPath: file.path), fm.fileExists(atPath: ntdll.path), fm.fileExists(atPath: driver.path),
               let header = try? Data(contentsOf: file, options: .mappedIfSafe).prefix(4), Array(header) == [0xcf, 0xfa, 0xed, 0xfe] {
                return file
            }
        }
        throw WayfarerError.message("\(runtime.name) has no supported native Cocoa loader. Direct display currently requires a modern Wine engine with lib/wine/x86_64-unix/wine and winemac.so (validated with CrossOver 26.3).")
    }

    public static func prepare(runtime: RuntimeInstallation, cache: URL = AppPaths.support.appendingPathComponent("NativeEngines")) throws -> URL {
        let source = try loaderSource(for: runtime)
        let unix = source.deletingLastPathComponent()
        let ntdll = unix.appendingPathComponent("ntdll.so")
        // Library links belong to this installation, even when two providers
        // ship identical loader binaries.
        let digest = SHA256.hash(data: try Data(("layout4:" + source.standardizedFileURL.path).utf8) + Data(contentsOf: source) + Data(contentsOf: ntdll)).map { String(format: "%02x", $0) }.joined()
        let fm = FileManager.default
        let root = cache.appendingPathComponent(String(digest.prefix(24)))
        let target = root.appendingPathComponent("lib/wine/x86_64-unix/wine")
        if fm.isExecutableFile(atPath: target.path), fm.fileExists(atPath: root.appendingPathComponent("ready").path) { return target }
        let staging = cache.appendingPathComponent(".prepare-\(UUID().uuidString)")
        try fm.createDirectory(at: staging, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: staging) }
        let lib = staging.appendingPathComponent("lib/wine/x86_64-unix")
        try fm.createDirectory(at: lib, withIntermediateDirectories: true)
        for file in try fm.contentsOfDirectory(at: unix, includingPropertiesForKeys: nil) {
            let dest = lib.appendingPathComponent(file.lastPathComponent)
            if ["wine", "ntdll.so"].contains(file.lastPathComponent) { try fm.copyItem(at: file, to: dest) }
            else { try fm.createSymbolicLink(at: dest, withDestinationURL: file) }
        }
        for file in try fm.contentsOfDirectory(at: unix.deletingLastPathComponent(), includingPropertiesForKeys: nil) where file.lastPathComponent != "x86_64-unix" {
            try fm.createSymbolicLink(at: lib.deletingLastPathComponent().appendingPathComponent(file.lastPathComponent), withDestinationURL: file)
        }
        let provider = unix.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        try prepareProviderLayout(provider: provider, staging: staging)
        let sign = Process(); sign.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        sign.arguments = ["--force", "--sign", "-", lib.appendingPathComponent("wine").path]
        sign.standardOutput = FileHandle.nullDevice; sign.standardError = FileHandle.nullDevice
        try sign.run(); sign.waitUntilExit()
        guard sign.terminationStatus == 0 else { throw WayfarerError.message("Could not sign Wayfarer's private Wine loader.") }
        let server=staging.appendingPathComponent("bin/wineserver")
        if fm.isExecutableFile(atPath:server.path) {
            let signer=Process(); signer.executableURL=URL(fileURLWithPath:"/usr/bin/codesign"); signer.arguments=["--force","--sign","-",server.path]
            signer.standardOutput=FileHandle.nullDevice; signer.standardError=FileHandle.nullDevice
            try signer.run(); signer.waitUntilExit()
            guard signer.terminationStatus==0 else { throw WayfarerError.message("Could not sign Wayfarer’s private Wine server.") }
        }
        try Data("1\n".utf8).write(to: staging.appendingPathComponent("ready"))
        if fm.fileExists(atPath: root.path) { try fm.removeItem(at: root) }
        try fm.moveItem(at: staging, to: root)
        return target
    }

    static func prepareProviderLayout(provider: URL, staging: URL) throws {
        let fm = FileManager.default
        // CrossOver's bin is a symlink to "CrossOver-Hosted Application".
        // Resolve it before enumerating: directory enumeration of the symlink
        // itself fails with Cocoa's "The file bin couldn't be opened" error.
        let sourceBin = provider.appendingPathComponent("bin", isDirectory: true).resolvingSymlinksInPath()
        let bin = staging.appendingPathComponent("bin", isDirectory: true)
        try fm.createDirectory(at: bin, withIntermediateDirectories: true)
        for program in try fm.contentsOfDirectory(at: sourceBin, includingPropertiesForKeys: nil) {
            let destination = bin.appendingPathComponent(program.lastPathComponent)
            if program.lastPathComponent == "wineserver" {
                try fm.copyItem(at: program.resolvingSymlinksInPath(), to: destination)
            } else {
                try fm.createSymbolicLink(at: destination, withDestinationURL: program)
            }
        }
        // Preserve graphics support files beside lib/wine, including lib64,
        // apple_gptk and dxmt. The provider installation remains read only.
        for file in try fm.contentsOfDirectory(at: provider, includingPropertiesForKeys: nil)
            where !["lib", "bin"].contains(file.lastPathComponent) {
            try fm.createSymbolicLink(at: staging.appendingPathComponent(file.lastPathComponent), withDestinationURL: file)
        }
        for file in try fm.contentsOfDirectory(at: provider.appendingPathComponent("lib"), includingPropertiesForKeys: nil)
            where file.lastPathComponent != "wine" {
            try fm.createSymbolicLink(at: staging.appendingPathComponent("lib").appendingPathComponent(file.lastPathComponent), withDestinationURL: file)
        }
    }

    public static func attachSteamBackend(_ command:LaunchCommand,runtime:RuntimeInstallation,loader:URL,adapter:URL,directory:URL) throws -> LaunchCommand {
        var result=try attachLoader(command,runtime:runtime,loader:loader,adapter:adapter,usePrivateServer:false)
        result.environment["WAYFARER_STEAM_BACKEND"]=directory.path
        return result
    }

    public static func attach(_ command: LaunchCommand, runtime: RuntimeInstallation, loader: URL, adapter: URL, socket: String, token: String) throws -> LaunchCommand {
        guard !socket.isEmpty, socket.utf8.count < 104, token.count >= 32, FileManager.default.fileExists(atPath: adapter.path) else {
            throw WayfarerError.message("Wayfarer's native display connection is unavailable.")
        }
        var result = try attachLoader(command,runtime:runtime,loader:loader,adapter:adapter,usePrivateServer:true)
        result.environment["WAYFARER_DISPLAY_SOCKET"] = socket
        result.environment["WAYFARER_DISPLAY_TOKEN"] = token
        return result
    }

    private static func attachLoader(_ command:LaunchCommand,runtime:RuntimeInstallation,loader:URL,adapter:URL,usePrivateServer:Bool) throws -> LaunchCommand {
        guard FileManager.default.fileExists(atPath:adapter.path) else { throw WayfarerError.message("Steam’s presentation adapter is unavailable.") }
        guard try supportsIntelAdapter(adapter) else { throw WayfarerError.message("Windows Steam requires Wayfarer’s universal native adapter. Rebuild the app’s WineDisplay target for both Intel and Apple silicon.") }
        var result=command
        result.environment["DYLD_INSERT_LIBRARIES"] = adapter.path
        result.environment["WINELOADER"] = loader.path
        let privateServer = loader.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("bin/wineserver")
        let server=usePrivateServer ? privateServer : runtime.executable.deletingLastPathComponent().appendingPathComponent("wineserver")
        result.environment["WINESERVER"] = server.path
        if runtime.kind == .crossOver {
            // CrossOver's Perl wrapper resets its loader, and macOS strips DYLD
            // variables when entering Perl. --env restores them after that reset.
            let variables = ["WINELOADER": loader.path, "CX_WINELOADER": loader.path, "WINESERVER": server.path, "DYLD_INSERT_LIBRARIES": adapter.path]
            let quoted = variables.sorted { $0.key < $1.key }.map { key, value in
                "'" + (key + "=" + value).replacingOccurrences(of: "'", with: "'\\''") + "'"
            }.joined(separator: " ")
            result.arguments.insert(contentsOf: ["--env", quoted, "--enable-alt-loader", "no"], at: 0)
        } else {
            // The native loader itself understands the original Windows arguments.
            // Older GPTK shell wrappers do not expose this ABI and are rejected.
            guard !runtime.toolkitWrapper else { throw WayfarerError.message("This GPTK wrapper does not expose a compatible native display loader. Choose its Wine executable or CrossOver.") }
            result.executable = loader
            if command.executable.lastPathComponent == "arch" { result.arguments = Array(command.arguments.dropFirst(2)) }
        }
        return result
    }

    static func supportsIntelAdapter(_ file:URL) throws -> Bool {
        let handle=try FileHandle(forReadingFrom:file); defer { try? handle.close() }
        let bytes=[UInt8](try handle.read(upToCount:1024) ?? Data())
        guard bytes.count >= 8 else { return false }
        func number(_ offset:Int,little:Bool=false) -> UInt32 {
            let value=bytes[offset..<offset+4]
            return (little ? Array(value.reversed()) : Array(value)).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        }
        let intel:UInt32=0x01000007
        let magic=number(0)
        if magic == 0xcffaedfe { return number(4,little:true) == intel }
        if magic == 0xfeedfacf { return number(4) == intel }
        let little=[UInt32(0xbebafeca),0xbfbafeca].contains(magic)
        guard [UInt32(0xcafebabe),0xcafebabf,0xbebafeca,0xbfbafeca].contains(magic) else { return false }
        let count=Int(number(4,little:little)),stride=[UInt32(0xcafebabf),0xbfbafeca].contains(magic) ? 32 : 20
        guard count > 0,count <= 16,8 + count*stride <= bytes.count else { return false }
        return (0..<count).contains { number(8 + $0*stride,little:little) == intel }
    }
}
