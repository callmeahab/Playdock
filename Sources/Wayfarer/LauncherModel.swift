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
    @Published private(set) var profiles: [RuntimeProfile] = []
    @Published private(set) var games: [SteamGame] = []
    @Published private(set) var macGames: [SteamGame] = []
    @Published private(set) var transfers: [SteamTransfer] = []
    @Published private(set) var catalog: [SteamCatalogGame] = []
    @Published private(set) var loadingCatalog = false
    @Published private(set) var catalogMessage = "Load your Steam library to see games you can install."
    private var catalogAccounts: [GamePlatform: String] = [:]
    private var catalogRoots: [GamePlatform: URL] = [:]
    private let catalogCache = SteamCatalogCache()
    private var catalogRefreshQueue = Set<GamePlatform>()
    private var catalogAttemptedAt: [GamePlatform: Date] = [:]
    private var catalogTask: Task<Void, Never>?
    private var requestedCatalogForSession = false
    @Published var showingQuickLauncher=false
    @Published var showingCouch=false
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
    private let achievementCache=AchievementCache()
    private var sessionMonitor:Task<Void,Never>?
    private var sessionTokens:[UUID:[RuntimeProcessToken]]=[:]
    private var recovery:[GamePlatform:BackendRecovery]=[:]
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
    private var previousUnread: [String: Int] = [:]
    private var socialAccounts: [GamePlatform: String] = [:]
    private var scheduleBusy = false
    @Published var selectedGameID: String?
    @Published var selectedGamePlatform: GamePlatform?
    @Published private(set) var pendingGameTitle: String?
    @Published private(set) var nativeGameWindows: [SessionWindow] = []
    private var pendingGameID: String?
    private var gameWindowPeers: [String: UUID] = [:]
    @Published private(set) var configuration = LauncherConfiguration()
    @Published var error: String?
    @Published private(set) var libraryWarnings: [String] = []
    @Published private(set) var status = "Checking installed runtimes…"
    @Published private(set) var refreshing = false
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
    private var launches: [UUID: RunningLaunch] = [:]
    private var launchContexts: [UUID: SessionContext] = [:]
    private let store:ConfigurationStore = {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--feature-preview") {return ConfigurationStore(file:URL(fileURLWithPath:"/private/tmp/wayfarer-seven-preview/settings.json"))}
        #endif
        return ConfigurationStore()
    }()
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
    private var macControlPort:UInt16 = 8080
    private var controlTask: Task<Void,Never>?
    private var installationTask: Task<Void,Never>?
    private var installationCleanup: Task<Void,Never>?
    var selectedGame: LibraryGame? { library.first { $0.id == selectedGameID } }

    var selectedProfile: RuntimeProfile? {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--managed-test") {
            return profiles.first { !$0.reusesExistingSteam && $0.runtime.kind == .crossOver }
        }
        #endif
        return RuntimeDiscovery.preferredProfile(profiles, selectedID: configuration.selectedProfileID)
    }
    var steamExecutable: URL? {
        guard let profile = selectedProfile else { return nil }
        return profile.steamExecutable
    }
    var addedGames: [AddedGame] { configuration.addedGames.filter { $0.effectivePlatform == .macOS || $0.profileID == selectedProfile?.id } }
    var library: [LibraryGame] { GameLibrary.merge(mac: macGames, windows: games, profileID: selectedProfile?.id, added: configuration.addedGames, catalog: catalog.filter { includesMacSteam || $0.client != .macOS }) }
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
            storageFolders[.windows]=nil;storageMessages[.windows]=nil;steamConnections[.windows]=nil;controlClients[.windows]=nil;controlPorts[.windows]=nil;recovery[.windows]=nil
            closeWindowsApps(); windowsSteamNeedsRecovery=false; disconnectSession(); configuration.selectedProfileID = newValue == "automatic" ? nil : newValue; save(); refresh() }
    }
    var missingSelection: Bool { configuration.selectedProfileID != nil && selectedProfile == nil }

    init() {
        do { configuration = try store.load() }
        catch {
            // Preserve unreadable settings for recovery rather than overwrite the user's library.
            canSave = false
            self.error = "Cannot read settings at \(store.file.path). Your file has been preserved. \(error.localizedDescription)"
        }
        notifications=SteamNotifications(model:self)
        UNUserNotificationCenter.current().delegate=notifications
        if var records=configuration.gameSessions {
            for index in records.indices where records[index].phase.active { records[index].phase = .interrupted;records[index].endedAt=Date();records[index].message="Wayfarer closed before this session ended." }
            configuration.gameSessions=records
        }
        refresh()
        sessionMonitor=Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for:.seconds(2)) } catch { return }
                guard let self else{return};await self.monitorGameSessions()
            }
        }
        featureMonitor = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(15)) } catch { return }
                guard let self else { return }
                await self.enforceDownloadSchedules()
                for client in GamePlatform.allCases where self.friendsSnapshots[client] != nil || self.configuration.friendNotifications == true { self.refreshFriends(client) }
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
                if NSApp.isActive || self?.gameSessions.contains(where:{$0.phase.active}) == true || self?.transfers.isEmpty == false || self?.steamConnections.values.contains(where:{!$0.downloads.isEmpty}) == true { self?.refreshLibrarySnapshot(); self?.refreshSteamControls() }
            }
        }
        nativeTermination = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            Task { @MainActor in
                guard let self, let entry = self.nativeApplications.removeValue(forKey: app.processIdentifier) else { return }
                self.activeLaunches.removeValue(forKey: entry.0)
                for record in self.gameSessions where self.sessionTokens[record.id]?.contains(where:{$0.pid==app.processIdentifier}) == true { self.endGameSession(record.id,phase:.finished,message:"Session ended.") }
            }
        }
    }

    func refresh() {
        discardChangedAccountCatalogs()
        refreshTask?.cancel()
        libraryScanTask?.cancel(); libraryScanTask = nil
        refreshing = true
        let custom = configuration.customProfiles
        let selected = configuration.selectedProfileID
        let includeMac = includesMacSteam
        refreshTask = Task {
            let result = await Task.detached(priority: .userInitiated) { () -> ([RuntimeInstallation], [RuntimeProfile], SteamLibraryScan?, SteamLibraryScan) in
                let discovery = RuntimeDiscovery()
                var runtimes = discovery.installations()
                for entry in custom where !runtimes.contains(where: { $0.id == entry.runtime.id }) { runtimes.append(entry.runtime) }
                let profiles = discovery.profiles(for: runtimes)
                let selection = RuntimeDiscovery.managedSelection(selected, in: profiles)
                let profile = RuntimeDiscovery.preferredProfile(profiles, selectedID: selection)
                let steam = profile?.steamExecutable
                let scan = profile.flatMap { profile in steam.map { SteamLibrary.scan(steamExecutable: $0, prefix: profile.prefix) } }
                return (runtimes, profiles, scan, includeMac ? SteamLibrary.scanMac() : SteamLibraryScan(games: [], warnings: []))
            }.value
            guard !Task.isCancelled else { return }
            runtimes = result.0
            profiles = result.1
            let migrated = RuntimeDiscovery.managedSelection(selected, in: profiles)
            if configuration.selectedProfileID != migrated { configuration.selectedProfileID = migrated; save() }
            games = result.2?.games ?? []
            macGames = result.3.games
            restoreCachedCatalogs()
            transfers = (result.2?.transfers ?? []) + result.3.transfers
            libraryWarnings = (result.2?.warnings ?? []) + result.3.warnings
            #if DEBUG
            if let flag = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--catalog-review=") }),
               let nonce = UUID(uuidString: String(flag.dropFirst("--catalog-review=".count))), let profile = selectedProfile, let root = steamExecutable?.deletingLastPathComponent(),
               let text = try? String(contentsOf: root.appendingPathComponent("logs/console_log.txt"), encoding: .utf8), let response = SteamCatalog.response(text, nonce: nonce),
               let snapshot = try? SteamCatalog.snapshot(response: response, root: root, client: .windows, profileID: profile.id) {
                catalog = snapshot.games; catalogMessage = "\(snapshot.games.count) Windows games loaded from Steam"
            }
            #endif
            refreshing = false
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

    // Refresh manifest snapshots without restarting engines or Steam. Skip
    // overlapping scans and unchanged publications to keep the native UI idle.
    private func refreshLibrarySnapshot() {
        guard !refreshing, libraryScanTask == nil else { return }
        discardChangedAccountCatalogs()
        let profile = selectedProfile, includeMac = includesMacSteam
        libraryScanTask = Task { [weak self] in
            let result = await Task.detached(priority: .utility) { () -> (SteamLibraryScan, SteamLibraryScan) in
                let empty = SteamLibraryScan(games: [], warnings: [])
                let windows = profile.flatMap { p in p.steamExecutable.map { SteamLibrary.scan(steamExecutable: $0, prefix: p.prefix) } } ?? empty
                return (windows, includeMac ? SteamLibrary.scanMac() : empty)
            }.value
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
        guard canSave else { return }
        do { try store.save(configuration) }
        catch { self.error = "Cannot save settings: \(error.localizedDescription)" }
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

    func addGame(name: String, executable: URL, arguments: String, platform: GamePlatform = .windows) throws {
        if platform == .windows && selectedProfile == nil { throw WayfarerError.message("Choose a Windows environment first.") }
        if platform == .macOS { try NativeGameLaunch.validateApplication(executable) }
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
        beginGameSession(game,platform:installation.platform)
        recordLaunch(game,platform:installation.platform,outcome:"Requested")
        switch installation {
        case .windowsSteam(let steam, let profileID):
            guard profileID == selectedProfile?.id else { error = "Choose this game's Windows environment in Engines."; return }
            launchSteam(appID: steam.appID, gameArguments:arguments)
        case .macSteam(let steam): launchMacSteam(steam,arguments:arguments)
        case .added(var added): added.arguments += arguments; launchGame(added)
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
        let root: URL, profileID: String?, command: LaunchCommand
        let nonce = UUID()
        do {
            if client == .windows {
                guard let profile = selectedProfile, let executable = steamExecutable else { catalogMessage="Choose a Steam environment first."; return }
                guard session.context?.profile.id == profile.id else { connectSteam(.windows); catalogMessage = "Connecting to Windows Steam. Refresh its library when connected."; return }
                root = executable.deletingLastPathComponent(); profileID = profile.id
                var request = try CommandBuilder.steam(profile: profile, executable: executable, bigPicture: false)
                request.arguments += SteamCatalog.commandArguments(nonce: nonce)
                command = try session.attach(request, profile: profile)
            } else {
                guard !steamMainApplications(.macOS).isEmpty else {
                    connectSteam(.macOS); catalogMessage = "Connecting to Mac Steam. Refresh its library when connected."; return
                }
                root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Steam")
                profileID = nil
                command = try session.backend.macCommand(arguments:SteamCatalog.commandArguments(nonce:nonce),port:macControlPort)
            }
        } catch { self.error = error.localizedDescription; return }
        guard let account = SteamCatalog.recentAccount(root: root) else { catalogMessage = "Sign in through Steam, then refresh its library."; return }
        let hadSavedLibrary=catalogAccounts[client] != nil
        let macRoot=FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Steam")
        let sameMacAccount=client == .windows && includesMacSteam && SteamCatalog.recentAccount(root:macRoot) == account && (connectionMode(.macOS) == .online || catalogAccounts[.macOS] == nil)
        loadingCatalog = true; catalogMessage = "Loading your \(client == .macOS ? "Mac" : "Windows") Steam library…"
        catalogTask = Task { [weak self] in
            do {
                let owned = try? await self?.controlClient(client).ownedGameIDs()
                let response = owned == nil ? try await SteamCatalog.refreshResponse(command: command, root: root, nonce: nonce) : nil
                let snapshots = try await Task.detached(priority: .utility) {
                    func snapshot(_ platform:GamePlatform,_ profile:String?=nil) throws -> SteamCatalogSnapshot {
                        if let owned { return try SteamCatalog.snapshot(ownedAppIDs:owned,root:root,client:platform,profileID:profile) }
                        return try SteamCatalog.snapshot(response:response!,root:root,client:platform,profileID:profile)
                    }
                    let primary=try snapshot(client,profileID)
                    let mac=sameMacAccount ? try snapshot(.macOS) : nil
                    return (primary,mac)
                }.value
                let snapshot=snapshots.0
                guard !Task.isCancelled, let self else { return }
                let mode=try await self.controlClient(client).snapshot().mode
                guard mode == .online || (mode == .offline && !hadSavedLibrary) else {
                    throw WayfarerError.message("Your saved library is unchanged. Go online to refresh it.")
                }
                guard account == SteamCatalog.recentAccount(root: root), client == .macOS || self.selectedProfile?.id == profileID else {
                    throw WayfarerError.message("The Steam account or environment changed. Refresh its library again.")
                }
                self.catalog.removeAll { $0.client == client }; self.catalog += snapshot.games
                self.catalogAccounts[client] = account
                self.catalogRoots[client] = root
                try self.catalogCache.save(games: snapshot.games, account: account, root: root, client: client, profileID: profileID)
                if let mac=snapshots.1, SteamCatalog.recentAccount(root:macRoot) == account {
                    self.catalog.removeAll { $0.client == .macOS }; self.catalog += mac.games
                    self.catalogAccounts[.macOS]=account
                    self.catalogRoots[.macOS]=macRoot
                    try self.catalogCache.save(games: mac.games, account: account, root: macRoot, client: .macOS, profileID: nil)
                    self.catalogAttemptedAt[.macOS]=Date()
                    self.catalogRefreshQueue.remove(.macOS)
                }
                self.catalogMessage = snapshot.games.isEmpty ? "No games returned. Sign in through Steam and refresh its library." : "\(snapshot.games.count) \(client == .macOS ? "Mac" : "Windows") games loaded from Steam" + (snapshot.missingMetadata > 0 ? " · Some titles still need metadata from Steam" : "")
                self.loadingCatalog = false; self.catalogTask = nil
                self.refreshQueuedCatalog()
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.loadingCatalog = false; self.catalogTask = nil; self.catalogMessage = error.localizedDescription
                self.refreshQueuedCatalog()
            }
        }
    }

    private func discardChangedAccountCatalogs() {
        for client in GamePlatform.allCases {
            let root = client == .macOS ? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Steam") : steamExecutable?.deletingLastPathComponent()
            if let previous = catalogAccounts[client], previous != root.flatMap({ SteamCatalog.recentAccount(root: $0) }) || catalogRoots[client]?.resolvingSymlinksInPath() != root?.resolvingSymlinksInPath() {
                friendsSnapshots.removeValue(forKey:client); friendsMessages.removeValue(forKey:client)
                cloudStatuses=cloudStatuses.filter{!$0.key.hasSuffix(":"+client.rawValue)}
                catalog.removeAll { $0.client == client }; catalogAccounts.removeValue(forKey: client)
                catalogRoots.removeValue(forKey: client); catalogAttemptedAt.removeValue(forKey: client)
            }
        }
    }

    private func restoreCachedCatalogs() {
        discardChangedAccountCatalogs()
        for client in GamePlatform.allCases where client == .windows || includesMacSteam {
            guard catalogAccounts[client] == nil, let context=steamContext(client), let account=SteamCatalog.recentAccount(root:context.root),
                  let saved=try? catalogCache.load(account:account,root:context.root,client:client,profileID:client == .windows ? selectedProfile?.id : nil) else { continue }
            catalog.removeAll { $0.client == client }; catalog += saved.games
            catalogAccounts[client]=account; catalogRoots[client]=context.root
            catalogMessage="Saved library · Updates when Steam is online."
        }
    }
    private func refreshQueuedCatalog() {
        guard !loadingCatalog, let client=GamePlatform.allCases.first(where:{catalogRefreshQueue.contains($0) && (connectionMode($0) == .online || (connectionMode($0) == .offline && catalogAccounts[$0] == nil))}) else { return }
        loadSteamLibrary(client)
    }
    private func refreshOnlineCatalog(_ client: GamePlatform) {
        // A first offline launch can seed the cache from Steam's local licenses.
        // After that, only an online session replaces the saved library.
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
            while self.connectionBusy.contains(.macOS) { try? await Task.sleep(for:.milliseconds(100)) }
            do {
                _=try NativeGameLaunch.steamURL(appID:game.appID)
                guard self.connectionMessages[.macOS]==nil else { throw WayfarerError.message(self.connectionMessages[.macOS]!) }
                self.status="Opening \(game.name) on your Mac…"
                try self.runMacSteam(arguments:["-applaunch",game.appID]+arguments); self.markLaunch(game.name,outcome:"Launch sent to Mac Steam")
            } catch { self.failGameSession("steam:"+game.appID,message:error.localizedDescription); self.markLaunch(game.name,outcome:error.localizedDescription); self.error=error.localizedDescription }
        }
    }

    private func macSteamClient() throws -> URL {
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Steam")
        let candidates = [URL(fileURLWithPath: "/Applications/Steam.app"), root.appendingPathComponent("Steam.AppBundle/Steam"),
                          NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.valvesoftware.steam")].compactMap { $0 }
        guard let client = candidates.first(where: { Bundle(url: $0)?.bundleIdentifier == "com.valvesoftware.steam" }) else {
            throw WayfarerError.message("Install macOS Steam to play Mac Steam games. Windows Steam stays separate in Wayfarer.")
        }
        return client
    }

    func openSteamClient(_ platform: GamePlatform, destination: SteamUIRequest.Destination = .account, friendID:String? = nil) {
        if platform == .windows, selectedProfile?.reusesExistingSteam != true {
            if destination == .chat {
                guard let profile=selectedProfile,steamExecutable != nil else { error="Set up Windows Steam in Engines before opening chat."; return }
                do {
                    var command=try CommandBuilder.steam(profile:profile,executable:steamExecutable,bigPicture:false)
                    command.arguments += ["-silent","steam://open/friends"]
                    try run(command,title:"Steam Chat",profile:profile,presentSession:false)
                    session.showChat(); chatRequest=UUID()
                    if let friendID { Task { try? await Task.sleep(for:.seconds(1)); try? await self.controlClient(.windows).openFriend(friendID) } }
                } catch { self.error=error.localizedDescription }
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

    private func setSteamClientHidden(_ platform:GamePlatform,hidden:Bool) {
        let root:URL, prefix:URL?
        if platform == .windows {
            guard let profile=selectedProfile,profile.reusesExistingSteam,let steam=steamExecutable else { return }
            root=steam.deletingLastPathComponent(); prefix=profile.prefix
        } else {
            root=FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Steam"); prefix=nil
        }
        for app in NSWorkspace.shared.runningApplications where RuntimeProcessIdentity.isSteamClient(pid:app.processIdentifier,root:root,prefix:prefix) {
            if hidden { app.hide() } else { app.unhide() }
        }
    }

    func runMacSteam(arguments:[String]=[]) throws {
        let root=FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Steam")
        if let port=SteamControlEndpoint.runningMacPort(root:root) { macControlPort=port }
        else if steamMainApplications(.macOS).isEmpty { macControlPort=try SteamControlEndpoint.availablePort() }
        let command=try session.backend.macCommand(arguments:arguments,port:macControlPort)
        let id=UUID()
        let launch=try ProcessRunner.start(command) { [weak self] code in
            Task { @MainActor in self?.launches.removeValue(forKey:id) }
        }
        launches[id]=launch
    }

    func steamContext(_ client:GamePlatform) -> (root:URL,prefix:URL?)? {
        if client == .macOS { return (FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Steam"),nil) }
        guard let profile=selectedProfile,let steam=steamExecutable else { return nil }
        return (steam.deletingLastPathComponent(),profile.prefix)
    }
    private func steamMainApplications(_ client:GamePlatform) -> [NSRunningApplication] {
        guard let context=steamContext(client) else { return [] }
        return NSWorkspace.shared.runningApplications.filter {
            guard RuntimeProcessIdentity.isSteamClient(pid:$0.processIdentifier,root:context.root,prefix:context.prefix) else { return false }
            // Current Mac Steam registers its main Steam Helper as the UI app;
            // steam_osx itself is a backend process, absent from this list.
            return client == .macOS || RuntimeProcessIdentity.windowsProgram(for:$0.processIdentifier)?.lowercased() == "steam.exe"
        }
    }
    private func ensureSteamBackend(_ client:GamePlatform, allowUncontrolledRestart:Bool = false) async throws {
        if client == .windows, selectedProfile?.reusesExistingSteam != true { return }
        guard let context=steamContext(client) else { throw WayfarerError.message("Choose a Steam environment first.") }
        let existing=steamMainApplications(client)
        guard existing.contains(where:{ !session.backend.isAttached($0,root:context.root,prefix:context.prefix) }) else { return }
        if client == .windows { windowsSteamNeedsRecovery=true }
        setSteamClientHidden(client,hidden:true)
        let steam:Set<String>=["steam.exe","steamwebhelper.exe","steamerrorreporter.exe"]
        if let prefix=context.prefix {
            let apps=try WindowsAppRecovery.apps(prefix:prefix)
            guard apps.isEmpty else {
                throw WayfarerError.message("Windows apps are running. Use Manage Windows apps to close them and reconnect Steam.")
            }
        }
        let activity:([String],SteamControlSnapshot)?
        do {
            let control=try controlClient(client)
            activity=(try await control.runningAppIDs(),try await control.snapshot())
        } catch {
            // A stopped Wine server can leave Steam/CEF processes behind. They
            // cannot service launches. Clean only verified orphan Steam PIDs,
            // after checking for other Windows apps and pending installations.
            guard client == .windows,let prefix=context.prefix else {
                throw WayfarerError.message("Close the existing Steam client, then reconnect it in Wayfarer to apply background mode.")
            }
            let scan=SteamLibrary.scan(steamExecutable:context.root.appendingPathComponent("steam.exe"),prefix:prefix)
            guard try WindowsAppRecovery.apps(prefix:prefix).isEmpty,scan.transfers.isEmpty,scan.warnings.isEmpty else {
                throw WayfarerError.message("Finish the running games and installations before reconnecting Steam.")
            }
            if allowUncontrolledRestart {
                // The user reviewed this environment in the app manager. Ask
                // Steam itself to shut down; do not terminate its Wine server.
                activity=nil
            } else {
                guard !((try? RuntimeProcessIdentity.hasWineServer(prefix:prefix)) ?? true) else {
                    throw WayfarerError.message("Steam needs to reconnect. Open Manage Windows apps to restart its backend.")
                }
                let processes=try RuntimeProcessIdentity.windowsProcesses(prefix:prefix)
                for process in processes where steam.contains(process.program) && RuntimeProcessIdentity.token(for:process.token.pid) == process.token && RuntimeProcessIdentity.isSteamClient(pid:process.token.pid,root:context.root,prefix:prefix) {
                    _=Darwin.kill(process.token.pid,SIGTERM)
                }
                for _ in 0..<40 {
                    if steamMainApplications(client).isEmpty { return }
                    try await Task.sleep(for:.milliseconds(250))
                }
                throw WayfarerError.message("The old Steam client is still closing. Reconnect its backend once it exits.")
            }
        }
        if let (running,snapshot)=activity {
            guard running.isEmpty,!snapshot.downloads.contains(where:{$0.active}) else {
                throw WayfarerError.message("Steam is running a game or downloading. Finish it, then reconnect Steam to apply background mode.")
            }
        }
        connectionMessages[client]="Restarting Steam in the background…"
        if client == .macOS { try runMacSteam(arguments:["-shutdown"]) }
        else if let profile=selectedProfile {
            var command=try CommandBuilder.steam(profile:profile,executable:steamExecutable,bigPicture:false)
            command.arguments += ["-silent","-shutdown"]
            try run(command,title:"Steam",profile:profile,presentSession:false)
        }
        for _ in 0..<80 {
            if try RuntimeProcessIdentity.steamProcesses(root:context.root,prefix:context.prefix).isEmpty {
                try await Task.sleep(for:.milliseconds(500))
                return
            }
            try await Task.sleep(for:.milliseconds(250))
        }
        throw WayfarerError.message("Steam has not finished closing. Close Steam, then reconnect its backend in Wayfarer.")
    }

    func showWindowsSession() { launchSteam() }

    func launchSteam(appID: String? = nil, gameArguments:[String] = []) {
        guard !installing else { return }
        guard let profile = selectedProfile else { error = "Choose an available environment in Engines."; return }
        if let appID,profile.reusesExistingSteam,let context=steamContext(.windows) {
            let clients=steamMainApplications(.windows)
            if connectionBusy.contains(.windows) || clients.isEmpty || clients.contains(where:{!session.backend.isAttached($0,root:context.root,prefix:context.prefix)}) {
                connectSteam(.windows)
                Task { [weak self] in
                    guard let self else { return }
                    while self.connectionBusy.contains(.windows) { try? await Task.sleep(for:.milliseconds(100)) }
                    guard self.selectedProfile?.id==profile.id else { return }
                    let connected=self.steamMainApplications(.windows)
                    guard !connected.isEmpty,connected.allSatisfy({self.session.backend.isAttached($0,root:context.root,prefix:context.prefix)}) else {
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
            var command = try CommandBuilder.steam(profile: profile, executable: steamExecutable, appID: appID, bigPicture: false, gameArguments:gameArguments)
            if appID == nil { command.arguments += ["steam://open/main"] }
            let title = appID.flatMap { id in games.first { $0.appID == id }?.name } ?? "Steam"
            if let appID { pendingGameTitle = title; pendingGameID = "steam:\(appID)" }
            try run(command, title: title, profile: profile, presentSession:false)
            if appID == nil && !profile.reusesExistingSteam { session.showSteam(); sessionRequest=UUID() }
        } catch { if let appID { failGameSession("steam:"+appID,message:error.localizedDescription) };pendingGameTitle = nil; pendingGameID = nil; self.error = error.localizedDescription }
    }

    func launchGame(_ game: AddedGame) {
        if game.effectivePlatform == .macOS {
            do {
                try NativeGameLaunch.validateApplication(game.executable)
                let options = NSWorkspace.OpenConfiguration(); options.arguments = game.arguments
                status = "Opening \(game.name) on your Mac…"
                NSWorkspace.shared.openApplication(at: game.executable, configuration: options) { [weak self] app, failure in
                    Task { @MainActor in
                        guard let self else { return }
                        if let failure { self.failGameSession("added:"+game.id.uuidString,message:failure.localizedDescription);self.markLaunch(game.name,outcome:failure.localizedDescription); self.error = failure.localizedDescription; return }
                        if let app, !app.isTerminated {
                            if let record=self.activeSession("added:"+game.id.uuidString),let token=RuntimeProcessIdentity.token(for:app.processIdentifier) { self.sessionTokens[record.id]=[token];self.observeGameSession(record.id,running:true) }
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
            return
        }
        guard let profile = selectedProfile, game.profileID == profile.id else { return }
        do {
            pendingGameTitle = game.name; pendingGameID = "added:\(game.id.uuidString)"
            try run(CommandBuilder.launch(profile: profile, program: game.executable, arguments: game.arguments), title: game.name, profile: profile, presentSession: false)
        } catch { failGameSession("added:"+game.id.uuidString,message:error.localizedDescription);pendingGameTitle = nil; pendingGameID = nil; self.error = error.localizedDescription }
    }

    func run(_ command: LaunchCommand, title: String, profile: RuntimeProfile, presentSession: Bool = true) throws {
        if presentSession, session.context?.profile.id == profile.id,
           let existing = launchContexts.values.first(where: { $0.title == title && $0.profile.id == profile.id }) {
            try session.begin(existing)
            session.chooseWindow(session.windows.first(where: { !$0.isSteamClient && !$0.program.isEmpty })?.id ?? session.selectedWindowID ?? "")
            pendingGameTitle = nil
            sessionRequest = UUID()
            return
        }
        if let prefix = command.environment["WINEPREFIX"] {
            try FileManager.default.createDirectory(at: URL(fileURLWithPath: prefix), withIntermediateDirectories: true)
        }
        let id = UUID()
        try session.begin(SessionContext(profile: profile, title: title), expectsWindow: presentSession)
        let nativeCommand = try session.attach(command, profile: profile)
        let launch = try ProcessRunner.start(nativeCommand) { [weak self] code in
            Task { @MainActor in
                guard let self else { return }
                guard self.launches.removeValue(forKey: id) != nil else { return }
                self.launchContexts.removeValue(forKey: id)
                self.activeLaunches.removeValue(forKey: id)
                // An existing Steam instance acknowledges -applaunch by exiting
                // the short-lived command process. The game window arrives later.
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
                self.refresh()
            }
        }
        launches[id] = launch
        activeLaunches[id] = title
        latestLog = launch.logURL
        status = "Launched \(title)"
        let context = SessionContext(profile: profile, title: title, launch: RuntimeProcessIdentity.token(for: launch.process.processIdentifier))
        launchContexts[id] = context
        try session.begin(context, expectsWindow: presentSession)
        if presentSession { sessionRequest = UUID() }
    }

    func disconnectSession() {
        setupTask?.cancel()
        catalogTask?.cancel(); catalogTask = nil; loadingCatalog = false; requestedCatalogForSession = false
        friendsSnapshots.removeValue(forKey:.windows); cloudStatuses=cloudStatuses.filter{!$0.key.hasSuffix(":windows")}
        catalog.removeAll { $0.client == .windows }; catalogAccounts.removeValue(forKey: .windows)
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
        do { try run(CommandBuilder.launch(profile: profile, program: file), title: file.lastPathComponent, profile: profile) }
        catch { self.error = error.localizedDescription }
    }

    func installSteam() {
        guard !installing, let profile = selectedProfile else { return }
        do { _ = try NativeRuntime.loaderSource(for: profile.runtime) }
        catch { self.error = error.localizedDescription; return }
        do { try session.begin(SessionContext(profile: profile, title: "Steam")) }
        catch { self.error = error.localizedDescription; return }
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
                let url = URL(string: "https://cdn.akamai.steamstatic.com/client/installer/SteamSetup.exe")!
                let (data, response) = try await URLSession.shared.data(from: url)
                guard let response = response as? HTTPURLResponse, response.statusCode == 200,
                      data.count > 2, data.starts(with: [0x4d, 0x5a]) else {
                    throw WayfarerError.message("Valve's download did not return a Windows Steam installer. Please try setup again.")
                }
                try Task.checkCancellation()
                let directory = AppPaths.support.appendingPathComponent("Installers")
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let file = directory.appendingPathComponent("SteamSetup.exe")
                try data.write(to: file, options: .atomic)
                if let preparation = try CommandBuilder.prepareNewProfile(profile) {
                    setupMessage = "Creating Wayfarer's Windows environment…"
                    status = setupMessage
                    let code = try await runPreparation(preparation)
                    try Task.checkCancellation()
                    guard code == 0 else { throw WayfarerError.message("Preparing the Windows environment failed (\(code)). Check the session log.") }
                }
                setupMessage = "Installing Steam for Wayfarer…"
                status = setupMessage
                let installerCommand = try session.attach(CommandBuilder.installSteam(profile: profile, installer: file), profile: profile)
                let code = try await runPreparation(installerCommand)
                try Task.checkCancellation()
                guard code == 0 else { throw WayfarerError.message("Steam installation failed (\(code)). Open the latest session log for details.") }
                guard let steam = profile.steamExecutable else { throw WayfarerError.message("Steam setup finished without installing steam.exe in Wayfarer's environment. Please retry setup.") }
                setupMessage = "Starting Steam. Sign in with your Steam account…"
                try run(CommandBuilder.steam(profile: profile, executable: steam, bigPicture: bigPicture), title: "Steam", profile: profile)
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
        if let path = command.environment["CX_BOTTLE_PATH"] {
            try FileManager.default.createDirectory(at: URL(fileURLWithPath: path), withIntermediateDirectories: true)
        }
        if let path = command.environment["WINEPREFIX"] {
            try FileManager.default.createDirectory(at: URL(fileURLWithPath: path), withIntermediateDirectories: true)
        }
        return try await withCheckedThrowingContinuation { continuation in
            do {
                let launch = try ProcessRunner.start(command) { [weak self] code in
                    Task { @MainActor in self?.launches.removeValue(forKey: id); continuation.resume(returning: code) }
                }
                launches[id] = launch
                latestLog = launch.logURL
            } catch { continuation.resume(throwing: error) }
        }
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
        do {
            try FileManager.default.createDirectory(at: AppPaths.logs, withIntermediateDirectories: true)
            NSWorkspace.shared.open(AppPaths.logs)
        } catch { self.error = error.localizedDescription }
    }

    func chooseExecutable(title: String, platform: GamePlatform = .windows) -> URL? {
        let panel = NSOpenPanel()
        panel.title = title
        panel.allowedContentTypes = platform == .macOS ? [.applicationBundle] : [UTType(filenameExtension: "exe") ?? .data]
        panel.canChooseDirectories = false
        return panel.runModal() == .OK ? panel.url : nil
    }
}

struct GameInstallationRequest: Identifiable {
    let id=UUID()
    let game: LibraryGame
    let platform: GamePlatform
    let appID: String
}
struct GameUninstallationRequest:Identifiable {
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
        guard let request=uninstallationRequest,!uninstallBusy else { return }
        uninstallBusy=true; uninstallMessage="Connecting to Steam…"
        Task { [weak self] in
            guard let self else { return }; defer { self.uninstallBusy=false }
            do {
                guard request.platform != .windows || request.profileID==self.selectedProfile?.id else { throw WayfarerError.message("The Windows environment changed. Open this game again.") }
                let connected=try? await self.controlClient(request.platform).snapshot()
                if self.connectionBusy.contains(request.platform) || connected == nil {
                    self.connectSteam(request.platform)
                    for _ in 0..<200 {
                        if !self.connectionBusy.contains(request.platform) { break }
                        try await Task.sleep(for:.milliseconds(100))
                    }
                }
                let control=try self.controlClient(request.platform)
                var state:SteamAppState?
                for _ in 0..<20 {
                    if let value=try? await control.appState(appID:request.appID) { state=value; break }
                    try await Task.sleep(nanoseconds:500_000_000)
                }
                guard let state else { throw WayfarerError.message("Steam is not connected. Open Steam here to sign in, then retry.") }
                guard self.uninstallationRequest?.id==request.id,
                      request.platform != .windows || request.profileID==self.selectedProfile?.id else { return }
                guard !state.isRunning else { throw WayfarerError.message("Close this game before uninstalling it.") }
                self.uninstallMessage="Uninstalling \(request.game.name)…"
                if state.installed { try await control.uninstall(appID:request.appID) }
                for _ in 0..<120 {
                    try await Task.sleep(nanoseconds:500_000_000)
                    if let current=try? await control.appState(appID:request.appID), !current.installed {
                        guard request.platform != .windows || request.profileID==self.selectedProfile?.id else { return }
                        self.uninstallationRequest=nil; self.uninstallMessage=""
                        if request.platform == .macOS { self.macGames.removeAll { $0.appID==request.appID } }
                        else { self.games.removeAll { $0.appID==request.appID } }
                        let root=request.platform == .macOS ? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Steam") : self.steamExecutable?.deletingLastPathComponent()
                        if current.owned,let root,let account=SteamCatalog.recentAccount(root:root),
                           !self.catalog.contains(where:{$0.appID==request.appID&&$0.client==request.platform}) {
                            self.catalogAccounts[request.platform]=account
                            self.catalogRoots[request.platform]=root
                            self.catalog.append(SteamCatalogGame(appID:request.appID,name:request.game.name,client:request.platform,profileID:request.profileID,artwork:request.game.artwork,heroArtwork:request.game.heroArtwork))
                            try? self.catalogCache.save(games:self.catalog.filter{$0.client==request.platform},account:account,root:root,client:request.platform,profileID:request.profileID)
                        }
                        self.status="Uninstalled \(request.game.name) · \(request.platform.name)"
                        self.refreshLibrarySnapshot(); self.refreshSteamControls()
                        return
                    }
                }
                throw WayfarerError.message("Steam has not finished uninstalling this game. Open Steam to check its progress.")
            } catch { self.uninstallMessage=error.localizedDescription }
        }
    }
    func connectionMode(_ client: GamePlatform) -> SteamConnectionMode { steamConnections[client]?.mode ?? .unavailable }
    func controlClient(_ client: GamePlatform) throws -> SteamControl {
        let endpoint:SteamControlEndpoint
        if client == .windows {
            guard let profile=selectedProfile,let steam=steamExecutable else {
                throw WayfarerError.message("Open Windows Steam from Wayfarer to connect.")
            }
            let root=steam.deletingLastPathComponent()
            let discovered=profile.reusesExistingSteam ? SteamControlEndpoint.runningWindowsPort(root:root,prefix:profile.prefix) : nil
            guard let port=discovered ?? (session.context?.profile.id==profile.id ? session.steamControlPort : nil),port>1024 else {
                throw WayfarerError.message("Connect Windows Steam in Wayfarer to use its controls.")
            }
            endpoint=SteamControlEndpoint(port:port,root:root,prefix:profile.prefix)
        } else {
            let root=FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Steam")
            if let discovered=SteamControlEndpoint.runningMacPort(root:root) { macControlPort=discovered }
            endpoint=SteamControlEndpoint(port:macControlPort,root:root)
        }
        if controlPorts[client]==endpoint.port, let saved=controlClients[client] { return saved }
        let control=SteamControl(endpoint:endpoint); controlClients[client]=control; controlPorts[client]=endpoint.port; return control
    }
    func refreshSteamControls() {
        guard controlTask==nil else { return }
        controlTask=Task { [weak self] in
            guard let self else { return }; defer { self.controlTask=nil }
            for client in GamePlatform.allCases where client == .windows || self.includesMacSteam {
                do {
                    let snapshot=try await self.controlClient(client).snapshot()
                    self.steamConnections[client]=snapshot
                    self.recovery[client,default:BackendRecovery()].connected()
                    self.restoreCachedCatalogs()
                    self.refreshOnlineCatalog(client)
                    if !self.connectionBusy.contains(client),client != .windows || !self.windowsSteamNeedsRecovery { self.connectionMessages[client]=nil }
                    if client == .windows,self.selectedProfile?.reusesExistingSteam == true,
                       let pending=self.pendingGameID,pending.hasPrefix("steam:"),
                       let state=try? await self.controlClient(client).appState(appID:String(pending.dropFirst(6))),state.isRunning {
                        self.status="Playing \(self.pendingGameTitle ?? "game")"
                        self.pendingGameTitle=nil; self.pendingGameID=nil
                    }
                } catch {
                    self.steamConnections.removeValue(forKey:client)
                    self.recovery[client,default:BackendRecovery()].failed()
                    self.recoverBackendIfSafe(client)
                }
            }
        }
    }
    func connectSteam(_ client: GamePlatform, allowUncontrolledRestart:Bool = false) {
        guard !connectionBusy.contains(client) else { return }
        connectionBusy.insert(client); connectionMessages[client]="Connecting in the background…"
        let profileID=selectedProfile?.id
        Task { [weak self] in
            guard let self else { return }; defer { self.connectionBusy.remove(client) }
            do {
                if client == .windows,let profile=self.selectedProfile,profile.reusesExistingSteam {
                    try self.session.begin(SessionContext(profile:profile,title:"Steam"),expectsWindow:false)
                }
                try await self.ensureSteamBackend(client,allowUncontrolledRestart:allowUncontrolledRestart)
                guard client == .macOS || self.selectedProfile?.id==profileID else { return }
                if client == .windows {
                    guard let profile=self.selectedProfile else { throw WayfarerError.message("Choose a Windows engine first.") }
                    let changed=self.session.context?.profile.id != profile.id
                    var command=try CommandBuilder.steam(profile:profile,executable:self.steamExecutable,bigPicture:false)
                    command.arguments += ["-silent"]
                    try self.run(command,title:"Steam",profile:profile,presentSession:false)
                    if changed { self.controlClients.removeValue(forKey:client) }
                } else { try self.runMacSteam() }
                if let request=self.steamUIRequest,request.platform==client,self.steamWindow.context?.id==request.id,
                   self.steamWindow.hasInputPermission,self.steamWindow.hasScreenPermission {
                    self.session.backend.present(root:request.root,prefix:request.prefix,in:self.steamWindow.surface.window)
                    self.setSteamClientHidden(client,hidden:false)
                    let destination=request.destination == .chat ? "steam://open/friends" : "steam://open/main"
                    if client == .macOS { try self.runMacSteam(arguments:[destination]) }
                    else if let profile=self.selectedProfile {
                        var command=try CommandBuilder.steam(profile:profile,executable:self.steamExecutable,bigPicture:false)
                        command.arguments += ["-silent",destination]
                        try self.run(command,title:"Steam",profile:profile,presentSession:false)
                    }
                }
                for _ in 0..<20 {
                    if let control=try? self.controlClient(client), let snapshot=try? await control.snapshot() {
                        self.steamConnections[client]=snapshot; self.connectionMessages[client]=nil
                        self.recovery[client,default:BackendRecovery()].connected()
                        if client == .windows { self.windowsSteamNeedsRecovery=false }
                        self.restoreCachedCatalogs()
                        self.refreshOnlineCatalog(client)
                        if let request=self.steamUIRequest,request.platform==client,request.destination == .chat,let friend=request.friendID { try? await control.openFriend(friend) }
                        return
                    }
                    try? await Task.sleep(nanoseconds:500_000_000)
                }
                self.connectionMessages[client]="Steam is still starting. Reconnect its backend to retry."
            } catch { self.connectionMessages[client]=error.localizedDescription }
        }
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
            let apps=try await Task.detached(priority:.utility) { try WindowsAppRecovery.apps(prefix:profile.prefix) }.value
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
                for app in apps where WindowsAppRecovery.isCurrent(app,prefix:profile.prefix) {
                    if force { try WindowsAppRecovery.forceQuit(app,prefix:profile.prefix) }
                    else { _=NSRunningApplication(processIdentifier:app.token.pid)?.terminate() }
                }
                let deadline=Date().addingTimeInterval(10)
                repeat {
                    guard !Task.isCancelled,self.windowsAppsOperation==operation,self.selectedProfile?.id==profile.id else { return }
                    let remaining=try await Task.detached(priority:.utility) { try WindowsAppRecovery.apps(prefix:profile.prefix) }.value
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
    func setSteamMode(_ client:GamePlatform, offline:Bool) {
        guard !connectionBusy.contains(client) else { return }
        connectionBusy.insert(client); connectionMessages[client]=offline ? "Going offline…" : "Connecting online…"
        Task { [weak self] in
            guard let self else { return }; defer { self.connectionBusy.remove(client) }
            do {
                let control=try self.controlClient(client)
                try await control.changeMode(offline:offline)
                var stable=0
                for _ in 0..<40 {
                    try await Task.sleep(nanoseconds:500_000_000)
                    if let snapshot=try? await control.snapshot(), snapshot.mode == (offline ? .offline : .online) {
                        stable += 1
                        guard stable >= 3 else { continue }
                        self.steamConnections[client]=snapshot; self.connectionMessages[client]=nil
                        if !offline { self.catalogAttemptedAt.removeValue(forKey:client); self.refreshOnlineCatalog(client) }
                        if self.installationRequest?.platform==client { self.prepareInstallation() }
                        return
                    } else { stable=0 }
                }
                throw WayfarerError.message("Steam has not finished changing modes. Open Steam to check its connection.")
            } catch { self.connectionMessages[client]=error.localizedDescription }
        }
    }
    func controlDownload(_ appID:String, client:GamePlatform, paused:Bool) {
        guard !connectionBusy.contains(client) else { return }
        connectionBusy.insert(client)
        Task { [weak self] in
            guard let self else { return }; defer { self.connectionBusy.remove(client) }
            do {
                let control=try self.controlClient(client); try await control.pause(appID:appID,paused:paused)
                self.steamConnections[client]=try await control.snapshot()
            } catch { self.error=error.localizedDescription }
        }
    }
    func pauseDownloads(_ client:GamePlatform, paused:Bool) {
        guard !connectionBusy.contains(client) else { return }
        configuration.scheduledPauses?.remove(downloadPolicyKey(client)); save()
        connectionBusy.insert(client)
        Task { [weak self] in
            guard let self else { return }; defer { self.connectionBusy.remove(client) }
            do {
                let control=try self.controlClient(client); try await control.enableDownloads(!paused)
                self.steamConnections[client]=try await control.snapshot()
            } catch { self.error=error.localizedDescription }
        }
    }
    /// Reconnect only when needed and resolve the client after a restart finishes.
    private func installationControl(_ request: GameInstallationRequest) async throws -> SteamControl {
        if !connectionBusy.contains(request.platform), let control=try? controlClient(request.platform),
           (try? await control.snapshot()) != nil { return control }
        try Task.checkCancellation()
        guard installationRequest?.id == request.id else { throw CancellationError() }
        connectSteam(request.platform)
        for _ in 0..<200 {
            try Task.checkCancellation()
            guard installationRequest?.id == request.id else { throw CancellationError() }
            if !connectionBusy.contains(request.platform) {
                if let control=try? controlClient(request.platform), (try? await control.snapshot()) != nil { return control }
                throw WayfarerError.message(connectionMessages[request.platform] ?? "Steam is not connected. Open login, sign in, then retry.")
            }
            try await Task.sleep(for:.milliseconds(100))
        }
        throw WayfarerError.message("Steam is still connecting. You can close this dialog and try again later.")
    }
    func prepareInstallation() {
        guard let request=installationRequest, !installBusy else { return }
        let operation=installDialog.begin("Connecting to Steam…")
        installationTask=Task { [weak self] in
            guard let self else { return }
            defer { if self.installDialog.operationID==operation { self.installationTask=nil } }
            do {
                if let cleanup=self.installationCleanup { await cleanup.value }
                try Task.checkCancellation()
                let control=try await self.installationControl(request)
                let snapshot=try await control.snapshot()
                try Task.checkCancellation()
                guard self.installationRequest?.id==request.id else { return }
                self.steamConnections[request.platform]=snapshot
                guard snapshot.mode == .online else {
                    self.installDialog.finish(operation,message:snapshot.mode == .offline ? "Go online to download this game." : "Sign in through Steam, then retry."); return
                }
                let plan=try await control.prepareInstall(appID:request.appID)
                try Task.checkCancellation()
                guard self.installationRequest?.id==request.id else { return }
                self.installDialog.finish(operation,plan:plan.failureMessage == nil ? plan : nil,message:plan.confirmationMessage)
            } catch {
                self.installDialog.finish(operation,message:error.localizedDescription)
            }
        }
    }
    func chooseInstallFolder(_ index:Int) {
        guard let request=installationRequest, !installBusy else { return }
        let operation=installDialog.begin("Updating library…",keepPlan:true)
        installationTask=Task { [weak self] in
            guard let self else { return }
            defer { if self.installDialog.operationID==operation { self.installationTask=nil } }
            do {
                let plan=try await self.controlClient(request.platform).chooseFolder(appID:request.appID,folder:index)
                try Task.checkCancellation()
                guard self.installationRequest?.id==request.id else { return }
                self.installDialog.finish(operation,plan:plan.failureMessage == nil ? plan : nil,message:plan.confirmationMessage)
            } catch { self.installDialog.finish(operation,message:error.localizedDescription) }
        }
    }
    func confirmInstallation(acceptedAgreements:Bool) {
        guard let request=installationRequest, let plan=installPlan, plan.canConfirm, !installBusy, !plan.needsAgreement || acceptedAgreements else { return }
        let operation=installDialog.begin("Starting download…",keepPlan:true)
        installationTask=Task { [weak self] in
            guard let self else { return }
            defer { if self.installDialog.operationID==operation { self.installationTask=nil } }
            do {
                let control=try self.controlClient(request.platform)
                let result=try await control.continueInstall(appID:request.appID,agreements:acceptedAgreements ? plan.eulas : [])
                try Task.checkCancellation()
                guard self.installationRequest?.id==request.id else { return }
                guard result.error==0 && result.state != 15 else { throw WayfarerError.message(result.failureMessage ?? "Steam could not start the installation. Retry to reload its details.") }
                if result.hasStarted {
                    self.installationRequest=nil; self.installDialog.dismiss(); self.status="Installing \(request.game.name)"
                    self.refreshLibrarySnapshot(); self.showDownloads()
                    if let snapshot=try? await control.snapshot() { self.steamConnections[request.platform]=snapshot }
                } else {
                    self.installDialog.finish(operation,plan:result,message:"Steam needs another confirmation. Review the agreements below or open Steam.")
                }
            } catch { self.installDialog.finish(operation,message:error.localizedDescription) }
        }
    }
    func cancelInstallation() {
        let request=installationRequest
        let pending=installationTask
        pending?.cancel(); installationTask=nil
        installationRequest=nil; installDialog.dismiss()
        closeSteamPanel()
        // Closing the native sheet never waits for Steam. Only dismiss our own
        // single-game confirmation; another wizard or started download is left alone.
        if let request,let control=try? controlClient(request.platform) {
            installationCleanup=Task {
                if let pending { await pending.value }
                try? await control.cancelInstall(appID:request.appID)
            }
        }
    }
    func closeSteamPanel(_ id: UUID? = nil) {
        guard id == nil || steamUIRequest?.id == id else { return }
        steamUIRequest=nil
        steamWindow.end()
    }
    func closeUninstallDialog() {
        uninstallationRequest=nil
        closeSteamPanel()
    }

}

extension LauncherModel {
    func rememberPlatform(_ platform:GamePlatform,game:LibraryGame) {
        var value=preferences(for:game); value.preferredPlatform=platform
        if configuration.gamePreferences==nil { configuration.gamePreferences=[:] }; configuration.gamePreferences?[game.id]=value; save()
    }
    func preferences(for game:LibraryGame) -> GamePreferences { configuration.gamePreferences?[game.id] ?? GamePreferences() }
    var visibleLibrary:[LibraryGame] { library.filter { !preferences(for:$0).hidden } }
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
    func launchInSavedEnvironment(_ game:LibraryGame,environment:String) {
        guard let target=profiles.first(where:{$0.id==environment}) else { error="The saved Windows environment is unavailable. Update this game's profile."; return }
        do {
            if let current=selectedProfile {
                guard nativeGameWindows.isEmpty,(try WindowsAppRecovery.apps(prefix:current.prefix)).isEmpty else { throw WayfarerError.message("Close the running Windows application before switching environments.") }
            }
            selection=target.id
            Task { [weak self] in
                guard let self else { return }
                for _ in 0..<50 { if !self.refreshing { break }; try? await Task.sleep(for:.milliseconds(200)) }
                guard self.selectedProfile?.id==target.id,let updated=self.library.first(where:{$0.id==game.id}) else { self.error="This game is not available in its saved environment. Refresh that Steam library or update its profile."; return }
                self.launch(updated,platform:.windows)
            }
        } catch { self.error=error.localizedDescription }
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
        do { try report.write(to:url,atomically:true,encoding:.utf8); NSWorkspace.shared.activateFileViewerSelecting([url]) }
        catch { self.error="Could not export diagnostics: \(error.localizedDescription)" }
    }

    func downloadPolicyKey(_ client:GamePlatform) -> String {
        let context=steamContext(client)
        return "\(client.rawValue):\(context?.root.path ?? "unavailable"):\(context.flatMap{SteamCatalog.recentAccount(root:$0.root)} ?? "signedOut")"
    }
    func downloadPolicy(_ client:GamePlatform) -> DownloadPolicy { configuration.downloadPolicies?[downloadPolicyKey(client)] ?? DownloadPolicy() }
    func readDownloadPolicy(_ client:GamePlatform) async -> DownloadPolicy {
        if let saved=configuration.downloadPolicies?[downloadPolicyKey(client)] { return saved }
        var policy=DownloadPolicy()
        if let settings=try? await controlClient(client).downloadSettings() {
            policy.enabled=settings.scheduled; policy.bandwidthKBps=max(0,settings.bandwidthKBps)
            if settings.startHour != settings.endHour { policy.startHour=settings.startHour; policy.endHour=settings.endHour }
        }
        return policy
    }
    func applyDownloadPolicy(_ policy:DownloadPolicy,client:GamePlatform) {
        guard !connectionBusy.contains(client) else { return }
        connectionBusy.insert(client); let key=downloadPolicyKey(client)
        Task { [weak self] in
            guard let self else { return }; defer { self.connectionBusy.remove(client) }
            do {
                try policy.validate(); try await self.controlClient(client).applyDownloadPolicy(policy)
                guard self.downloadPolicyKey(client) == key else { return }
                if self.configuration.downloadPolicies == nil { self.configuration.downloadPolicies=[:] }
                self.configuration.downloadPolicies?[key]=policy; self.save()
                self.downloadPolicyMessages[client]="Saved in Steam"; await self.enforceDownloadSchedules()
            } catch { self.downloadPolicyMessages[client]="Steam could not confirm all changes · \(error.localizedDescription)" }
        }
    }
    func enforceDownloadSchedules() async {
        guard !scheduleBusy else { return }; scheduleBusy=true; defer { scheduleBusy=false }
        for client in GamePlatform.allCases where client == .windows || includesMacSteam {
            let key=downloadPolicyKey(client)
            guard let policy=configuration.downloadPolicies?[key],connectionMode(client) == .online,!connectionBusy.contains(client) else { continue }
            do {
                let control=try controlClient(client),snapshot=try await control.snapshot()
                guard downloadPolicyKey(client) == key else { continue }
                let owned=configuration.scheduledPauses?.contains(key) == true
                if !policy.allows(Date()),!snapshot.downloadsPaused,!snapshot.downloads.isEmpty {
                    try await control.enableDownloads(false)
                    if configuration.scheduledPauses == nil { configuration.scheduledPauses=[] }; configuration.scheduledPauses?.insert(key); save()
                } else if policy.allows(Date()),owned {
                    if snapshot.downloadsPaused { try await control.enableDownloads(true) }
                    configuration.scheduledPauses?.remove(key); save()
                }
                steamConnections[client]=try await control.snapshot()
            } catch { downloadPolicyMessages[client]="Schedule waiting for Steam" }
        }
    }
    func prioritizeDownload(_ appID:String,client:GamePlatform,toTop:Bool) {
        guard !connectionBusy.contains(client),connectionMode(client) == .online else { return }
        let key=downloadPolicyKey(client); connectionBusy.insert(client)
        Task { [weak self] in
            guard let self else { return }; defer { self.connectionBusy.remove(client) }
            do {
                let control=try self.controlClient(client)
                let snapshot=try await control.snapshot()
                guard self.downloadPolicyKey(client) == key,snapshot.downloads.contains(where:{$0.appID==appID}) else { return }
                var policy=self.downloadPolicy(client); var ordered=policy.ordered(snapshot.downloads.map(\.appID)); ordered.removeAll{$0==appID}
                if toTop { ordered.insert(appID,at:0) } else { ordered.append(appID) }
                try await control.prioritize(appID:appID,index:toTop ? 0 : max(0,ordered.count-1))
                policy.priorityAppIDs=ordered
                if self.configuration.downloadPolicies==nil { self.configuration.downloadPolicies=[:] }; self.configuration.downloadPolicies?[key]=policy; self.save()
                self.steamConnections[client]=try await control.snapshot()
            } catch { self.error=error.localizedDescription }
        }
    }

    func refreshFriends(_ client:GamePlatform) {
        guard !friendsBusy.contains(client) else { return }
        let key=downloadPolicyKey(client)
        if socialAccounts[client] != key { friendsSnapshots.removeValue(forKey:client); previousUnread=previousUnread.filter{!$0.key.hasPrefix(client.rawValue+":")}; socialAccounts[client]=key }
        guard connectionMode(client) == .online else { friendsSnapshots.removeValue(forKey:client); friendsMessages[client]=connectionMode(client) == .offline ? "Go online to see your friends." : "Connect and sign in to Steam."; return }
        friendsBusy.insert(client)
        Task { [weak self] in
            guard let self else { return }; defer { self.friendsBusy.remove(client) }
            do {
                let snapshot=try await self.controlClient(client).friends()
                guard self.downloadPolicyKey(client) == key else { return }
                self.friendsSnapshots[client]=snapshot; self.friendsMessages[client]=snapshot.ready ? nil : "Friends are still connecting. Load Steam Friends to retry."
                for friend in snapshot.friends {
                    let id="\(client.rawValue):\(friend.id)",previous=self.previousUnread[id]
                    self.previousUnread[id]=friend.unread
                    if let previous,friend.unread>previous,self.configuration.friendNotifications==true,!(client == .windows && self.friendsSnapshots[.macOS]?.ready == true && self.steamContext(.macOS).flatMap{SteamCatalog.recentAccount(root:$0.root)} == self.steamContext(.windows).flatMap{SteamCatalog.recentAccount(root:$0.root)}) { self.notifyUnread(friend,client:client) }
                }
            } catch { self.friendsSnapshots.removeValue(forKey:client); self.friendsMessages[client]="Friends are unavailable. Load Steam Friends or open chat to reconnect." }
        }
    }
    func loadFriendsEngine(_ client:GamePlatform) {
        connectSteam(client)
        Task { [weak self] in
            guard let self else { return }
            while self.connectionBusy.contains(client) { try? await Task.sleep(for:.milliseconds(100)) }
            do {
                guard self.connectionMode(client) == .online else { self.refreshFriends(client); return }
                if client == .macOS { try self.runMacSteam(arguments:["steam://open/friends"]) }
                else if let profile=self.selectedProfile {
                    var command=try CommandBuilder.steam(profile:profile,executable:self.steamExecutable,bigPicture:false)
                    command.arguments += ["-silent","steam://open/friends"]
                    try self.run(command,title:"Steam Friends",profile:profile,presentSession:false)
                }
                try await Task.sleep(for:.seconds(2)); self.refreshFriends(client)
            } catch { self.friendsMessages[client]=error.localizedDescription }
        }
    }
    func showFriends() { chatRequest=UUID() }
    var unreadFriendsCount:Int {
        var counts:[String:Int]=[:]
        for (client,snapshot) in friendsSnapshots { let account=steamContext(client).flatMap{SteamCatalog.recentAccount(root:$0.root)} ?? client.rawValue; for friend in snapshot.friends { let key=account+":"+friend.id; counts[key]=max(counts[key] ?? 0,friend.unread) } }
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
    func suggestedSaveFolder(_ game:LibraryGame,platform:GamePlatform) -> URL? {
        guard game.isSteam,platform != .windows || preferences(for:game).environmentID == nil || preferences(for:game).environmentID == selectedProfile?.id,let context=steamContext(platform),let account=SteamCatalog.recentAccount(root:context.root),let id=UInt64(account),id>=76561197960265728 else { return nil }
        let folder=context.root.appendingPathComponent("userdata/\(id-76561197960265728)/\(game.id.dropFirst(6))/remote")
        return (try? SaveBackupStore.validateFolder(folder)) == nil ? nil : folder
    }
    func saveScope(_ game:LibraryGame,platform:GamePlatform) -> String { "\(game.id):\(platform.rawValue):\(platform == .windows ? (preferences(for:game).environmentID ?? selectedProfile?.id ?? "unavailable") : "native")" }
    func saveFolders(_ game:LibraryGame,platform:GamePlatform) -> [URL] { preferences(for:game).saveFolders[saveScope(game,platform:platform)] ?? [] }
    func chooseSaveFolder(_ game:LibraryGame,platform:GamePlatform) {
        let panel=NSOpenPanel(); panel.title="Choose \(game.name)'s save folder"; panel.canChooseDirectories=true; panel.canChooseFiles=false; panel.allowsMultipleSelection=false
        guard panel.runModal() == .OK,let folder=panel.url else { return }
        do { try SaveBackupStore.validateFolder(folder); var preferences=preferences(for:game); let key=saveScope(game,platform:platform); var folders=preferences.saveFolders[key] ?? []; if !folders.contains(folder) { folders.append(folder) }; preferences.saveFolders[key]=folders; try updatePreferences(preferences,game:game) }
        catch { self.error=error.localizedDescription }
    }
    func refreshBackups(_ game:LibraryGame,platform:GamePlatform) { let key=saveScope(game,platform:platform); saveBackups[key]=(try? SaveBackupStore().list(gameID:key)) ?? [] }
    func createSaveBackup(_ game:LibraryGame,platform:GamePlatform) {
        guard !saveBusy else { return }; let folders=saveFolders(game,platform:platform),scope=saveScope(game,platform:platform); saveBusy=true; saveMessage="Creating restore point…"
        Task { [weak self] in
            do {
                let backup=try await Task.detached(priority:.utility){try SaveBackupStore().create(gameID:scope,name:game.name,folders:folders)}.value
                self?.saveMessage="Restore point created · \(backup.files.count) files"; self?.refreshBackups(game,platform:platform)
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
                    else if let profile=self.selectedProfile { guard !(try RuntimeProcessIdentity.windowsProcesses(prefix:profile.prefix)).contains(where:{$0.program==installation.location.lastPathComponent.lowercased()}) else { throw WayfarerError.message("Close the game before restoring its saves.") } }
                }
                _ = try await Task.detached(priority:.utility){try SaveBackupStore().restore(backup)}.value
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
        configuration.gameSessions=Array(history.suffix(200));save()
    }
    private func changeSession(_ id:UUID,_ change:(inout GameSessionRecord)->Void) {
        guard var records=configuration.gameSessions,let index=records.firstIndex(where:{$0.id==id}) else{return}
        let before=records[index];change(&records[index]);guard before != records[index] else{return};configuration.gameSessions=records;save()
        if !records[index].phase.active, pendingGameID==records[index].gameID { pendingGameID=nil;pendingGameTitle=nil }
    }
    private func observeGameSession(_ id:UUID,running:Bool?) { changeSession(id){$0.observe(running:running)} }
    private func endGameSession(_ id:UUID,phase:GameSessionPhase,message:String) { changeSession(id){$0.phase=phase;$0.endedAt=Date();$0.message=message};sessionTokens.removeValue(forKey:id) }
    private func failGameSession(_ gameID:String,message:String) { if let record=activeSession(gameID){endGameSession(record.id,phase:.failed,message:message)} }
    private func monitorGameSessions() async {
        for client in GamePlatform.allCases {
            let records=gameSessions.filter{$0.phase.active && $0.platform==client && $0.gameID.hasPrefix("steam:") && (client == .macOS || $0.environmentID==selectedProfile?.id)}
            guard !records.isEmpty || steamConnections[client] != nil else{continue}
            let profileID=selectedProfile?.id
            let running=try? await controlClient(client).runningAppIDs()
            guard client == .macOS || profileID==selectedProfile?.id else{continue}
            for record in records {
                let isRunning=running.map{$0.contains(String(record.gameID.dropFirst(6)))}
                if isRunning==false,record.startedAt != nil,record.phase != .stopping,let context=steamContext(client),let code=SteamGameExit.abnormalCode(root:context.root,appID:String(record.gameID.dropFirst(6)),since:record.requestedAt){endGameSession(record.id,phase:.crashed,message:"Steam reported the game exiting with code \(code). See launch diagnostics.")}
                else{observeGameSession(record.id,running:isRunning)}
            }
            for appID in running ?? [] {
                let gameID="steam:"+appID
                if activeSession(gameID)==nil,let game=library.first(where:{$0.id==gameID}),game.installation(for:client) != nil {
                    beginGameSession(game,platform:client);if let record=activeSession(gameID){observeGameSession(record.id,running:true)}
                }
            }
        }
        let records=gameSessions.filter{$0.phase.active && $0.gameID.hasPrefix("added:")}
        let prefix=selectedProfile?.prefix ?? URL(fileURLWithPath:"/nonexistent")
        let windows=records.contains{$0.platform == .windows} ? try? await Task.detached(priority:.utility){try WindowsAppRecovery.apps(prefix:prefix)}.value : nil
        for record in records {
            guard let added=configuration.addedGames.first(where:{"added:"+$0.id.uuidString==record.gameID}) else{continue}
            if record.platform == .macOS {
                let apps=NSWorkspace.shared.runningApplications.filter{$0.bundleURL?.resolvingSymlinksInPath()==added.executable.resolvingSymlinksInPath() && !$0.isTerminated}
                sessionTokens[record.id]=apps.compactMap{RuntimeProcessIdentity.token(for:$0.processIdentifier)}
                observeGameSession(record.id,running:!apps.isEmpty)
            } else if record.environmentID==selectedProfile?.id,let windows {
                let matches=windows.filter{$0.program==added.executable.lastPathComponent.lowercased() && RuntimeProcessIdentity.belongsToPrefix(pid:$0.token.pid,prefix:added.executable.deletingLastPathComponent())}
                sessionTokens[record.id]=matches.map{$0.token};observeGameSession(record.id,running:!matches.isEmpty)
            }
        }
    }
    func bringGameForward(_ record:GameSessionRecord) {
        guard record.phase.active else{return}
        if let peer=gameWindowPeers[record.gameID],let window=nativeGameWindows.first(where:{$0.peer.id==peer}) { session.activateNativeWindow(window.id);return }
        let installation=library.first{$0.id==record.gameID}?.installation(for:record.platform)
        if let location=installation?.location {
            let apps=NSWorkspace.shared.runningApplications.filter { app in
                if RuntimeProcessIdentity.isSteamClient(pid:app.processIdentifier,root:steamContext(record.platform)?.root ?? location,prefix:steamContext(record.platform)?.prefix){return false}
                return app.bundleURL?.resolvingSymlinksInPath()==location.resolvingSymlinksInPath() || RuntimeProcessIdentity.belongsToPrefix(pid:app.processIdentifier,prefix:location)
            }
            if let app=apps.first { app.activate(options:[.activateAllWindows,.activateIgnoringOtherApps]);return }
        }
        changeSession(record.id){$0.message="No game window is available yet. Check Steam for an update or launch confirmation."}
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
                    let tokens=sessionTokens[record.id] ?? []
                    guard !tokens.isEmpty else{throw WayfarerError.message("No verified game process is available. Close the game from its own menu.")}
                    for token in tokens where RuntimeProcessIdentity.token(for:token.pid)==token { _=NSRunningApplication(processIdentifier:token.pid)?.terminate() }
                }
                try await Task.sleep(for:.seconds(8));await monitorGameSessions()
                if activeSession(record.gameID)?.id==record.id { changeSession(record.id){$0.phase = .playing;$0.message="The game is still running. Close it from its menu, or review Windows apps in Steam controls."} }
            } catch { changeSession(record.id){$0.phase = .disconnected;$0.message=error.localizedDescription} }
        }
    }
    private func recoverBackendIfSafe(_ client:GamePlatform) {
        let safe = !connectionBusy.contains(client) && installationRequest==nil && uninstallationRequest==nil && maintenance.values.allSatisfy{$0.completed || $0.failed} && !gameSessions.contains{$0.phase.active && $0.platform==client} && !transfers.contains{$0.client==client}
        guard recovery[client,default:BackendRecovery()].shouldRetry(safe:safe,enabled:startsSteamInBackground && !ProcessInfo.processInfo.arguments.contains("--no-background-steam")) else {
            if recovery[client]?.wasConnected == true && !connectionBusy.contains(client) { connectionMessages[client] = safe ? "Steam disconnected. Reconnect its backend to retry." : "Steam disconnected. Automatic recovery is waiting for games or file operations to finish. Reconnect to check safely." };return
        }
        recovery[client,default:BackendRecovery()].attempted();connectSteam(client)
    }
    func navigate(_ destination:String) { showingCouch=false;navigationDestination=destination;navigationRequest=UUID();showingQuickLauncher=false }
    func openQuickLauncher() { guard installationRequest==nil,uninstallationRequest==nil,steamUIRequest==nil,featureGame==nil,windowsAppsProfile==nil,storageGame==nil,achievementGame==nil,!showingCollections,!showingDiagnostics else{return};showingQuickLauncher=true }
    func quickPlatform(_ game:LibraryGame)->GamePlatform? { preferredGamePlatform(game).flatMap{game.installation(for:$0)?.platform} ?? game.preferredInstallation?.platform }
    var quickGames:[LibraryGame] { visibleLibrary.sorted { a,b in
        let aRecent=gameSessions.last{$0.gameID==a.id}?.requestedAt ?? Date(timeIntervalSince1970:a.lastPlayed),bRecent=gameSessions.last{$0.gameID==b.id}?.requestedAt ?? Date(timeIntervalSince1970:b.lastPlayed)
        if favorites.contains(a.id) != favorites.contains(b.id){return favorites.contains(a.id)};if aRecent != bRecent{return aRecent>bRecent};return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
    } }
    func compatibilityTests(_ game:LibraryGame)->[CompatibilityTest] { (configuration.compatibilityTests ?? []).filter{$0.gameID==game.id}.sorted{$0.testedAt>$1.testedAt} }
    func recordCompatibility(_ game:LibraryGame,profile:RuntimeProfile,rating:CompatibilityRating,notes:String) {
        var records=configuration.compatibilityTests ?? [];records.removeAll{$0.gameID==game.id && $0.environmentID==profile.id}
        records.append(CompatibilityTest(gameID:game.id,environmentID:profile.id,engine:profile.runtime.name,fingerprint:CompatibilityTest.fingerprint(profile),options:preferences(for:game).launchOptions,rating:rating,notes:notes));configuration.compatibilityTests=Array(records.suffix(500));save()
    }
    func suggestedProfile(_ game:LibraryGame)->RuntimeProfile? {
        for record in compatibilityTests(game) where record.rating != .broken {
            if let profile=profiles.first(where:{$0.id==record.environmentID && CompatibilityTest.fingerprint($0)==record.fingerprint}){return profile}
        }
        return ([selectedProfile].compactMap{$0}+profiles).first{profile in !compatibilityTests(game).contains{$0.environmentID==profile.id && $0.rating == .broken && $0.fingerprint==CompatibilityTest.fingerprint(profile)}}
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
        Task { do {
            let client=try controlClient(platform)
            if let folder {try await client.moveGame(appID:steam.appID,folder:folder)}else{try await client.verifyFiles(appID:steam.appID)}
            while !Task.isCancelled {
                guard platform == .macOS || profileID==selectedProfile?.id else{throw WayfarerError.message("Environment changed. Check the original Steam library for this operation.")}
                let progress=try await client.maintenanceProgress(appID:steam.appID);maintenance[key]=progress
                if progress.completed || progress.failed { refreshLibrarySnapshot();refreshStorage(platform);return }
                try await Task.sleep(for:.seconds(2))
            }
        } catch { maintenance[key]=SteamMaintenanceProgress(kind:folder==nil ? "verify":"move",progress:nil,task:error.localizedDescription,completed:false,failed:true);storageMessages[platform]=error.localizedDescription } }
    }
    func achievementScope(_ client:GamePlatform)->String? {
        guard connectionMode(client) != .signedOut,let context=steamContext(client),let account=SteamCatalog.recentAccount(root:context.root) else{return nil}
        return client.rawValue+":"+context.root.resolvingSymlinksInPath().path+":"+account+":"+(client == .windows ? selectedProfile?.id ?? "" : "")
    }
    func achievementSnapshot(_ game:LibraryGame,platform:GamePlatform)->AchievementSnapshot? {
        guard let scope=achievementScope(platform),let snapshot=achievementSnapshots[game.id+":"+platform.rawValue],snapshot.scope==scope else{return nil};return snapshot
    }
    func refreshAchievements(_ game:LibraryGame,platform:GamePlatform) {
        guard game.id.hasPrefix("steam:"),let scope=achievementScope(platform) else{return}
        let id=String(game.id.dropFirst(6)),key=game.id+":"+platform.rawValue
        if let saved=try? achievementCache.load(scope:scope,appID:id){achievementSnapshots[key]=saved}
        guard !achievementBusy.contains(key) else{return}
        if connectionMode(platform) == .unavailable || connectionMode(platform) == .signedOut {achievementMessages[key]="Saved achievements. Connect Steam to refresh.";return}
        achievementBusy.insert(key)
        Task {defer{achievementBusy.remove(key)};do {
            let items=try await controlClient(platform).achievements(appID:id);guard scope==achievementScope(platform) else{return}
            let snapshot=AchievementSnapshot(scope:scope,appID:id,updatedAt:Date(),achievements:items,offline:connectionMode(platform) == .offline);achievementSnapshots[key]=snapshot;achievementMessages[key]=snapshot.offline == true ? "Steam’s offline achievement data. Go online to update it.":nil;try achievementCache.save(snapshot)
        }catch{if scope==achievementScope(platform){achievementMessages[key]=error.localizedDescription}}}
    }
}
