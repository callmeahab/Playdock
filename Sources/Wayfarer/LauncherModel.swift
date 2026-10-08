import AppKit
import Combine
import Foundation
import UniformTypeIdentifiers
import WayfarerCore
import Darwin
import UserNotifications

@MainActor
final class LauncherModel: ObservableObject {
    @Published private(set) var runtimes: [RuntimeInstallation] = []
    @Published private(set) var profiles: [RuntimeProfile] = [] { didSet { scheduleLibraryPresentation() } }
    private var automaticProfileID: String?
    private var discoveredSteamExecutables: [String: URL] = [:]
    private var runtimeFingerprints: [String: String] = [:]
    private var discoveredMacSteamClient: URL?
    @Published private(set) var games: [SteamGame] = [] { didSet { scheduleLibraryPresentation() } }
    @Published private(set) var macGames: [SteamGame] = [] { didSet { scheduleLibraryPresentation() } }
    @Published private(set) var transfers: [SteamTransfer] = []
    @Published private(set) var catalog: [SteamCatalogGame] = [] { didSet { scheduleLibraryPresentation() } }
    @Published private(set) var libraryPresentation = GameLibraryPresentation.empty
    private var presentationInput: GameLibraryInput?
    private var presentationRevision = 0
    private var presentationTask: Task<Void, Never>?
    @Published private(set) var loadingCatalog = false
    @Published private(set) var catalogMessage = "Load your Steam library to see games you can install."
    private var catalogAccounts: [GamePlatform: String] = [:]
    @Published private var currentSteamAccounts: [GamePlatform: String] = [:]
    private var catalogRoots: [GamePlatform: URL] = [:]
    private let macLibraryService = SteamLibraryService(client: .macOS)
    private let windowsLibraryService = SteamLibraryService(client: .windows)
    private let presentationService = LibraryPresentationService()
    private let runtimeService = RuntimeService()
    private let runtimeProcesses = RuntimeProcessService()
    private let macBackend = BackendCoordinator()
    private let windowsBackend = BackendCoordinator()
    private let installationCoordinator = InstallCoordinator()
    private let macDownloads = DownloadScheduler()
    private let windowsDownloads = DownloadScheduler()
    private let macSocial = SocialCoordinator()
    private let windowsSocial = SocialCoordinator()
    private let maintenanceCoordinator = MaintenanceCoordinator()
    private let sessionCoordinator = SessionMonitor()
    private let performanceCoordinator = PerformanceCoordinator()
    private let performanceEnvironments = PerformanceEnvironmentService()
    private let performanceReportService = PerformanceReportService()
    @Published private(set) var gameplayQuiet = false
    @Published private(set) var performanceSnapshots: [String: PerformanceEnvironmentSnapshot] = [:]
    @Published private(set) var performanceBusy = Set<String>()
    @Published private(set) var performanceMessages: [String: String] = [:]
    private var performanceCapture: Task<Void, Never>?
    @Published private(set) var capturingPerformanceFor: String?
    private var activationObservers: [NSObjectProtocol] = []
    private var workflowRevision = 0
    private var installationRevision = 0
    private var sessionHistoryRevision = 0
    private func backendCoordinator(_ client: GamePlatform) -> BackendCoordinator { client == .macOS ? macBackend : windowsBackend }
    private func downloadScheduler(_ client: GamePlatform) -> DownloadScheduler { client == .macOS ? macDownloads : windowsDownloads }
    private func socialCoordinator(_ client: GamePlatform) -> SocialCoordinator { client == .macOS ? macSocial : windowsSocial }
    private func libraryService(_ client: GamePlatform) -> SteamLibraryService {
        client == .macOS ? macLibraryService : windowsLibraryService
    }
    private var catalogRefreshQueue = Set<GamePlatform>()
    private var catalogAttemptedAt: [GamePlatform: Date] = [:]
    private var catalogTask: Task<Void, Never>?
    private var requestedCatalogForSession = false
    @Published var showingQuickLauncher=false
    @Published var showingCouch=false
    @Published private(set) var couchRequest = UUID()
    @Published var navigationRequest=UUID()
    var navigationDestination="Library"
    @Published var storageGame:LibraryGame?
    @Published var storagePlatform:GamePlatform = .macOS
    @Published var storageFolders:[GamePlatform:[SteamStorageFolder]]=[:]
    @Published var storageMessages:[GamePlatform:String]=[:]
    @Published var storageBusy=Set<GamePlatform>()
    @Published var maintenance:[String:SteamMaintenanceProgress]=[:]
    @Published var achievementGame:LibraryGame?
    @Published var achievementPlatform:GamePlatform = .macOS
    @Published var achievementSnapshots:[String:AchievementSnapshot]=[:]
    @Published var achievementMessages:[String:String]=[:]
    @Published var achievementBusy=Set<String>()
    private let achievementService = AchievementService()
    @Published var workshopGame: LibraryGame?
    @Published var workshopPlatform: GamePlatform = .macOS
    @Published var workshopSnapshots: [String: WorkshopSnapshot] = [:]
    @Published var workshopMessages: [String: String] = [:]
    @Published var workshopBusy = Set<String>()
    @Published var workshopChanging = Set<String>()
    private let workshopService = WorkshopService()
    private var workshopRevisions: [String: UUID] = [:]
    private let saveService = SaveService()
    @Published private var suggestedSaveFolders: [String: URL] = [:]
    @Published var featureGame: LibraryGame?
    @Published var showingCollections = false
    @Published var showingDiagnostics = false
    @Published var friendsClient:GamePlatform = .macOS
    private var notifications:SteamNotifications?
    @Published var friendsSnapshots: [GamePlatform: SteamFriendsSnapshot] = [:]
    @Published var friendsMessages: [GamePlatform: String] = [:]
    @Published var friendsBusy = Set<GamePlatform>()
    @Published var downloadPolicyMessages: [GamePlatform: String] = [:]
    @Published var cloudStatuses: [String: SteamCloudStatus] = [:]
    @Published var saveBackups: [String: [SaveBackup]] = [:]
    @Published var saveBusy = false
    @Published var saveMessage = ""
    private var featureMonitor: Task<Void,Never>?
    @Published var selectedGameID: String?
    @Published var selectedGamePlatform: GamePlatform?
    @Published private(set) var pendingGameTitle: String?
    @Published private(set) var nativeGameWindows: [SessionWindow] = []
    private var pendingGameID: String?
    private var gameWindowPeers: [String: UUID] = [:]
    @Published private(set) var configuration = LauncherConfiguration() {
        didSet {
            if oldValue.selectedProfileID != configuration.selectedProfileID || oldValue.includesMacSteam != configuration.includesMacSteam { invalidateWorkflows() }
            scheduleLibraryPresentation()
        }
    }
    @Published var error: String?
    @Published private(set) var libraryWarnings: [String] = []
    @Published private(set) var status = "Checking installed runtimes…"
    @Published private(set) var refreshing = false
    @Published private(set) var libraryLoadingMessage = "Finding your games…"
    private var libraryLoadingStages: [GamePlatform: String] = [:]
    private var discoveringRuntimes = false
    private var catalogRestoreTask: Task<Void, Never>?
    @Published private(set) var installing = false
    @Published private(set) var latestLog: URL?
    @Published private(set) var activeLaunches: [UUID: String] = [:]
    @Published private(set) var sessionRequest = UUID()
    @Published private(set) var downloadsRequest = UUID()
    @Published private(set) var libraryRequest = UUID()
    @Published private(set) var chatRequest = UUID()
    func showDownloads() { downloadsRequest = UUID() }
    @Published private(set) var setupMessage = ""
    let session = EmbeddedSession()
    private var setupTask: Task<Void, Never>?
    private var launches: [UUID: LaunchReceipt] = [:]
    private let processService = ProcessService()
    private var launchContexts: [UUID: SessionContext] = [:]
    private let store:ConfigurationStore = {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--feature-preview") {return ConfigurationStore(file:URL(fileURLWithPath:"/private/tmp/wayfarer-seven-preview/settings.json"))}
        #endif
        return ConfigurationStore()
    }()
    private lazy var settingsService = ConfigurationService(store: store)
    private var settingsRevision = 0
    private var loadingSettings = true
    private var shuttingDown = false
    private var canSave = true
    private var refreshTask: Task<Void, Never>?
    private var initialSteamLaunch = ProcessInfo.processInfo.arguments.contains("--open-steam")
    private var initialMacLaunch = ProcessInfo.processInfo.arguments.contains("--connect-mac")
    private var initialBackgroundConnection = true
    @Published var steamUIRequest:SteamUIRequest?
    let steamWindow = SteamWindowSession()
    private var nativeApplications: [pid_t: (UUID, String)] = [:]
    private var nativeTermination: NSObjectProtocol?
    private var libraryMonitor: Task<Void, Never>?
    private var libraryScanTask: Task<Void, Never>?
    private var nextLibraryScan = Date.distantPast
    @Published private(set) var steamConnections: [GamePlatform: SteamControlSnapshot] = [:]
    @Published private(set) var connectionBusy = Set<GamePlatform>()
    @Published private(set) var connectionMessages: [GamePlatform: String] = [:]
    @Published private(set) var windowsSteamNeedsRecovery = false
    @Published var windowsAppsProfile: RuntimeProfile?
    @Published private(set) var windowsApps: [RuntimeProcessIdentity.WindowsProcess] = []
    @Published private(set) var windowsAppsBusy = false
    @Published private(set) var windowsAppsLoading = false
    @Published private(set) var windowsAppsCanForceQuit = false
    @Published private(set) var windowsAppsMessage = ""
    private var windowsAppsOperation = UUID()
    private var windowsAppsTask: Task<Void, Never>?
    @Published var installationRequest: GameInstallationRequest?
    @Published var uninstallationRequest:GameUninstallationRequest?
    @Published private(set) var uninstallBusy=false
    @Published private(set) var uninstallMessage=""
    @Published private var installDialog = SteamInstallDialogState()
    var installPlan: SteamInstallPlan? { installDialog.plan }
    var installBusy: Bool { installDialog.busy }
    var installMessage: String { installDialog.message }
    var installRevision: UUID { installDialog.operationID }
    private var controlClients: [GamePlatform: SteamControl] = [:]
    private var controlPorts: [GamePlatform: UInt16] = [:]
    private var discoveredControlPorts: [GamePlatform: UInt16] = [:]
    private var macControlPort:UInt16 = 8080
    var selectedGame: LibraryGame? {
        guard let selectedGameID else { return nil }
        return library.first { $0.id == selectedGameID }
    }

    var selectedProfile: RuntimeProfile? {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--managed-test") {
            return profiles.first { !$0.reusesExistingSteam && $0.runtime.kind == .crossOver }
        }
        #endif
        let id = configuration.selectedProfileID ?? automaticProfileID
        return profiles.first { $0.id == id }
    }
    var steamExecutable: URL? {
        guard let profile = selectedProfile else { return nil }
        return discoveredSteamExecutables[profile.id]
    }
    var addedGames: [AddedGame] { configuration.addedGames.filter { $0.effectivePlatform == .macOS || $0.profileID == selectedProfile?.id } }
    var library: [LibraryGame] { libraryPresentation.library }
    var visibleLibrary: [LibraryGame] { libraryPresentation.visible }
    var quickGames: [LibraryGame] { libraryPresentation.quick }

    private func scheduleLibraryPresentation() {
        presentationRevision += 1
        guard presentationTask == nil else { return }
        presentationTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                let revision = presentationRevision
                let includeMac = includesMacSteam
                var recent: [String: Date] = [:]
                for record in gameSessions { recent[record.gameID] = record.requestedAt }
                let input = GameLibraryInput(mac: includeMac ? macGames : [], windows: games,
                                             profileID: selectedProfile?.id, added: configuration.addedGames,
                                             catalog: catalog.filter { includeMac || $0.client != .macOS },
                                             hidden: Set((configuration.gamePreferences ?? [:]).filter { $0.value.hidden }.keys),
                                             favorites: favorites, recent: recent)
                if input != presentationInput {
                    guard let result = try? await presentationService.prepare(input) else { return }
                    guard !Task.isCancelled else { return }
                    if revision == presentationRevision {
                        presentationInput = input
                        if libraryPresentation != result { libraryPresentation = result }
                    }
                }
                if revision == presentationRevision { break }
            }
            presentationTask = nil
        }
    }
    var favorites: Set<String> { configuration.favoriteGameIDs ?? [] }
    var includesMacSteam: Bool {
        get { configuration.includesMacSteam ?? true }
        set { configuration.includesMacSteam = newValue; save(); refresh() }
    }
    var startsSteamInBackground:Bool {
        get { configuration.startsSteamInBackground ?? true }
        set { configuration.startsSteamInBackground=newValue; save() }
    }
    var bigPicture: Bool {
        get { configuration.bigPicture }
        set { configuration.bigPicture = newValue; save() }
    }
    var selection: String {
        get { configuration.selectedProfileID ?? "automatic" }
        set {
            guard newValue != selection else{return}
            guard !gameSessions.contains(where:{$0.phase.active && $0.platform == .windows}),!maintenance.values.contains(where:{!$0.completed && !$0.failed}),installationRequest==nil,uninstallationRequest==nil else{error="Finish the running game or file operation before switching environments.";return}
            storageFolders[.windows]=nil;storageMessages[.windows]=nil;steamConnections[.windows]=nil;controlClients[.windows]=nil;controlPorts[.windows]=nil;discoveredControlPorts[.windows]=nil
            closeWindowsApps(); windowsSteamNeedsRecovery=false; disconnectSession(); configuration.selectedProfileID = newValue == "automatic" ? nil : newValue; save(); refresh() }
    }
    var missingSelection: Bool { configuration.selectedProfileID != nil && selectedProfile == nil }

    init() {
        notifications = SteamNotifications(model: self)
        UNUserNotificationCenter.current().delegate = notifications
        refreshing = true; libraryLoadingMessage = "Loading your saved settings…"
        Task { [weak self] in
            guard let self else { return }
            do { configuration = try await settingsService.load() }
            catch {
                canSave = false
                self.error = "Cannot read settings at \(store.file.path). Your file has been preserved. \(error.localizedDescription)"
            }
            if var records = configuration.gameSessions {
                for index in records.indices where records[index].phase.active {
                    records[index].phase = .interrupted; records[index].endedAt = Date()
                    records[index].message = "Wayfarer closed before this session ended."
                }
                configuration.gameSessions = records
            }
            syncSessionHistory()
            loadingSettings = false
            guard !shuttingDown else { return }
            refresh()
        }
        Task { [weak self] in
            guard let self else { return }
            await sessionCoordinator.start(input: { [weak self] in await self?.sessionMonitorInput() },
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
            if window.isSteamClient, ["Steam", "Steam Big Picture Mode"].contains(window.title), window.frame.width >= 800, window.frame.height >= 500,
               !self.requestedCatalogForSession, !self.loadingCatalog {
                self.requestedCatalogForSession = true
                self.loadSteamLibrary(.windows)
            }
            guard self.pendingGameTitle != nil, !window.program.isEmpty, !window.isSteamClient else { return }
            let title = self.pendingGameTitle ?? window.title
            if window.presentsNatively {
                if let gameID = self.pendingGameID { self.gameWindowPeers[gameID] = window.peer.id }
                self.pendingGameTitle = nil; self.pendingGameID = nil
                self.status = "Playing \(title)"; self.markLaunch(title,outcome:"Game window visible")
                self.session.activateNativeWindow(window.id)
            } else {
                self.pendingGameTitle = nil; self.pendingGameID = nil
                self.session.chooseWindow(window.id)
                self.sessionRequest = UUID()
            }
        }
        session.nativeWindowsChanged = { [weak self] windows in
            guard let self else { return }
            self.nativeGameWindows = windows
            let peers = Set(windows.map { $0.peer.id })
            self.gameWindowPeers = self.gameWindowPeers.filter { peers.contains($0.value) }
        }
        libraryMonitor = Task { [weak self] in
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
                self.activeLaunches.removeValue(forKey: entry.0)
                let ids = await self.sessionCoordinator.sessions(forPID: app.processIdentifier)
                guard !self.shuttingDown else { return }
                for id in ids { self.endGameSession(id, phase: .finished, message: "Session ended.") }
            }
        }
    }

    func refresh() {
        guard !loadingSettings, !shuttingDown else { return }
        refreshTask?.cancel()
        catalogRestoreTask?.cancel(); catalogRestoreTask = nil
        libraryScanTask?.cancel(); libraryScanTask = nil
        refreshing = true
        libraryWarnings = []
        discoveringRuntimes = true
        libraryLoadingStages = includesMacSteam ? [.macOS: "Loading saved Mac games…"] : [:]
        updateLibraryLoadingMessage()
        let custom = configuration.customProfiles
        let selected = configuration.selectedProfileID
        let includeMac = includesMacSteam
        refreshTask = Task { [weak self] in
            guard let self else { return }
            async let mac: Void = self.loadMacLibrary(includeMac: includeMac)
            let result = await runtimeService.discover(custom: custom)
            guard !Task.isCancelled else { return }
            discoveredSteamExecutables = result.steamExecutables
            runtimeFingerprints = result.fingerprints
            discoveredMacSteamClient = result.macSteamClient
            let previousEnvironment = selectedProfile?.id
            automaticProfileID = result.automaticProfileID
            runtimes = result.runtimes
            profiles = result.profiles
            if previousEnvironment != selectedProfile?.id { invalidateWorkflows() }
            let migrated = RuntimeDiscovery.managedSelection(selected, in: profiles)
            if configuration.selectedProfileID != migrated { configuration.selectedProfileID = migrated; save() }
            discoveringRuntimes = false
            async let windows: Void = self.loadWindowsLibrary(profile: self.selectedProfile)
            _ = await (mac, windows)
            guard !Task.isCancelled else { return }
            #if DEBUG
            if let flag = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--catalog-review=") }),
               let nonce = UUID(uuidString: String(flag.dropFirst("--catalog-review=".count))), let profile = selectedProfile, let root = steamExecutable?.deletingLastPathComponent(),
               let data = try? await FileService.shared.read(root.appendingPathComponent("logs/console_log.txt")), let response = SteamCatalog.response(String(decoding: data, as: UTF8.self), nonce: nonce),
               let snapshot = try? await windowsLibraryService.catalog(owned: nil, response: response, root: root, profileID: profile.id) {
                catalog = snapshot.games; catalogMessage = "\(snapshot.games.count) Windows games loaded from Steam"
            }
            #endif
            refreshing = false
            refreshTask = nil
            status = library.isEmpty ? "Your next adventure starts here" : "\(library.count) games · Mac & Windows"
            if initialBackgroundConnection {
                initialBackgroundConnection=false
                if startsSteamInBackground && !ProcessInfo.processInfo.arguments.contains("--no-background-steam") {
                    if selectedProfile != nil && steamExecutable != nil { connectSteam(.windows) }
                    if includesMacSteam && (try? macSteamClient()) != nil { connectSteam(.macOS) }
                }
            }
            if initialSteamLaunch, selectedProfile != nil { initialSteamLaunch = false; connectSteam(.windows) }
            #if DEBUG
            if initialMacLaunch { initialMacLaunch=false; connectSteam(.macOS) }
            #endif
        }
    }


    private func updateLibraryLoadingMessage() {
        let stages = (discoveringRuntimes ? ["Finding Windows engines…"] : []) + GamePlatform.allCases.compactMap { libraryLoadingStages[$0] }
        libraryLoadingMessage = stages.isEmpty ? "Finishing library refresh…" : stages.joined(separator: " · ")
    }

    private func loadMacLibrary(includeMac: Bool) async {
        guard !Task.isCancelled else { return }
        guard includeMac else { macGames = []; transfers.removeAll { $0.client == .macOS }; return }
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Steam")
        await loadLibrarySource(client: .macOS, root: root, prefix: nil, profileID: nil)
    }

    private func loadWindowsLibrary(profile: RuntimeProfile?) async {
        guard !Task.isCancelled else { return }
        guard let profile, let steam = discoveredSteamExecutables[profile.id] else {
            games = []; transfers.removeAll { $0.client == .windows }
            clearCatalogAccount(.windows)
            updateLibraryLoadingMessage()
            return
        }
        await loadLibrarySource(client: .windows, root: steam.deletingLastPathComponent(), prefix: profile.prefix, profileID: profile.id)
    }

    private func loadLibrarySource(client: GamePlatform, root: URL, prefix: URL?, profileID: String?) async {
        libraryLoadingStages[client] = "Loading saved \(client.name) games…"
        updateLibraryLoadingMessage()
        let service = libraryService(client)
        let previousAccount = catalogAccounts[client], previousRoot = catalogRoots[client]
        let account = await service.account(root: root, profileID: profileID, includeInstalled: true)
        guard !Task.isCancelled else { return }
        if catalogAccounts[client] == previousAccount, catalogRoots[client] == previousRoot { applyCatalogAccount(account) }
        #if DEBUG
        let useInstalledCache = !ProcessInfo.processInfo.arguments.contains("--ignore-installed-cache")
        #else
        let useInstalledCache = true
        #endif
        if useInstalledCache, let installed = account.installed {
            if client == .macOS { if macGames != installed.games { macGames = installed.games } }
            else if games != installed.games { games = installed.games }
        }
        libraryLoadingStages[client] = "Checking installed \(client.name) games…"
        updateLibraryLoadingMessage()
        #if DEBUG
        if let flag = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--probe-delay-library=") }),
           let seconds = Double(flag.dropFirst("--probe-delay-library=".count)), seconds > 0, seconds <= 30 {
            do { try await Task.sleep(for: .seconds(seconds)) } catch { return }
        }
        #endif
        var warnings: [String] = []
        var finalScan: SteamLibraryScan?
        for await scan in service.updates(root: root, prefix: prefix) {
            guard !Task.isCancelled else { return }
            if client == .macOS { if macGames != scan.games { macGames = scan.games } }
            else if games != scan.games { games = scan.games }
            let mergedTransfers = transfers.filter { $0.client != client } + scan.transfers
            if transfers != mergedTransfers { transfers = mergedTransfers }
            warnings = scan.warnings
            finalScan = scan
        }
        guard !Task.isCancelled else { return }
        libraryWarnings += warnings.filter { !libraryWarnings.contains($0) }
        libraryLoadingStages.removeValue(forKey: client)
        updateLibraryLoadingMessage()
        if let finalScan, finalScan.warnings.isEmpty {
            try? await service.saveInstallations(finalScan, account: account.account, root: root, profileID: profileID)
        }
    }

    // Coalesce manifest refreshes and publish only changed snapshots.
    private func refreshLibrarySnapshot(force: Bool = true) {
        guard !refreshing, libraryScanTask == nil else { return }
        guard force || Date() >= nextLibraryScan else { return }
        let tracking = !transfers.isEmpty || steamConnections.values.contains { !$0.downloads.isEmpty } || gameSessions.contains { $0.phase.active }
        nextLibraryScan = Date().addingTimeInterval(tracking ? 5 : 30)
        restoreCachedCatalogs()
        let profile = selectedProfile, includeMac = includesMacSteam
        let windowsRoot = steamContext(.windows)?.root
        let macRoot = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Steam")
        let windowsService = windowsLibraryService, macService = macLibraryService
        libraryScanTask = Task { [weak self] in
            let empty = SteamLibraryScan(games: [], warnings: [])
            async let windows = windowsRoot != nil ? windowsService.scanAndSave(root: windowsRoot!, prefix: profile?.prefix, profileID: profile?.id) : empty
            async let mac = includeMac ? macService.scanAndSave(root: macRoot, prefix: nil, profileID: nil) : empty
            let result = await (windows, mac)
            guard !Task.isCancelled, let self else { return }
            self.libraryScanTask = nil
            guard profile?.id == self.selectedProfile?.id, includeMac == self.includesMacSteam else { return }
            if self.games != result.0.games { self.games = result.0.games }
            if self.macGames != result.1.games { self.macGames = result.1.games }
            let transfers = result.0.transfers + result.1.transfers
            if self.transfers != transfers { self.transfers = transfers }
            let warnings = result.0.warnings + result.1.warnings
            if self.libraryWarnings != warnings { self.libraryWarnings = warnings }
        }
    }

    func showGame(_ game: LibraryGame, platform: GamePlatform? = nil) {
        selectedGamePlatform = platform; selectedGameID = game.id
    }

    func save() {
        guard canSave, !loadingSettings, !shuttingDown else { return }
        settingsRevision += 1
        let revision = settingsRevision, snapshot = configuration
        Task {
            do { try await settingsService.save(snapshot, revision: revision) }
            catch { self.error = "Cannot save settings: \(error.localizedDescription)" }
        }
    }

    func prepareForTermination() async {
        shuttingDown = true
        refreshTask?.cancel(); libraryScanTask?.cancel(); catalogRestoreTask?.cancel()
        catalogTask?.cancel(); presentationTask?.cancel(); setupTask?.cancel()
        featureMonitor?.cancel(); libraryMonitor?.cancel()
        performanceCapture?.cancel()
        activationObservers.forEach { NotificationCenter.default.removeObserver($0) }; activationObservers.removeAll()
        async let macBackendStop: Void = macBackend.stop()
        async let windowsBackendStop: Void = windowsBackend.stop()
        async let installStop: Void = installationCoordinator.stop()
        async let macDownloadStop: Void = macDownloads.stop()
        async let windowsDownloadStop: Void = windowsDownloads.stop()
        async let macSocialStop: Void = macSocial.stop()
        async let windowsSocialStop: Void = windowsSocial.stop()
        async let maintenanceStop: Void = maintenanceCoordinator.stop()
        async let sessionStop: Void = sessionCoordinator.stop()
        _ = await (macBackendStop, windowsBackendStop, installStop, macDownloadStop, windowsDownloadStop,
                   macSocialStop, windowsSocialStop, maintenanceStop, sessionStop)
        let downloadStates = await [macDownloads.stateSnapshot(), windowsDownloads.stateSnapshot()]
        for state in downloadStates.compactMap({ $0 }) {
            persistDownloadState(state.policy, owned: state.ownedPause, key: state.scope,
                persistPolicy: state.policyChanged || configuration.downloadPolicies?[state.scope] != nil)
        }
        if canSave, !loadingSettings {
            settingsRevision += 1
            try? await settingsService.save(configuration, revision: settingsRevision)
        }
        await session.finishForTermination()
        await session.backend.hideAll()
    }

    func addProfile(_ profile: RuntimeProfile) {
        let managed = RuntimeDiscovery.managedProfile(for: profile.runtime)
        if !configuration.customProfiles.contains(where: { $0.runtime.id == managed.runtime.id }) { configuration.customProfiles.append(managed) }
        configuration.selectedProfileID = managed.id
        save()
        refresh()
    }

    func forgetCustomProfile(_ profile: RuntimeProfile) {
        configuration.customProfiles.removeAll { $0.runtime.id == profile.runtime.id }
        if configuration.selectedProfileID == profile.id { configuration.selectedProfileID = nil }
        save()
        refresh()
    }

    func addGame(name: String, executable: URL, arguments: String, platform: GamePlatform = .windows) async throws {
        if platform == .windows && selectedProfile == nil { throw WayfarerError.message("Choose a Windows environment first.") }
        if platform == .macOS { try await FileService.shared.validateApplication(executable) }
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw WayfarerError.message("Give the game a name.") }
        let canonical = executable.standardizedFileURL
        guard !configuration.addedGames.contains(where: { $0.executable.standardizedFileURL == canonical && $0.effectivePlatform == platform && (platform == .macOS || $0.profileID == selectedProfile?.id) }) else {
            throw WayfarerError.message("This game is already in your library.")
        }
        configuration.addedGames.append(AddedGame(name: title, executable: executable, arguments: try ArgumentParser.parse(arguments), profileID: platform == .windows ? selectedProfile!.id : "", platform: platform))
        save()
    }

    func removeGame(_ game: AddedGame) {
        configuration.favoriteGameIDs?.remove("added:\(game.id.uuidString)")
        configuration.addedGames.removeAll { $0.id == game.id }
        save()
    }

    func toggleFavorite(_ game: LibraryGame) {
        var values = favorites
        if !values.insert(game.id).inserted { values.remove(game.id) }
        configuration.favoriteGameIDs = values
        save()
    }

    func launch(_ game: LibraryGame, platform: GamePlatform? = nil) {
        if let active=activeSession(game.id) { bringGameForward(active);return }
        if let operation=maintenance.first(where:{$0.key.hasPrefix(game.id+":") && !$0.value.completed && !$0.value.failed}) { error="Wait for this game’s \(operation.value.kind == "move" ? "move":"verification") to finish before playing.";return }
        let desired = platform ?? preferredGamePlatform(game)
        if desired == .windows, let environment = preferences(for:game).environmentID, environment != selectedProfile?.id {
            launchInSavedEnvironment(game,environment:environment); return
        }
        let platform = platform ?? preferredGamePlatform(game)
        if installationDisabled(game, platform: platform) { return }
        let target = platform.flatMap { game.installation(for: $0) }
        guard let installation = target else { install(game, platform: platform); return }
        if installation.platform == .windows, let peer = gameWindowPeers[game.id], let window = nativeGameWindows.first(where: { $0.peer.id == peer }) {
            session.activateNativeWindow(window.id); return
        }
        let arguments:[String]
        do { arguments=try preferences(for:game).arguments() } catch { self.error=error.localizedDescription; return }
        if installation.platform == .windows && selectedProfile == nil { error="Choose a Windows environment first.";return }
        Task {
            do {
                if installation.platform == .windows, let profile = selectedProfile {
                    try await performanceEnvironments.checkLaunch(preferences(for: game).effectivePerformance, profile: profile)
                    guard selectedProfile?.id == profile.id else { return }
                }
                guard activeSession(game.id) == nil, !shuttingDown else { return }
                beginGameSession(game,platform:installation.platform)
                recordLaunch(game,platform:installation.platform,outcome:"Requested")
                switch installation {
                case .windowsSteam(let steam, let profileID):
                    guard profileID == selectedProfile?.id else { failGameSession(game.id, message: "Choose this game's Windows environment in Engines."); return }
                    launchSteam(appID: steam.appID, gameArguments:arguments)
                case .macSteam(let steam): launchMacSteam(steam,arguments:arguments)
                case .added(var added): added.arguments += arguments; launchGame(added)
                }
            } catch { self.error = error.localizedDescription }
        }
    }

    func install(_ game: LibraryGame, platform: GamePlatform?) {
        guard !installationDisabled(game, platform: platform) else { return }
        guard let platform, let offer = game.offer(for: platform) else { error = "Load this Steam account’s library before installing the game."; return }
        if platform == .windows, offer.profileID != selectedProfile?.id { error = "Choose this game’s Windows environment first."; return }
        guard installationRequest == nil else { return }
        installationRequest=GameInstallationRequest(game:game,platform:platform,appID:offer.appID)
        prepareInstallation()
    }

    func loadSteamLibrary(_ client: GamePlatform) {
        guard connectionMode(client) != .signedOut else { catalogMessage="Sign in to Steam to update your saved library."; return }
        guard connectionMode(client) != .offline || catalogAccounts[client] == nil else {
            catalogMessage = "Saved library · Go online to install games."
            return
        }
        guard !loadingCatalog else { catalogRefreshQueue.insert(client); return }
        catalogRefreshQueue.remove(client)
        catalogAttemptedAt[client] = Date()
        loadingCatalog = true
        catalogMessage = "Loading your \(client.name) Steam library…"
        catalogTask = Task { [weak self] in
            guard let self else { return }
            do { try await self.fetchSteamLibrary(client) }
            catch { if !Task.isCancelled { self.catalogMessage = error.localizedDescription } }
            guard !Task.isCancelled else { return }
            self.loadingCatalog = false; self.catalogTask = nil
            self.refreshQueuedCatalog()
        }
    }

    private func fetchSteamLibrary(_ client: GamePlatform) async throws {
        let root: URL, profileID: String?, command: LaunchCommand
        let nonce = UUID()
        do {
            if client == .windows {
                guard let profile = selectedProfile, let executable = steamExecutable else { catalogMessage="Choose a Steam environment first."; return }
                guard session.context?.profile.id == profile.id else { connectSteam(.windows); catalogMessage = "Connecting to Windows Steam. Refresh its library when connected."; return }
                root = executable.deletingLastPathComponent(); profileID = profile.id
                var request = try await runtimeService.command(profile: profile, executable: executable)
                request.arguments += SteamCatalog.commandArguments(nonce: nonce)
                command = try await session.attach(request, profile: profile)
            } else {
                guard !(await steamMainApplications(.macOS)).isEmpty else {
                    connectSteam(.macOS); catalogMessage = "Connecting to Mac Steam. Refresh its library when connected."; return
                }
                root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Steam")
                profileID = nil
                command = try await session.backend.macCommand(arguments:SteamCatalog.commandArguments(nonce:nonce),port:macControlPort)
            }
        } catch { self.error = error.localizedDescription; return }
        let service = libraryService(client)
        guard let account = await service.currentAccount(root: root) else { catalogMessage = "Sign in through Steam, then refresh its library."; return }
        let hadSavedLibrary=catalogAccounts[client] != nil
        let macRoot=FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Steam")
        let macAccount = await macLibraryService.currentAccount(root: macRoot)
        let sameMacAccount = client == .windows && includesMacSteam && macAccount == account && (connectionMode(.macOS) == .online || catalogAccounts[.macOS] == nil)
        loadingCatalog = true; catalogMessage = "Loading your \(client == .macOS ? "Mac" : "Windows") Steam library…"
        let owned = try? await self.controlClient(client).ownedGameIDs()
        let response = owned == nil ? try await service.refreshResponse(command: command, root: root, nonce: nonce) : nil
        let snapshot = try await service.catalog(owned: owned, response: response, root: root, profileID: profileID)
        let macSnapshot = sameMacAccount ? try await macLibraryService.catalog(owned: owned, response: response, root: root, profileID: nil) : nil
        guard !Task.isCancelled else { return }
        let mode=try await self.controlClient(client).snapshot().mode
        guard mode == .online || (mode == .offline && !hadSavedLibrary) else {
            throw WayfarerError.message("Your saved library is unchanged. Go online to refresh it.")
        }
        guard account == (await service.currentAccount(root: root)), client == .macOS || self.selectedProfile?.id == profileID else {
            throw WayfarerError.message("The Steam account or environment changed. Refresh its library again.")
        }
        self.catalog.removeAll { $0.client == client }; self.catalog += snapshot.games
        self.catalogAccounts[client] = account
        self.catalogRoots[client] = root
        try await service.saveCatalog(games: snapshot.games, account: account, root: root, profileID: profileID)
        guard !Task.isCancelled else { return }
        if let mac = macSnapshot, await macLibraryService.currentAccount(root: macRoot) == account {
            self.catalog.removeAll { $0.client == .macOS }; self.catalog += mac.games
            self.catalogAccounts[.macOS] = account
            self.catalogRoots[.macOS] = macRoot
            try await macLibraryService.saveCatalog(games: mac.games, account: account, root: macRoot, profileID: nil)
            guard !Task.isCancelled else { return }
            self.catalogAttemptedAt[.macOS] = Date()
            self.catalogRefreshQueue.remove(.macOS)
        }
        self.catalogMessage = snapshot.games.isEmpty ? "No games returned. Sign in through Steam and refresh its library." : "\(snapshot.games.count) \(client == .macOS ? "Mac" : "Windows") games loaded from Steam" + (snapshot.missingMetadata > 0 ? " · Some titles still need metadata from Steam" : "")
    }

    private func clearCatalogAccount(_ client: GamePlatform) {
        friendsSnapshots.removeValue(forKey: client); friendsMessages.removeValue(forKey: client)
        cloudStatuses = cloudStatuses.filter { !$0.key.hasSuffix(":" + client.rawValue) }
        catalog.removeAll { $0.client == client }; catalogAccounts.removeValue(forKey: client)
        catalogRoots.removeValue(forKey: client); catalogAttemptedAt.removeValue(forKey: client)
    }

    private func applyCatalogAccount(_ snapshot: SteamLibraryAccountSnapshot) {
        let client = snapshot.client
        if currentSteamAccounts[client] != snapshot.account { currentSteamAccounts[client] = snapshot.account }
        if (catalogAccounts[client] != nil || catalogRoots[client] != nil),
           catalogAccounts[client] != snapshot.account || catalogRoots[client] != snapshot.root {
            clearCatalogAccount(client)
        }
        guard catalogAccounts[client] == nil, let account = snapshot.account, let saved = snapshot.saved else { return }
        catalog.removeAll { $0.client == client }; catalog += saved.games
        catalogAccounts[client] = account; catalogRoots[client] = snapshot.root
        catalogMessage = "Saved library · Updates when Steam is online."
    }

    private func restoreCachedCatalogs() {
        guard !refreshing, catalogRestoreTask == nil else { return }
        let scopes = GamePlatform.allCases.compactMap { client -> (GamePlatform, URL, String?)? in
            guard client == .windows || includesMacSteam, let context = steamContext(client) else { return nil }
            return (client, context.root, client == .windows ? selectedProfile?.id : nil)
        }
        let previousAccounts = catalogAccounts, previousRoots = catalogRoots
        catalogRestoreTask = Task { [weak self] in
            guard let self else { return }
            var snapshots: [SteamLibraryAccountSnapshot] = []
            for scope in scopes {
                snapshots.append(await self.libraryService(scope.0).account(root: scope.1, profileID: scope.2))
            }
            guard !Task.isCancelled else { return }
            self.catalogRestoreTask = nil
            for snapshot in snapshots {
                guard snapshot.client != .macOS || self.includesMacSteam,
                      snapshot.client != .windows || snapshot.profileID == self.selectedProfile?.id,
                      self.steamContext(snapshot.client)?.root == snapshot.root,
                      self.catalogAccounts[snapshot.client] == previousAccounts[snapshot.client],
                      self.catalogRoots[snapshot.client] == previousRoots[snapshot.client] else { continue }
                self.applyCatalogAccount(snapshot)
            }
        }
    }
    private func refreshQueuedCatalog() {
        guard !gameplayQuiet, !loadingCatalog, let client=GamePlatform.allCases.first(where:{catalogRefreshQueue.contains($0) && (connectionMode($0) == .online || (connectionMode($0) == .offline && catalogAccounts[$0] == nil))}) else { return }
        loadSteamLibrary(client)
    }
    private func refreshOnlineCatalog(_ client: GamePlatform) {
        // Seed an empty offline cache once; only online sessions replace existing catalogs.
        guard connectionMode(client) == .online || (connectionMode(client) == .offline && catalogAccounts[client] == nil),
              Date().timeIntervalSince(catalogAttemptedAt[client] ?? .distantPast) > 900 else { return }
        catalogRefreshQueue.insert(client); refreshQueuedCatalog()
    }
    func installationDisabled(_ game: LibraryGame, platform: GamePlatform?) -> Bool {
        guard let platform else { return false }
        return connectionMode(platform) != .online && game.unavailableOffline(for:platform)
    }
    func preferredGamePlatform(_ game: LibraryGame) -> GamePlatform? {
        let preferred=preferences(for:game).preferredPlatform.flatMap { game.platforms.contains($0) ? $0 : nil } ?? game.preferredPlatform
        if installationDisabled(game,platform:preferred), let installed=game.preferredInstallation { return installed.platform }
        return preferred
    }
    func installationAvailabilityMessage(_ platform: GamePlatform) -> String {
        switch connectionMode(platform) {
        case .offline: return "Offline · Install when online"
        case .signedOut: return "Sign in to install"
        case .unavailable: return "Connect Steam to install"
        case .online: return "Ready to install"
        }
    }

    private func launchMacSteam(_ game: SteamGame, arguments:[String] = []) {
        connectSteam(.macOS)
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.waitForSteamConnection(.macOS)
                _=try NativeGameLaunch.steamURL(appID:game.appID)
                guard self.connectionMessages[.macOS]==nil else { throw WayfarerError.message(self.connectionMessages[.macOS]!) }
                self.status="Opening \(game.name) on your Mac…"
                try await self.runMacSteam(arguments:["-applaunch",game.appID]+arguments); self.markLaunch(game.name,outcome:"Launch sent to Mac Steam")
            } catch { self.failGameSession("steam:"+game.appID,message:error.localizedDescription); self.markLaunch(game.name,outcome:error.localizedDescription); self.error=error.localizedDescription }
        }
    }

    private func macSteamClient() throws -> URL {
        guard let client = discoveredMacSteamClient else {
            throw WayfarerError.message("Install macOS Steam to play Mac Steam games. Windows Steam stays separate in Wayfarer.")
        }
        return client
    }
    func runtimeFingerprint(_ profile: RuntimeProfile) -> String { runtimeFingerprints[profile.id] ?? "unavailable" }

    func openSteamClient(_ platform: GamePlatform, destination: SteamUIRequest.Destination = .account, friendID:String? = nil) {
        if platform == .windows, selectedProfile?.reusesExistingSteam != true {
            if case .workshop(let url) = destination {
                guard let profile = selectedProfile, steamExecutable != nil else { error = "Choose an installed Steam environment first."; return }
                Task {
                    do {
                        var command = try await runtimeService.command(profile: profile, executable: steamExecutable)
                        command.arguments += ["-silent", url.absoluteString]
                        try await run(command, title: "Steam Workshop", profile: profile, presentSession: false)
                        session.showSteam(); sessionRequest = UUID()
                    } catch { self.error = error.localizedDescription }
                }
                return
            }
            if destination == .chat {
                guard let profile=selectedProfile,steamExecutable != nil else { error="Set up Windows Steam in Engines before opening chat."; return }
                Task {
                    do {
                        var command = try await runtimeService.command(profile: profile, executable: steamExecutable)
                        command.arguments += ["-silent","steam://open/friends"]
                        try await run(command,title:"Steam Chat",profile:profile,presentSession:false)
                        session.showChat(); chatRequest=UUID()
                        if let friendID { Task { try? await Task.sleep(for:.seconds(1)); try? await self.controlClient(.windows).openFriend(friendID) } }
                    } catch { self.error=error.localizedDescription }
                }
            } else { launchSteam() }
            return
        }
        if platform == .windows {
            guard let profile=selectedProfile, let steam=steamExecutable else { error="Choose an installed Steam environment first."; return }
            steamUIRequest=SteamUIRequest(platform:platform,root:steam.deletingLastPathComponent(),prefix:profile.prefix,destination:destination,friendID:friendID)
        } else {
            guard (try? macSteamClient()) != nil else { error="Install macOS Steam to use its account panel."; return }
            steamUIRequest=SteamUIRequest(platform:platform,root:FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Steam"),prefix:nil,destination:destination,friendID:friendID)
        }
    }
    func displaySteamWindow(_ request:SteamUIRequest) {
        guard steamUIRequest?.id==request.id else { return }
        connectSteam(request.platform)
    }

    private func setSteamClientHidden(_ platform: GamePlatform, hidden: Bool) async {
        if platform == .windows, selectedProfile?.reusesExistingSteam != true { return }
        for app in await steamMainApplications(platform) {
            if hidden { app.hide() } else { app.unhide() }
        }
    }

    func runMacSteam(arguments:[String]=[]) async throws {
        guard !shuttingDown else { throw CancellationError() }
        if discoveredControlPorts[.macOS] == nil, (await steamMainApplications(.macOS)).isEmpty { macControlPort=try SteamControlEndpoint.availablePort() }
        let command=try await session.backend.macCommand(arguments:arguments,port:macControlPort)
        try Task.checkCancellation()
        guard !shuttingDown else { throw CancellationError() }
        let id=UUID()
        let launch = try await processService.start(command, id: id)
        launches[id] = launch
        await processService.observe(id) { [weak self] _ in
            Task { @MainActor in self?.launches.removeValue(forKey: id) }
        }
    }

    func steamContext(_ client:GamePlatform) -> (root:URL,prefix:URL?)? {
        if client == .macOS { return (FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Steam"),nil) }
        guard let profile=selectedProfile,let steam=steamExecutable else { return nil }
        return (steam.deletingLastPathComponent(),profile.prefix)
    }
    private func steamMainApplications(_ client: GamePlatform) async -> [NSRunningApplication] {
        guard let context = steamContext(client) else { return [] }
        let apps = NSWorkspace.shared.runningApplications
        let pids = apps.map(\.processIdentifier)
        let verified = await runtimeProcesses.mainSteamProcesses(pids: pids, root: context.root, prefix: context.prefix, windows: client == .windows)
        guard !Task.isCancelled, steamContext(client)?.root == context.root else { return [] }
        return apps.filter { !($0.isTerminated) && verified[$0.processIdentifier] != nil && RuntimeProcessIdentity.token(for: $0.processIdentifier) == verified[$0.processIdentifier] }
    }
    private func ensureSteamBackend(_ client:GamePlatform, allowUncontrolledRestart:Bool = false) async throws {
        if client == .windows, selectedProfile?.reusesExistingSteam != true { return }
        guard let context=steamContext(client) else { throw WayfarerError.message("Choose a Steam environment first.") }
        let existing=await steamMainApplications(client)
        try Task.checkCancellation()
        guard !existing.isEmpty else { return }
        if await session.backend.allAttached(existing, root: context.root, prefix: context.prefix) { return }
        try Task.checkCancellation()
        if client == .windows { windowsSteamNeedsRecovery=true }
        await setSteamClientHidden(client,hidden:true)
        if let prefix=context.prefix {
            let apps = try await runtimeProcesses.windowsApps(prefix: prefix)
            try Task.checkCancellation()
            guard apps.isEmpty else {
                throw WayfarerError.message("Windows apps are running. Use Manage Windows apps to close them and reconnect Steam.")
            }
        }
        let activity:([String],SteamControlSnapshot)?
        do {
            let control=try controlClient(client)
            activity=(try await control.runningAppIDs(),try await control.snapshot())
        } catch {
            // Clean verified orphan Steam PIDs only after excluding active apps and installations.
            guard client == .windows,let prefix=context.prefix else {
                throw WayfarerError.message("Close the existing Steam client, then reconnect it in Wayfarer to apply background mode.")
            }
            async let scan = windowsLibraryService.scan(root: context.root, prefix: prefix)
            async let apps = runtimeProcesses.windowsApps(prefix: prefix)
            async let hasServer = runtimeProcesses.hasWineServer(prefix: prefix)
            let state = try await (scan, apps.isEmpty, hasServer)
            guard state.1, state.0.transfers.isEmpty, state.0.warnings.isEmpty else {
                throw WayfarerError.message("Finish the running games and installations before reconnecting Steam.")
            }
            if allowUncontrolledRestart {
                // After app review, request Steam shutdown without terminating the Wine server.
                activity=nil
            } else {
                guard !state.2 else {
                    throw WayfarerError.message("Steam needs to reconnect. Open Manage Windows apps to restart its backend.")
                }
                try Task.checkCancellation()
                try await runtimeProcesses.terminateOrphanSteam(root: context.root, prefix: prefix)
                try await backendCoordinator(client).waitForExit(attempts: 40, check: { [weak self] in
                    guard let self else { throw CancellationError() }
                    return await self.steamMainApplications(client).isEmpty
                })
                return
            }
        }
        if let (running,snapshot)=activity {
            guard running.isEmpty,!snapshot.downloads.contains(where:{$0.active}) else {
                throw WayfarerError.message("Steam is running a game or downloading. Finish it, then reconnect Steam to apply background mode.")
            }
        }
        try Task.checkCancellation()
        connectionMessages[client]="Restarting Steam in the background…"
        if client == .macOS { try await runMacSteam(arguments:["-shutdown"]) }
        else if let profile=selectedProfile {
            var command = try await runtimeService.command(profile: profile, executable: steamExecutable)
            command.arguments += ["-silent","-shutdown"]
            try await run(command,title:"Steam",profile:profile,presentSession:false)
        }
        let processes = runtimeProcesses
        try await backendCoordinator(client).waitForExit(attempts: 80, settle: true, check: {
            try await processes.steamProcesses(root: context.root, prefix: context.prefix).isEmpty
        })
    }

    func showWindowsSession() { launchSteam() }

    private func queueWindowsLaunch(profile: RuntimeProfile, gameID: String?, action: @escaping @MainActor () -> Void) -> Bool {
        guard connectionBusy.contains(.windows) else { return false }
        Task { [weak self] in
            guard let self else { return }
            do { try await self.waitForSteamConnection(.windows) } catch { return }
            guard self.selectedProfile?.id == profile.id, self.session.context?.profile.id == profile.id else {
                let message = self.connectionMessages[.windows] ?? "Windows Steam could not be prepared. Reconnect it and try again."
                if let gameID { self.failGameSession(gameID, message: message) }
                self.error = message
                return
            }
            action()
        }
        return true
    }

    func launchSteam(appID: String? = nil, gameArguments:[String] = []) {
        guard !installing else { return }
        guard let profile = selectedProfile else { error = "Choose an available environment in Engines."; return }
        if queueWindowsLaunch(profile: profile, gameID: appID.map { "steam:" + $0 }, action: { [weak self] in self?.launchSteam(appID: appID, gameArguments: gameArguments) }) { return }
        Task { [self] in
            if let appID,profile.reusesExistingSteam,let context=steamContext(.windows) {
                let clients=await steamMainApplications(.windows)
                let attached = await session.backend.allAttached(clients, root: context.root, prefix: context.prefix)
                if connectionBusy.contains(.windows) || clients.isEmpty || !attached {
                    connectSteam(.windows)
                    Task { [weak self] in
                        guard let self else { return }
                        do { try await self.waitForSteamConnection(.windows) } catch { return }
                        guard self.selectedProfile?.id==profile.id else { return }
                        let connected=await self.steamMainApplications(.windows)
                        guard !connected.isEmpty, await self.session.backend.allAttached(connected, root: context.root, prefix: context.prefix) else {
                            self.error=self.connectionMessages[.windows] ?? "Steam’s backend has not started. Reconnect Steam, then try Play again."
                            self.failGameSession("steam:"+appID,message:self.error!)
                            return
                        }
                        self.launchSteam(appID:appID,gameArguments:gameArguments)
                    }
                    return
                }
            }
            if appID==nil && profile.reusesExistingSteam { openSteamClient(.windows); return }
            guard steamExecutable != nil else { installSteam(); return }
            do {
                var command = try await runtimeService.command(profile: profile, executable: steamExecutable, appID: appID, gameArguments: gameArguments)
                if appID == nil { command.arguments += ["steam://open/main"] }
                let title = appID.flatMap { id in games.first { $0.appID == id }?.name } ?? "Steam"
                if let appID { pendingGameTitle = title; pendingGameID = "steam:\(appID)" }
                try await run(command, title: title, profile: profile, presentSession:false)
                if appID == nil && !profile.reusesExistingSteam { session.showSteam(); sessionRequest=UUID() }
            } catch { if let appID { failGameSession("steam:"+appID,message:error.localizedDescription) };pendingGameTitle = nil; pendingGameID = nil; self.error = error.localizedDescription }
        }
    }

    func launchGame(_ game: AddedGame) {
        if game.effectivePlatform == .macOS {
            Task { [self] in
            do {
                try await FileService.shared.validateApplication(game.executable)
                let options = NSWorkspace.OpenConfiguration(); options.arguments = game.arguments
                status = "Opening \(game.name) on your Mac…"
                NSWorkspace.shared.openApplication(at: game.executable, configuration: options) { [weak self] app, failure in
                    Task { @MainActor in
                        guard let self else { return }
                        if let failure { self.failGameSession("added:"+game.id.uuidString,message:failure.localizedDescription);self.markLaunch(game.name,outcome:failure.localizedDescription); self.error = failure.localizedDescription; return }
                        if let app, !app.isTerminated {
                            if let record=self.activeSession("added:"+game.id.uuidString),let token=RuntimeProcessIdentity.token(for:app.processIdentifier) { self.observeGameSession(record.id,running:true); Task {
                                await self.sessionCoordinator.synchronize(self.gameSessions, revision: self.sessionHistoryRevision)
                                await self.sessionCoordinator.register([token], for: record.id)
                            } }
                            self.markLaunch(game.name,outcome:"Native application opened")
                            if self.nativeApplications[app.processIdentifier] == nil {
                                let id = UUID(); self.nativeApplications[app.processIdentifier] = (id, game.name)
                                self.activeLaunches[id] = game.name
                            }
                            if let index = self.configuration.addedGames.firstIndex(where: { $0.id == game.id }) {
                                self.configuration.addedGames[index].lastPlayed = Date().timeIntervalSince1970
                                self.save()
                            }
                        }
                    }
                }
            } catch { failGameSession("added:"+game.id.uuidString,message:error.localizedDescription);self.error = error.localizedDescription }
            }
            return
        }
        guard let profile = selectedProfile, game.profileID == profile.id else { return }
        if queueWindowsLaunch(profile: profile, gameID: "added:" + game.id.uuidString, action: { [weak self] in self?.launchGame(game) }) { return }
        Task {
            do {
                pendingGameTitle = game.name; pendingGameID = "added:\(game.id.uuidString)"
                try await run(try await runtimeService.launch(profile: profile, program: game.executable, arguments: game.arguments), title: game.name, profile: profile, presentSession: false)
            } catch { failGameSession("added:"+game.id.uuidString,message:error.localizedDescription);pendingGameTitle = nil; pendingGameID = nil; self.error = error.localizedDescription }
        }
    }

    func run(_ command: LaunchCommand, title: String, profile: RuntimeProfile, presentSession: Bool = true) async throws {
        guard !shuttingDown else { throw CancellationError() }
        if presentSession, session.context?.profile.id == profile.id,
           let existing = launchContexts.values.first(where: { $0.title == title && $0.profile.id == profile.id }) {
            try session.begin(existing)
            session.chooseWindow(session.windows.first(where: { !$0.isSteamClient && !$0.program.isEmpty })?.id ?? session.selectedWindowID ?? "")
            pendingGameTitle = nil
            sessionRequest = UUID()
            return
        }
        if let prefix = command.environment["WINEPREFIX"] {
            try await runtimeService.createDirectory(URL(fileURLWithPath: prefix))
        }
        let id = UUID()
        try await session.prepare(SessionContext(profile: profile, title: title))
        try Task.checkCancellation()
        guard !shuttingDown, selectedProfile?.id == profile.id else { throw CancellationError() }
        let nativeCommand = try await session.attach(command, profile: profile)
        try Task.checkCancellation()
        guard !shuttingDown, selectedProfile?.id == profile.id else { throw CancellationError() }
        let launch = try await processService.start(nativeCommand, id: id)
        guard !shuttingDown, !Task.isCancelled, selectedProfile?.id == profile.id else {
            await processService.observe(id) { _ in }
            throw CancellationError()
        }
        launches[id] = launch
        activeLaunches[id] = title
        latestLog = launch.logURL
        status = "Launched \(title)"
        let context = SessionContext(profile: profile, title: title, launch: launch.token)
        launchContexts[id] = context
        var presentationError: Error?
        do {
            try session.begin(context, expectsWindow: presentSession)
            if presentSession { sessionRequest = UUID() }
        } catch { presentationError = error }
        await processService.observe(id) { [weak self] code in
            Task { @MainActor in
                guard let self else { return }
                guard self.launches.removeValue(forKey: id) != nil else { return }
                self.launchContexts.removeValue(forKey: id)
                self.activeLaunches.removeValue(forKey: id)
                // The -applaunch command may exit before the actual game starts.
                if code != 0 && self.pendingGameTitle == title { self.pendingGameTitle = nil; self.pendingGameID = nil }
                if code != 0 {
                    if let record=self.gameSessions.last(where:{$0.name==title && $0.phase.active}) {
                        let direct=record.gameID.hasPrefix("added:") && record.startedAt != nil
                        self.endGameSession(record.id,phase:direct ? .crashed : .failed,message:"Game launch exited with code \(code). See launch diagnostics.")
                    }
                    if title != "Steam" { self.error="\(title) exited with code \(code). Open the latest session log for details." }
                }
                self.status = code == 0 ? "\(title) launch command finished" : "\(title) launch failed"
                self.markLaunch(title,outcome:code == 0 ? "Launch command accepted" : "Launch exited with code \(code)")
                self.refreshLibrarySnapshot()
            }
        }
        if let presentationError { throw presentationError }
    }

    func disconnectSession() {
        setupTask?.cancel()
        catalogTask?.cancel(); catalogTask = nil; loadingCatalog = false; requestedCatalogForSession = false
        friendsSnapshots.removeValue(forKey:.windows); cloudStatuses=cloudStatuses.filter{!$0.key.hasSuffix(":windows")}
        catalog.removeAll { $0.client == .windows }; catalogAccounts.removeValue(forKey: .windows)
        currentSteamAccounts.removeValue(forKey: .windows)
        catalogRoots.removeValue(forKey:.windows); catalogAttemptedAt.removeValue(forKey:.windows); catalogRefreshQueue.remove(.windows)
        controlClients.removeValue(forKey:.windows); steamConnections.removeValue(forKey:.windows)
        pendingGameTitle = nil; pendingGameID = nil; gameWindowPeers.removeAll()
        launchContexts.removeAll(); launches.removeAll()
        let nativeIDs = Set(nativeApplications.values.map { $0.0 })
        activeLaunches = activeLaunches.filter { nativeIDs.contains($0.key) }
        session.end()
    }

    func runInstaller() {
        guard let profile = selectedProfile, let file = chooseExecutable(title: "Run a Windows installer") else { return }
        Task {
            do { try await run(try await runtimeService.launch(profile: profile, program: file), title: file.lastPathComponent, profile: profile) }
            catch { self.error = error.localizedDescription }
        }
    }

    func installSteam() {
        guard !installing, let profile = selectedProfile else { return }
        sessionRequest = UUID()
        startSteamSetup(profile)
    }

    private func startSteamSetup(_ profile: RuntimeProfile) {
        guard !installing else { return }
        installing = true
        setupMessage = "Downloading Steam from Valve…"
        status = setupMessage
        setupTask = Task {
            defer { installing = false }
            do {
                try await session.prepare(SessionContext(profile: profile, title: "Steam"))
                let url = URL(string: "https://cdn.akamai.steamstatic.com/client/installer/SteamSetup.exe")!
                let (data, response) = try await URLSession.shared.data(from: url)
                guard let response = response as? HTTPURLResponse, response.statusCode == 200,
                      data.count > 2, data.starts(with: [0x4d, 0x5a]) else {
                    throw WayfarerError.message("Valve's download did not return a Windows Steam installer. Please try setup again.")
                }
                try Task.checkCancellation()
                let directory = AppPaths.support.appendingPathComponent("Installers")
                let file = directory.appendingPathComponent("SteamSetup.exe")
                try await FileService.shared.write(data, to: file)
                if let preparation = try await runtimeService.prepareNewProfile(profile) {
                    setupMessage = "Creating Wayfarer's Windows environment…"
                    status = setupMessage
                    let code = try await runPreparation(preparation)
                    try Task.checkCancellation()
                    guard code == 0 else { throw WayfarerError.message("Preparing the Windows environment failed (\(code)). Check the session log.") }
                }
                setupMessage = "Installing Steam for Wayfarer…"
                status = setupMessage
                let installerCommand = try await session.attach(try await runtimeService.installSteam(profile: profile, installer: file), profile: profile)
                let code = try await runPreparation(installerCommand)
                try Task.checkCancellation()
                guard code == 0 else { throw WayfarerError.message("Steam installation failed (\(code)). Open the latest session log for details.") }
                guard let steam = await runtimeService.steamExecutable(profile: profile) else { throw WayfarerError.message("Steam setup finished without installing steam.exe in Wayfarer's environment. Please retry setup.") }
                setupMessage = "Starting Steam. Sign in with your Steam account…"
                try await run(try await runtimeService.command(profile: profile, executable: steam), title: "Steam", profile: profile)
                refresh()
            } catch is CancellationError {
                status = "Steam setup paused. Open Steam to continue."
            } catch {
                if Task.isCancelled { status = "Steam setup paused. Open Steam to continue." }
                else {
                    setupMessage = "Steam setup could not finish."
                    self.error = error.localizedDescription
                    session.end()
                }
            }
        }
    }

    private func runPreparation(_ command: LaunchCommand) async throws -> Int32 {
        let id = UUID()
        for key in ["CX_BOTTLE_PATH", "WINEPREFIX"] {
            if let path = command.environment[key] { try await runtimeService.createDirectory(URL(fileURLWithPath: path)) }
        }
        let launch = try await processService.start(command, id: id)
        launches[id] = launch; latestLog = launch.logURL
        let code = try await processService.wait(id)
        launches[id] = nil
        return code
    }

    func openRuntime(_ runtime: RuntimeInstallation) {
        var url = runtime.executable
        while url.path != "/" {
            if url.pathExtension == "app" { NSWorkspace.shared.open(url); return }
            url.deleteLastPathComponent()
        }
        NSWorkspace.shared.open(runtime.kind.setupURL)
    }

    func openLogs() {
        Task {
            do { try await runtimeService.createDirectory(AppPaths.logs); NSWorkspace.shared.open(AppPaths.logs) }
            catch { self.error = error.localizedDescription }
        }
    }

    func chooseExecutable(title: String, platform: GamePlatform = .windows) -> URL? {
        let panel = NSOpenPanel()
        panel.title = title
        panel.allowedContentTypes = platform == .macOS ? [.applicationBundle] : [UTType(filenameExtension: "exe") ?? .data]
        panel.canChooseDirectories = false
        return panel.runModal() == .OK ? panel.url : nil
    }
}

struct GameInstallationRequest: Identifiable, Sendable {
    let id=UUID()
    let game: LibraryGame
    let platform: GamePlatform
    let appID: String
}
struct GameUninstallationRequest:Identifiable, Sendable {
    let id=UUID()
    let game:LibraryGame
    let platform:GamePlatform
    let appID:String
    let profileID:String?
    let location:URL
}

extension LauncherModel {
    func requestUninstall(_ game:LibraryGame,platform:GamePlatform) {
        guard activeSession(game.id)==nil,!(maintenance[game.id+":"+platform.rawValue].map{!$0.completed && !$0.failed} ?? false) else{error="Close the game and finish its current file operation before uninstalling.";return}
        guard installationRequest == nil, uninstallationRequest == nil, !uninstallBusy,
              let installation=game.installation(for:platform), let steam=installation.steamGame else { return }
        uninstallationRequest=GameUninstallationRequest(game:game,platform:platform,appID:steam.appID,profileID:platform == .windows ? selectedProfile?.id : nil,location:installation.location)
        uninstallMessage=""
    }

    func confirmUninstall() {
        guard !shuttingDown, let request = uninstallationRequest, !uninstallBusy else { return }
        uninstallBusy = true; uninstallMessage = "Connecting to Steam…"
        installationRevision += 1; let revision = installationRevision, epoch = workflowRevision
        Task { [weak self] in
            guard let self else { return }
            await installationCoordinator.uninstall(revision: revision, requestID: request.id, appID: request.appID,
                resolve: { [weak self] in
                    guard let self else { throw CancellationError() }
                    return try await self.uninstallationControl(request)
                }, publish: { [weak self] event in
                    await self?.applyUninstallationEvent(event, request: request, revision: epoch)
                })
        }
    }
    private func uninstallationControl(_ request: GameUninstallationRequest) async throws -> any SteamWorkflowControl {
        try await backendCoordinator(request.platform).installationControl(state: { [weak self] in
            guard let self else { throw CancellationError() }
            return try await self.uninstallationConnectionState(request)
        }, connect: { [weak self] in await self?.connectSteam(request.platform) })
    }
    private func uninstallationConnectionState(_ request: GameUninstallationRequest) throws -> SteamConnectionAvailability {
        guard !shuttingDown, uninstallationRequest?.id == request.id,
              request.platform == .macOS || request.profileID == selectedProfile?.id else { throw CancellationError() }
        return SteamConnectionAvailability(control: try? controlClient(request.platform), busy: connectionBusy.contains(request.platform), message: connectionMessages[request.platform])
    }
    private func applyUninstallationEvent(_ event: UninstallationEvent, request: GameUninstallationRequest, revision: Int) async {
        guard !shuttingDown, workflowRevision == revision, uninstallationRequest?.id == request.id else { return }
        switch event {
        case .starting: uninstallMessage = "Uninstalling \(request.game.name)…"
        case .failed(let message): uninstallMessage = message; uninstallBusy = false
        case .finished(let current):
            uninstallationRequest = nil; uninstallMessage = ""; uninstallBusy = false
            if request.platform == .macOS { macGames.removeAll { $0.appID == request.appID } }
            else { games.removeAll { $0.appID == request.appID } }
            if current.owned, let root = steamContext(request.platform)?.root,
               let account = await libraryService(request.platform).currentAccount(root: root), !shuttingDown, workflowRevision == revision,
               !catalog.contains(where: { $0.appID == request.appID && $0.client == request.platform }) {
                catalogAccounts[request.platform] = account; catalogRoots[request.platform] = root
                catalog.append(SteamCatalogGame(appID: request.appID, name: request.game.name, client: request.platform,
                    profileID: request.profileID, artwork: request.game.artwork, heroArtwork: request.game.heroArtwork))
                try? await libraryService(request.platform).saveCatalog(games: catalog.filter { $0.client == request.platform }, account: account, root: root, profileID: request.profileID)
            }
            guard !shuttingDown, workflowRevision == revision else { return }
            status = "Uninstalled \(request.game.name) · \(request.platform.name)"
            refreshLibrarySnapshot(); refreshSteamControls()
        }
    }
    private func publishSteamSnapshot(_ snapshot: SteamControlSnapshot, client: GamePlatform) {
        if steamConnections[client] != snapshot { steamConnections[client] = snapshot }
    }
    private func refreshSteamAccount(_ client: GamePlatform) async {
        guard let context = steamContext(client) else { return }
        let profileID = selectedProfile?.id
        let account = await libraryService(client).currentAccount(root: context.root)
        guard !Task.isCancelled, steamContext(client)?.root == context.root,
              client == .macOS || selectedProfile?.id == profileID else { return }
        if currentSteamAccounts[client] != account {
            clearCatalogAccount(client)
            currentSteamAccounts[client] = account
        }
    }

    private func setConnectionMessage(_ message: String?, client: GamePlatform) {
        if connectionMessages[client] != message { connectionMessages[client] = message }
    }

    func connectionMode(_ client: GamePlatform) -> SteamConnectionMode { steamConnections[client]?.mode ?? .unavailable }
    private func discoverSteamControl(_ client: GamePlatform) async {
        guard let context = steamContext(client) else { return }
        let profileID = selectedProfile?.id
        let port = await runtimeProcesses.controlPort(root: context.root, prefix: context.prefix)
        guard !Task.isCancelled, steamContext(client)?.root == context.root,
              client == .macOS || selectedProfile?.id == profileID else { return }
        discoveredControlPorts[client] = port
        if client == .macOS, let port { macControlPort = port }
    }

    func controlClient(_ client: GamePlatform) throws -> SteamControl {
        let endpoint:SteamControlEndpoint
        if client == .windows {
            guard let profile=selectedProfile,let steam=steamExecutable else {
                throw WayfarerError.message("Open Windows Steam from Wayfarer to connect.")
            }
            let root=steam.deletingLastPathComponent()
            let discovered=profile.reusesExistingSteam ? discoveredControlPorts[client] : nil
            guard let port=discovered ?? (session.context?.profile.id==profile.id ? session.steamControlPort : nil),port>1024 else {
                throw WayfarerError.message("Connect Windows Steam in Wayfarer to use its controls.")
            }
            endpoint=SteamControlEndpoint(port:port,root:root,prefix:profile.prefix)
        } else {
            let root=FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Steam")
            endpoint=SteamControlEndpoint(port:macControlPort,root:root)
        }
        if controlPorts[client]==endpoint.port, let saved=controlClients[client] { return saved }
        let control=SteamControl(endpoint:endpoint); controlClients[client]=control; controlPorts[client]=endpoint.port; return control
    }
    private func waitForSteamConnection(_ client: GamePlatform) async throws {
        let revision = workflowRevision
        try await backendCoordinator(client).waitForConnection(busy: { [weak self] in
            guard let self else { throw CancellationError() }
            return try await self.connectionIsBusy(client, revision: revision)
        })
    }
    private func connectionIsBusy(_ client: GamePlatform, revision: Int) throws -> Bool {
        guard !shuttingDown, workflowRevision == revision else { throw CancellationError() }
        return connectionBusy.contains(client)
    }
    private func resolveBackendControl(_ client: GamePlatform, revision: Int) async throws -> SteamControl {
        guard !shuttingDown, workflowRevision == revision else { throw CancellationError() }
        await discoverSteamControl(client)
        await refreshSteamAccount(client)
        guard !shuttingDown, workflowRevision == revision else { throw CancellationError() }
        return try controlClient(client)
    }
    private func applyBackendEvent(_ event: BackendEvent, client: GamePlatform, revision: Int, connecting: Bool) async {
        guard !shuttingDown, workflowRevision == revision else { return }
        switch event {
        case .connected(let snapshot):
            publishSteamSnapshot(snapshot, client: client)
            if connecting || !connectionBusy.contains(client) { setConnectionMessage(nil, client: client) }
            if client == .windows, connecting { windowsSteamNeedsRecovery = false }
            restoreCachedCatalogs(); refreshOnlineCatalog(client)
            if connecting, let request = steamUIRequest, request.platform == client, request.destination == .chat, let friend = request.friendID {
                try? await controlClient(client).openFriend(friend)
            }
            guard !shuttingDown, workflowRevision == revision else { return }
            if client == .windows, selectedProfile?.reusesExistingSteam == true,
               let pending = pendingGameID, pending.hasPrefix("steam:"),
               let state = try? await controlClient(client).appState(appID: String(pending.dropFirst(6))), state.isRunning,
               workflowRevision == revision, pendingGameID == pending {
                status = "Playing \(pendingGameTitle ?? "game")"; pendingGameTitle = nil; pendingGameID = nil
            }
        case .disconnected:
            steamConnections.removeValue(forKey: client)
            await recoverBackendIfSafe(client, revision: revision)
        case .message(let message): setConnectionMessage(message, client: client)
        case .finished: connectionBusy.remove(client)
        }
    }
    func refreshSteamControls() {
        guard !shuttingDown else { return }
        let revision = workflowRevision
        for client in GamePlatform.allCases where client == .windows || includesMacSteam {
            Task { [weak self] in
                guard let self else { return }
                await backendCoordinator(client).refresh(revision: revision,
                    resolve: { [weak self] in
                        guard let self else { throw CancellationError() }
                        return try await self.resolveBackendControl(client, revision: revision)
                    }, publish: { [weak self] event in
                        await self?.applyBackendEvent(event, client: client, revision: revision, connecting: false)
                    })
            }
        }
    }
    func connectSteam(_ client: GamePlatform, allowUncontrolledRestart: Bool = false) {
        guard !shuttingDown, !connectionBusy.contains(client) else { return }
        connectionBusy.insert(client); connectionMessages[client] = "Connecting in the background…"
        let revision = workflowRevision
        Task { [weak self] in
            guard let self else { return }
            await backendCoordinator(client).connect(revision: revision,
                prepare: { [weak self] in
                    guard let self else { throw CancellationError() }
                    try await self.prepareSteamConnection(client, revision: revision, allowUncontrolledRestart: allowUncontrolledRestart)
                }, resolve: { [weak self] in
                    guard let self else { throw CancellationError() }
                    return try await self.resolveBackendControl(client, revision: revision)
                }, publish: { [weak self] event in
                    await self?.applyBackendEvent(event, client: client, revision: revision, connecting: true)
                })
        }
    }
    private func prepareSteamConnection(_ client: GamePlatform, revision: Int, allowUncontrolledRestart: Bool) async throws {
        guard !shuttingDown, workflowRevision == revision else { throw CancellationError() }
        let profileID = selectedProfile?.id
        connectionMessages[client] = "Preparing \(client.name) Steam…"
        await discoverSteamControl(client)
        guard workflowRevision == revision else { throw CancellationError() }
        try Task.checkCancellation()
        guard !shuttingDown, workflowRevision == revision, client == .macOS || selectedProfile?.id == profileID else { throw CancellationError() }
        if client == .windows, let profile = selectedProfile {
            let port = try discoveredControlPorts[client] ?? SteamControlEndpoint.availablePort()
            try await session.prepare(SessionContext(profile: profile, title: "Steam"), controlPort: port)
        } else {
            try await session.backend.prepare()
        }
        try Task.checkCancellation()
        guard workflowRevision == revision else { throw CancellationError() }
        connectionMessages[client] = "Connecting \(client.name) Steam…"
        try await ensureSteamBackend(client,allowUncontrolledRestart:allowUncontrolledRestart)
        try Task.checkCancellation()
        guard !shuttingDown, workflowRevision == revision, client == .macOS || selectedProfile?.id==profileID else { throw CancellationError() }
        if client == .windows {
            guard let profile=selectedProfile else { throw WayfarerError.message("Choose a Windows engine first.") }
            let changed=session.context?.profile.id != profile.id
            var command = try await runtimeService.command(profile: profile, executable: steamExecutable)
            command.arguments += ["-silent"]
            try await run(command,title:"Steam",profile:profile,presentSession:false)
            if changed { controlClients.removeValue(forKey:client) }
        } else { try await runMacSteam() }
        if let request=steamUIRequest,request.platform==client,steamWindow.context?.id==request.id,
           steamWindow.hasInputPermission,steamWindow.hasScreenPermission {
            session.backend.present(root:request.root,prefix:request.prefix,in:steamWindow.surface.window)
            await setSteamClientHidden(client,hidden:false)
            let destination = request.destination.url
            if client == .macOS { try await runMacSteam(arguments:[destination]) }
            else if let profile=selectedProfile {
                var command = try await runtimeService.command(profile: profile, executable: steamExecutable)
                command.arguments += ["-silent",destination]
                try await run(command,title:"Steam",profile:profile,presentSession:false)
            }
        }
        guard !shuttingDown, workflowRevision == revision else { throw CancellationError() }
    }
    func manageWindowsApps() {
        guard let profile=selectedProfile else { error="Choose a Windows engine first."; return }
        closeWindowsApps()
        windowsAppsProfile=profile; windowsAppsLoading=true
    }
    func closeWindowsApps() {
        windowsAppsOperation=UUID(); windowsAppsTask?.cancel(); windowsAppsTask=nil
        windowsAppsProfile=nil; windowsApps=[]; windowsAppsBusy=false; windowsAppsLoading=false
        windowsAppsCanForceQuit=false; windowsAppsMessage=""
    }
    func refreshWindowsApps() async {
        guard let profile=windowsAppsProfile,!windowsAppsBusy else { return }
        let operation=windowsAppsOperation
        do {
            let apps = try await self.runtimeProcesses.windowsApps(prefix: profile.prefix)
            guard windowsAppsOperation==operation,windowsAppsProfile?.id==profile.id else { return }
            windowsApps=apps; windowsAppsLoading=false
        } catch {
            guard windowsAppsOperation==operation else { return }
            windowsAppsLoading=false; windowsAppsMessage=error.localizedDescription
        }
    }
    func windowsAppName(_ app:RuntimeProcessIdentity.WindowsProcess) -> String {
        if let window=(session.nativeWindows+session.windows).first(where:{$0.peer.pid==app.token.pid && !$0.title.isEmpty}) { return window.title }
        if let added=addedGames.first(where:{$0.executable.lastPathComponent.lowercased()==app.program}) { return added.name }
        return app.program
    }
    func closeWindowsAppsAndReconnect(force:Bool = false, reviewedApps:[RuntimeProcessIdentity.WindowsProcess]? = nil) {
        guard let profile=windowsAppsProfile,profile.id==selectedProfile?.id,!windowsAppsBusy,!connectionBusy.contains(.windows),!windowsAppsLoading else { return }
        let apps=reviewedApps ?? windowsApps
        windowsAppsTask?.cancel(); windowsAppsOperation=UUID()
        let operation=windowsAppsOperation
        windowsAppsBusy=true; windowsAppsCanForceQuit=false; windowsAppsMessage=force ? "Force quitting the selected apps…" : "Closing Windows apps…"
        windowsAppsTask=Task { [weak self] in
            guard let self else { return }
            do {
                for app in apps {
                    guard await self.runtimeProcesses.isCurrent(app, prefix: profile.prefix) else { continue }
                    if force { _ = try await self.runtimeProcesses.forceQuit(app, prefix: profile.prefix) }
                    else { _=NSRunningApplication(processIdentifier:app.token.pid)?.terminate() }
                }
                let deadline=Date().addingTimeInterval(10)
                repeat {
                    guard !Task.isCancelled,self.windowsAppsOperation==operation,self.selectedProfile?.id==profile.id else { return }
                    let remaining = try await self.runtimeProcesses.windowsApps(prefix: profile.prefix)
                    guard !Task.isCancelled,self.windowsAppsOperation==operation,self.selectedProfile?.id==profile.id else { return }
                    self.windowsApps=remaining
                    if remaining.isEmpty {
                        self.closeWindowsApps()
                        self.connectSteam(.windows,allowUncontrolledRestart:true)
                        return
                    }
                    try await Task.sleep(for:.milliseconds(250))
                } while Date()<deadline
                self.windowsAppsBusy=false; self.windowsAppsCanForceQuit=true
                self.windowsAppsMessage="Some apps are still open. Save your work and try again, or force quit them."
            } catch {
                guard self.windowsAppsOperation==operation else { return }
                self.windowsAppsBusy=false; self.windowsAppsMessage=error.localizedDescription
            }
        }
    }
    func setSteamMode(_ client: GamePlatform, offline: Bool) {
        guard !shuttingDown, !connectionBusy.contains(client) else { return }
        connectionBusy.insert(client); connectionMessages[client] = offline ? "Going offline…" : "Connecting online…"
        let revision = workflowRevision
        Task { [weak self] in
            guard let self else { return }
            await backendCoordinator(client).changeMode(revision: revision, offline: offline,
                resolve: { [weak self] in
                    guard let self else { throw CancellationError() }
                    return try await self.resolveBackendControl(client, revision: revision)
                }, publish: { [weak self] event in
                    guard let self else { return }
                    await self.applyBackendEvent(event, client: client, revision: revision, connecting: true)
                    await self.didChangeSteamMode(event, client: client, offline: offline, revision: revision)
                })
        }
    }
    private func didChangeSteamMode(_ event: BackendEvent, client: GamePlatform, offline: Bool, revision: Int) {
        guard !shuttingDown, workflowRevision == revision, case .connected = event else { return }
        if !offline { catalogAttemptedAt.removeValue(forKey: client); refreshOnlineCatalog(client) }
        if installationRequest?.platform == client { prepareInstallation() }
    }
    func controlDownload(_ appID: String, client: GamePlatform, paused: Bool) { submitDownload(.pause(appID, paused), client: client) }
    func pauseDownloads(_ client: GamePlatform, paused: Bool) { submitDownload(.enabled(!paused), client: client) }
    private func installationControl(_ request: GameInstallationRequest) async throws -> any SteamWorkflowControl {
        try await backendCoordinator(request.platform).installationControl(state: { [weak self] in
            guard let self else { throw CancellationError() }
            return try await self.installationConnectionState(request)
        }, connect: { [weak self] in await self?.connectSteam(request.platform) })
    }
    private func installationConnectionState(_ request: GameInstallationRequest) throws -> SteamConnectionAvailability {
        guard !shuttingDown, installationRequest?.id == request.id else { throw CancellationError() }
        return SteamConnectionAvailability(control: try? controlClient(request.platform), busy: connectionBusy.contains(request.platform), message: connectionMessages[request.platform])
    }
    private func installationPublisher(_ request: GameInstallationRequest, operation: UUID) -> InstallCoordinator.Publish {
        { [weak self] event in await self?.applyInstallationEvent(event, request: request, operation: operation) }
    }
    private func applyInstallationEvent(_ event: InstallationEvent, request: GameInstallationRequest, operation: UUID) {
        guard !shuttingDown, installationRequest?.id == request.id, installDialog.operationID == operation else { return }
        switch event {
        case .snapshot(let snapshot): publishSteamSnapshot(snapshot, client: request.platform)
        case .prepared(let plan, let message): installDialog.finish(operation, plan: plan, message: message)
        case .started:
            installationRequest = nil; installDialog.dismiss(); status = "Installing \(request.game.name)"
            refreshLibrarySnapshot(); refreshSteamControls(); showDownloads()
        }
    }
    func prepareInstallation() {
        guard !shuttingDown, let request = installationRequest, !installBusy else { return }
        let operation = installDialog.begin("Connecting to Steam…")
        installationRevision += 1; let revision = installationRevision
        Task { [weak self] in
            guard let self else { return }
            await installationCoordinator.prepare(revision: revision, requestID: request.id, appID: request.appID,
                resolve: { [weak self] in
                    guard let self else { throw CancellationError() }
                    return try await self.installationControl(request)
                }, publish: installationPublisher(request, operation: operation))
        }
    }
    func chooseInstallFolder(_ index: Int) {
        guard !shuttingDown, let request = installationRequest, !installBusy else { return }
        let operation = installDialog.begin("Updating library…", keepPlan: true)
        installationRevision += 1; let revision = installationRevision
        Task { await installationCoordinator.chooseFolder(revision: revision, requestID: request.id, appID: request.appID,
            folder: index, publish: installationPublisher(request, operation: operation)) }
    }
    func confirmInstallation(acceptedAgreements: Bool) {
        guard !shuttingDown, let request = installationRequest, let plan = installPlan, plan.canConfirm,
              !installBusy, !plan.needsAgreement || acceptedAgreements else { return }
        let operation = installDialog.begin("Starting download…", keepPlan: true)
        installationRevision += 1; let revision = installationRevision
        Task { await installationCoordinator.confirm(revision: revision, requestID: request.id, appID: request.appID,
            acceptedAgreements: acceptedAgreements, publish: installationPublisher(request, operation: operation)) }
    }
    func cancelInstallation() {
        let request = installationRequest, control = request.flatMap { try? controlClient($0.platform) }
        installationRevision += 1; let revision = installationRevision
        installationRequest = nil; installDialog.dismiss(); closeSteamPanel()
        Task { await installationCoordinator.cancel(revision: revision, appID: request?.appID, control: control) }
    }
    func closeSteamPanel(_ id: UUID? = nil) {
        guard id == nil || steamUIRequest?.id == id else { return }
        steamUIRequest=nil
        steamWindow.end()
    }
    func closeUninstallDialog() {
        guard uninstallationRequest != nil else { return }
        uninstallationRequest = nil; uninstallBusy = false; closeSteamPanel()
        installationRevision += 1; let revision = installationRevision
        Task { await installationCoordinator.cancel(revision: revision, appID: nil, control: nil) }
    }

}

extension LauncherModel {
    func rememberPlatform(_ platform:GamePlatform,game:LibraryGame) {
        var value=preferences(for:game); value.preferredPlatform=platform
        if configuration.gamePreferences==nil { configuration.gamePreferences=[:] }; configuration.gamePreferences?[game.id]=value; save()
    }
    func preferences(for game:LibraryGame) -> GamePreferences { configuration.gamePreferences?[game.id] ?? GamePreferences() }
    var collections:[GameCollection] { configuration.collections ?? [] }
    func updatePreferences(_ preferences:GamePreferences,game:LibraryGame) throws {
        _ = try preferences.arguments()
        if let id=preferences.environmentID, !profiles.contains(where:{$0.id==id}) { throw WayfarerError.message("This Windows environment is unavailable. Choose an installed environment.") }
        var value=preferences
        value.tags=Array(NSOrderedSet(array:preferences.tags.map{$0.trimmingCharacters(in:.whitespacesAndNewlines)}.filter{!$0.isEmpty}.map{String($0.prefix(40))})) as? [String] ?? []
        guard value.tags.count<=50 else { throw WayfarerError.message("Use at most 50 tags per game.") }
        if configuration.gamePreferences == nil { configuration.gamePreferences=[:] }
        configuration.gamePreferences?[game.id]=value; save()
    }
    func saveCollection(_ collection:GameCollection) throws {
        try GameCollection.validate(collection,in:collections)
        var values=collections; values.removeAll{$0.id==collection.id}; values.append(collection)
        configuration.collections=values.sorted{$0.name.localizedStandardCompare($1.name) == .orderedAscending}; save()
    }
    func deleteCollection(_ collection:GameCollection) {
        var values=collections; values.removeAll{$0.id==collection.id}
        for index in values.indices where values[index].parentID==collection.id { values[index].parentID=collection.parentID }
        configuration.collections=values
        for id in configuration.gamePreferences?.keys.map({$0}) ?? [] { configuration.gamePreferences?[id]?.collectionIDs.remove(collection.id) }
        save()
    }
    func inCollection(_ game:LibraryGame,id:String) -> Bool {
        let ids=GameCollection.descendants(of:id,in:collections)
        return collections.filter{ids.contains($0.id)}.contains{$0.matches(game,preferences:preferences(for:game),favorites:favorites)}
    }
    func launchInSavedEnvironment(_ game: LibraryGame, environment: String) {
        guard let target = profiles.first(where: { $0.id == environment }) else { error = "The saved Windows environment is unavailable. Update this game's profile."; return }
        Task {
            do {
                if let current = selectedProfile {
                    let apps = try await runtimeProcesses.windowsApps(prefix: current.prefix)
                    guard nativeGameWindows.isEmpty, apps.isEmpty else { throw WayfarerError.message("Close the running Windows application before switching environments.") }
                    guard selectedProfile?.id == current.id else { return }
                }
                selection = target.id
                for _ in 0..<50 {
                    if !refreshing && presentationTask == nil { break }
                    try await Task.sleep(for: .milliseconds(200))
                }
                guard selectedProfile?.id == target.id, let updated = library.first(where: { $0.id == game.id }) else {
                    error = "This game is not available in its saved environment. Refresh that Steam library or update its profile."
                    return
                }
                launch(updated, platform: .windows)
            } catch { self.error = error.localizedDescription }
        }
    }
    func markLaunch(_ name:String,outcome:String) {
        if let index=configuration.launchHistory?.lastIndex(where:{$0.name==name}) { configuration.launchHistory?[index].outcome=DiagnosticReport.redact(String(outcome.prefix(300))); save() }
    }
    func recordLaunch(_ game:LibraryGame,platform:GamePlatform,outcome:String) {
        var history=configuration.launchHistory ?? []
        history.append(LaunchDiagnostic(gameID:game.id,name:game.name,platform:platform,environment:platform == .macOS ? "Native Mac" : selectedProfile?.runtime.name ?? "Windows",outcome:DiagnosticReport.redact(outcome)))
        configuration.launchHistory=Array(history.suffix(100)); save()
    }
    func exportDiagnostics() {
        let panel=NSSavePanel(); panel.nameFieldStringValue="Wayfarer-diagnostics.txt"; panel.allowedContentTypes=[.plainText]
        guard panel.runModal() == .OK,let url=panel.url else { return }
        let report=DiagnosticReport.make(version:Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Development",os:ProcessInfo.processInfo.operatingSystemVersionString,architecture:RuntimeDiscovery.isAppleSilicon ? "Apple silicon" : "Intel",runtimes:Array(Set(runtimes.map{$0.name})).sorted(),connections:Dictionary(uniqueKeysWithValues:GamePlatform.allCases.map{($0.name,connectionMode($0).title)}),history:configuration.launchHistory ?? [])
        Task {
            do { try await FileService.shared.write(Data(report.utf8), to: url); NSWorkspace.shared.activateFileViewerSelecting([url]) }
            catch { self.error = "Could not export diagnostics: \(error.localizedDescription)" }
        }
    }

    func downloadPolicyKey(_ client:GamePlatform) -> String {
        let context=steamContext(client)
        return "\(client.rawValue):\(context?.root.path ?? "unavailable"):\(currentSteamAccounts[client] ?? "signedOut")"
    }
    func downloadPolicy(_ client:GamePlatform) -> DownloadPolicy { configuration.downloadPolicies?[downloadPolicyKey(client)] ?? DownloadPolicy() }
    func readDownloadPolicy(_ client:GamePlatform) async -> DownloadPolicy {
        await refreshSteamAccount(client)
        if let saved=configuration.downloadPolicies?[downloadPolicyKey(client)] { return saved }
        var policy=DownloadPolicy()
        if let settings=try? await controlClient(client).downloadSettings() {
            policy.enabled=settings.scheduled; policy.bandwidthKBps=max(0,settings.bandwidthKBps)
            if settings.startHour != settings.endHour { policy.startHour=settings.startHour; policy.endHour=settings.endHour }
        }
        return policy
    }
    func applyDownloadPolicy(_ policy: DownloadPolicy, client: GamePlatform) { submitDownload(.apply(policy), client: client) }
    private func submitDownload(_ action: DownloadAction, client: GamePlatform, scheduled: Bool = false) {
        guard !shuttingDown, !connectionBusy.contains(client) else { return }
        if !scheduled { connectionBusy.insert(client) }
        let revision = workflowRevision
        Task { [weak self] in
            guard let self else { return }
            await refreshSteamAccount(client)
            guard !shuttingDown, workflowRevision == revision else { return }
            let key = downloadPolicyKey(client)
            let changesPolicy: Bool
            switch action { case .apply, .prioritize: changesPolicy = true; default: changesPolicy = configuration.downloadPolicies?[key] != nil }
            do {
                let control = try controlClient(client)
                await downloadScheduler(client).submit(action, scope: key, revision: revision, policy: downloadPolicy(client),
                    ownedPause: configuration.scheduledPauses?.contains(key) == true, control: control,
                    publish: { [weak self] event in
                        await self?.applyDownloadEvent(event, client: client, key: key, revision: revision, scheduled: scheduled, persistPolicy: changesPolicy)
                    })
            } catch {
                if !scheduled { connectionBusy.remove(client) }
                downloadPolicyMessages[client] = error.localizedDescription
            }
        }
    }
    private func applyDownloadEvent(_ event: DownloadEvent, client: GamePlatform, key: String, revision: Int, scheduled: Bool, persistPolicy: Bool) {
        guard !shuttingDown, workflowRevision == revision else { return }
        if case .finished = event { if !scheduled { connectionBusy.remove(client) }; return }
        guard downloadPolicyKey(client) == key else { return }
        switch event {
        case .state(let policy, let owned):
            persistDownloadState(policy, owned: owned, key: key, persistPolicy: persistPolicy)
        case .updated(let policy, let owned, let snapshot):
            persistDownloadState(policy, owned: owned, key: key, persistPolicy: persistPolicy)
            publishSteamSnapshot(snapshot, client: client)
            if !scheduled { downloadPolicyMessages[client] = "Saved in Steam" }
        case .failed(let message): downloadPolicyMessages[client] = scheduled ? "Schedule waiting for Steam" : "Steam could not confirm all changes · \(message)"
        case .finished: break
        }
    }
    private func persistDownloadState(_ policy: DownloadPolicy, owned: Bool, key: String, persistPolicy: Bool) {
        var changed = false
        if persistPolicy, configuration.downloadPolicies?[key] != policy {
            if configuration.downloadPolicies == nil { configuration.downloadPolicies = [:] }
            configuration.downloadPolicies?[key] = policy; changed = true
        }
        if (configuration.scheduledPauses?.contains(key) == true) != owned {
            if configuration.scheduledPauses == nil { configuration.scheduledPauses = [] }
            if owned { configuration.scheduledPauses?.insert(key) } else { configuration.scheduledPauses?.remove(key) }
            changed = true
        }
        if changed { save() }
    }
    func enforceDownloadSchedules() async {
        for client in GamePlatform.allCases where client == .windows || includesMacSteam {
            guard connectionMode(client) == .online, configuration.downloadPolicies?[downloadPolicyKey(client)] != nil else { continue }
            submitDownload(.enforce, client: client, scheduled: true)
        }
    }
    func prioritizeDownload(_ appID: String, client: GamePlatform, toTop: Bool) {
        guard connectionMode(client) == .online else { return }
        submitDownload(.prioritize(appID, toTop: toTop), client: client)
    }
    func refreshFriends(_ client: GamePlatform) {
        guard !shuttingDown, !friendsBusy.contains(client) else { return }
        friendsBusy.insert(client)
        let revision = workflowRevision
        Task { [weak self] in
            guard let self else { return }
            await refreshSteamAccount(client)
            guard !shuttingDown, workflowRevision == revision else { return }
            let key = downloadPolicyKey(client), mode = connectionMode(client)
            await socialCoordinator(client).refresh(scope: key, revision: revision, mode: mode,
                fetch: { [weak self] in
                    guard let self else { throw CancellationError() }
                    return try await self.fetchFriends(client, key: key, revision: revision)
                }, publish: { [weak self] update in
                    await self?.applySocialUpdate(update, client: client, key: key, revision: revision)
                })
        }
    }
    private func fetchFriends(_ client: GamePlatform, key: String, revision: Int) async throws -> SteamFriendsSnapshot {
        guard !shuttingDown, workflowRevision == revision, downloadPolicyKey(client) == key else { throw CancellationError() }
        return try await controlClient(client).friends()
    }
    private func applySocialUpdate(_ update: SocialUpdate, client: GamePlatform, key: String, revision: Int) {
        guard !shuttingDown, workflowRevision == revision else { return }
        friendsBusy.remove(client)
        guard downloadPolicyKey(client) == key else { friendsSnapshots.removeValue(forKey: client); return }
        friendsSnapshots[client] = update.snapshot; friendsMessages[client] = update.message
        let duplicatesMac = client == .windows && friendsSnapshots[.macOS]?.ready == true && currentSteamAccounts[.macOS] != nil && currentSteamAccounts[.macOS] == currentSteamAccounts[.windows]
        if configuration.friendNotifications == true, !duplicatesMac {
            for friend in update.newUnread { notifyUnread(friend, client: client) }
        }
    }
    func loadFriendsEngine(_ client:GamePlatform) {
        connectSteam(client)
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.waitForSteamConnection(client)
                guard self.connectionMode(client) == .online else { self.refreshFriends(client); return }
                if client == .macOS { try await self.runMacSteam(arguments:["steam://open/friends"]) }
                else if let profile=self.selectedProfile {
                    var command = try await self.runtimeService.command(profile: profile, executable: self.steamExecutable)
                    command.arguments += ["-silent","steam://open/friends"]
                    try await self.run(command,title:"Steam Friends",profile:profile,presentSession:false)
                }
                try await Task.sleep(for:.seconds(2)); self.refreshFriends(client)
            } catch { self.friendsMessages[client]=error.localizedDescription }
        }
    }
    func showFriends() { chatRequest=UUID() }
    var unreadFriendsCount:Int {
        var counts:[String:Int]=[:]
        for (client,snapshot) in friendsSnapshots { let account = currentSteamAccounts[client] ?? client.rawValue; for friend in snapshot.friends { let key=account+":"+friend.id; counts[key]=max(counts[key] ?? 0,friend.unread) } }
        return counts.values.reduce(0,+)
    }
    func setFriendNotifications(_ enabled:Bool) {
        if !enabled { configuration.friendNotifications=false; save(); return }
        UNUserNotificationCenter.current().requestAuthorization(options:[.alert,.sound,.badge]) { [weak self] granted,_ in
            Task { @MainActor in self?.configuration.friendNotifications=granted; self?.save(); if !granted { self?.error="Allow notifications for Wayfarer in System Settings to receive chat alerts." } }
        }
    }
    private func notifyUnread(_ friend:SteamFriend,client:GamePlatform) {
        let content=UNMutableNotificationContent(); content.title="New Steam chat"; content.body="\(friend.name) · \(friend.unread) unread \(friend.unread==1 ? "message" : "messages")"; content.sound = .default
        content.userInfo=["wayfarerChatClient":client.rawValue]
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier:"wayfarer-chat-\(client.rawValue)-\(friend.id)",content:content,trigger:nil))
    }
    func refreshCloud(_ game:LibraryGame,platform:GamePlatform) {
        guard game.isSteam else { return }; let key="\(game.id):\(platform.rawValue)",account=downloadPolicyKey(platform)
        cloudStatuses.removeValue(forKey:key)
        Task { [weak self] in
            guard let self else { return }
            if let state=try? await self.controlClient(platform).cloudStatus(appID:String(game.id.dropFirst(6))),self.downloadPolicyKey(platform) == account { self.cloudStatuses[key]=state }
        }
    }
    func suggestedSaveFolder(_ game: LibraryGame, platform: GamePlatform) -> URL? {
        suggestedSaveFolders[saveScope(game, platform: platform)]
    }
    func saveScope(_ game:LibraryGame,platform:GamePlatform) -> String { "\(game.id):\(platform.rawValue):\(platform == .windows ? (preferences(for:game).environmentID ?? selectedProfile?.id ?? "unavailable") : "native")" }
    func saveFolders(_ game:LibraryGame,platform:GamePlatform) -> [URL] { preferences(for:game).saveFolders[saveScope(game,platform:platform)] ?? [] }
    func chooseSaveFolder(_ game:LibraryGame,platform:GamePlatform) {
        let panel=NSOpenPanel(); panel.title="Choose \(game.name)'s save folder"; panel.canChooseDirectories=true; panel.canChooseFiles=false; panel.allowsMultipleSelection=false
        guard panel.runModal() == .OK,let folder=panel.url else { return }
        Task {
        do { try await FileService.shared.validateSaveFolder(folder); var preferences=preferences(for:game); let key=saveScope(game,platform:platform); var folders=preferences.saveFolders[key] ?? []; if !folders.contains(folder) { folders.append(folder) }; preferences.saveFolders[key]=folders; try updatePreferences(preferences,game:game) }
        catch { self.error=error.localizedDescription }
        }
    }
    func refreshBackups(_ game: LibraryGame, platform: GamePlatform) {
        let key = saveScope(game, platform: platform), context = steamContext(platform)
        let account = currentSteamAccounts[platform]
        Task {
            let backups = (try? await saveService.list(gameID: key)) ?? []
            let suggested = game.isSteam && context != nil ? await saveService.suggestedFolder(root: context!.root, account: account, appID: String(game.id.dropFirst(6))) : nil
            guard key == saveScope(game, platform: platform), currentSteamAccounts[platform] == account else { return }
            saveBackups[key] = backups; suggestedSaveFolders[key] = suggested
        }
    }
    func createSaveBackup(_ game:LibraryGame,platform:GamePlatform) {
        guard !saveBusy else { return }; let folders=saveFolders(game,platform:platform),scope=saveScope(game,platform:platform); saveBusy=true; saveMessage="Creating restore point…"
        Task { [weak self] in
            do {
                guard let self else { return }
                let backup = try await self.saveService.create(gameID: scope, name: game.name, folders: folders)
                self.saveMessage="Restore point created · \(backup.files.count) files"; self.refreshBackups(game,platform:platform)
            } catch { self?.saveMessage=error.localizedDescription }
            self?.saveBusy=false
        }
    }
    func restoreSaveBackup(_ backup:SaveBackup,game:LibraryGame,platform:GamePlatform) {
        guard !saveBusy else { return }; saveBusy=true; saveMessage="Checking game and restore point…"
        Task { [weak self] in
            guard let self else { return }; defer { self.saveBusy=false }
            do {
                guard backup.gameID==self.saveScope(game,platform:platform),Set(backup.folders)==Set(self.saveFolders(game,platform:platform)) else { throw WayfarerError.message("Add this restore point’s original save folders before restoring it.") }
                guard platform != .windows || self.preferences(for:game).environmentID == nil || self.preferences(for:game).environmentID == self.selectedProfile?.id else { throw WayfarerError.message("Select this game’s saved Windows environment in Engines before restoring saves.") }
                if game.isSteam { let state=try await self.controlClient(platform).appState(appID:String(game.id.dropFirst(6))); guard !state.isRunning else { throw WayfarerError.message("Close the game before restoring its saves.") } }
                else if let installation=game.installation(for:platform) {
                    if platform == .macOS { guard !NSWorkspace.shared.runningApplications.contains(where:{$0.bundleURL==installation.location}) else { throw WayfarerError.message("Close the game before restoring its saves.") } }
                    else if let profile = self.selectedProfile {
                        let processes = try await runtimeProcesses.windowsProcesses(prefix: profile.prefix)
                        let running = processes.contains { $0.program == installation.location.lastPathComponent.lowercased() }
                        guard !running else { throw WayfarerError.message("Close the game before restoring its saves.") }
                    }
                }
                try await saveService.restore(backup)
                self.saveMessage="Saves restored. Previous saves are kept in a recovery point."; self.refreshBackups(game,platform:platform)
            } catch { self.saveMessage=error.localizedDescription }
        }
    }
}


extension LauncherModel {
    var gameSessions:[GameSessionRecord] { configuration.gameSessions ?? [] }
    func activeSession(_ gameID:String)->GameSessionRecord? { gameSessions.last{$0.gameID==gameID && $0.phase.active} }
    private func beginGameSession(_ game:LibraryGame,platform:GamePlatform) {
        guard activeSession(game.id)==nil else{return}
        var history=gameSessions
        history.append(GameSessionRecord(gameID:game.id,name:game.name,platform:platform,environmentID:platform == .windows ? selectedProfile?.id : nil))
        configuration.gameSessions=Array(history.suffix(200));syncSessionHistory();save()
    }
    private func changeSession(_ id:UUID,_ change:(inout GameSessionRecord)->Void) {
        guard var records=configuration.gameSessions,let index=records.firstIndex(where:{$0.id==id}) else{return}
        let before=records[index];change(&records[index]);guard before != records[index] else{return};configuration.gameSessions=records;syncSessionHistory();save()
        if !records[index].phase.active, pendingGameID==records[index].gameID { pendingGameID=nil;pendingGameTitle=nil }
    }
    private func observeGameSession(_ id:UUID,running:Bool?) { changeSession(id){$0.observe(running:running)} }
    private func endGameSession(_ id:UUID,phase:GameSessionPhase,message:String) { changeSession(id){$0.phase=phase;$0.endedAt=Date();$0.message=message} }
    private func failGameSession(_ gameID:String,message:String) { if let record=activeSession(gameID){endGameSession(record.id,phase:.failed,message:message)} }
    private func syncSessionHistory() {
        sessionHistoryRevision += 1
        let revision = sessionHistoryRevision, records = gameSessions
        Task { await sessionCoordinator.synchronize(records, revision: revision) }
        Task { await refreshOptionalWork() }
    }
    private func sessionMonitorInput() -> SessionMonitorInput? {
        guard !shuttingDown, !loadingSettings else { return nil }
        let clients = GamePlatform.allCases.compactMap { client -> SessionClientInput? in
            guard let context = steamContext(client) else { return nil }
            return SessionClientInput(platform: client, root: context.root, control: try? controlClient(client))
        }
        let paths = SessionMonitorInput.nativeBundleSnapshot(NSWorkspace.shared.runningApplications.filter { !$0.isTerminated }.compactMap { app in app.bundleURL.map { (app.processIdentifier, $0) } })
        return SessionMonitorInput(revision: workflowRevision, historyRevision: sessionHistoryRevision, records: gameSessions,
            clients: clients, library: library, added: configuration.addedGames, environmentID: selectedProfile?.id,
            prefix: selectedProfile?.prefix, nativeBundles: paths)
    }
    private func applySessionUpdate(_ update: SessionUpdate) {
        guard !shuttingDown, workflowRevision == update.revision else { return }
        var records = gameSessions
        for change in update.changes {
            if let before = change.before {
                guard let index = records.firstIndex(where: { $0.id == before.id }), records[index] == before else { continue }
                records[index] = change.after
            } else {
                guard !records.contains(where: { $0.gameID == change.after.gameID && $0.phase.active }) else { continue }
                records.append(change.after)
            }
            if !change.after.phase.active, pendingGameID == change.after.gameID { pendingGameID = nil; pendingGameTitle = nil }
        }
        if records != gameSessions { configuration.gameSessions = Array(records.suffix(200)); syncSessionHistory(); save() }
    }
    private func monitorGameSessions() async { await sessionCoordinator.refresh() }
    func bringGameForward(_ record:GameSessionRecord) {
        guard record.phase.active else{return}
        if let peer=gameWindowPeers[record.gameID],let window=nativeGameWindows.first(where:{$0.peer.id==peer}) { session.activateNativeWindow(window.id);return }
        let installation=library.first{$0.id==record.gameID}?.installation(for:record.platform)
        guard let location = installation?.location else { return }
        let context = steamContext(record.platform)
        let apps = NSWorkspace.shared.runningApplications
        let paths = Dictionary(uniqueKeysWithValues: apps.compactMap { app in app.bundleURL.map { (app.processIdentifier, $0) } })
        Task {
            let tokens = await runtimeProcesses.gameProcesses(pids: apps.map(\.processIdentifier), bundlePaths: paths, location: location, steamRoot: context?.root ?? location, prefix: context?.prefix)
            guard activeSession(record.gameID)?.id == record.id else { return }
            if let app = apps.first(where: { app in tokens.contains { $0.pid == app.processIdentifier && RuntimeProcessIdentity.token(for: $0.pid) == $0 } }) {
                app.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
            } else {
                changeSession(record.id) { $0.message = "No game window is available yet. Check Steam for an update or launch confirmation." }
            }
        }
    }

    func stopGame(_ record:GameSessionRecord) {
        guard let current=activeSession(record.gameID),current.id==record.id,current.phase != .stopping else{return}
        changeSession(record.id){$0.phase = .stopping;$0.message="Asking the game to close…"}
        Task {
            do {
                if record.gameID.hasPrefix("steam:") {
                    guard record.platform == .macOS || record.environmentID==selectedProfile?.id else{throw WayfarerError.message("Choose this game’s Windows environment before stopping it.")}
                    try await controlClient(record.platform).terminateGame(appID:String(record.gameID.dropFirst(6)))
                } else {
                    let tokens = await sessionCoordinator.verifiedTokens(for: record.id)
                    guard activeSession(record.gameID)?.id == record.id else { return }
                    guard !tokens.isEmpty else{throw WayfarerError.message("No verified game process is available. Close the game from its own menu.")}
                    for token in tokens where RuntimeProcessIdentity.token(for:token.pid)==token { _=NSRunningApplication(processIdentifier:token.pid)?.terminate() }
                }
                try await Task.sleep(for:.seconds(8));await monitorGameSessions()
                if activeSession(record.gameID)?.id==record.id { changeSession(record.id){$0.phase = .playing;$0.message="The game is still running. Close it from its menu, or review Windows apps in Steam controls."} }
            } catch {
                guard activeSession(record.gameID)?.id == record.id else { return }
                changeSession(record.id){$0.phase = .disconnected;$0.message=error.localizedDescription}
            }
        }
    }
    private func recoverBackendIfSafe(_ client: GamePlatform, revision: Int) async {
        let safe = !connectionBusy.contains(client) && installationRequest == nil && uninstallationRequest == nil && maintenance.values.allSatisfy { $0.completed || $0.failed } && !gameSessions.contains { $0.phase.active && $0.platform == client } && !transfers.contains { $0.client == client }
        let decision = await backendCoordinator(client).retryDecision(revision: revision, safe: safe,
            enabled: startsSteamInBackground && !ProcessInfo.processInfo.arguments.contains("--no-background-steam"))
        guard !shuttingDown, workflowRevision == revision else { return }
        if decision.retry { connectSteam(client) }
        else if decision.wasConnected, !connectionBusy.contains(client) {
            setConnectionMessage(safe ? "Steam disconnected. Reconnect its backend to retry." : "Steam disconnected. Automatic recovery is waiting for games or file operations to finish. Reconnect to check safely.", client: client)
        }
    }
    private func invalidateWorkflows() {
        workflowRevision += 1
        let revision = workflowRevision
        connectionBusy = []; friendsBusy = []; friendsSnapshots = [:]
        controlClients = [:]; controlPorts = [:]; discoveredControlPorts = [:]; steamConnections = [:]
        Task {
            await macBackend.invalidate(revision: revision); await windowsBackend.invalidate(revision: revision)
            await macDownloads.invalidate(revision: revision); await windowsDownloads.invalidate(revision: revision)
            await macSocial.invalidate(revision: revision); await windowsSocial.invalidate(revision: revision)
            await maintenanceCoordinator.invalidate(revision: revision); await sessionCoordinator.invalidate(revision: revision)
        }
    }
    func openCouch() { showingCouch = true; couchRequest = UUID() }
    func navigate(_ destination:String) { selectedGameID=nil;navigationDestination=destination;navigationRequest=UUID();showingQuickLauncher=false }
    func openQuickLauncher() { guard installationRequest==nil,uninstallationRequest==nil,steamUIRequest==nil,featureGame==nil,windowsAppsProfile==nil,storageGame==nil,achievementGame==nil,workshopGame==nil,!showingCollections,!showingDiagnostics else{return};showingQuickLauncher=true }
    func quickPlatform(_ game:LibraryGame)->GamePlatform? { preferredGamePlatform(game).flatMap{game.installation(for:$0)?.platform} ?? game.preferredInstallation?.platform }
    func compatibilityTests(_ game:LibraryGame)->[CompatibilityTest] { (configuration.compatibilityTests ?? []).filter{$0.gameID==game.id}.sorted{$0.testedAt>$1.testedAt} }
    func recordCompatibility(_ game:LibraryGame,profile:RuntimeProfile,rating:CompatibilityRating,notes:String) {
        var records=configuration.compatibilityTests ?? [];records.removeAll{$0.gameID==game.id && $0.environmentID==profile.id}
        records.append(CompatibilityTest(gameID:game.id,environmentID:profile.id,engine:profile.runtime.name,fingerprint:runtimeFingerprint(profile),options:preferences(for:game).launchOptions,rating:rating,notes:notes));configuration.compatibilityTests=Array(records.suffix(500));save()
    }
    func suggestedProfile(_ game:LibraryGame)->RuntimeProfile? {
        for record in compatibilityTests(game) where record.rating != .broken {
            if let profile=profiles.first(where:{$0.id==record.environmentID && runtimeFingerprint($0)==record.fingerprint}){return profile}
        }
        return ([selectedProfile].compactMap{$0}+profiles).first{profile in !compatibilityTests(game).contains{$0.environmentID==profile.id && $0.rating == .broken && $0.fingerprint==runtimeFingerprint(profile)}}
    }
    func useCompatibility(_ test:CompatibilityTest,game:LibraryGame) {
        guard profiles.contains(where:{$0.id==test.environmentID}) else{return}
        var prefs=preferences(for:game);prefs.environmentID=test.environmentID;prefs.preferredPlatform = .windows;prefs.launchOptions=test.options;do {try updatePreferences(prefs,game:game)}catch{self.error=error.localizedDescription}
    }
    func refreshStorage(_ client:GamePlatform) {
        guard !storageBusy.contains(client) else{return};storageBusy.insert(client)
        let profileID=selectedProfile?.id
        Task { defer{storageBusy.remove(client)};do {
            let folders=try await controlClient(client).storageFolders();guard client == .macOS || profileID==selectedProfile?.id else{return}
            storageFolders[client]=folders;storageMessages[client]=nil
        }catch{storageMessages[client]=error.localizedDescription} }
    }
    func maintainGame(_ game:LibraryGame,platform:GamePlatform,folder:Int?=nil) {
        guard let steam=game.installation(for:platform)?.steamGame else{return}
        let key=game.id+":"+platform.rawValue
        guard installationRequest==nil,uninstallationRequest==nil else{storageMessages[platform]="Finish or close the installation confirmation first.";return}
        guard activeSession(game.id)==nil,!transfers.contains(where:{$0.appID==steam.appID && $0.client==platform}),maintenance[key]==nil || maintenance[key]?.completed == true || maintenance[key]?.failed == true else{storageMessages[platform]="Close the game and finish its download or current file operation first.";return}
        let profileID=selectedProfile?.id
        maintenance[key]=SteamMaintenanceProgress(kind:folder==nil ? "verify":"move",progress:nil,task:"Starting…",completed:false,failed:false)
        let revision = workflowRevision
        Task { [self] in
            do {
                let control = try controlClient(platform)
                await maintenanceCoordinator.start(key: key, appID: steam.appID, folder: folder, revision: revision, control: control,
                    publish: { [weak self] progress in await self?.applyMaintenance(progress, key: key, platform: platform, revision: revision, profileID: profileID) })
            } catch { applyMaintenance(SteamMaintenanceProgress(kind: folder == nil ? "verify" : "move", progress: nil,
                task: error.localizedDescription, completed: false, failed: true), key: key, platform: platform, revision: revision, profileID: profileID) }
        }
    }
    private func applyMaintenance(_ progress: SteamMaintenanceProgress, key: String, platform: GamePlatform, revision: Int, profileID: String?) {
        guard !shuttingDown, workflowRevision == revision, platform == .macOS || profileID == selectedProfile?.id else { return }
        maintenance[key] = progress
        if progress.failed { storageMessages[platform] = progress.task }
        if progress.completed || progress.failed { refreshLibrarySnapshot(); refreshStorage(platform) }
    }
    func achievementScope(_ client:GamePlatform)->String? {
        guard connectionMode(client) != .signedOut,let context=steamContext(client),let account = currentSteamAccounts[client] else{return nil}
        return client.rawValue+":"+context.root.path+":"+account+":"+(client == .windows ? selectedProfile?.id ?? "" : "")
    }
    func achievementSnapshot(_ game:LibraryGame,platform:GamePlatform)->AchievementSnapshot? {
        guard let scope=achievementScope(platform),let snapshot=achievementSnapshots[game.id+":"+platform.rawValue],snapshot.scope==scope else{return nil};return snapshot
    }
    func refreshAchievements(_ game:LibraryGame,platform:GamePlatform) {
        guard game.id.hasPrefix("steam:"),let scope=achievementScope(platform) else{return}
        let id=String(game.id.dropFirst(6)),key=game.id+":"+platform.rawValue
        guard !achievementBusy.contains(key) else{return}
        achievementBusy.insert(key)
        Task {defer{achievementBusy.remove(key)};do {
            if let saved = try? await achievementService.load(scope: scope, appID: id), scope == achievementScope(platform) { achievementSnapshots[key] = saved }
            guard scope == achievementScope(platform), !Task.isCancelled else { return }
            if connectionMode(platform) == .unavailable || connectionMode(platform) == .signedOut {
                achievementMessages[key] = "Saved achievements. Connect Steam to refresh."
                return
            }
            let items=try await controlClient(platform).achievements(appID:id);guard scope==achievementScope(platform) else{return}
            let snapshot=AchievementSnapshot(scope:scope,appID:id,updatedAt:Date(),achievements:items,offline:connectionMode(platform) == .offline);achievementSnapshots[key]=snapshot;achievementMessages[key]=snapshot.offline == true ? "Steam’s offline achievement data. Go online to update it.":nil;try await achievementService.save(snapshot)
        }catch{if scope==achievementScope(platform){achievementMessages[key]=error.localizedDescription}}}
    }

    func workshopScope(_ platform: GamePlatform) -> String? {
        guard let context = steamContext(platform) else { return nil }
        let account = connectionMode(platform) == .signedOut ? "local" : currentSteamAccounts[platform] ?? "local"
        return platform.rawValue + ":" + context.root.path + ":" + (context.prefix?.path ?? "") + ":" + account
    }
    func workshopSnapshot(_ game: LibraryGame, platform: GamePlatform) -> WorkshopSnapshot? {
        let key = game.id + ":" + platform.rawValue
        guard let snapshot = workshopSnapshots[key], snapshot.scope == workshopScope(platform) else { return nil }
        return snapshot
    }
    func showWorkshop(_ game: LibraryGame, platform: GamePlatform) {
        workshopPlatform = platform; workshopGame = game
    }
    func refreshWorkshop(_ game: LibraryGame, platform: GamePlatform, afterChange: Bool = false) async {
        let key = game.id + ":" + platform.rawValue
        guard game.isSteam, let scope = workshopScope(platform), let context = steamContext(platform),
              (afterChange || !workshopBusy.contains(key)), !workshopChanging.contains(key) else { return }
        let revision = UUID(); workshopRevisions[key] = revision
        workshopBusy.insert(key)
        defer { workshopBusy.remove(key) }
        let id = String(game.id.dropFirst(6))
        let cache = currentSteamAccounts[platform] != nil && connectionMode(platform) != .signedOut
        func current() -> Bool { !Task.isCancelled && workshopRevisions[key] == revision && workshopGame?.id == game.id && workshopPlatform == platform && workshopScope(platform) == scope }
        do {
            if workshopSnapshot(game, platform: platform) == nil {
                if let saved = try? await workshopService.initial(scope: scope, appID: id, root: context.root, prefix: context.prefix, useCache: cache) {
                    guard current() else { return }; workshopSnapshots[key] = saved
                }
            }
            guard current() else { return }
            let live = try await controlClient(platform).workshop(appID: id)
            guard current() else { return }
            let snapshot = try await workshopService.resolve(live, scope: scope, root: context.root, prefix: context.prefix, save: cache)
            guard current() else { return }
            workshopSnapshots[key] = snapshot; workshopMessages[key] = nil
        } catch is CancellationError { }
        catch {
            if current() {
                if var previous = workshopSnapshots[key], previous.scope == scope, previous.source == .steam {
                    previous.source = .saved; previous.capabilities = WorkshopCapabilities(); workshopSnapshots[key] = previous
                }
                workshopMessages[key] = error.localizedDescription
            }
        }
    }
    func lookupWorkshop(_ game: LibraryGame, platform: GamePlatform, input: String) async throws -> WorkshopItemDetails {
        let scope = workshopScope(platform)
        let item = try await workshopService.lookup(appID: String(game.id.dropFirst(6)), input: input)
        guard !Task.isCancelled, workshopGame?.id == game.id, workshopPlatform == platform, workshopScope(platform) == scope else { throw CancellationError() }
        return item
    }
    func changeWorkshop(_ game: LibraryGame, platform: GamePlatform, action: WorkshopAction) async -> Bool {
        let key = game.id + ":" + platform.rawValue
        guard let scope = workshopScope(platform), workshopGame?.id == game.id, workshopPlatform == platform,
              !workshopChanging.contains(key), let snapshot = workshopSnapshot(game, platform: platform), snapshot.source == .steam else { return false }
        workshopChanging.insert(key); workshopMessages[key] = nil
        workshopRevisions[key] = UUID()
        var success = false
        do {
            await refreshSteamAccount(platform)
            guard !Task.isCancelled, workshopScope(platform) == scope, workshopGame?.id == game.id, workshopPlatform == platform else { throw CancellationError() }
            if case .subscribe(let id, true) = action {
                _ = try await workshopService.lookup(appID: String(game.id.dropFirst(6)), input: id)
            }
            guard !Task.isCancelled, workshopScope(platform) == scope else { throw CancellationError() }
            try await controlClient(platform).changeWorkshop(appID: String(game.id.dropFirst(6)), action: action)
            success = true
        } catch is CancellationError { }
        catch { if workshopScope(platform) == scope { workshopMessages[key] = error.localizedDescription } }
        workshopChanging.remove(key)
        let message = workshopMessages[key]
        if workshopScope(platform) == scope { await refreshWorkshop(game, platform: platform, afterChange: true) }
        if !success, let message, workshopScope(platform) == scope { workshopMessages[key] = message }
        return success
    }
    func browseWorkshop(_ game: LibraryGame, platform: GamePlatform, itemID: String? = nil) {
        do {
            let url = try WorkshopIdentifier.browserURL(appID: String(game.id.dropFirst(6)), itemID: itemID)
            let profileID = selectedProfile?.id
            workshopGame = nil
            Task {
                try? await Task.sleep(for: .milliseconds(300))
                guard platform == .macOS || profileID == selectedProfile?.id else { return }
                openSteamClient(platform, destination: .workshop(url))
            }
        } catch { self.error = error.localizedDescription }
    }
}

#if DEBUG
extension LauncherModel {
    // Measure UI heartbeat during navigation and delayed library loading.
    func measureUIResponsiveness(output: URL) async {
        var delays: [Double] = [], loadingSamples = 0, populatedSamples = 0, navigationChanges = 0
        var pageDelays: [String: [Double]] = [:]
        var firstLibrary: Double?, firstInstalled: Double?, installedWhileLoading = false
        let started = ProcessInfo.processInfo.systemUptime
        var nextNavigation = started + 0.5
        let destinations = ["Library", "Home", "Downloads", "Home", "Engines", "Activity", "Storage", "Home"]
        while ProcessInfo.processInfo.systemUptime - started < 12 {
            let expected = ProcessInfo.processInfo.systemUptime + 0.05
            do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
            let now = ProcessInfo.processInfo.systemUptime
            delays.append(max(0, now - expected) * 1000)
            pageDelays[showingQuickLauncher ? "Quick launcher" : navigationDestination, default: []].append(max(0, now - expected) * 1000)
            if refreshing { loadingSamples += 1 }
            if !library.isEmpty {
                populatedSamples += 1
                if firstLibrary == nil { firstLibrary = now - started }
            }
            if library.contains(where: \.isInstalled) {
                if firstInstalled == nil { firstInstalled = now - started }
                if refreshing { installedWhileLoading = true }
            }
            if now >= nextNavigation {
                navigate(destinations[navigationChanges % destinations.count])
                if navigationChanges % destinations.count == 3 { showingQuickLauncher = true }
                navigationChanges += 1; nextNavigation = now + 0.5
            }
        }
        navigate("Home")
        let sorted = delays.sorted()
        let result: [String: Any] = [
            "samples": delays.count, "loadingSamples": loadingSamples, "populatedSamples": populatedSamples,
            "navigationChanges": navigationChanges, "maxDelayMs": sorted.last ?? 0,
            "firstLibrarySeconds": firstLibrary ?? -1, "firstInstalledSeconds": firstInstalled ?? -1,
            "installedWhileLoading": installedWhileLoading,
            "maxDelayByPageMs": pageDelays.mapValues { $0.max() ?? 0 },
            "p95DelayMs": sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))],
            "games": library.count, "elapsedSeconds": ProcessInfo.processInfo.systemUptime - started
        ]
        if let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]) {
            try? await FileService.shared.write(data, to: output)
        }
        print("UI_RESPONSIVENESS_PROBE_DONE"); fflush(stdout)
    }
}
#endif

extension LauncherModel {
    private func performanceWorkload() -> PerformanceWorkload {
        PerformanceWorkload(quietGameRunning: gameSessions.contains { $0.phase.active && (configuration.gamePreferences?[$0.gameID]?.effectivePerformance.quietWhilePlaying ?? true) },
            launcherActive: NSApp.isActive, downloadsActive: !transfers.isEmpty || steamConnections.values.contains { !$0.downloads.isEmpty })
    }
    private func refreshOptionalWork() async {
        guard !shuttingDown, !loadingSettings else { return }
        let workload = performanceWorkload()
        if gameplayQuiet != workload.quiet {
            gameplayQuiet = workload.quiet
            session.setQuietPresentation(workload.quiet)
            if !workload.quiet { nextLibraryScan = .distantPast; refreshQueuedCatalog() }
        }
        let work = await performanceCoordinator.due(workload)
        guard !shuttingDown, workload == performanceWorkload() else { return }
        if work.contains(.library) { refreshLibrarySnapshot(force: false) }
        if work.contains(.steam) { refreshSteamControls() }
        if work.contains(.social) {
            for client in GamePlatform.allCases where friendsSnapshots[client] != nil || configuration.friendNotifications == true { refreshFriends(client) }
        }
    }
    func performanceProfile(for game: LibraryGame, environmentID: String? = nil) -> RuntimeProfile? {
        let id = environmentID ?? preferences(for: game).environmentID
        return id.flatMap { value in profiles.first { $0.id == value } } ?? (id == nil ? selectedProfile : nil)
    }
    func reloadPerformanceEnvironment(_ profile: RuntimeProfile) async {
        do { performanceSnapshots[profile.id] = try await performanceEnvironments.snapshot(profile) }
        catch { performanceMessages[profile.id] = error.localizedDescription }
    }
    func applyPerformanceProfile(_ settings: GamePerformanceProfile, game: LibraryGame, profile: RuntimeProfile) {
        guard !performanceBusy.contains(profile.id), let snapshot = performanceSnapshots[profile.id] else { return }
        guard !gameSessions.contains(where: { $0.phase.active && $0.environmentID == profile.id }), !connectionBusy.contains(.windows), !installing,
              installationRequest == nil, uninstallationRequest == nil, maintenance.values.allSatisfy({ $0.completed || $0.failed }) else {
            performanceMessages[profile.id] = "Finish games and file operations before changing this environment."; return
        }
        performanceBusy.insert(profile.id); performanceMessages[profile.id] = "Checking that this environment is closed…"
        Task {
            defer { performanceBusy.remove(profile.id) }
            do {
                let backup = try await performanceEnvironments.apply(settings, profile: profile, expected: snapshot.fingerprint)
                guard !shuttingDown else { return }
                await reloadPerformanceEnvironment(profile)
                performanceMessages[profile.id] = backup == nil ? "The environment already uses these settings." : "Applied to \(profile.name). Reopen Steam before playing. Previous settings saved in PerformanceBackups."
            } catch { performanceMessages[profile.id] = error.localizedDescription; await reloadPerformanceEnvironment(profile) }
        }
    }
    func performanceReports(for game: LibraryGame) -> [GamePerformanceReport] {
        (configuration.performanceReports ?? []).filter { $0.gameID == game.id }.sorted { $0.createdAt > $1.createdAt }
    }
    private func makePerformanceReport(_ samples: [PerformanceFrame], game: LibraryGame, scene: String, cache: PerformanceCacheState,
                                       profile: RuntimeProfile?, settings: GamePerformanceProfile, snapshot: PerformanceEnvironmentSnapshot?, source: PerformanceReportSource) throws -> GamePerformanceReport {
        let thermal: String
        switch ProcessInfo.processInfo.thermalState { case .nominal: thermal = "Nominal"; case .fair: thermal = "Fair"; case .serious: thermal = "Serious"; case .critical: thermal = "Critical"; @unknown default: thermal = "Unknown" }
        return try GamePerformanceReport(gameID: game.id, scene: scene, cache: cache, environmentID: profile?.id,
            engine: profile.map { $0.runtime.name + " " + (snapshot?.version ?? "") } ?? "Imported", fingerprint: profile.map { runtimeFingerprint($0) } ?? "",
            settings: settings, effectiveVariables: snapshot?.variables ?? [:], samples: samples, thermal: source == .imported ? "Unknown (imported)" : thermal, source: source)
    }
    private func savePerformanceReport(_ report: GamePerformanceReport) {
        var reports = configuration.performanceReports ?? []; reports.append(report)
        configuration.performanceReports = Array(reports.suffix(100)); save()
    }
    func importPerformanceReport(_ game: LibraryGame, scene: String, cache: PerformanceCacheState) {
        guard !performanceBusy.contains(game.id) else { return }
        let panel = NSOpenPanel(); panel.title = "Import \(game.name)'s frame timings"; panel.allowsMultipleSelection = false; panel.allowedContentTypes = [.text, .commaSeparatedText]
        let profile = performanceProfile(for: game), settings = preferences(for: game).effectivePerformance
        performanceBusy.insert(game.id)
        Task {
            defer { performanceBusy.remove(game.id) }
            guard let file = await performanceFile(panel), !shuttingDown else { return }
            performanceMessages[game.id] = "Reading frame timings…"
            do {
                let samples = try await performanceReportService.imported(file)
                let snapshot: PerformanceEnvironmentSnapshot?
                if let profile { snapshot = try? await performanceEnvironments.snapshot(profile) } else { snapshot = nil }
                guard !shuttingDown else { return }
                savePerformanceReport(try makePerformanceReport(samples, game: game, scene: scene, cache: cache, profile: profile, settings: settings, snapshot: snapshot, source: .imported))
                performanceMessages[game.id] = "Imported \(samples.count) frames. Environment metadata reflects the current settings; verify it matches the imported run."
            } catch { performanceMessages[game.id] = error.localizedDescription }
        }
    }
    func capturePerformanceReport(_ game: LibraryGame, scene: String, cache: PerformanceCacheState) {
        guard capturingPerformanceFor == nil, let record = activeSession(game.id), record.platform == .windows, let profile = selectedProfile else {
            performanceMessages[game.id] = "Start this Windows game before recording frame timings."; return
        }
        let settings = preferences(for: game).effectivePerformance
        capturingPerformanceFor = game.id; performanceMessages[game.id] = "Recording for 30 seconds. Return to the game and play the scene you want to compare."
        performanceCapture = Task {
            defer { capturingPerformanceFor = nil; performanceCapture = nil }
            do {
                let snapshot = try await performanceEnvironments.snapshot(profile)
                guard snapshot.variables["MTL_HUD_LOGGING_ENABLED"] == "1" else { throw WayfarerError.message("Enable and apply Metal HUD logging, reopen Steam, then relaunch the game before recording.") }
                let tokens: [RuntimeProcessToken]
                if let installation = game.installation(for: .windows), let steam = installation.steamGame, let location = steam.installDirectory {
                    let windows = try await runtimeProcesses.windowsProcesses(prefix: profile.prefix)
                    tokens = await runtimeProcesses.gameProcesses(pids: windows.map { $0.token.pid }, bundlePaths: [:], location: location, steamRoot: steam.library, prefix: profile.prefix)
                } else { tokens = await sessionCoordinator.verifiedTokens(for: record.id) }
                guard !tokens.isEmpty else { throw WayfarerError.message("Waiting for a verified game process. Try recording once the game is visible.") }
                let start = Date()
                try await Task.sleep(for: .seconds(30))
                guard activeSession(game.id)?.id == record.id else { throw WayfarerError.message("The game ended during recording. Import a completed capture instead.") }
                let verified = await runtimeProcesses.verified(tokens)
                guard verified.count == tokens.count else { throw WayfarerError.message("The game's processes changed. Record another run.") }
                let samples = try await performanceReportService.capture(tokens: verified, start: start, end: Date())
                try Task.checkCancellation()
                guard !shuttingDown else { return }
                savePerformanceReport(try makePerformanceReport(samples, game: game, scene: scene, cache: cache, profile: profile, settings: settings, snapshot: snapshot, source: .recorded))
                performanceMessages[game.id] = "Recorded \(samples.count) frames."
            } catch is CancellationError { performanceMessages[game.id] = "Recording cancelled." }
            catch { performanceMessages[game.id] = error.localizedDescription }
        }
    }
    func cancelPerformanceCapture() { performanceCapture?.cancel() }
    func exportPerformanceReport(_ report: GamePerformanceReport) {
        let panel = NSSavePanel(); panel.title = "Export performance report"; panel.nameFieldStringValue = "wayfarer-performance.json"; panel.allowedContentTypes = [.json]
        Task {
            guard let file = await performanceFile(panel), !shuttingDown else { return }
            do { try await performanceReportService.export(report, to: file) } catch { self.error = error.localizedDescription }
        }
    }
    private func performanceFile(_ panel: NSSavePanel) async -> URL? {
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow else { return nil }
        return await withCheckedContinuation { continuation in
            panel.beginSheetModal(for: window) { response in continuation.resume(returning: response == .OK ? panel.url : nil) }
        }
    }
    func deletePerformanceReport(_ report: GamePerformanceReport) {
        configuration.performanceReports?.removeAll { $0.id == report.id }; save()
    }
}
