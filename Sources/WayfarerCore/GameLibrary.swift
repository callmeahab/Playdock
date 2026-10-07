import Foundation

public enum GameInstallation: Hashable, Sendable {
    case macSteam(SteamGame)
    case windowsSteam(SteamGame, profileID: String)
    case added(AddedGame)

    public var platform: GamePlatform {
        switch self {
        case .macSteam: return .macOS
        case .windowsSteam: return .windows
        case .added(let game): return game.effectivePlatform
        }
    }
    public var name: String {
        switch self { case .macSteam(let game), .windowsSteam(let game, _): return game.name; case .added(let game): return game.name }
    }
    public var artwork: URL? {
        switch self { case .macSteam(let game), .windowsSteam(let game, _): return game.artwork; case .added: return nil }
    }
    public var heroArtwork: URL? {
        switch self { case .macSteam(let game), .windowsSteam(let game, _): return game.heroArtwork; case .added: return nil }
    }
    public var lastPlayed: TimeInterval {
        switch self { case .macSteam(let game), .windowsSteam(let game, _): return game.lastPlayed; case .added(let game): return game.lastPlayed ?? 0 }
    }
    public var location: URL {
        switch self {
        case .macSteam(let game), .windowsSteam(let game, _): return game.installDirectory ?? game.library
        case .added(let game): return game.executable
        }
    }
    public var steamGame: SteamGame? {
        switch self { case .macSteam(let game), .windowsSteam(let game, _): return game; case .added: return nil }
    }
}

public struct LibraryGame: Identifiable, Hashable, Sendable {
    public var id: String
    public var installations: [GameInstallation]
    public var availableVersions: [SteamCatalogGame] = []
    /// Native first, without changing the user's Windows environment selection.
    public var preferredInstallation: GameInstallation? { installation(for: .macOS) ?? installations.first }
    public func installation(for platform: GamePlatform) -> GameInstallation? { installations.first { $0.platform == platform } }
    public var preferredPlatform: GamePlatform? {
        if installation(for: .macOS) != nil || offer(for: .macOS) != nil { return .macOS }
        return preferredInstallation?.platform ?? availableVersions.first?.client
    }
    public func offer(for platform: GamePlatform) -> SteamCatalogGame? { availableVersions.first { $0.client == platform } }
    public var isInstalled: Bool { !installations.isEmpty }
    public func unavailableOffline(for platform: GamePlatform) -> Bool {
        installation(for: platform) == nil && offer(for: platform) != nil
    }
    public var name: String { preferredInstallation?.name ?? availableVersions.first?.name ?? "Game" }
    public var artwork: URL? { preferredInstallation?.artwork ?? installations.compactMap(\.artwork).first ?? availableVersions.compactMap(\.artwork).first }
    public var heroArtwork: URL? { preferredInstallation?.heroArtwork ?? installations.compactMap(\.heroArtwork).first ?? availableVersions.compactMap(\.heroArtwork).first ?? artwork }
    public var platforms: [GamePlatform] { GamePlatform.allCases.filter { platform in installations.contains { $0.platform == platform } || availableVersions.contains { $0.client == platform } } }
    public var lastPlayed: TimeInterval { installations.map(\.lastPlayed).max() ?? 0 }
    public var isSteam: Bool { id.hasPrefix("steam:") }
}

/// Immutable inputs let a background worker prepare one display snapshot per
/// library change. Rendering and navigation never merge or sort source data.
public struct GameLibraryInput: Equatable, Sendable {
    public var mac: [SteamGame]
    public var windows: [SteamGame]
    public var profileID: String?
    public var added: [AddedGame]
    public var catalog: [SteamCatalogGame]
    public var hidden: Set<String>
    public var favorites: Set<String>
    public var recent: [String: Date]

    public init(mac: [SteamGame], windows: [SteamGame], profileID: String?, added: [AddedGame], catalog: [SteamCatalogGame], hidden: Set<String>, favorites: Set<String>, recent: [String: Date]) {
        self.mac = mac; self.windows = windows; self.profileID = profileID
        self.added = added; self.catalog = catalog; self.hidden = hidden
        self.favorites = favorites; self.recent = recent
    }
}

public struct GameLibraryPresentation: Equatable, Sendable {
    public var library: [LibraryGame]
    public var visible: [LibraryGame]
    public var quick: [LibraryGame]
    public var favoriteCount: Int
    public var platformCounts: [GamePlatform: Int]
    public static let empty = Self(library: [], visible: [], quick: [], favoriteCount: 0, platformCounts: [:])

    public static func build(_ input: GameLibraryInput) -> Self {
        let library = GameLibrary.merge(mac: input.mac, windows: input.windows, profileID: input.profileID, added: input.added, catalog: input.catalog)
        let visible = library.filter { !input.hidden.contains($0.id) }
        // Resolve title and history once, rather than looking them up in each
        // comparison of the sort.
        let quick = visible.map { game in
            (game: game, favorite: input.favorites.contains(game.id), recent: input.recent[game.id] ?? Date(timeIntervalSince1970: game.lastPlayed), name: game.name)
        }.sorted {
            if $0.favorite != $1.favorite { return $0.favorite }
            if $0.recent != $1.recent { return $0.recent > $1.recent }
            let order = $0.name.localizedCaseInsensitiveCompare($1.name)
            return order == .orderedSame ? $0.game.id < $1.game.id : order == .orderedAscending
        }.map(\.game)
        return Self(library: library, visible: visible, quick: quick,
                    favoriteCount: library.filter { input.favorites.contains($0.id) }.count,
                    platformCounts: Dictionary(uniqueKeysWithValues: GamePlatform.allCases.map { platform in
                        (platform, library.filter { $0.platforms.contains(platform) }.count)
                    }))
    }
}

public enum GameLibrary {
    public static func merge(mac: [SteamGame], windows: [SteamGame], profileID: String?, added: [AddedGame], catalog: [SteamCatalogGame] = []) -> [LibraryGame] {
        var entries: [String: LibraryGame] = [:]
        func append(_ installation: GameInstallation, id: String) {
            if entries[id] == nil { entries[id] = LibraryGame(id: id, installations: []) }
            if entries[id]?.installations.contains(installation) == false { entries[id]?.installations.append(installation) }
        }
        for game in mac { append(.macSteam(game), id: "steam:\(game.appID)") }
        if let profileID {
            for game in windows { append(.windowsSteam(game, profileID: profileID), id: "steam:\(game.appID)") }
        }
        for game in added where game.effectivePlatform == .macOS || game.profileID == profileID {
            append(.added(game), id: "added:\(game.id.uuidString)")
        }
        for offer in catalog where offer.client == .macOS || (profileID != nil && offer.profileID == profileID) {
            guard (try? NativeGameLaunch.steamURL(appID: offer.appID)) != nil else { continue }
            let id = "steam:\(offer.appID)"
            if entries[id] == nil { entries[id] = LibraryGame(id: id, installations: []) }
            if entries[id]?.availableVersions.contains(offer) == false { entries[id]?.availableVersions.append(offer) }
        }
        return entries.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

public enum NativeGameLaunch {
    public static func steamURL(appID: String) throws -> URL {
        guard !appID.isEmpty, appID.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }),
              let number = UInt32(appID), number > 0, let url = URL(string: "steam://rungameid/\(number)") else {
            throw WayfarerError.message("The game has an invalid Steam identifier.")
        }
        return url
    }

    public static func steamInstallURL(appID: String) throws -> URL {
        let play = try steamURL(appID: appID)
        return URL(string: play.absoluteString.replacingOccurrences(of: "rungameid", with: "install"))!
    }

    public static func validateApplication(_ url: URL) throws {
        guard url.pathExtension.lowercased() == "app", let bundle = Bundle(url: url),
              let executable = bundle.executableURL, FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw WayfarerError.message("Choose an installed Mac game application (.app).")
        }
    }
}
