import AppKit
import Foundation
import UniformTypeIdentifiers
import PlaydockCore
import PlaydockPresentation

extension LauncherModel {
    func prefixProfile(for game: LibraryGame, environmentID: String? = nil) -> RuntimeProfile? {
        guard var profile = performanceProfile(for: game, environmentID: environmentID) else { return nil }
        if game.isSteam {
            guard let prefix = game.installation(for: .windows)?.steamGame?.bridgePrefix else { return nil }
            profile.prefix = prefix
        }
        return profile
    }
    func prefixSnapshot(_ profile: RuntimeProfile) async -> GamePrefixSnapshot { await runtimeState.prefixService.snapshot(profile) }
    func openPrefixTool(_ tool: PrefixTool, game: LibraryGame, profile: RuntimeProfile) {
        let prefix = profile.prefix
        guard !shuttingDown, !runtimeState.bridgeBusy, !runtimeState.prefixToolsBusy.contains(prefix), activeSession(game.id) == nil,
              installationState.installationRequest == nil, installationState.uninstallationRequest == nil,
              !installationState.maintenance.values.contains(where: { !$0.completed && !$0.failed }) else {
            runtimeState.prefixMessages[prefix] = "Finish games and file operations before opening Windows tools."; return
        }
        runtimeState.prefixToolsBusy.insert(prefix); runtimeState.prefixMessages[prefix] = "Opening \(tool.name)…"
        Task { [self] in
            do {
                if game.isSteam { try await ensureBridgeReady() }
                let command = try await runtimeState.prefixService.command(tool, profile: profile)
                guard !shuttingDown, !runtimeState.bridgeBusy, activeSession(game.id) == nil,
                      prefixProfile(for: game)?.prefix == prefix else { throw CancellationError() }
                let id = UUID()
                let launch = try await processService.start(command, id: id)
                launches[id] = launch; activityState.latestLog = launch.logURL
                runtimeState.prefixMessages[prefix] = "\(tool.name) is open. Changes affect this prefix."
                await processService.observe(launch.id) { [weak self] code in
                    Task { @MainActor in
                        guard let self else { return }
                        self.launches.removeValue(forKey: id); self.runtimeState.prefixToolsBusy.remove(prefix)
                        self.runtimeState.prefixMessages[prefix] = code == 0 ? "\(tool.name) closed." : "\(tool.name) exited with code \(code). See the latest session log."
                    }
                }
            } catch {
                runtimeState.prefixToolsBusy.remove(prefix); runtimeState.prefixMessages[prefix] = error.localizedDescription
            }
        }
    }
    func performanceWorkload() -> PerformanceWorkload {
        PerformanceWorkload(quietGameRunning: gameSessions.contains { $0.phase.active && (settingsState.configuration.gamePreferences[$0.gameID]?.effectivePerformance.quietWhilePlaying ?? true) },
            launcherActive: NSApp.isActive, downloadsActive: !downloadsState.transfers.isEmpty || (steamState.snapshot.map { !$0.downloads.isEmpty } ?? false))
    }
    func refreshOptionalWork() async {
        guard !runtimeState.bridgeBusy else { return }
        guard !shuttingDown, !loadingSettings else { return }
        let workload = performanceWorkload()
        if activityState.gameplayQuiet != workload.quiet {
            activityState.gameplayQuiet = workload.quiet
            if !workload.quiet { libraryState.nextLibraryScan = .distantPast; refreshQueuedCatalog() }
        }
        let work = await activityState.performanceCoordinator.due(workload)
        guard !shuttingDown, workload == performanceWorkload() else { return }
        if work.contains(.library) { refreshLibrarySnapshot(force: false) }
        if work.contains(.steam) { refreshSteamControls() }
        if work.contains(.social) {
            if socialState.snapshot != nil || settingsState.configuration.friendNotifications == true { refreshFriends() }
        }
    }
    func performanceProfile(for game: LibraryGame, environmentID: String? = nil) -> RuntimeProfile? {
        guard preferredGamePlatform(game) == .windows else { return nil }
        if game.isSteam { return steamBridgeProfile }
        let originalID: String?
        if case .added(let added) = game.installation(for: .windows) { originalID = added.profileID }
        else { originalID = nil }
        let id = environmentID ?? preferences(for: game).environmentID ?? originalID
        return id.flatMap { value in runtimeState.profiles.first { $0.id == value } } ?? (id == nil ? selectedProfile : nil)
    }
    func reloadPerformanceEnvironment(_ profile: RuntimeProfile) async {
        do { runtimeState.performanceSnapshots[profile.id] = try await runtimeState.performanceEnvironments.snapshot(profile); runtimeState.performanceMessages[profile.id] = nil }
        catch { runtimeState.performanceMessages[profile.id] = error.localizedDescription }
    }
    func applyPerformanceProfile(_ settings: GamePerformanceProfile, game: LibraryGame, profile: RuntimeProfile) {
        guard !runtimeState.performanceBusy.contains(profile.id), let snapshot = runtimeState.performanceSnapshots[profile.id] else { return }
        guard !gameSessions.contains(where: { $0.phase.active && $0.environmentID == profile.id }), !runtimeState.bridgeBusy,
              installationState.installationRequest == nil, installationState.uninstallationRequest == nil, installationState.maintenance.values.allSatisfy({ $0.completed || $0.failed }) else {
            runtimeState.performanceMessages[profile.id] = "Finish games and file operations before changing this environment."; return
        }
        runtimeState.performanceBusy.insert(profile.id); runtimeState.performanceMessages[profile.id] = "Checking that this environment is closed…"
        Task {
            defer { runtimeState.performanceBusy.remove(profile.id) }
            do {
                let backup = try await runtimeState.performanceEnvironments.apply(settings, profile: profile, expected: snapshot.fingerprint)
                guard !shuttingDown else { return }
                await reloadPerformanceEnvironment(profile)
                runtimeState.performanceMessages[profile.id] = backup == nil ? "The environment already uses these settings." : "Applied to \(profile.name). Relaunch the game before playing. Previous settings saved in PerformanceBackups."
            } catch { runtimeState.performanceMessages[profile.id] = error.localizedDescription; await reloadPerformanceEnvironment(profile) }
        }
    }
    func performanceReports(for game: LibraryGame) -> [GamePerformanceReport] {
        (settingsState.configuration.performanceReports).filter { $0.gameID == game.id }.sorted { $0.createdAt > $1.createdAt }
    }
    func makePerformanceReport(_ samples: [PerformanceFrame], game: LibraryGame, scene: String, cache: PerformanceCacheState,
                                       profile: RuntimeProfile?, settings: GamePerformanceProfile, snapshot: PerformanceEnvironmentSnapshot?, source: PerformanceReportSource) throws -> GamePerformanceReport {
        let thermal: String
        switch ProcessInfo.processInfo.thermalState { case .nominal: thermal = "Nominal"; case .fair: thermal = "Fair"; case .serious: thermal = "Serious"; case .critical: thermal = "Critical"; @unknown default: thermal = "Unknown" }
        return try GamePerformanceReport(gameID: game.id, scene: scene, cache: cache, environmentID: profile?.id,
            engine: profile.map { $0.runtime.name + " " + (snapshot?.version ?? "") } ?? "Imported", fingerprint: profile.map { runtimeFingerprint($0) } ?? "",
            settings: settings, effectiveVariables: snapshot?.variables ?? [:], samples: samples, thermal: source == .imported ? "Unknown (imported)" : thermal, source: source)
    }
    func savePerformanceReport(_ report: GamePerformanceReport) {
        var reports = settingsState.configuration.performanceReports; reports.append(report)
        settingsState.configuration.performanceReports = Array(reports.suffix(100)); save()
    }
    func importPerformanceReport(_ game: LibraryGame, scene: String, cache: PerformanceCacheState) {
        guard !runtimeState.performanceBusy.contains(game.id) else { return }
        let panel = NSOpenPanel(); panel.title = "Import \(game.name)'s frame timings"; panel.allowsMultipleSelection = false; panel.allowedContentTypes = [.text, .commaSeparatedText]
        let profile = performanceProfile(for: game), settings = preferences(for: game).effectivePerformance
        runtimeState.performanceBusy.insert(game.id)
        Task {
            defer { runtimeState.performanceBusy.remove(game.id) }
            guard let file = await performanceFile(panel), !shuttingDown else { return }
            runtimeState.performanceMessages[game.id] = "Reading frame timings…"
            do {
                let samples = try await runtimeState.performanceReportService.imported(file)
                let snapshot: PerformanceEnvironmentSnapshot?
                if let profile { snapshot = try? await runtimeState.performanceEnvironments.snapshot(profile) } else { snapshot = nil }
                guard !shuttingDown else { return }
                savePerformanceReport(try makePerformanceReport(samples, game: game, scene: scene, cache: cache, profile: profile, settings: settings, snapshot: snapshot, source: .imported))
                runtimeState.performanceMessages[game.id] = "Imported \(samples.count) frames. Environment metadata reflects the current settings; verify it matches the imported run."
            } catch { runtimeState.performanceMessages[game.id] = error.localizedDescription }
        }
    }
    func capturePerformanceReport(_ game: LibraryGame, scene: String, cache: PerformanceCacheState) {
        guard runtimeState.capturingPerformanceFor == nil, let record = activeSession(game.id), record.platform == .windows, let profile = performanceProfile(for: game) else {
            runtimeState.performanceMessages[game.id] = "Start this Windows game before recording frame timings."; return
        }
        let settings = preferences(for: game).effectivePerformance
        runtimeState.capturingPerformanceFor = game.id; runtimeState.performanceMessages[game.id] = "Recording for 30 seconds. Return to the game and play the scene you want to compare."
        runtimeState.performanceCapture = Task {
            defer { runtimeState.capturingPerformanceFor = nil; runtimeState.performanceCapture = nil }
            do {
                let snapshot = try await runtimeState.performanceEnvironments.snapshot(profile)
                guard profile.nativeSteamBridge == true ? settings.metalHUD == .enabled : snapshot.variables["MTL_HUD_LOGGING_ENABLED"] == "1" else { throw PlaydockError.message("Enable and apply Metal HUD logging, reopen Steam, then relaunch the game before recording.") }
                let tokens: [RuntimeProcessToken]
                if let installation = game.installation(for: .windows), let steam = installation.steamGame, let location = steam.installDirectory {
                    let prefix = windowsPrefix(for: game) ?? profile.prefix
                    let windows = try await runtimeState.runtimeProcesses.windowsProcesses(prefix: prefix)
                    tokens = await runtimeState.runtimeProcesses.gameProcesses(pids: windows.map { $0.token.pid }, bundlePaths: [:], location: location, steamRoot: steam.library)
                } else { tokens = await activityState.sessionCoordinator.verifiedTokens(for: record.id) }
                guard !tokens.isEmpty else { throw PlaydockError.message("Waiting for a verified game process. Try recording once the game is visible.") }
                let start = Date()
                try await Task.sleep(for: .seconds(30))
                guard activeSession(game.id)?.id == record.id else { throw PlaydockError.message("The game ended during recording. Import a completed capture instead.") }
                let verified = await runtimeState.runtimeProcesses.verified(tokens)
                guard verified.count == tokens.count else { throw PlaydockError.message("The game's processes changed. Record another run.") }
                let samples = try await runtimeState.performanceReportService.capture(tokens: verified, start: start, end: Date())
                try Task.checkCancellation()
                guard !shuttingDown else { return }
                savePerformanceReport(try makePerformanceReport(samples, game: game, scene: scene, cache: cache, profile: profile, settings: settings, snapshot: snapshot, source: .recorded))
                runtimeState.performanceMessages[game.id] = "Recorded \(samples.count) frames."
            } catch is CancellationError { runtimeState.performanceMessages[game.id] = "Recording cancelled." }
            catch { runtimeState.performanceMessages[game.id] = error.localizedDescription }
        }
    }
    func cancelPerformanceCapture() { runtimeState.performanceCapture?.cancel() }
    func exportPerformanceReport(_ report: GamePerformanceReport) {
        let panel = NSSavePanel(); panel.title = "Export performance report"; panel.nameFieldStringValue = "playdock-performance.json"; panel.allowedContentTypes = [.json]
        Task {
            guard let file = await performanceFile(panel), !shuttingDown else { return }
            do { try await runtimeState.performanceReportService.export(report, to: file) } catch { self.error = error.localizedDescription }
        }
    }
    func performanceFile(_ panel: NSSavePanel) async -> URL? {
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow else { return nil }
        return await withCheckedContinuation { continuation in
            panel.beginSheetModal(for: window) { response in continuation.resume(returning: response == .OK ? panel.url : nil) }
        }
    }
    func deletePerformanceReport(_ report: GamePerformanceReport) {
        settingsState.configuration.performanceReports.removeAll { $0.id == report.id }; save()
    }
}
