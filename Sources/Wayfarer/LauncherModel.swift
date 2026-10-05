import AppKit
import Combine
import Foundation
import UniformTypeIdentifiers
import WayfarerCore
import Darwin

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
    private let store = ConfigurationStore()
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
    @Published var installationRequest: GameInstallationRequest?
    @Published var uninstallationRequest:GameUninstallationRequest?
    @Published private(set) var uninstallBusy=false
    @Published private(set) var uninstallMessage=""
    @Published private(set) var installPlan: SteamInstallPlan?
    @Published private(set) var installBusy = false
    @Published private(set) var installMessage = ""
    private var controlClients: [GamePlatform: SteamControl] = [:]
    private var controlPorts: [GamePlatform: UInt16] = [:]
    private var macControlPort:UInt16 = 8080
    private var controlTask: Task<Void,Never>?
    private var installationTask: Task<Void,Never>?
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
        set { disconnectSession(); configuration.selectedProfileID = newValue == "automatic" ? nil : newValue; save(); refresh() }
    }
    var missingSelection: Bool { configuration.selectedProfileID != nil && selectedProfile == nil }

    init() {
        do { configuration = try store.load() }
        catch {
            // Preserve unreadable settings for recovery rather than overwrite the user's library.
            canSave = false
            self.error = "Cannot read settings at \(store.file.path). Your file has been preserved. \(error.localizedDescription)"
        }
        refresh()
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
                self.status = "Playing \(title)"
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
                if NSApp.isActive { self?.refreshLibrarySnapshot(); self?.refreshSteamControls() }
            }
        }
        nativeTermination = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            Task { @MainActor in
                guard let self, let entry = self.nativeApplications.removeValue(forKey: app.processIdentifier) else { return }
                self.activeLaunches.removeValue(forKey: entry.0)
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

    private func save() {
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
        let platform = platform ?? preferredGamePlatform(game)
        if installationDisabled(game, platform: platform) { return }
        let target = platform.flatMap { game.installation(for: $0) }
        guard let installation = target else { install(game, platform: platform); return }
        if installation.platform == .windows, let peer = gameWindowPeers[game.id], let window = nativeGameWindows.first(where: { $0.peer.id == peer }) {
            session.activateNativeWindow(window.id); return
        }
        switch installation {
        case .windowsSteam(let steam, let profileID):
            guard profileID == selectedProfile?.id else { error = "Choose this game's Windows environment in Engines."; return }
            launchSteam(appID: steam.appID)
        case .macSteam(let steam): launchMacSteam(steam)
        case .added(let added): launchGame(added)
        }
    }

    func install(_ game: LibraryGame, platform: GamePlatform?) {
        guard !installationDisabled(game, platform: platform) else { return }
        guard let platform, let offer = game.offer(for: platform) else { error = "Load this Steam account’s library before installing the game."; return }
        if platform == .windows, offer.profileID != selectedProfile?.id { error = "Choose this game’s Windows environment first."; return }
        guard installationRequest == nil else { return }
        installationRequest=GameInstallationRequest(game:game,platform:platform,appID:offer.appID)
        installPlan=nil; installMessage="Connecting to Steam…"
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
        let sameMacAccount=client == .windows && includesMacSteam && SteamCatalog.recentAccount(root:macRoot)==account && (connectionMode(.macOS) == .online || catalogAccounts[.macOS] == nil)
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
                if let mac=snapshots.1, SteamCatalog.recentAccount(root:macRoot)==account {
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
        let preferred=game.preferredPlatform
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

    private func launchMacSteam(_ game: SteamGame) {
        connectSteam(.macOS)
        Task { [weak self] in
            guard let self else { return }
            while self.connectionBusy.contains(.macOS) { try? await Task.sleep(for:.milliseconds(100)) }
            do {
                _=try NativeGameLaunch.steamURL(appID:game.appID)
                guard self.connectionMessages[.macOS]==nil else { throw WayfarerError.message(self.connectionMessages[.macOS]!) }
                self.status="Opening \(game.name) on your Mac…"
                try self.runMacSteam(arguments:["-applaunch",game.appID])
            } catch { self.error=error.localizedDescription }
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

    func openSteamClient(_ platform: GamePlatform, destination: SteamUIRequest.Destination = .account) {
        if platform == .windows, selectedProfile?.reusesExistingSteam != true {
            if destination == .chat {
                guard let profile=selectedProfile,steamExecutable != nil else { error="Set up Windows Steam in Engines before opening chat."; return }
                do {
                    var command=try CommandBuilder.steam(profile:profile,executable:steamExecutable,bigPicture:false)
                    command.arguments += ["-silent","steam://open/friends"]
                    try run(command,title:"Steam Chat",profile:profile,presentSession:false)
                    session.showChat(); chatRequest=UUID()
                } catch { self.error=error.localizedDescription }
            } else { launchSteam() }
            return
        }
        if platform == .windows {
            guard let profile=selectedProfile, let steam=steamExecutable else { error="Choose an installed Steam environment first."; return }
            steamUIRequest=SteamUIRequest(platform:platform,root:steam.deletingLastPathComponent(),prefix:profile.prefix,destination:destination)
        } else {
            guard (try? macSteamClient()) != nil else { error="Install macOS Steam to use its account panel."; return }
            steamUIRequest=SteamUIRequest(platform:platform,root:FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Steam"),prefix:nil,destination:destination)
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

    private func runMacSteam(arguments:[String]=[]) throws {
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

    private func steamContext(_ client:GamePlatform) -> (root:URL,prefix:URL?)? {
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
            return client == .macOS || RuntimeProcessIdentity.windowsProgram(for:$0.processIdentifier)?.lowercased()=="steam.exe"
        }
    }
    private func ensureSteamBackend(_ client:GamePlatform) async throws {
        if client == .windows, selectedProfile?.reusesExistingSteam != true { return }
        guard let context=steamContext(client) else { throw WayfarerError.message("Choose a Steam environment first.") }
        let existing=steamMainApplications(client)
        guard existing.contains(where:{ !session.backend.isAttached($0,root:context.root,prefix:context.prefix) }) else { return }
        setSteamClientHidden(client,hidden:true)
        let steam:Set<String>=["steam.exe","steamwebhelper.exe","steamerrorreporter.exe"]
        let services=steam.union(["services.exe","winedevice.exe","rpcss.exe","explorer.exe","steamservice.exe","winewrapper.exe","plugplay.exe"])
        if let prefix=context.prefix {
            let processes=try RuntimeProcessIdentity.windowsProcesses(prefix:prefix)
            guard processes.allSatisfy({services.contains($0.program)}) else {
                throw WayfarerError.message("A Windows application is running. Close it before reconnecting Steam to apply background mode.")
            }
        }
        let running:[String], snapshot:SteamControlSnapshot
        do {
            let control=try controlClient(client)
            running=try await control.runningAppIDs(); snapshot=try await control.snapshot()
        } catch {
            // A stopped Wine server can leave Steam/CEF processes behind. They
            // cannot service launches. Clean only verified orphan Steam PIDs,
            // after checking for other Windows apps and pending installations.
            guard client == .windows,let prefix=context.prefix,!((try? RuntimeProcessIdentity.hasWineServer(prefix:prefix)) ?? true) else {
                throw WayfarerError.message("Close the existing Steam client, then reconnect it in Wayfarer to apply background mode.")
            }
            let processes=try RuntimeProcessIdentity.windowsProcesses(prefix:prefix)
            let scan=SteamLibrary.scan(steamExecutable:context.root.appendingPathComponent("steam.exe"),prefix:prefix)
            guard processes.allSatisfy({services.contains($0.program)}),scan.transfers.isEmpty,scan.warnings.isEmpty else {
                throw WayfarerError.message("Close the existing Steam client after its games and installations finish, then reconnect it in Wayfarer.")
            }
            for process in processes where steam.contains(process.program) && RuntimeProcessIdentity.token(for:process.token.pid)==process.token && RuntimeProcessIdentity.isSteamClient(pid:process.token.pid,root:context.root,prefix:prefix) {
                _=Darwin.kill(process.token.pid,SIGTERM)
            }
            for _ in 0..<40 {
                if steamMainApplications(client).isEmpty { return }
                try await Task.sleep(for:.milliseconds(250))
            }
            throw WayfarerError.message("The old Steam client is still closing. Reconnect its backend once it exits.")
        }
        guard running.isEmpty,!snapshot.downloads.contains(where:{$0.active}) else {
            throw WayfarerError.message("Steam is running a game or downloading. Finish it, then reconnect Steam to apply background mode.")
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

    func launchSteam(appID: String? = nil) {
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
                        return
                    }
                    self.launchSteam(appID:appID)
                }
                return
            }
        }
        if appID==nil && profile.reusesExistingSteam { openSteamClient(.windows); return }
        guard steamExecutable != nil else { installSteam(); return }
        do {
            var command = try CommandBuilder.steam(profile: profile, executable: steamExecutable, appID: appID, bigPicture: false)
            if appID == nil { command.arguments += ["steam://open/main"] }
            let title = appID.flatMap { id in games.first { $0.appID == id }?.name } ?? "Steam"
            if let appID { pendingGameTitle = title; pendingGameID = "steam:\(appID)" }
            try run(command, title: title, profile: profile, presentSession:false)
            if appID == nil && !profile.reusesExistingSteam { session.showSteam(); sessionRequest=UUID() }
        } catch { pendingGameTitle = nil; pendingGameID = nil; self.error = error.localizedDescription }
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
                        if let failure { self.error = failure.localizedDescription; return }
                        if let app, !app.isTerminated {
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
            } catch { self.error = error.localizedDescription }
            return
        }
        guard let profile = selectedProfile, game.profileID == profile.id else { return }
        do {
            pendingGameTitle = game.name; pendingGameID = "added:\(game.id.uuidString)"
            try run(CommandBuilder.launch(profile: profile, program: game.executable, arguments: game.arguments), title: game.name, profile: profile, presentSession: false)
        } catch { pendingGameTitle = nil; pendingGameID = nil; self.error = error.localizedDescription }
    }

    private func run(_ command: LaunchCommand, title: String, profile: RuntimeProfile, presentSession: Bool = true) throws {
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
                if code != 0 { self.error = "\(title) exited with code \(code). Open the latest session log for details." }
                self.status = code == 0 ? "\(title) launch command finished" : "\(title) launch failed"
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
        guard installationRequest == nil, uninstallationRequest == nil,
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
                self.connectSteam(request.platform)
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
    private func controlClient(_ client: GamePlatform) throws -> SteamControl {
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
                    self.restoreCachedCatalogs()
                    self.refreshOnlineCatalog(client)
                    if !self.connectionBusy.contains(client) { self.connectionMessages[client]=nil }
                    if client == .windows,self.selectedProfile?.reusesExistingSteam == true,
                       let pending=self.pendingGameID,pending.hasPrefix("steam:"),
                       let state=try? await self.controlClient(client).appState(appID:String(pending.dropFirst(6))),state.isRunning {
                        self.status="Playing \(self.pendingGameTitle ?? "game")"
                        self.pendingGameTitle=nil; self.pendingGameID=nil
                    }
                } catch {
                    self.steamConnections.removeValue(forKey:client)
                }
            }
        }
    }
    func connectSteam(_ client: GamePlatform) {
        guard !connectionBusy.contains(client) else { return }
        connectionBusy.insert(client); connectionMessages[client]="Connecting in the background…"
        let profileID=selectedProfile?.id
        Task { [weak self] in
            guard let self else { return }; defer { self.connectionBusy.remove(client) }
            do {
                if client == .windows,let profile=self.selectedProfile,profile.reusesExistingSteam {
                    try self.session.begin(SessionContext(profile:profile,title:"Steam"),expectsWindow:false)
                }
                try await self.ensureSteamBackend(client)
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
                        self.restoreCachedCatalogs()
                        self.refreshOnlineCatalog(client)
                        return
                    }
                    try? await Task.sleep(nanoseconds:500_000_000)
                }
                self.connectionMessages[client]="Steam is still starting. Reconnect its backend to retry."
            } catch { self.connectionMessages[client]=error.localizedDescription }
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
        connectionBusy.insert(client)
        Task { [weak self] in
            guard let self else { return }; defer { self.connectionBusy.remove(client) }
            do {
                let control=try self.controlClient(client); try await control.enableDownloads(!paused)
                self.steamConnections[client]=try await control.snapshot()
            } catch { self.error=error.localizedDescription }
        }
    }
    func prepareInstallation() {
        guard let request=installationRequest, !installBusy else { return }
        installBusy=true; installMessage="Connecting to Steam…"
        installationTask=Task { [weak self] in
            guard let self else { return }; defer { self.installBusy=false; self.installationTask=nil }
            do {
                self.connectSteam(request.platform)
                let control=try self.controlClient(request.platform)
                var snapshot:SteamControlSnapshot?
                for _ in 0..<20 {
                    if let value=try? await control.snapshot() { snapshot=value; break }
                    try await Task.sleep(nanoseconds:500_000_000)
                }
                guard let snapshot else { throw WayfarerError.message("Steam is not connected. If Mac Steam was already open, quit it and reopen it from Wayfarer. Sign in through Steam, then retry.") }
                guard self.installationRequest?.id==request.id else { return }
                self.steamConnections[request.platform]=snapshot
                guard snapshot.mode == .online else { self.installMessage=snapshot.mode == .offline ? "Go online to download this game." : "Sign in through Steam, then retry."; return }
                self.installPlan=try await control.prepareInstall(appID:request.appID)
                self.installMessage="Choose a library for the \(request.platform.name) version."
            } catch { self.installMessage=error.localizedDescription }
        }
    }
    func chooseInstallFolder(_ index:Int) {
        guard let request=installationRequest, !installBusy else { return }; installBusy=true
        installationTask=Task { [weak self] in
            guard let self else { return }; defer { self.installBusy=false; self.installationTask=nil }
            do { self.installPlan=try await self.controlClient(request.platform).chooseFolder(appID:request.appID,folder:index) }
            catch { self.installMessage=error.localizedDescription }
        }
    }
    func confirmInstallation(acceptedAgreements:Bool) {
        guard let request=installationRequest, let plan=installPlan, plan.canConfirm, !installBusy, !plan.needsAgreement || acceptedAgreements else { return }
        installBusy=true; installMessage="Starting download…"
        installationTask=Task { [weak self] in
            guard let self else { return }; defer { self.installBusy=false; self.installationTask=nil }
            do {
                let control=try self.controlClient(request.platform)
                let result=try await control.continueInstall(appID:request.appID,agreements:acceptedAgreements ? plan.eulas : [])
                self.installPlan=result
                guard result.error==0 && result.state != 15 else { throw WayfarerError.message("Steam could not start the installation. \(result.detail)") }
                if result.hasStarted {
                    self.installationRequest=nil; self.installPlan=nil; self.status="Installing \(request.game.name)"
                    self.steamConnections[request.platform]=try await control.snapshot()
                    self.refreshLibrarySnapshot(); self.showDownloads()
                } else { self.installMessage="Steam needs another confirmation. Review the agreements below or open Steam." }
            } catch { self.installMessage=error.localizedDescription }
        }
    }
    func cancelInstallation() {
        guard let request=installationRequest, !installBusy else { return }
        let hadPlan=installPlan != nil
        installBusy=true
        Task { [weak self] in
            guard let self else { return }; defer { self.installBusy=false }
            do {
                if hadPlan { try await self.controlClient(request.platform).cancelInstall(appID:request.appID) }
                self.installationRequest=nil; self.installPlan=nil
            } catch { self.installMessage=error.localizedDescription }
        }
    }
}
