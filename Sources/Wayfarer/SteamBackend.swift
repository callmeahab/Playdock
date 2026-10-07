import AppKit
import CryptoKit
import Security
import WayfarerCore

/// Owns backend files and command validation. No filesystem work runs in the
/// presentation bridge below, including when a Steam panel becomes active.
private actor SteamBackendStorage {
    private var directories = Set<URL>()
    private var presentations: [URL: Data] = [:]

    private func directory(root: URL, prefix: URL?) throws -> URL {
        let key = (prefix ?? root).resolvingSymlinksInPath().path
        let hash = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        let directory = AppPaths.support.appendingPathComponent("SteamBackend/\(hash)", isDirectory: true)
        if directories.contains(directory) { return directory }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard directory.resolvingSymlinksInPath().standardizedFileURL == directory.standardizedFileURL else {
            throw WayfarerError.message("Steam’s background presentation folder is redirected. Choose a local Wayfarer support folder.")
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        try Data("{}".utf8).write(to: directory.appendingPathComponent("presentation.json"), options: .atomic)
        directories.insert(directory)
        return directory
    }

    func attached(tokens: [RuntimeProcessToken], root: URL, prefix: URL?, identity: String) -> Bool {
        guard let directory = try? directory(root: root, prefix: prefix) else { return false }
        return tokens.allSatisfy { token in
            guard RuntimeProcessIdentity.token(for: token.pid) == token,
                  let ready = try? String(contentsOf: directory.appendingPathComponent("\(token.pid).ready"), encoding: .utf8) else { return false }
            return ready == "\(token.startedSeconds):\(token.startedMicroseconds)\n\(identity)"
        }
    }

    func present(root: URL, prefix: URL?, data: Data) {
        guard let directory = try? directory(root: root, prefix: prefix), presentations[directory] != data else { return }
        do {
            try data.write(to: directory.appendingPathComponent("presentation.json"), options: .atomic)
            presentations[directory] = data
        } catch { }
    }
    func hideAll() {
        for directory in directories {
            try? Data("{}".utf8).write(to: directory.appendingPathComponent("presentation.json"), options: .atomic)
        }
        presentations.removeAll()
    }
    func attach(_ command: LaunchCommand, profile: RuntimeProfile, loader: URL, adapter: URL) throws -> LaunchCommand {
        try Task.checkCancellation()
        guard let steam = profile.steamExecutable else { throw WayfarerError.message("Steam is missing from this environment.") }
        return try NativeRuntime.attachSteamBackend(command, runtime: profile.runtime, loader: loader, adapter: adapter,
                                                    directory: directory(root: steam.deletingLastPathComponent(), prefix: profile.prefix))
    }
    func macCommand(arguments: [String], port: UInt16, adapter: URL) throws -> LaunchCommand {
        try Task.checkCancellation()
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Steam")
        let executable = root.appendingPathComponent("Steam.AppBundle/Steam/Contents/MacOS/steam_osx")
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw WayfarerError.message("Complete the macOS Steam installation before connecting its backend in Wayfarer.")
        }
        var code: SecStaticCode?, info: CFDictionary?
        guard SecStaticCodeCreateWithPath(executable as CFURL, [], &code) == errSecSuccess, let code,
              SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let flags = (info as? [String: Any])?[kSecCodeInfoFlags as String] as? UInt32, flags & 0x10000 == 0 else {
            throw WayfarerError.message("This Mac Steam build blocks Wayfarer’s background adapter.")
        }
        return LaunchCommand(executable: executable, arguments: ["-silent", "-cef-enable-debugging", "-devtools-port", String(port)] + arguments,
                             environment: ["WAYFARER_STEAM_BACKEND": try directory(root: root, prefix: nil).path, "DYLD_INSERT_LIBRARIES": adapter.path], workingDirectory: root)
    }
}

/// AppKit window identity is captured on the main actor; file and runtime work
/// is owned by actors and awaited without blocking event handling.
@MainActor
final class SteamBackend {
    private let storage = SteamBackendStorage()
    private var currentAdapterStamp: String?
    private var preparedAdapter: URL?
    private var preparedLoaders: [String: URL] = [:]

    func allAttached(_ apps: [NSRunningApplication], root: URL, prefix: URL?) async -> Bool {
        guard let identity = currentAdapterStamp else { return false }
        let tokens = apps.compactMap { RuntimeProcessIdentity.token(for: $0.processIdentifier) }
        guard tokens.count == apps.count else { return false }
        return await storage.attached(tokens: tokens, root: root, prefix: prefix, identity: identity)
    }
    func present(root: URL, prefix: URL?, in window: NSWindow?) {
        var state: [String: Any] = [:]
        if let window, let token = RuntimeProcessIdentity.token(for: getpid()) {
            state = ["window": window.windowNumber, "pid": token.pid, "seconds": token.startedSeconds, "microseconds": token.startedMicroseconds]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: state, options: [.sortedKeys]) else { return }
        Task { await storage.present(root: root, prefix: prefix, data: data) }
    }
    func hideAll() async { await storage.hideAll() }
    func prepare(runtime: RuntimeInstallation? = nil) async throws {
        if preparedAdapter == nil {
            guard let source = Bundle.main.privateFrameworksURL?.appendingPathComponent("libWayfarerWineDisplay.dylib") else {
                throw WayfarerError.message("Steam’s background presentation adapter is missing from this build.")
            }
            let result = try await RuntimePreparationService.shared.adapter(source: source)
            preparedAdapter = result.file; currentAdapterStamp = result.identity
        }
        if let runtime, preparedLoaders[runtime.id] == nil {
            preparedLoaders[runtime.id] = try await RuntimePreparationService.shared.loader(runtime: runtime)
        }
        try Task.checkCancellation()
    }
    func loader(for runtime: RuntimeInstallation) throws -> URL {
        guard let loader = preparedLoaders[runtime.id] else {
            throw WayfarerError.message("The Windows engine is still being prepared. Reconnect Steam and try again.")
        }
        return loader
    }
    func adapter() throws -> URL {
        guard let adapter = preparedAdapter else {
            throw WayfarerError.message("Steam’s background adapter is still being prepared. Reconnect Steam and try again.")
        }
        return adapter
    }
    func attach(_ command: LaunchCommand, profile: RuntimeProfile) async throws -> LaunchCommand {
        try await storage.attach(command, profile: profile, loader: loader(for: profile.runtime), adapter: adapter())
    }
    func macCommand(arguments: [String], port: UInt16) async throws -> LaunchCommand {
        try await storage.macCommand(arguments: arguments, port: port, adapter: adapter())
    }
}
