import Foundation
import CryptoKit

public struct CachedSteamCatalog: Codable, Sendable {
    public let version: Int
    public let account: String
    public let root: String
    public let client: GamePlatform
    public let profileID: String?
    public let updatedAt: Date
    public let games: [SteamCatalogGame]
}

/// A remembered library is display metadata. Steam still verifies licenses and installations.
public struct SteamCatalogCache {
    public var directory: URL
    public init(directory: URL = AppPaths.support.appendingPathComponent("LibraryCache")) { self.directory = directory }

    public func load(account: String, root: URL, client: GamePlatform, profileID: String?) throws -> CachedSteamCatalog? {
        let file = location(account: account, root: root, client: client)
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        let size = (try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.intValue ?? 0
        guard size <= 16_000_000 else { throw WayfarerError.message("The saved Steam library is too large.") }
        let record = try JSONDecoder().decode(CachedSteamCatalog.self, from: Data(contentsOf: file))
        guard record.version == 1, record.account == account, record.root == root.resolvingSymlinksInPath().path,
              record.client == client, record.profileID == profileID, valid(record.games, client: client, profileID: profileID) else { return nil }
        return record
    }

    public func save(games: [SteamCatalogGame], account: String, root: URL, client: GamePlatform, profileID: String?, updatedAt: Date = Date()) throws {
        guard UInt64(account) != nil, valid(games, client: client, profileID: profileID) else { throw WayfarerError.message("Steam’s library cannot be cached for this account or environment.") }
        let record = CachedSteamCatalog(version: 1, account: account, root: root.resolvingSymlinksInPath().path,
                                        client: client, profileID: profileID, updatedAt: updatedAt, games: games)
        let data = try JSONEncoder().encode(record)
        guard data.count <= 16_000_000 else { throw WayfarerError.message("The Steam library is too large to cache.") }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let file = location(account: account, root: root, client: client)
        try data.write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    private func location(account: String, root: URL, client: GamePlatform) -> URL {
        let identity = account + "\n" + root.resolvingSymlinksInPath().path + "\n" + client.rawValue
        let hash = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(hash + ".json")
    }
    private func valid(_ games: [SteamCatalogGame], client: GamePlatform, profileID: String?) -> Bool {
        games.count <= 50_000 && games.allSatisfy { game in
            game.client == client && game.profileID == profileID && (try? NativeGameLaunch.steamURL(appID: game.appID)) != nil
        } && Set(games.map(\.appID)).count == games.count
    }
}
