import AppKit
import Combine
import Foundation
import UniformTypeIdentifiers
import PlaydockCore
import PlaydockPresentation
import Darwin
import UserNotifications

@MainActor
final class LauncherModel: ObservableObject {
    let libraryState = LibraryModel()
    let runtimeState = RuntimeModel()
    let installationState = InstallationModel()
    let socialState = SocialModel()
    let downloadsState = DownloadsModel()
    let featuresState = GameFeaturesModel()
    let settingsState = SettingsModel()
    let activityState = ActivityModel()
    let steamState = SteamConnectionModel()

    var activationObservers: [NSObjectProtocol] = []
    var workflowRevision = 0
    func libraryService(_ client: GamePlatform) -> SteamLibraryService {
        client == .macOS ? libraryState.macLibraryService : libraryState.windowsLibraryService
    }
    @Published var showingQuickLauncher=false
    @Published var showingCouch=false
    @Published var couchRequest = UUID()
    @Published var navigationRequest=UUID()
    var navigationDestination="Library"
    @Published var storageGame:LibraryGame?
    @Published var storagePlatform:GamePlatform = .macOS

    @Published var achievementGame:LibraryGame?
    @Published var achievementPlatform:GamePlatform = .macOS

    @Published var showingSteamBridgeSetup = false {
        didSet { if !showingSteamBridgeSetup { startInitialSteamConnectionIfNeeded() } }
    }

    var bridgeClosedSteam = false
    var bridgeTask: Task<Void, Never>?
    lazy var bridgeService = SteamIntegrationSetupService(helper: Bundle.main.executableURL!.deletingLastPathComponent().appendingPathComponent("PlaydockSteamIntegration"))
    @Published var workshopGame: LibraryGame?

    @Published var featureGame: LibraryGame?
    @Published var showingCollections = false
    @Published var showingDiagnostics = false
    var notifications:SteamNotifications?

    var featureMonitor: Task<Void,Never>?
    @Published var selectedGameID: String?

    var pendingGameID: String?
    var gameWindowPeers: [String: UUID] = [:]
    var presentedLaunchConfirmations = Set<String>()

    #if DEBUG
    var launchProbeStarted = false
    #endif

    @Published var error: String?

    var discoveringRuntimes = false

    @Published var sessionRequest = UUID()
    @Published var downloadsRequest = UUID()
    @Published var libraryRequest = UUID()
    @Published var chatRequest = UUID()
    func showDownloads() { downloadsRequest = UUID() }
    let session = NativeSession()
    var launches: [UUID: LaunchReceipt] = [:]
    let processService = ProcessService()
    var launchContexts: [UUID: SessionContext] = [:]
    let store:ConfigurationStore = {
        #if DEBUG
        if let flag = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--settings-file=") }) {
            return ConfigurationStore(file: URL(fileURLWithPath: String(flag.dropFirst("--settings-file=".count))))
        }
        #endif
        return ConfigurationStore()
    }()
    lazy var settingsService = ConfigurationService(store: store)
    var settingsRevision = 0
    var loadingSettings = true
    var shuttingDown = false
    var canSave = true
    var refreshTask: Task<Void, Never>?
    #if DEBUG
    var initialMacLaunch = ProcessInfo.processInfo.arguments.contains("--connect-mac")
    #endif
    var initialBackgroundConnection = true
    var initialBridgeCheck = true
    var nativeApplications: [pid_t: (UUID, String)] = [:]
    var nativeTermination: NSObjectProtocol?

    var selectedGame: LibraryGame? {
        guard let selectedGameID else { return nil }
        return library.first { $0.id == selectedGameID }
    }

    var steamBridgeProfile: RuntimeProfile {
        let runner = SteamIntegrationPaths.currentRunner
        var profile = RuntimeProfile(runtime: RuntimeInstallation(kind: .crossOver, executable: runner.appendingPathComponent("bin/wine")), prefix: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Steam/steamapps/compatdata"), name: "Mac Steam + CrossOver")
        profile.nativeSteamBridge = true
        return profile
    }
    var selectedProfile: RuntimeProfile? {
        let id = settingsState.configuration.selectedProfileID ?? runtimeState.automaticProfileID
        return runtimeState.profiles.first { $0.id == id }
    }
    var hasMacSteam: Bool { runtimeState.discoveredMacSteamClient != nil }

    var addedGames: [AddedGame] { settingsState.configuration.addedGames }
    var library: [LibraryGame] { libraryState.libraryPresentation.library }
    var visibleLibrary: [LibraryGame] { libraryState.libraryPresentation.visible }
    var quickGames: [LibraryGame] { libraryState.libraryPresentation.quick }

    func scheduleLibraryPresentation() {
        libraryState.presentationRevision += 1
        guard libraryState.presentationTask == nil else { return }
        libraryState.presentationTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                let revision = libraryState.presentationRevision
                var recent: [String: Date] = [:]
                for record in gameSessions { recent[record.gameID] = record.requestedAt }
                let input = GameLibraryInput(mac: libraryState.macGames, windows: libraryState.games,
                                             profileID: selectedProfile?.id, added: settingsState.configuration.addedGames,
                                             catalog: libraryState.catalog,
                                             hidden: Set(settingsState.configuration.gamePreferences.filter { $0.value.hidden }.keys),
                                             favorites: favorites, recent: recent)
                if input != libraryState.presentationInput {
                    guard let result = try? await libraryState.presentationService.prepare(input) else { return }
                    guard !Task.isCancelled else { return }
                    if revision == libraryState.presentationRevision {
                        libraryState.presentationInput = input
                        if libraryState.libraryPresentation != result { libraryState.libraryPresentation = result }
                    }
                }
                if revision == libraryState.presentationRevision { break }
            }
            libraryState.presentationTask = nil
        }
    }
    var favorites: Set<String> { settingsState.configuration.favoriteGameIDs }
    var startsSteamInBackground:Bool {
        get { settingsState.configuration.startsSteamInBackground }
        set { settingsState.configuration.startsSteamInBackground=newValue; save() }
    }
    var selection: String {
        get { settingsState.configuration.selectedProfileID ?? "automatic" }
        set {
            guard newValue != selection else{return}
            guard !gameSessions.contains(where:{$0.phase.active && $0.platform == .windows}),!installationState.maintenance.values.contains(where:{!$0.completed && !$0.failed}),installationState.installationRequest==nil,installationState.uninstallationRequest==nil else{error="Finish the running game or file operation before switching environments.";return}
            closeWindowsApps(); disconnectSession(); settingsState.configuration.selectedProfileID = newValue == "automatic" ? nil : newValue; save(); refresh() }
    }
    var missingSelection: Bool { settingsState.configuration.selectedProfileID != nil && selectedProfile == nil }

    init() {
        libraryState.changed = { [weak self] in self?.scheduleLibraryPresentation() }
        runtimeState.changed = { [weak self] in self?.scheduleLibraryPresentation() }
        settingsState.changed = { [weak self] in self?.scheduleLibraryPresentation() }
        notifications = SteamNotifications(model: self)
        UNUserNotificationCenter.current().delegate = notifications
        libraryState.refreshing = true; libraryState.libraryLoadingMessage = "Loading your saved settings…"
        Task { [weak self] in
            guard let self else { return }
            do { settingsState.configuration = try await settingsService.load() }
            catch {
                canSave = false
                self.error = "Cannot read settings at \(store.file.path). Your file has been preserved. \(error.localizedDescription)"
            }
            for index in settingsState.configuration.gameSessions.indices where settingsState.configuration.gameSessions[index].phase.active {
                settingsState.configuration.gameSessions[index].phase = .interrupted
                settingsState.configuration.gameSessions[index].endedAt = Date()
                settingsState.configuration.gameSessions[index].message = "Playdock closed before this session ended."
            }
            syncSessionHistory()
            runtimeState.bridgeCrossOverPath = settingsState.configuration.bridgeCrossOverPath
            Task { await refreshBridgeEnvironment() }
            loadingSettings = false
            guard !shuttingDown else { return }
            refresh()
        }
        Task { [weak self] in
            guard let self else { return }
            await activityState.sessionCoordinator.start(input: { [weak self] in await self?.sessionMonitorInput() },
                publish: { [weak self] update in await self?.applySessionUpdate(update) })
        }
        featureMonitor = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(15)) } catch { return }
                guard let self else { return }
                await self.enforceDownloadSchedules()
            }
        }
        session.windowArrived = { [weak self] window in
            guard let self else { return }
            guard self.activityState.pendingGameTitle != nil, !window.program.isEmpty, !window.isSteamClient else { return }
            let title = self.activityState.pendingGameTitle ?? window.title
            if let gameID = self.pendingGameID { self.gameWindowPeers[gameID] = window.peer.id }
            self.activityState.pendingGameTitle = nil; self.pendingGameID = nil
            self.activityState.status = "Playing \(title)"; self.markLaunch(title,outcome:"Game window visible")
            self.session.activateNativeWindow(window.id)
        }
        session.nativeWindowsChanged = { [weak self] windows in
            guard let self else { return }
            self.activityState.nativeGameWindows = windows
            let peers = Set(windows.map { $0.peer.id })
            self.gameWindowPeers = self.gameWindowPeers.filter { peers.contains($0.value) }
        }
        libraryState.libraryMonitor = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
                await self?.refreshOptionalWork()
            }
        }
        for name in [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification] {
            activationObservers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in await self?.refreshOptionalWork() }
            })
        }
        nativeTermination = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            Task { @MainActor in
                guard let self, let entry = self.nativeApplications.removeValue(forKey: app.processIdentifier) else { return }
                self.activityState.activeLaunches.removeValue(forKey: entry.0)
                let ids = await self.activityState.sessionCoordinator.sessions(forPID: app.processIdentifier)
                guard !self.shuttingDown else { return }
                for id in ids { self.endGameSession(id, phase: .finished, message: "Session ended.") }
            }
        }
    }

}
