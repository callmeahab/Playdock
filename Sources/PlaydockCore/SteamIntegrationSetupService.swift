import CryptoKit
import Foundation

public actor SteamIntegrationSetupService {
    private let helper: URL
    private let cache: URL
    private let resources: URL?
    private let processes = ProcessService()
    private var running = false
    private var launchResourcesVerified = false
    private struct Readiness {
        let client: RuntimeProcessToken?
        let revision: Int
        let crossOver: URL?
        let state: SteamIntegrationEnvironment
        let paths: [URL]
        let stamp: [String]
    }
    private var readiness: Readiness?
    public init(helper: URL, resources: URL? = Bundle.main.resourceURL?.appendingPathComponent("SteamBridge"), cache: URL = AppPaths.support.appendingPathComponent("BridgeSetup")) {
        self.helper = helper; self.resources = resources; self.cache = cache
    }
    public static var supportedSystem: Bool {
        #if arch(arm64)
        if #available(macOS 26, *) { return true }
        #endif
        return false
    }
    public func inspect(crossOver: URL? = nil) async throws -> SteamIntegrationEnvironment {
        guard !running else { throw PlaydockError.message("Setup is already running.") }
        readiness = nil
        running = true
        defer { running = false }
        return try await invoke("inspect", resources: nil, crossOver: crossOver, report: { _ in }).environment ?? SteamIntegrationEnvironment()
    }
    public func run(_ operation: SteamIntegrationOperation, crossOver: URL?, prepareMutation: @escaping @Sendable () async throws -> Void, report: @escaping @Sendable (SteamIntegrationProgress) async -> Void) async throws -> SteamIntegrationHelperResult {
        guard !running else { throw PlaydockError.message("Setup is already running.") }
        guard Self.supportedSystem else { throw PlaydockError.message("The Steam–CrossOver bridge requires Apple silicon and macOS 26 or later.") }
        running = true
        readiness = nil
        defer { running = false }
        let state = try await invoke("inspect", resources: nil, crossOver: crossOver, report: report).environment ?? SteamIntegrationEnvironment()
        if operation != .remove, !state.canSetUp(crossOver: crossOver?.path) {
            throw PlaydockError.message(state.problems.first ?? "Choose a supported and activated CrossOver installation.")
        }
        let canRestore = operation == .remove && state.recoveryAvailable
        let resources = canRestore ? nil : self.resources
        if !canRestore {
            guard let resources else { throw PlaydockError.message("This Playdock build is missing its bundled Steam bridge components. Rebuild or reinstall Playdock.") }
            await report(SteamIntegrationProgress("Verifying bundled Steam bridge components", canCancel: true))
            try Self.validateResources(resources)
        }
        if let resources { _ = try await invoke("validate-package", resources: resources, crossOver: nil, report: report) }
        try Task.checkCancellation()
        try await prepareMutation()
        try Task.checkCancellation()
        await report(SteamIntegrationProgress("Applying changes · Steam will reopen when finished", canCancel: false))
        return try await invoke(operation.rawValue, resources: resources, crossOver: crossOver, report: report)
    }

    public func ensureReady(client: RuntimeProcessToken?, revision: Int, crossOver: URL? = nil) async throws -> SteamIntegrationEnvironment {
        if let cached = readiness, cached.client == client, cached.revision == revision, cached.crossOver == crossOver,
           Self.fileStamp(cached.paths) == cached.stamp { return cached.state }
        let state = try await inspect(crossOver: crossOver)
        guard state.ready else { throw PlaydockError.message(state.problems.first ?? "Repair the Steam–CrossOver bridge before playing Windows games.") }
        try await updateLaunchSupport()
        let paths = readinessPaths(state)
        readiness = Readiness(client: client, revision: revision, crossOver: crossOver, state: state,
                              paths: paths, stamp: Self.fileStamp(paths))
        return state
    }

    static func fileStamp(_ paths: [URL]) -> [String] {
        paths.map { path in
            let a = try? FileManager.default.attributesOfItem(atPath: path.path)
            return [path.path, path.resolvingSymlinksInPath().path,
                    (a?[.systemFileNumber] as? NSNumber)?.stringValue ?? "missing",
                    (a?[.size] as? NSNumber)?.stringValue ?? "",
                    (a?[.posixPermissions] as? NSNumber)?.stringValue ?? "",
                    (a?[.modificationDate] as? Date)?.timeIntervalSince1970.description ?? ""].joined(separator: "\n")
        }
    }

    private func readinessPaths(_ state: SteamIntegrationEnvironment) -> [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let steam = home.appendingPathComponent("Library/Application Support/Steam")
        let support = home.appendingPathComponent("Library/Application Support/" + SteamIntegrationPaths.supportDirectoryName)
        let runner = SteamIntegrationPaths.currentRunner
        var paths = [helper, support.appendingPathComponent("transaction.json"), runner,
                     steam.appendingPathComponent("compatibilitytools.d/" + SteamIntegrationPaths.toolID),
                     steam.appendingPathComponent("compatibilitytools.d/" + SteamIntegrationPaths.toolID + "/run"),
                     URL(fileURLWithPath: "/Applications"), home.appendingPathComponent("Applications")]
        for name in ["Contents/Info.plist", "Contents/MacOS/" + SteamIntegrationPaths.dylibName] {
            paths.append(URL(fileURLWithPath: "/Applications/Steam.app").appendingPathComponent(name))
        }
        for name in ["steam_client_signed-2_osx.manifest", "steam_client_signed_osx.manifest", "steam_client_osx.manifest"] {
            paths.append(steam.appendingPathComponent("Steam.AppBundle/Steam/Contents/MacOS/package/" + name))
        }
        for directory in [support.appendingPathComponent("bridge"), resources].compactMap({ $0 }) {
            paths.append(directory)
            if let files = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil) {
                paths += files.compactMap { $0 as? URL }
            }
        }
        for root in [runner] + state.crossOver.map({ URL(fileURLWithPath: $0.path).appendingPathComponent("Contents/SharedSupport/CrossOver") }) {
            for name in ["etc/crossover.conf", "share/crossover/data/tie.pub", "bin/wineserver", "bin/wineserver-arm64", "bin/wineserver-x86"] {
                paths.append(root.appendingPathComponent(name))
            }
            for arch in ["aarch64-windows", "x86_64-windows", "i386-windows"] {
                for name in ["ntdll.dll", "lsteamclient.dll"] { paths.append(root.appendingPathComponent("lib/wine/\(arch)/\(name)")) }
            }
            for arch in ["aarch64-unix", "x86_64-unix"] {
                for name in ["wine", "ntdll.so", "lsteamclient.so", "wine.app/Contents/MacOS/wine", "wine.app/Contents/_CodeSignature/CodeResources"] {
                    paths.append(root.appendingPathComponent("lib/wine/\(arch)/\(name)"))
                }
            }
        }
        for directory in [home.appendingPathComponent("Library/Preferences"), URL(fileURLWithPath: "/Library/Preferences")] {
            for ext in ["license", "sha256", "sig"] { paths.append(directory.appendingPathComponent("com.codeweavers.CrossOver." + ext)) }
        }
        for install in state.crossOver { paths.append(URL(fileURLWithPath: install.path).appendingPathComponent("Contents/Info.plist")) }
        return paths
    }

    public func updateLaunchSupport() async throws {
        guard !running else { throw PlaydockError.message("Setup is already running.") }
        guard let resources else { throw PlaydockError.message("Playdock's bundled Steam launch helpers are missing. Reinstall Playdock.") }
        running = true
        defer { running = false }
        if !launchResourcesVerified {
            try Self.validateResources(resources)
            launchResourcesVerified = true
        }
        try Task.checkCancellation()
        _ = try await invoke("update-launch-support", resources: resources, crossOver: nil, report: { _ in })
    }

    public static func validateResources(_ root: URL) throws {
        let files = FileManager.default, canonical = root.resolvingSymlinksInPath().standardizedFileURL
        let manifest = root.appendingPathComponent("release.json")
        guard try digest(manifest) == SteamIntegrationRelease.resourceManifestSHA256 else {
            throw PlaydockError.message("Playdock's bundled bridge manifest failed verification. Rebuild or reinstall Playdock.")
        }
        struct Component: Decodable { let sha256: String; let bytes: UInt64 }
        struct Manifest: Decodable { let files: [String: Component]; let compiled: [String] }
        struct Build: Decodable { let files: [String: Component] }
        let expected = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: manifest))
        let buildFile = root.appendingPathComponent("build.json")
        guard let size = (try files.attributesOfItem(atPath: buildFile.path)[.size] as? NSNumber)?.intValue,
              size < 32_768 else { throw CocoaError(.fileReadCorruptFile) }
        let built = try JSONDecoder().decode(Build.self, from: Data(contentsOf: buildFile))
        guard Set(built.files.keys) == Set(expected.compiled) else { throw CocoaError(.fileReadCorruptFile) }
        // Build-generated hashes are sealed by the app signature, since compiler output varies by toolchain.
        let app = root.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        guard app.pathExtension == "app", root.standardizedFileURL.path == app.appendingPathComponent("Contents/Resources/SteamBridge").standardizedFileURL.path else {
            throw PlaydockError.message("The Steam integration must come from a signed Playdock app bundle.")
        }
        let verification = Process()
        verification.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        verification.arguments = ["--verify", "--deep", "--strict", app.path]
        verification.standardOutput = FileHandle.nullDevice
        verification.standardError = FileHandle.nullDevice
        try verification.run(); verification.waitUntilExit()
        guard verification.terminationStatus == 0 else {
            throw PlaydockError.message("Playdock's app signature failed verification. Rebuild or reinstall Playdock.")
        }
        for (name, component) in expected.files.merging(built.files, uniquingKeysWith: { original, _ in original }) {
            let file = root.appendingPathComponent(name)
            guard file.resolvingSymlinksInPath().path.hasPrefix(canonical.path + "/"),
                  let attributes = try? files.attributesOfItem(atPath: file.path), attributes[.type] as? FileAttributeType == .typeRegular,
                  (attributes[.size] as? NSNumber)?.uint64Value == component.bytes, try digest(file) == component.sha256 else {
                throw PlaydockError.message("Playdock's bundled bridge component \(name) failed verification. Rebuild or reinstall Playdock.")
            }
        }
        guard let walker = files.enumerator(at: root, includingPropertiesForKeys: [.isSymbolicLinkKey, .fileSizeKey]) else { throw CocoaError(.fileReadCorruptFile) }
        var count = 0
        for case let file as URL in walker {
            count += 1
            guard count < 500, file.resolvingSymlinksInPath().path.hasPrefix(canonical.path + "/") else { throw CocoaError(.fileReadCorruptFile) }
        }
    }
    private static func digest(_ file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hash = SHA256()
        while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty { hash.update(data: chunk) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
    private func invoke(_ operation: String, resources: URL?, crossOver: URL?, report: @escaping @Sendable (SteamIntegrationProgress) async -> Void) async throws -> SteamIntegrationHelperResult {
        guard FileManager.default.isExecutableFile(atPath: helper.path) else { throw PlaydockError.message("The bridge setup helper is missing. Reinstall Playdock.") }
        let run = cache.appendingPathComponent("run-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: run, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: run) }
        let request = SteamIntegrationHelperRequest(operation: operation, resources: resources?.path, crossOver: crossOver?.path,
            output: run.appendingPathComponent("result.json").path, progress: run.appendingPathComponent("progress.json").path)
        let input = run.appendingPathComponent("request.json")
        try JSONEncoder().encode(request).write(to: input, options: .atomic)
        let environment = resources.map { ["PLAYDOCK_STEAM_INTEGRATION_RESOURCES": $0.path] } ?? [:]
        let receipt = try await processes.start(LaunchCommand(executable: helper, arguments: [input.path], environment: environment), id: UUID(), logsDirectory: cache.appendingPathComponent("logs"))
        let wait = Task { try await processes.wait(receipt.id) }
        var previous: SteamIntegrationProgress?
        while !FileManager.default.fileExists(atPath: request.output) {
            if let data = try? Data(contentsOf: URL(fileURLWithPath: request.progress)), data.count < 16_384,
               let progress = try? JSONDecoder().decode(SteamIntegrationProgress.self, from: data), progress != previous {
                previous = progress; await report(progress)
            }
            // Operations which change files finish their recovery before returning, even if the sheet closes.
            if (operation == "inspect" || operation == "validate-package") && Task.isCancelled {
                await processes.terminate(receipt.id); _ = try? await wait.value; throw CancellationError()
            }
            if kill(receipt.pid, 0) != 0 { break }
            await Task.detached { try? await Task.sleep(for: .milliseconds(200)) }.value
        }
        let code = try await wait.value
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: request.output)), data.count < 256_000,
              let result = try? JSONDecoder().decode(SteamIntegrationHelperResult.self, from: data) else {
            throw PlaydockError.message("Bridge setup stopped unexpectedly. Use Repair integration to recover; details are in \(receipt.logURL.path).")
        }
        if let error = result.error { throw PlaydockError.message(error) }
        guard code == 0 else { throw PlaydockError.message("Bridge setup did not finish successfully.") }
        return result
    }
}
