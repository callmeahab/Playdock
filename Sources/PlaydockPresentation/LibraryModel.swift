import Combine
import Foundation
import PlaydockCore

@MainActor
public final class LibraryModel: ObservableObject {
    public init() {}
    @Published public var games: [SteamGame] = [] { didSet { changed?() } }
    @Published public var macGames: [SteamGame] = [] { didSet { changed?() } }
    @Published public var catalog: [SteamCatalogGame] = [] { didSet { changed?() } }
    @Published public var libraryPresentation = GameLibraryPresentation.empty
    @Published public var loadingCatalog = false
    @Published public var catalogMessage = "Load your Steam library to see games you can install."
    @Published public var libraryWarnings: [String] = []
    @Published public var refreshing = false
    @Published public var libraryLoadingMessage = "Finding your games…"
    public var changed: (() -> Void)?

    public let macLibraryService = SteamLibraryService(client: .macOS)
    public let windowsLibraryService = SteamLibraryService(client: .windows)
    public let presentationService = LibraryPresentationService()
    public var presentationInput: GameLibraryInput?
    public var presentationRevision = 0
    public var presentationTask: Task<Void, Never>?
    public var catalogAccounts: [GamePlatform: String] = [:]
    public var catalogRoots: [GamePlatform: URL] = [:]
    public var catalogRefreshQueue = Set<GamePlatform>()
    public var catalogAttemptedAt: [GamePlatform: Date] = [:]
    public var catalogTask: Task<Void, Never>?
    public var libraryLoadingStages: [GamePlatform: String] = [:]
    public var catalogRestoreTask: Task<Void, Never>?
    public var libraryMonitor: Task<Void, Never>?
    public var libraryScanTask: Task<Void, Never>?
    public var nextLibraryScan = Date.distantPast
}
