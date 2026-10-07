import Foundation

public enum GamePlatform: String, Codable, CaseIterable, Sendable {
    case macOS, windows
    public var name: String { self == .macOS ? "Mac" : "Windows" }
}

public enum RuntimeKind: String, Codable, CaseIterable, Sendable {
    case crossOver, gptk, wine

    public var name: String {
        switch self {
        case .crossOver: return "CrossOver"
        case .gptk: return "Game Porting Toolkit"
        case .wine: return "Wine"
        }
    }

    public var setupURL: URL {
        switch self {
        case .crossOver: return URL(string: "https://www.codeweavers.com/crossover")!
        case .gptk: return URL(string: "https://developer.apple.com/games/game-porting-toolkit/")!
        case .wine: return URL(string: "https://gitlab.winehq.org/wine/wine/-/wikis/MacOS")!
        }
    }
}

public struct RuntimeInstallation: Codable, Identifiable, Hashable, Sendable {
    public var kind: RuntimeKind
    public var executable: URL
    /// Apple's wrapper takes a prefix argument. GPTK's bare Wine uses WINEPREFIX instead.
    public var toolkitWrapper: Bool
    public var id: String { "\(kind.rawValue):\(executable.path)" }
    public var name: String { kind.name }

    public init(kind: RuntimeKind, executable: URL, toolkitWrapper: Bool = false) {
        self.kind = kind
        self.executable = executable.standardizedFileURL
        self.toolkitWrapper = toolkitWrapper
    }
}

public struct RuntimeProfile: Codable, Identifiable, Hashable, Sendable {
    public var runtime: RuntimeInstallation
    public var prefix: URL
    public var name: String
    public var reuseExisting: Bool?
    public var reusesExistingSteam: Bool { reuseExisting == true }
    public var id: String { "\(runtime.id):\(prefix.path)" }

    public init(runtime: RuntimeInstallation, prefix: URL, name: String, reuseExisting: Bool = false) {
        self.runtime = runtime
        self.prefix = prefix.standardizedFileURL
        self.name = name
        self.reuseExisting = reuseExisting ? true : nil
    }

    public var steamExecutable: URL? {
        let paths = ["drive_c/Program Files (x86)/Steam/steam.exe", "drive_c/Program Files/Steam/steam.exe", "drive_c/Steam/steam.exe"]
        return paths.map { prefix.appendingPathComponent($0) }.first { FileManager.default.fileExists(atPath: $0.path) }
    }
}

public struct AddedGame: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var executable: URL
    public var arguments: [String]
    public var profileID: String
    /// Absent in older configuration files, which contain Windows games only.
    public var platform: GamePlatform?
    public var lastPlayed: TimeInterval?
    public var effectivePlatform: GamePlatform { platform ?? .windows }

    public init(name: String, executable: URL, arguments: [String] = [], profileID: String, platform: GamePlatform = .windows) {
        id = UUID()
        self.name = name
        self.executable = executable
        self.arguments = arguments
        self.profileID = profileID
        self.platform = platform
    }
}

public struct SteamGame: Codable, Identifiable, Hashable, Sendable {
    public var appID: String
    public var name: String
    public var library: URL
    public var artwork: URL?
    public var lastPlayed: TimeInterval
    public var installDirectory: URL? = nil
    public var heroArtwork: URL? = nil
    public var sizeOnDisk: UInt64? = nil
    public var requiresUpdate: Bool = false
    public var id: String { appID }
}

public struct LauncherConfiguration: Codable, Sendable {
    public var selectedProfileID: String?
    public var customProfiles: [RuntimeProfile] = []
    public var steamOverrides: [String: URL] = [:]
    public var addedGames: [AddedGame] = []
    public var bigPicture = false
    public var favoriteGameIDs: Set<String>?
    public var includesMacSteam: Bool?
    public var startsSteamInBackground: Bool?
    public var gamePreferences: [String: GamePreferences]?
    public var collections: [GameCollection]?
    public var downloadPolicies: [String: DownloadPolicy]?
    public var scheduledPauses: Set<String>?
    public var friendNotifications: Bool?
    public var launchHistory: [LaunchDiagnostic]?
    public var gameSessions: [GameSessionRecord]?
    public var compatibilityTests: [CompatibilityTest]?
    public var performanceReports: [GamePerformanceReport]?

    public init() {}
}

public enum WayfarerError: LocalizedError {
    case message(String)
    public var errorDescription: String? {
        switch self { case .message(let text): return text }
    }
}

public enum AppPaths {
    public static var support: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Wayfarer")
    }
    public static var logs: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Wayfarer")
    }
}

public struct ConfigurationStore: Sendable {
    public var file: URL
    public init(file: URL = AppPaths.support.appendingPathComponent("settings.json")) { self.file = file }

    public func load() throws -> LauncherConfiguration {
        guard FileManager.default.fileExists(atPath: file.path) else { return LauncherConfiguration() }
        return try JSONDecoder().decode(LauncherConfiguration.self, from: Data(contentsOf: file))
    }

    public func save(_ configuration: LauncherConfiguration) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(configuration).write(to: file, options: .atomic)
    }
}
