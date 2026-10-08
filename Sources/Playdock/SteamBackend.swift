import AppKit
import CryptoKit
import Security
import PlaydockCore

/// Owns backend file I/O and command validation.
private actor SteamBackendStorage {
    private var directories = Set<URL>()

    private func directory(root: URL) throws -> URL {
        let key = root.resolvingSymlinksInPath().path
        let hash = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        let directory = AppPaths.support.appendingPathComponent("SteamBackend/\(hash)", isDirectory: true)
        if directories.contains(directory) { return directory }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard directory.resolvingSymlinksInPath().standardizedFileURL == directory.standardizedFileURL else {
            throw PlaydockError.message("Steam’s background presentation folder is redirected. Choose a local Playdock support folder.")
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        directories.insert(directory)
        return directory
    }

    func attached(tokens: [RuntimeProcessToken], root: URL, identity: String) -> Bool {
        guard let directory = try? directory(root: root) else { return false }
        return tokens.allSatisfy { token in
            guard RuntimeProcessIdentity.token(for: token.pid) == token,
                  let ready = try? String(contentsOf: directory.appendingPathComponent("\(token.pid).ready"), encoding: .utf8) else { return false }
            return ready == "\(token.startedSeconds):\(token.startedMicroseconds)\n\(identity)"
        }
    }

    func macCommand(arguments: [String], port: UInt16, adapter: URL) throws -> LaunchCommand {
        try Task.checkCancellation()
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Steam")
        let executable = root.appendingPathComponent("Steam.AppBundle/Steam/Contents/MacOS/steam_osx")
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw PlaydockError.message("Complete the macOS Steam installation before connecting its backend in Playdock.")
        }
        var code: SecStaticCode?, info: CFDictionary?
        guard SecStaticCodeCreateWithPath(executable as CFURL, [], &code) == errSecSuccess, let code,
              SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let flags = (info as? [String: Any])?[kSecCodeInfoFlags as String] as? UInt32, flags & 0x10000 == 0 else {
            throw PlaydockError.message("This Mac Steam build blocks Playdock’s background adapter.")
        }
        return LaunchCommand(executable: executable, arguments: ["-silent", "-cef-enable-debugging", "-devtools-port", String(port)] + arguments,
                             environment: ["PLAYDOCK_STEAM_BACKEND": try directory(root: root).path, "DYLD_INSERT_LIBRARIES": try SteamBridgeInjection.libraries(adapter: adapter)], workingDirectory: root)
    }
}

/// Main-actor presentation bridge; workers own file and runtime operations.
@MainActor
final class SteamBackend {
    private let storage = SteamBackendStorage()
    private var currentAdapterStamp: String?
    private var preparedAdapter: URL?
    private var preparedLoaders: [String: URL] = [:]

    func allAttached(_ apps: [NSRunningApplication], root: URL) async -> Bool {
        guard let identity = currentAdapterStamp else { return false }
        let tokens = apps.compactMap { RuntimeProcessIdentity.token(for: $0.processIdentifier) }
        guard tokens.count == apps.count else { return false }
        return await storage.attached(tokens: tokens, root: root, identity: identity)
    }
    func prepare(runtime: RuntimeInstallation? = nil) async throws {
        if preparedAdapter == nil {
            guard let source = Bundle.main.privateFrameworksURL?.appendingPathComponent("libPlaydockWineDisplay.dylib") else {
                throw PlaydockError.message("Steam’s background presentation adapter is missing from this build.")
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
            throw PlaydockError.message("The Windows engine is still being prepared. Retry the app when preparation finishes.")
        }
        return loader
    }
    func adapter() throws -> URL {
        guard let adapter = preparedAdapter else {
            throw PlaydockError.message("Steam’s background adapter is still being prepared. Reconnect Steam and try again.")
        }
        return adapter
    }
    func macCommand(arguments: [String], port: UInt16) async throws -> LaunchCommand {
        try await storage.macCommand(arguments: arguments, port: port, adapter: adapter())
    }
}
