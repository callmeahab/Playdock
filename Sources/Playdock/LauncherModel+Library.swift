import AppKit
import Foundation
import PlaydockCore
import PlaydockPresentation

extension LauncherModel {
    func refresh() {
        guard !loadingSettings, !shuttingDown else { return }
        refreshTask?.cancel()
        libraryState.catalogRestoreTask?.cancel(); libraryState.catalogRestoreTask = nil
        libraryState.libraryScanTask?.cancel(); libraryState.libraryScanTask = nil
        libraryState.refreshing = true
        libraryState.libraryWarnings = []
        discoveringRuntimes = true
        libraryState.libraryLoadingStages = [.macOS: "Loading saved Mac games…", .windows: "Loading saved Windows games…"]
        updateLibraryLoadingMessage()
        let custom = settingsState.configuration.customProfiles
        refreshTask = Task { [weak self] in
            guard let self else { return }
            async let mac: Void = self.loadMacLibrary()
            async let windows: Void = self.loadWindowsLibrary()
            let result = await runtimeState.runtimeService.discover(custom: custom)
            guard !Task.isCancelled else { return }
            runtimeState.runtimeFingerprints = result.fingerprints
            runtimeState.discoveredMacSteamClient = result.macSteamClient
            runtimeState.automaticProfileID = result.automaticProfileID
            runtimeState.runtimes = result.runtimes
            runtimeState.profiles = result.profiles
            discoveringRuntimes = false
            startInitialSteamConnectionIfNeeded()
            _ = await (mac, windows)
            guard !Task.isCancelled else { return }
            libraryState.refreshing = false
            refreshTask = nil
            activityState.status = library.isEmpty ? "Your next adventure starts here" : "\(library.count) games · Mac & Windows"
            startInitialSteamConnectionIfNeeded()
        }
    }

    func startInitialSteamConnectionIfNeeded() {
        guard !loadingSettings, !discoveringRuntimes, !initialBridgeCheck, !showingSteamBridgeSetup,
              !runtimeState.bridgeBusy, !steamState.signingIn, !shuttingDown else { return }
        if initialBackgroundConnection {
            initialBackgroundConnection = false
            if startsSteamInBackground && !ProcessInfo.processInfo.arguments.contains("--no-background-steam") && hasMacSteam {
                connectSteam()
            }
        }
        #if DEBUG
        if initialMacLaunch { initialMacLaunch = false; connectSteam() }
        #endif
    }

    func updateLibraryLoadingMessage() {
        let stages = (discoveringRuntimes ? ["Finding Windows engines…"] : []) + GamePlatform.allCases.compactMap { libraryState.libraryLoadingStages[$0] }
        libraryState.libraryLoadingMessage = stages.isEmpty ? "Finishing library refresh…" : stages.joined(separator: " · ")
    }

    func loadMacLibrary() async {
        guard !Task.isCancelled else { return }
        await loadLibrarySource(client: .macOS, root: steamRoot, profileID: nil)
    }

    func loadWindowsLibrary() async {
        guard !Task.isCancelled else { return }
        await loadLibrarySource(client: .windows, root: steamRoot, profileID: RuntimeProfile.steamBridgeID)
    }

    func loadLibrarySource(client: GamePlatform, root: URL, profileID: String?) async {
        libraryState.libraryLoadingStages[client] = "Loading saved \(client.name) games…"
        updateLibraryLoadingMessage()
        let service = libraryService(client)
        let previousAccount = libraryState.catalogAccounts[client], previousRoot = libraryState.catalogRoots[client]
        let account = await service.account(root: root, profileID: profileID, includeInstalled: true)
        guard !Task.isCancelled else { return }
        if libraryState.catalogAccounts[client] == previousAccount, libraryState.catalogRoots[client] == previousRoot { applyCatalogAccount(account) }
        #if DEBUG
        let useInstalledCache = !ProcessInfo.processInfo.arguments.contains("--ignore-installed-cache")
        #else
        let useInstalledCache = true
        #endif
        if useInstalledCache, let installed = account.installed {
            if client == .macOS { if libraryState.macGames != installed.games { libraryState.macGames = installed.games } }
            else if libraryState.games != installed.games { libraryState.games = installed.games }
        }
        libraryState.libraryLoadingStages[client] = "Checking installed \(client.name) games…"
        updateLibraryLoadingMessage()
        #if DEBUG
        if let flag = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--probe-delay-library=") }),
           let seconds = Double(flag.dropFirst("--probe-delay-library=".count)), seconds > 0, seconds <= 30 {
            do { try await Task.sleep(for: .seconds(seconds)) } catch { return }
        }
        #endif
        var warnings: [String] = []
        var finalScan: SteamLibraryScan?
        for await scan in service.updates(root: root) {
            guard !Task.isCancelled else { return }
            if client == .macOS { if libraryState.macGames != scan.games { libraryState.macGames = scan.games } }
            else if libraryState.games != scan.games { libraryState.games = scan.games }
            let mergedTransfers = downloadsState.transfers.filter { $0.client != client } + scan.transfers
            if downloadsState.transfers != mergedTransfers { downloadsState.transfers = mergedTransfers }
            warnings = scan.warnings
            finalScan = scan
        }
        guard !Task.isCancelled else { return }
        libraryState.libraryWarnings += warnings.filter { !libraryState.libraryWarnings.contains($0) }
        libraryState.libraryLoadingStages.removeValue(forKey: client)
        updateLibraryLoadingMessage()
        if let finalScan, finalScan.warnings.isEmpty {
            try? await service.saveInstallations(finalScan, account: account.account, root: root, profileID: profileID)
        }
    }

    // Coalesce manifest refreshes and publish only changed snapshots.
    func refreshLibrarySnapshot(force: Bool = true) {
        guard !libraryState.refreshing, libraryState.libraryScanTask == nil else { return }
        guard force || Date() >= libraryState.nextLibraryScan else { return }
        let tracking = !downloadsState.transfers.isEmpty || (steamState.snapshot.map { !$0.downloads.isEmpty } ?? false) || gameSessions.contains { $0.phase.active }
        libraryState.nextLibraryScan = Date().addingTimeInterval(tracking ? 5 : 30)
        restoreCachedCatalogs()
        let macRoot = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Steam")
        let windowsService = libraryState.windowsLibraryService, macService = libraryState.macLibraryService
        libraryState.libraryScanTask = Task { [weak self] in
            async let windows = windowsService.scanAndSave(root: macRoot, profileID: RuntimeProfile.steamBridgeID)
            async let mac = macService.scanAndSave(root: macRoot, profileID: nil)
            let result = await (windows, mac)
            guard !Task.isCancelled, let self else { return }
            self.libraryState.libraryScanTask = nil
            if self.libraryState.games != result.0.games { self.libraryState.games = result.0.games }
            if self.libraryState.macGames != result.1.games { self.libraryState.macGames = result.1.games }
            let scannedTransfers = result.0.transfers + result.1.transfers
            if self.downloadsState.transfers != scannedTransfers { self.downloadsState.transfers = scannedTransfers }
            let warnings = result.0.warnings + result.1.warnings
            if self.libraryState.libraryWarnings != warnings { self.libraryState.libraryWarnings = warnings }
        }
    }

    func showGame(_ game: LibraryGame) { selectedGameID = game.id }

    func loadSteamLibrary(_ client: GamePlatform) {
        guard connectionMode() != .signedOut else { libraryState.catalogMessage="Sign in to Steam to update your saved library."; return }
        guard connectionMode() != .offline || libraryState.catalogAccounts[client] == nil else {
            libraryState.catalogMessage = "Saved library · Go online to install games."
            return
        }
        guard !libraryState.loadingCatalog else { libraryState.catalogRefreshQueue.insert(client); return }
        libraryState.catalogRefreshQueue.remove(client)
        libraryState.catalogAttemptedAt[client] = Date()
        libraryState.loadingCatalog = true
        libraryState.catalogMessage = "Loading your Steam library…"
        libraryState.catalogTask = Task { [weak self] in
            guard let self else { return }
            do { try await self.fetchSteamLibrary(client) }
            catch { if !Task.isCancelled { self.libraryState.catalogMessage = error.localizedDescription } }
            guard !Task.isCancelled else { return }
            self.libraryState.loadingCatalog = false; self.libraryState.catalogTask = nil
            self.refreshQueuedCatalog()
        }
    }

    func fetchSteamLibrary(_ client: GamePlatform) async throws {
        let root: URL, profileID: String?, command: LaunchCommand
        let nonce = UUID()
        do {
            guard !(await steamMainApplications()).isEmpty else {
                connectSteam(); libraryState.catalogMessage = "Connecting to Steam. Refresh its library when connected."; return
            }
            root = steamRoot
            profileID = client == .windows ? RuntimeProfile.steamBridgeID : nil
            command = try await session.backend.macCommand(arguments: SteamCatalog.commandArguments(nonce: nonce), port: steamState.port)
        } catch { self.error = error.localizedDescription; return }
        let service = libraryService(client)
        guard let account = await service.currentAccount(root: root) else { libraryState.catalogMessage = "Sign in through Steam, then refresh its library."; return }
        let hadSavedLibrary=libraryState.catalogAccounts[client] != nil
        let macRoot=FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Steam")
        let macAccount = await libraryState.macLibraryService.currentAccount(root: macRoot)
        let sameMacAccount = client == .windows && macAccount == account && (connectionMode() == .online || libraryState.catalogAccounts[.macOS] == nil)
        libraryState.loadingCatalog = true; libraryState.catalogMessage = "Loading your Steam library…"
        let owned = try? await self.controlClient().ownedGameIDs()
        let response = owned == nil ? try await service.refreshResponse(command: command, root: root, nonce: nonce) : nil
        let snapshot = try await service.catalog(owned: owned, response: response, root: root, profileID: profileID)
        let macSnapshot = sameMacAccount ? try await libraryState.macLibraryService.catalog(owned: owned, response: response, root: root, profileID: nil) : nil
        guard !Task.isCancelled else { return }
        let mode=try await self.controlClient().snapshot().mode
        guard mode == .online || (mode == .offline && !hadSavedLibrary) else {
            throw PlaydockError.message("Your saved library is unchanged. Go online to refresh it.")
        }
        guard account == (await service.currentAccount(root: root)), client == .macOS || profileID == RuntimeProfile.steamBridgeID else {
            throw PlaydockError.message("The Steam account or environment changed. Refresh its library again.")
        }
        self.libraryState.catalog.removeAll { $0.client == client }; self.libraryState.catalog += snapshot.games
        self.libraryState.catalogAccounts[client] = account
        self.libraryState.catalogRoots[client] = root
        try await service.saveCatalog(games: snapshot.games, account: account, root: root, profileID: profileID)
        guard !Task.isCancelled else { return }
        if let mac = macSnapshot, await libraryState.macLibraryService.currentAccount(root: macRoot) == account {
            self.libraryState.catalog.removeAll { $0.client == .macOS }; self.libraryState.catalog += mac.games
            self.libraryState.catalogAccounts[.macOS] = account
            self.libraryState.catalogRoots[.macOS] = macRoot
            try await libraryState.macLibraryService.saveCatalog(games: mac.games, account: account, root: macRoot, profileID: nil)
            guard !Task.isCancelled else { return }
            self.libraryState.catalogAttemptedAt[.macOS] = Date()
            self.libraryState.catalogRefreshQueue.remove(.macOS)
        }
        self.libraryState.catalogMessage = snapshot.games.isEmpty ? "No games returned. Sign in through Steam and refresh its library." : "\(snapshot.games.count) \(client == .macOS ? "Mac" : "Windows") games loaded from Steam" + (snapshot.missingMetadata > 0 ? " · Some titles still need metadata from Steam" : "")
    }

    func clearCatalogAccount(_ client: GamePlatform) {
        socialState.snapshot = nil; socialState.message = nil
        featuresState.cloudStatuses = featuresState.cloudStatuses.filter { !$0.key.hasSuffix(":" + client.rawValue) }
        libraryState.catalog.removeAll { $0.client == client }; libraryState.catalogAccounts.removeValue(forKey: client)
        libraryState.catalogRoots.removeValue(forKey: client); libraryState.catalogAttemptedAt.removeValue(forKey: client)
    }

    func applyCatalogAccount(_ snapshot: SteamLibraryAccountSnapshot) {
        let client = snapshot.client
        if steamState.account != snapshot.account {
            for platform in GamePlatform.allCases { clearCatalogAccount(platform) }
            steamState.account = snapshot.account
        }
        if (libraryState.catalogAccounts[client] != nil || libraryState.catalogRoots[client] != nil),
           libraryState.catalogAccounts[client] != snapshot.account || libraryState.catalogRoots[client] != snapshot.root {
            clearCatalogAccount(client)
        }
        guard libraryState.catalogAccounts[client] == nil, let account = snapshot.account, let saved = snapshot.saved else { return }
        libraryState.catalog.removeAll { $0.client == client }; libraryState.catalog += saved.games
        libraryState.catalogAccounts[client] = account; libraryState.catalogRoots[client] = snapshot.root
        libraryState.catalogMessage = "Saved library · Updates when Steam is online."
    }

    func restoreCachedCatalogs() {
        guard !libraryState.refreshing, libraryState.catalogRestoreTask == nil else { return }
        let scopes = GamePlatform.allCases.map { client -> (GamePlatform, URL, String?) in
            (client, steamRoot, client == .windows ? RuntimeProfile.steamBridgeID : nil)
        }
        let previousAccounts = libraryState.catalogAccounts, previousRoots = libraryState.catalogRoots
        libraryState.catalogRestoreTask = Task { [weak self] in
            guard let self else { return }
            var snapshots: [SteamLibraryAccountSnapshot] = []
            for scope in scopes {
                snapshots.append(await self.libraryService(scope.0).account(root: scope.1, profileID: scope.2))
            }
            guard !Task.isCancelled else { return }
            self.libraryState.catalogRestoreTask = nil
            for snapshot in snapshots {
                guard snapshot.client != .windows || snapshot.profileID == RuntimeProfile.steamBridgeID,
                      self.steamRoot == snapshot.root,
                      self.libraryState.catalogAccounts[snapshot.client] == previousAccounts[snapshot.client],
                      self.libraryState.catalogRoots[snapshot.client] == previousRoots[snapshot.client] else { continue }
                self.applyCatalogAccount(snapshot)
            }
        }
    }
    func refreshQueuedCatalog() {
        guard !activityState.gameplayQuiet, !libraryState.loadingCatalog, let client=GamePlatform.allCases.first(where:{libraryState.catalogRefreshQueue.contains($0) && (connectionMode() == .online || (connectionMode() == .offline && libraryState.catalogAccounts[$0] == nil))}) else { return }
        loadSteamLibrary(client)
    }
    func refreshOnlineCatalog(_ client: GamePlatform) {
        // Seed an empty offline cache once; only online sessions replace existing catalogs.
        guard connectionMode() == .online || (connectionMode() == .offline && libraryState.catalogAccounts[client] == nil),
              Date().timeIntervalSince(libraryState.catalogAttemptedAt[client] ?? .distantPast) > 900 else { return }
        libraryState.catalogRefreshQueue.insert(client); refreshQueuedCatalog()
    }

    func installationDisabled(_ game: LibraryGame, platform: GamePlatform?) -> Bool {
        guard let platform else { return false }
        if !game.isSteam, platform == .windows, performanceProfile(for: game) == nil { return true }
        if game.isSteam, platform == .windows, runtimeState.bridgeEnvironment?.ready != true { return true }
        return runtimeState.bridgeBusy || (connectionMode() != .online && game.unavailableOffline(for:platform))
    }
    func executionTarget(_ game: LibraryGame) -> GameExecutionTarget? {
        if let active = activeSession(game.id) {
            return GameExecutionTarget(platform: active.platform, installation: game.installation(for: active.platform), offer: game.offer(for: active.platform))
        }
        return game.executionTarget(online: !game.isSteam || connectionMode() == .online)
    }
    func preferredGamePlatform(_ game: LibraryGame) -> GamePlatform? { executionTarget(game)?.platform }
    func executionName(_ game: LibraryGame) -> String {
        guard preferredGamePlatform(game) == .windows else { return "Native Mac" }
        return "Windows · " + (performanceProfile(for: game)?.runtime.name ?? "Runtime unavailable")
    }
    func executionInstalled(_ game: LibraryGame) -> Bool { executionTarget(game)?.isInstalled == true }
    func gameAvailabilityMessage(_ game: LibraryGame) -> String {
        if preferredGamePlatform(game) == .windows {
            if game.isSteam, runtimeState.bridgeEnvironment?.ready != true { return "Set up compatibility runtime" }
            if !game.isSteam, performanceProfile(for: game) == nil { return "Choose a compatibility runtime" }
        }
        if runtimeState.bridgeBusy { return "Runtime setup in progress" }
        return installationAvailabilityMessage(preferredGamePlatform(game) ?? .macOS)
    }
    func installationAvailabilityMessage(_ platform: GamePlatform) -> String {
        switch connectionMode() {
        case .offline: return "Offline · Install when online"
        case .signedOut: return "Sign in to install"
        case .unavailable: return "Connect Steam to install"
        case .online: return "Ready to install"
        }
    }
}
