import Foundation

public struct GamePreferences: Codable, Equatable, Sendable {
    public var preferredPlatform: GamePlatform?
    public var environmentID: String?
    public var launchOptions = ""
    public var tags: [String] = []
    public var hidden = false
    public var collectionIDs: Set<String> = []
    public var saveFolders: [String: [URL]] = [:]
    public var performance: GamePerformanceProfile?
    public var effectivePerformance: GamePerformanceProfile { performance ?? GamePerformanceProfile() }
    public init() {}
    public func arguments() throws -> [String] {
        guard launchOptions.utf8.count <= 8192, !launchOptions.contains("\0") else { throw WayfarerError.message("Launch options are too long or contain an invalid character.") }
        return try ArgumentParser.parse(launchOptions)
    }
}

public enum CollectionRule: String, Codable, CaseIterable, Sendable {
    case manual, installed, mac, windows, recent, favorites, tag
    public var title: String {
        switch self { case .manual: return "Manual collection"; case .installed: return "Installed games"; case .mac: return "Mac games"; case .windows: return "Windows games"; case .recent: return "Played in the last 14 days"; case .favorites: return "Favorites"; case .tag: return "Games with a tag" }
    }
}
public struct GameCollection: Codable, Identifiable, Equatable, Sendable {
    public var id: String = UUID().uuidString
    public var name: String
    public var parentID: String?
    public var rule: CollectionRule
    public var tag = ""
    public init(name: String, parentID: String? = nil, rule: CollectionRule = .manual) { self.name = name; self.parentID = parentID; self.rule = rule }
    public func matches(_ game: LibraryGame, preferences: GamePreferences, favorites: Set<String>, now: Date = Date()) -> Bool {
        switch rule {
        case .manual: return preferences.collectionIDs.contains(id)
        case .installed: return game.isInstalled
        case .mac: return game.platforms.contains(.macOS)
        case .windows: return game.platforms.contains(.windows)
        case .recent: return game.lastPlayed > 0 && now.timeIntervalSince1970 - game.lastPlayed < 14 * 86400
        case .favorites: return favorites.contains(game.id)
        case .tag: return !tag.isEmpty && preferences.tags.contains { $0.localizedCaseInsensitiveCompare(tag) == .orderedSame }
        }
    }
    public static func descendants(of id: String, in collections: [GameCollection]) -> Set<String> {
        var result: Set<String> = [id]
        while true { let count = result.count; for item in collections where item.parentID.map(result.contains) == true { result.insert(item.id) }; if result.count == count { return result } }
    }
    public static func validate(_ collection: GameCollection, in collections: [GameCollection]) throws {
        guard !collection.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, collection.name.count <= 80 else { throw WayfarerError.message("Give the collection a name of up to 80 characters.") }
        if let parent = collection.parentID {
            guard collections.contains(where: { $0.id == parent }), !descendants(of: collection.id, in: collections).contains(parent) else { throw WayfarerError.message("Choose a parent folder outside this collection.") }
        }
    }
}

public struct DownloadPolicy: Codable, Equatable, Sendable {
    public var enabled = false
    public var startHour = 22
    public var endHour = 7
    /// Steam's setting is in kilobytes per second. Zero is unlimited.
    public var bandwidthKBps = 0
    public var priorityAppIDs: [String] = []
    public init() {}
    public func validate() throws {
        guard (0..<24).contains(startHour), (0..<24).contains(endHour), (0...1_000_000).contains(bandwidthKBps), startHour != endHour || !enabled else { throw WayfarerError.message("Choose different start and end hours and a valid bandwidth limit.") }
    }
    public func allows(_ date: Date, calendar: Calendar = .current) -> Bool {
        guard enabled else { return true }
        let hour = calendar.component(.hour, from: date)
        return startHour < endHour ? hour >= startHour && hour < endHour : hour >= startHour || hour < endHour
    }
    public func ordered(_ appIDs: [String]) -> [String] {
        let priority = priorityAppIDs.filter { appIDs.contains($0) }
        return Array(NSOrderedSet(array: priority + appIDs)) as? [String] ?? appIDs
    }
}

public struct LaunchDiagnostic: Codable, Identifiable, Sendable {
    public var id = UUID()
    public var date = Date()
    public var gameID: String
    public var name: String
    public var platform: GamePlatform
    public var environment: String
    public var outcome: String
    public init(gameID: String, name: String, platform: GamePlatform, environment: String, outcome: String) { self.gameID = gameID; self.name = name; self.platform = platform; self.environment = environment; self.outcome = outcome }
}
