import Foundation
import CryptoKit
import Darwin

public struct SteamLibraryAccountSnapshot: Sendable {
    public let client: GamePlatform
    public let root: URL
    public let profileID: String?
    public let account: String?
    public let saved: CachedSteamCatalog?
    public let installed: CachedSteamInstallations?
}

/// Platform scans of the shared Mac Steam library publish immutable snapshots.
public actor SteamLibraryService {
    private let client: GamePlatform
    private let catalogCache: SteamCatalogCache
    private let installationCache: SteamInstallationCache

    public init(client: GamePlatform, catalogCache: SteamCatalogCache = SteamCatalogCache(), installationCache: SteamInstallationCache = SteamInstallationCache()) {
        self.client = client; self.catalogCache = catalogCache; self.installationCache = installationCache
    }

    public func account(root: URL, profileID: String?, includeInstalled: Bool = false) -> SteamLibraryAccountSnapshot {
        let account = SteamCatalog.recentAccount(root: root)
        let saved = account.flatMap { try? catalogCache.load(account: $0, root: root, client: client, profileID: profileID) }
        let installed = includeInstalled ? try? installationCache.load(account: account, root: root, client: client, profileID: profileID) : nil
        let current = SteamCatalog.recentAccount(root: root)
        return SteamLibraryAccountSnapshot(client: client, root: root, profileID: profileID, account: current,
                                           saved: current == account ? saved : nil, installed: current == account ? installed : nil)
    }

    public func currentAccount(root: URL) -> String? { SteamCatalog.recentAccount(root: root) }
    public func refreshResponse(command: LaunchCommand, root: URL, nonce: UUID) async throws -> String {
        try await SteamCatalog.refreshResponse(command: command, root: root, nonce: nonce)
    }

    public nonisolated func updates(root: URL) -> AsyncStream<SteamLibraryScan> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let worker = Task(priority: .userInitiated) { await self.stream(root: root, into: continuation) }
            continuation.onTermination = { @Sendable _ in worker.cancel() }
        }
    }

    private func stream(root: URL, into continuation: AsyncStream<SteamLibraryScan>.Continuation) {
        defer { continuation.finish() }
        guard !Task.isCancelled else { return }
        let result = scan(root: root) { continuation.yield($0) }
        if !Task.isCancelled { continuation.yield(result) }
    }

    public func scan(root: URL, onProgress: (@Sendable (SteamLibraryScan) -> Void)? = nil) -> SteamLibraryScan {
        if !FileManager.default.fileExists(atPath: root.appendingPathComponent("steamapps").path) {
            return SteamLibraryScan(games: [], warnings: [])
        }
        return SteamLibrary.scan(root: root, client: client, onProgress: onProgress)
    }

    public func saveInstallations(_ scan: SteamLibraryScan, account: String?, root: URL, profileID: String?) throws {
        try Task.checkCancellation()
        guard scan.warnings.isEmpty, SteamCatalog.recentAccount(root: root) == account else { return }
        try installationCache.save(games: scan.games, account: account, root: root, client: client, profileID: profileID)
    }

    public func scanAndSave(root: URL, profileID: String?) -> SteamLibraryScan {
        let account = SteamCatalog.recentAccount(root: root)
        let result = scan(root: root)
        try? saveInstallations(result, account: account, root: root, profileID: profileID)
        return result
    }

    public func catalog(owned: [String]?, response: String?, root: URL, profileID: String?) throws -> SteamCatalogSnapshot {
        try Task.checkCancellation()
        if let owned { return try SteamCatalog.snapshot(ownedAppIDs: owned, root: root, client: client, profileID: profileID) }
        guard let response else { throw WayfarerError.message("Steam did not return its library.") }
        return try SteamCatalog.snapshot(response: response, root: root, client: client, profileID: profileID)
    }

    public func saveCatalog(games: [SteamCatalogGame], account: String, root: URL, profileID: String?) throws {
        try Task.checkCancellation()
        guard SteamCatalog.recentAccount(root: root) == account else { throw WayfarerError.message("The Steam account changed while saving its library.") }
        try catalogCache.save(games: games, account: account, root: root, client: client, profileID: profileID)
    }
}

/// Caches prepared library snapshots separately from disk scans.
public actor LibraryPresentationService {
    private var input: GameLibraryInput?
    private var presentation = GameLibraryPresentation.empty
    public init() {}
    public func prepare(_ input: GameLibraryInput) throws -> GameLibraryPresentation {
        try Task.checkCancellation()
        if self.input != input {
            presentation = GameLibraryPresentation.build(input)
            self.input = input
        }
        return presentation
    }
}

public struct RuntimeDiscoverySnapshot: Sendable {
    public let runtimes: [RuntimeInstallation]
    public let profiles: [RuntimeProfile]
    public let automaticProfileID: String?
    public let fingerprints: [String: String]
    public let macSteamClient: URL?
}

public actor RuntimeService {
    public init() {}
    public func discover(custom: [RuntimeProfile]) -> RuntimeDiscoverySnapshot {
        let discovery = RuntimeDiscovery()
        var runtimes = discovery.installations()
        for entry in custom where !runtimes.contains(where: { $0.id == entry.runtime.id }) { runtimes.append(entry.runtime) }
        let profiles = discovery.profiles(for: runtimes)
        return RuntimeDiscoverySnapshot(runtimes: runtimes, profiles: profiles,
                                        automaticProfileID: RuntimeDiscovery.preferredProfile(profiles, selectedID: nil)?.id,
                                        fingerprints: Dictionary(uniqueKeysWithValues: profiles.map { ($0.id, CompatibilityTest.fingerprint($0)) }),
                                        macSteamClient: macSteamClient())
    }
    public func fingerprint(_ profile: RuntimeProfile) -> String { CompatibilityTest.fingerprint(profile) }
    private func macSteamClient() -> URL? {
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Steam")
        let candidates = [URL(fileURLWithPath: "/Applications/Steam.app"), FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/Steam.app"), root.appendingPathComponent("Steam.AppBundle/Steam")]
        return candidates.first { Bundle(url: $0)?.bundleIdentifier == "com.valvesoftware.steam" }
    }
    public func launch(profile: RuntimeProfile, program: URL, arguments: [String] = []) throws -> LaunchCommand {
        try CommandBuilder.launch(profile: profile, program: program, arguments: arguments)
    }
    public func prepareNewProfile(_ profile: RuntimeProfile) throws -> LaunchCommand? { try CommandBuilder.prepareNewProfile(profile) }
    public func stopOwnedEnvironment(_ profile: RuntimeProfile) throws { try NativeRuntime.stopOwnedEnvironment(profile) }
    public func createDirectory(_ url: URL) throws { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
}

public struct PreparedAdapter: Sendable {
    public let file: URL
    public let identity: String
}

/// Serialize preparation so launches share immutable runtime copies.
public actor RuntimePreparationService {
    public static let shared = RuntimePreparationService()
    private var adapters: [URL: PreparedAdapter] = [:]
    private var loaders: [String: URL] = [:]
    public init() {}
    public func adapter(source: URL) throws -> PreparedAdapter {
        try Task.checkCancellation()
        if let prepared = adapters[source] { return prepared }
        let file = try NativeRuntime.prepareAdapter(source: source)
        let hash = SHA256.hash(data: try Data(contentsOf: file)).map { String(format: "%02x", $0) }.joined()
        let prepared = PreparedAdapter(file: file, identity: file.path + "\n" + hash)
        adapters[source] = prepared
        return prepared
    }
    public func loader(runtime: RuntimeInstallation) throws -> URL {
        try Task.checkCancellation()
        if let loader = loaders[runtime.id] { return loader }
        let loader = try NativeRuntime.prepare(runtime: runtime)
        loaders[runtime.id] = loader
        return loader
    }
    public func attachDisplay(_ command: LaunchCommand, runtime: RuntimeInstallation, loader: URL, adapter: URL, endpoint: NativeDisplayEndpoint) throws -> LaunchCommand {
        try NativeRuntime.attach(command, runtime: runtime, loader: loader, adapter: adapter, socket: endpoint.socketPath, token: endpoint.token)
    }
}

public actor ConfigurationService {
    private let store: ConfigurationStore
    private var savedRevision = 0
    public init(store: ConfigurationStore = ConfigurationStore()) { self.store = store }
    public func load() throws -> LauncherConfiguration { try store.load() }
    public func save(_ configuration: LauncherConfiguration, revision: Int) throws {
        guard revision > savedRevision else { return }
        try store.save(configuration)
        savedRevision = revision
    }
}

public actor SaveService {
    private let store = SaveBackupStore()
    public init() {}
    public func list(gameID: String) throws -> [SaveBackup] { try store.list(gameID: gameID) }
    public func suggestedFolder(root: URL, account: String?, appID: String) -> URL? {
        guard let account, let id = UInt64(account), id >= 76561197960265728,
              (try? NativeGameLaunch.steamURL(appID: appID)) != nil else { return nil }
        let folder = root.appendingPathComponent("userdata/\(id - 76561197960265728)/\(appID)/remote")
        return (try? SaveBackupStore.validateFolder(folder)) == nil ? nil : folder
    }
    public func create(gameID: String, name: String, folders: [URL]) throws -> SaveBackup {
        try Task.checkCancellation()
        return try store.create(gameID: gameID, name: name, folders: folders)
    }
    public func restore(_ backup: SaveBackup) throws {
        try Task.checkCancellation()
        _ = try store.restore(backup)
    }
}

public actor AchievementService {
    private let cache = AchievementCache()
    public init() {}
    public func load(scope: String, appID: String) throws -> AchievementSnapshot? { try cache.load(scope: scope, appID: appID) }
    public func save(_ snapshot: AchievementSnapshot) throws { try cache.save(snapshot) }
}
