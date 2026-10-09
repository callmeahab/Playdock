import AppKit
import Foundation
import PlaydockCore
import PlaydockPresentation

extension LauncherModel {
    func publishSteamSnapshot(_ snapshot: SteamControlSnapshot) {
        if steamState.snapshot != snapshot { steamState.snapshot = snapshot }
    }
    func refreshSteamAccount() async {
        let account = await libraryState.macLibraryService.currentAccount(root: steamRoot)
        guard !Task.isCancelled else { return }
        if steamState.account != account {
            for platform in GamePlatform.allCases { clearCatalogAccount(platform) }
            steamState.account = account
        }
    }

    func setConnectionMessage(_ message: String?) {
        if steamState.message != message { steamState.message = message }
    }

    func connectionMode() -> SteamConnectionMode { steamState.snapshot?.mode ?? .unavailable }
    func discoverSteamControl() async {
        let port = await runtimeState.runtimeProcesses.controlPort(root: steamRoot)
        guard !Task.isCancelled else { return }
        steamState.discoveredControlPort = port
        if let port { steamState.port = port }
    }

    func controlClient(allowDuringBridgeSetup: Bool = false) throws -> SteamControl {
        guard !runtimeState.bridgeBusy || allowDuringBridgeSetup else { throw PlaydockError.message("Wait for bridge setup to finish.") }
        let endpoint = SteamControlEndpoint(port: steamState.port, root: steamRoot)
        if steamState.controlPort == endpoint.port, let control = steamState.savedControl { return control }
        if let old = steamState.savedControl { Task { await old.disconnect() } }
        let control = SteamControl(endpoint: endpoint); steamState.savedControl = control; steamState.controlPort = endpoint.port; return control
    }
    func waitForSteamConnection() async throws {
        let revision = workflowRevision
        try await steamState.coordinator.waitForConnection(busy: { [weak self] in
            guard let self else { throw CancellationError() }
            return try await self.connectionIsBusy(revision: revision)
        })
    }
    func connectionIsBusy(revision: Int) throws -> Bool {
        guard !shuttingDown, workflowRevision == revision else { throw CancellationError() }
        return steamState.busy
    }
    func resolveBackendControl(revision: Int) async throws -> SteamControl {
        guard !shuttingDown, workflowRevision == revision else { throw CancellationError() }
        if await steamState.savedControl?.connectionIdentity() == nil { await discoverSteamControl() }
        await refreshSteamAccount()
        guard !shuttingDown, workflowRevision == revision else { throw CancellationError() }
        return try controlClient()
    }
    func applyBackendEvent(_ event: BackendEvent, revision: Int, connecting: Bool) async {
        guard !shuttingDown, workflowRevision == revision else { return }
        switch event {
        case .connected(let snapshot):
            publishSteamSnapshot(snapshot)
            if snapshot.mode == .signedOut, settingsState.configuration.setupReviewedAt == nil {
                showingSteamBridgeSetup = true
            }
            if connecting || !steamState.busy { setConnectionMessage(nil) }
            if connecting, runtimeState.bridgeEnvironment?.ready == true {
                do { try await bridgeService.updateLaunchSupport() }
                catch { runtimeState.bridgeMessage = error.localizedDescription }
            }
            restoreCachedCatalogs(); for platform in GamePlatform.allCases { refreshOnlineCatalog(platform) }
            if connecting, [.online, .offline].contains(snapshot.mode), installationState.installationRequest != nil, !installationState.installBusy {
                prepareInstallation()
            }
            guard !shuttingDown, workflowRevision == revision else { return }
        case .disconnected:
            steamState.snapshot = nil
            await recoverBackendIfSafe(revision: revision)
        case .message(let message): setConnectionMessage(message)
        case .finished: steamState.busy = false
        }
    }
    func refreshSteamControls() {
        guard !shuttingDown, !runtimeState.bridgeBusy, !steamState.signingIn else { return }
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains(where: { $0.hasPrefix("--setup-environment=") }) { return }
        #endif
        let revision = workflowRevision
        Task { [weak self] in
            guard let self else { return }
            await steamState.coordinator.refresh(revision: revision,
                resolve: { [weak self] in
                    guard let self else { throw CancellationError() }
                    return try await self.resolveBackendControl(revision: revision)
                }, publish: { [weak self] event in
                    await self?.applyBackendEvent(event, revision: revision, connecting: false)
                })
        }
    }
    func connectSteam() {
        guard !runtimeState.bridgeBusy else { return }
        guard !shuttingDown, !steamState.busy else { return }
        steamState.signingIn = false
        steamState.busy = true; steamState.message = "Connecting in the background…"
        let revision = workflowRevision
        Task { [weak self] in
            guard let self else { return }
            await steamState.coordinator.connect(revision: revision,
                prepare: { [weak self] in
                    guard let self else { throw CancellationError() }
                    try await self.prepareSteamConnection(revision: revision)
                }, resolve: { [weak self] in
                    guard let self else { throw CancellationError() }
                    return try await self.resolveBackendControl(revision: revision)
                }, publish: { [weak self] event in
                    await self?.applyBackendEvent(event, revision: revision, connecting: true)
                })
        }
    }
    func prepareSteamConnection(revision: Int) async throws {
        guard !shuttingDown, workflowRevision == revision else { throw CancellationError() }
        steamState.message = "Preparing Steam…"
        await discoverSteamControl()
        try await session.backend.prepare()
        try Task.checkCancellation()
        guard !shuttingDown, workflowRevision == revision else { throw CancellationError() }
        try await ensureSteamBackend()
        try await runMacSteam()
        guard !shuttingDown, workflowRevision == revision else { throw CancellationError() }
    }

    func setSteamMode(offline: Bool) {
        guard !runtimeState.bridgeBusy, !shuttingDown, !steamState.busy else { return }
        steamState.busy = true; steamState.message = offline ? "Going offline…" : "Connecting online…"
        let revision = workflowRevision
        Task { [weak self] in
            guard let self else { return }
            await steamState.coordinator.changeMode(revision: revision, offline: offline,
                resolve: { [weak self] in
                    guard let self else { throw CancellationError() }
                    return try await self.resolveBackendControl(revision: revision)
                }, publish: { [weak self] event in
                    guard let self else { return }
                    await self.applyBackendEvent(event, revision: revision, connecting: true)
                    await self.didChangeSteamMode(event, offline: offline, revision: revision)
                })
        }
    }
    func didChangeSteamMode(_ event: BackendEvent, offline: Bool, revision: Int) {
        guard !shuttingDown, workflowRevision == revision, case .connected = event else { return }
        if !offline { for platform in GamePlatform.allCases { libraryState.catalogAttemptedAt.removeValue(forKey: platform); refreshOnlineCatalog(platform) } }
        if installationState.installationRequest != nil { prepareInstallation() }
    }
    func controlDownload(_ appID: String, paused: Bool) { submitDownload(.pause(appID, paused)) }
    func pauseDownloads(paused: Bool) { submitDownload(.enabled(!paused)) }

    func launchMacSteam(_ game: SteamGame, arguments:[String] = [], windows: Bool = false) {
        let revision = workflowRevision
        Task { [weak self] in
            guard let self else { return }
            do {
                let control = try await steamLaunchControl()
                guard !shuttingDown, workflowRevision == revision else { throw CancellationError() }
                _=try NativeGameLaunch.steamURL(appID:game.appID)
                guard self.steamState.message==nil else { throw PlaydockError.message(self.steamState.message!) }
                guard [.online, .offline].contains(self.connectionMode()) else {
                    throw PlaydockError.message("Sign in to Steam before playing this game.")
                }
                self.activityState.status="Opening \(game.name) on your Mac…"
                if windows { try await ensureBridgeReady() }
                if runtimeState.bridgeEnvironment?.ready == true { try await control.setCrossOver(appID: game.appID, enabled: windows) }
                let settings = settingsState.configuration.gamePreferences["steam:" + game.appID]?.effectivePerformance ?? GamePerformanceProfile()
                if windows {
                    let profile = steamBridgeProfile
                    let snapshot = try await runtimeState.performanceEnvironments.snapshot(profile)
                    try await runtimeState.performanceEnvironments.validate(settings, snapshot: snapshot)
                }
                let launchArguments = windows ? settings.steamEnvironment.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" } + arguments : arguments
                guard !shuttingDown, workflowRevision == revision else { throw CancellationError() }
                try await self.runMacSteam(arguments:["-applaunch",game.appID]+launchArguments); self.markLaunch(game.name,outcome:"Launch sent to Mac Steam")
            } catch { self.failGameSession("steam:"+game.appID,message:error.localizedDescription); self.markLaunch(game.name,outcome:error.localizedDescription); self.error=error.localizedDescription }
        }
    }

    func steamLaunchControl() async throws -> SteamControl {
        let revision = workflowRevision
        if !steamState.busy, !steamState.signingIn, let control = steamState.savedControl,
           await control.connectionIdentity() != nil {
            if let snapshot = try? await control.snapshot() {
                guard !shuttingDown, workflowRevision == revision else { throw CancellationError() }
                publishSteamSnapshot(snapshot)
                guard [.online, .offline].contains(snapshot.mode) else { throw PlaydockError.message("Sign in to Steam before playing this game.") }
                setConnectionMessage(nil)
                return control
            }
        }
        connectSteam()
        try await waitForSteamConnection()
        return try controlClient()
    }

    #if DEBUG
    func probeInstalledSteamLaunch(output: URL) async {
        guard !launchProbeStarted else { return }
        launchProbeStarted = true
        let appID = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--probe-game=") }).map { String($0.dropFirst("--probe-game=".count)) } ?? ""
        for _ in 0..<200 {
            if !loadingSettings, !libraryState.refreshing, !initialBridgeCheck { break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        let gameID = "steam:" + appID
        var resetRuntime = false
        if let game = library.first(where: { $0.id == gameID }), game.installation(for: preferredGamePlatform(game) ?? .macOS) != nil {
            if ProcessInfo.processInfo.arguments.contains("--probe-reset-runtime"), preferredGamePlatform(game) == .windows {
                connectSteam()
                do {
                    try await waitForSteamConnection()
                    try await controlClient().setCrossOver(appID: appID, enabled: false)
                    resetRuntime = true
                } catch { self.error = error.localizedDescription }
            }
            guard error == nil else {
                if let data = try? JSONSerialization.data(withJSONObject: ["error": error ?? "", "resetRuntime": resetRuntime]) { try? await FileService.shared.write(data, to: output) }
                return
            }
            launch(game)
            for _ in 0..<450 {
                try? await Task.sleep(for: .milliseconds(100))
                let phase = gameSessions.last(where: { $0.gameID == gameID })?.phase
                if error != nil || phase == .playing || phase == .failed || activityState.steamLaunchPrompt != nil { break }
            }
        } else { error = "The launch probe requires an installed game." }
        let record = gameSessions.last(where: { $0.gameID == gameID })
        let result: [String: Any] = ["gameID": gameID, "mode": connectionMode().rawValue,
            "phase": record?.phase.rawValue ?? "none", "message": record?.message ?? "", "error": error ?? "",
            "nativeConfirmation": activityState.steamLaunchPrompt != nil, "resetRuntime": resetRuntime]
        if let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]) {
            try? await FileService.shared.write(data, to: output)
        }
    }
    #endif

    func runtimeFingerprint(_ profile: RuntimeProfile) -> String {
        if profile.nativeSteamBridge { return runtimeState.performanceSnapshots[profile.id]?.fingerprint ?? "unavailable" }
        return runtimeState.runtimeFingerprints[profile.id] ?? "unavailable"
    }

    func runMacSteam(arguments:[String]=[], background: Bool = true) async throws {
        guard !shuttingDown else { throw CancellationError() }
        if steamState.discoveredControlPort == nil, (await steamMainApplications()).isEmpty { steamState.port=try SteamControlEndpoint.availablePort() }
        let command=try await session.backend.macCommand(arguments:arguments,port:steamState.port,background:background)
        try Task.checkCancellation()
        guard !shuttingDown else { throw CancellationError() }
        let id=UUID()
        let launch = try await processService.start(command, id: id)
        launches[id] = launch
        await processService.observe(id) { [weak self] _ in
            Task { @MainActor in self?.launches.removeValue(forKey: id) }
        }
    }

    var steamRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Steam")
    }
    func steamMainApplications() async -> [NSRunningApplication] {
        let root = steamRoot
        let apps = NSWorkspace.shared.runningApplications
        let pids = apps.map(\.processIdentifier)
        let verified = await runtimeState.runtimeProcesses.mainSteamProcesses(pids: pids, root: root)
        guard !Task.isCancelled else { return [] }
        return apps.filter { !($0.isTerminated) && verified[$0.processIdentifier] != nil && RuntimeProcessIdentity.token(for: $0.processIdentifier) == verified[$0.processIdentifier] }
    }
    func ensureSteamBackend() async throws {
        let root = steamRoot
        let existing = await steamMainApplications()
        try Task.checkCancellation()
        guard !existing.isEmpty else { return }
        if await session.backend.allAttached(existing, root: root) { return }
        let control = try controlClient()
        let activity: ([String], SteamControlSnapshot)
        do { activity = (try await control.runningAppIDs(), try await control.snapshot()) }
        catch { throw PlaydockError.message("Close Steam, then reconnect it in Playdock to apply background mode.") }
        guard activity.0.isEmpty, !activity.1.downloads.contains(where: { $0.active }) else {
            throw PlaydockError.message("Finish Steam games and downloads before reconnecting its background mode.")
        }
        steamState.message = "Restarting Steam in the background…"
        try await runMacSteam(arguments: ["-shutdown"])
        let processes = runtimeState.runtimeProcesses
        try await steamState.coordinator.waitForExit(attempts: 80, settle: true, check: {
            try await processes.steamProcesses(root: root).isEmpty
        })
    }

    func recoverBackendIfSafe(revision: Int) async {
        let safe = !steamState.busy && installationState.installationRequest == nil && installationState.uninstallationRequest == nil && installationState.maintenance.values.allSatisfy { $0.completed || $0.failed } && !gameSessions.contains { $0.phase.active } && downloadsState.transfers.isEmpty
        let decision = await steamState.coordinator.retryDecision(revision: revision, safe: safe,
            enabled: startsSteamInBackground && !steamState.signingIn && !showingSteamBridgeSetup && !ProcessInfo.processInfo.arguments.contains("--no-background-steam"))
        guard !shuttingDown, workflowRevision == revision else { return }
        if decision.retry { connectSteam() }
        else if decision.wasConnected, !steamState.busy {
            setConnectionMessage(safe ? "Steam disconnected. Reconnect its backend to retry." : "Steam disconnected. Automatic recovery is waiting for games or file operations to finish. Reconnect to check safely.")
        }
    }
    func invalidateWorkflows() {
        workflowRevision += 1
        let revision = workflowRevision
        steamState.busy = false; socialState.busy = false; socialState.snapshot = nil
        let oldControl = steamState.savedControl
        steamState.savedControl = nil; steamState.controlPort = nil; steamState.discoveredControlPort = nil; steamState.snapshot = nil
        Task {
            await oldControl?.disconnect()
            await steamState.coordinator.invalidate(revision: revision)
            await downloadsState.scheduler.invalidate(revision: revision)
            await socialState.coordinator.invalidate(revision: revision)
            await installationState.maintenanceCoordinator.invalidate(revision: revision); await activityState.sessionCoordinator.invalidate(revision: revision)
        }
    }
}
