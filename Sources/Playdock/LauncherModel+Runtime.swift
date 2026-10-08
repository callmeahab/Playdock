import AppKit
import Foundation
import PlaydockCore
import PlaydockPresentation
import UniformTypeIdentifiers

extension LauncherModel {
    func addProfile(_ profile: RuntimeProfile) {
        let managed = RuntimeDiscovery.managedProfile(for: profile.runtime)
        if !settingsState.configuration.customProfiles.contains(where: { $0.runtime.id == managed.runtime.id }) { settingsState.configuration.customProfiles.append(managed) }
        settingsState.configuration.selectedProfileID = managed.id
        save()
        refresh()
    }

    func forgetCustomProfile(_ profile: RuntimeProfile) {
        settingsState.configuration.customProfiles.removeAll { $0.runtime.id == profile.runtime.id }
        if settingsState.configuration.selectedProfileID == profile.id { settingsState.configuration.selectedProfileID = nil }
        save()
        refresh()
    }

    func addGame(name: String, executable: URL, arguments: String, platform: GamePlatform = .windows) async throws {
        if platform == .windows && selectedProfile == nil { throw PlaydockError.message("Choose a Windows environment first.") }
        if platform == .macOS { try await FileService.shared.validateApplication(executable) }
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw PlaydockError.message("Give the game a name.") }
        let canonical = executable.standardizedFileURL
        guard !settingsState.configuration.addedGames.contains(where: { $0.executable.standardizedFileURL == canonical && $0.platform == platform && (platform == .macOS || $0.profileID == selectedProfile?.id) }) else {
            throw PlaydockError.message("This game is already in your library.")
        }
        settingsState.configuration.addedGames.append(AddedGame(name: title, executable: executable, arguments: try ArgumentParser.parse(arguments), profileID: platform == .windows ? selectedProfile!.id : "", platform: platform))
        save()
    }

    func removeGame(_ game: AddedGame) {
        settingsState.configuration.favoriteGameIDs.remove("added:\(game.id.uuidString)")
        settingsState.configuration.addedGames.removeAll { $0.id == game.id }
        save()
    }

    func toggleFavorite(_ game: LibraryGame) {
        var values = favorites
        if !values.insert(game.id).inserted { values.remove(game.id) }
        settingsState.configuration.favoriteGameIDs = values
        save()
    }

    func manageWindowsApps() {
        guard let profile=selectedProfile else { error="Choose a Windows engine first."; return }
        closeWindowsApps()
        runtimeState.windowsAppsProfile=profile; runtimeState.windowsAppsLoading=true
    }
    func closeWindowsApps() {
        runtimeState.windowsAppsOperation=UUID(); runtimeState.windowsAppsTask?.cancel(); runtimeState.windowsAppsTask=nil
        runtimeState.windowsAppsProfile=nil; runtimeState.windowsApps=[]; runtimeState.windowsAppsBusy=false; runtimeState.windowsAppsLoading=false
        runtimeState.windowsAppsCanForceQuit=false; runtimeState.windowsAppsMessage=""
    }
    func refreshWindowsApps() async {
        guard let profile=runtimeState.windowsAppsProfile,!runtimeState.windowsAppsBusy else { return }
        let operation=runtimeState.windowsAppsOperation
        do {
            let apps = try await self.runtimeState.runtimeProcesses.windowsApps(prefix: profile.prefix)
            guard runtimeState.windowsAppsOperation==operation,runtimeState.windowsAppsProfile?.id==profile.id else { return }
            runtimeState.windowsApps=apps; runtimeState.windowsAppsLoading=false
        } catch {
            guard runtimeState.windowsAppsOperation==operation else { return }
            runtimeState.windowsAppsLoading=false; runtimeState.windowsAppsMessage=error.localizedDescription
        }
    }
    func windowsAppName(_ app:RuntimeProcessIdentity.WindowsProcess) -> String {
        if let window=session.nativeWindows.first(where:{$0.peer.pid==app.token.pid && !$0.title.isEmpty}) { return window.title }
        if let added=addedGames.first(where:{$0.executable.lastPathComponent.lowercased()==app.program}) { return added.name }
        return app.program
    }
    func closeManagedWindowsApps(force:Bool = false, reviewedApps:[RuntimeProcessIdentity.WindowsProcess]? = nil) {
        guard let profile=runtimeState.windowsAppsProfile,profile.id==selectedProfile?.id,!runtimeState.windowsAppsBusy,!runtimeState.windowsAppsLoading else { return }
        let apps=reviewedApps ?? runtimeState.windowsApps
        runtimeState.windowsAppsTask?.cancel(); runtimeState.windowsAppsOperation=UUID()
        let operation=runtimeState.windowsAppsOperation
        runtimeState.windowsAppsBusy=true; runtimeState.windowsAppsCanForceQuit=false; runtimeState.windowsAppsMessage=force ? "Force quitting the selected apps…" : "Closing Windows apps…"
        runtimeState.windowsAppsTask=Task { [weak self] in
            guard let self else { return }
            do {
                for app in apps {
                    guard await self.runtimeState.runtimeProcesses.isCurrent(app, prefix: profile.prefix) else { continue }
                    if force { _ = try await self.runtimeState.runtimeProcesses.forceQuit(app, prefix: profile.prefix) }
                    else { _=NSRunningApplication(processIdentifier:app.token.pid)?.terminate() }
                }
                let deadline=Date().addingTimeInterval(10)
                repeat {
                    guard !Task.isCancelled,self.runtimeState.windowsAppsOperation==operation,self.selectedProfile?.id==profile.id else { return }
                    let remaining = try await self.runtimeState.runtimeProcesses.windowsApps(prefix: profile.prefix)
                    guard !Task.isCancelled,self.runtimeState.windowsAppsOperation==operation,self.selectedProfile?.id==profile.id else { return }
                    self.runtimeState.windowsApps=remaining
                    if remaining.isEmpty {
                        self.closeWindowsApps()
                        return
                    }
                    try await Task.sleep(for:.milliseconds(250))
                } while Date()<deadline
                self.runtimeState.windowsAppsBusy=false; self.runtimeState.windowsAppsCanForceQuit=true
                self.runtimeState.windowsAppsMessage="Some apps are still open. Save your work and try again, or force quit them."
            } catch {
                guard self.runtimeState.windowsAppsOperation==operation else { return }
                self.runtimeState.windowsAppsBusy=false; self.runtimeState.windowsAppsMessage=error.localizedDescription
            }
        }
    }

    func compatibilityTests(_ game:LibraryGame)->[CompatibilityTest] { (settingsState.configuration.compatibilityTests).filter{$0.gameID==game.id}.sorted{$0.testedAt>$1.testedAt} }
    func recordCompatibility(_ game:LibraryGame,profile:RuntimeProfile,rating:CompatibilityRating,notes:String) {
        var records=settingsState.configuration.compatibilityTests;records.removeAll{$0.gameID==game.id && $0.environmentID==profile.id}
        records.append(CompatibilityTest(gameID:game.id,environmentID:profile.id,engine:profile.runtime.name,fingerprint:runtimeFingerprint(profile),options:preferences(for:game).launchOptions,rating:rating,notes:notes));settingsState.configuration.compatibilityTests=Array(records.suffix(500));save()
    }
    func suggestedProfile(_ game:LibraryGame)->RuntimeProfile? {
        if game.isSteam { return performanceProfile(for: game) }
        for record in compatibilityTests(game) where record.rating != .broken {
            if let profile=runtimeState.profiles.first(where:{$0.id==record.environmentID && runtimeFingerprint($0)==record.fingerprint}){return profile}
        }
        return ([selectedProfile].compactMap{$0}+runtimeState.profiles).first{profile in !compatibilityTests(game).contains{$0.environmentID==profile.id && $0.rating == .broken && $0.fingerprint==runtimeFingerprint(profile)}}
    }
    func useCompatibility(_ test:CompatibilityTest,game:LibraryGame) {
        guard game.isSteam ? test.environmentID == RuntimeProfile.steamBridgeID : runtimeState.profiles.contains(where:{$0.id==test.environmentID}) else{return}
        var prefs=preferences(for:game);prefs.environmentID=test.environmentID;prefs.launchOptions=test.options;do {try updatePreferences(prefs,game:game)}catch{self.error=error.localizedDescription}
    }

    func launchGame(_ game: AddedGame) {
        if game.platform == .macOS {
            Task { [self] in
            do {
                try await FileService.shared.validateApplication(game.executable)
                let options = NSWorkspace.OpenConfiguration(); options.arguments = game.arguments
                activityState.status = "Opening \(game.name) on your Mac…"
                NSWorkspace.shared.openApplication(at: game.executable, configuration: options) { [weak self] app, failure in
                    Task { @MainActor in
                        guard let self else { return }
                        if let failure { self.failGameSession("added:"+game.id.uuidString,message:failure.localizedDescription);self.markLaunch(game.name,outcome:failure.localizedDescription); self.error = failure.localizedDescription; return }
                        if let app, !app.isTerminated {
                            if let record=self.activeSession("added:"+game.id.uuidString),let token=RuntimeProcessIdentity.token(for:app.processIdentifier) { self.observeGameSession(record.id,running:true); Task {
                                await self.activityState.sessionCoordinator.synchronize(self.gameSessions, revision: self.activityState.sessionHistoryRevision)
                                await self.activityState.sessionCoordinator.register([token], for: record.id)
                            } }
                            self.markLaunch(game.name,outcome:"Native application opened")
                            if self.nativeApplications[app.processIdentifier] == nil {
                                let id = UUID(); self.nativeApplications[app.processIdentifier] = (id, game.name)
                                self.activityState.activeLaunches[id] = game.name
                            }
                            if let index = self.settingsState.configuration.addedGames.firstIndex(where: { $0.id == game.id }) {
                                self.settingsState.configuration.addedGames[index].lastPlayed = Date().timeIntervalSince1970
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
        Task {
            do {
                try await prepareNonSteamEnvironment(profile)
                activityState.pendingGameTitle = game.name; pendingGameID = "added:\(game.id.uuidString)"
                try await run(try await runtimeState.runtimeService.launch(profile: profile, program: game.executable, arguments: game.arguments), title: game.name, profile: profile, showActivity: false)
            } catch { failGameSession("added:"+game.id.uuidString,message:error.localizedDescription);activityState.pendingGameTitle = nil; pendingGameID = nil; self.error = error.localizedDescription }
        }
    }

    func run(_ command: LaunchCommand, title: String, profile: RuntimeProfile, showActivity: Bool = true) async throws {
        guard !shuttingDown else { throw CancellationError() }
        if showActivity, session.context?.profile.id == profile.id,
           let existing = launchContexts.values.first(where: { $0.title == title && $0.profile.id == profile.id }) {
            try session.begin(existing)
            if let window = session.nativeWindows.first(where: { !$0.isSteamClient }) { session.activateNativeWindow(window.id) }
            activityState.pendingGameTitle = nil
            sessionRequest = UUID()
            return
        }
        if let prefix = command.environment["WINEPREFIX"] {
            try await runtimeState.runtimeService.createDirectory(URL(fileURLWithPath: prefix))
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
        activityState.activeLaunches[id] = title
        activityState.latestLog = launch.logURL
        activityState.status = "Launched \(title)"
        let context = SessionContext(profile: profile, title: title, launch: launch.token)
        launchContexts[id] = context
        var presentationError: Error?
        do {
            try session.begin(context)
            if showActivity { sessionRequest = UUID() }
        } catch { presentationError = error }
        await processService.observe(id) { [weak self] code in
            Task { @MainActor in
                guard let self else { return }
                guard self.launches.removeValue(forKey: id) != nil else { return }
                self.launchContexts.removeValue(forKey: id)
                self.activityState.activeLaunches.removeValue(forKey: id)
                // The -applaunch command may exit before the actual game starts.
                if code != 0 && self.activityState.pendingGameTitle == title { self.activityState.pendingGameTitle = nil; self.pendingGameID = nil }
                if code != 0 {
                    if let record=self.gameSessions.last(where:{$0.name==title && $0.phase.active}) {
                        let direct=record.gameID.hasPrefix("added:") && record.startedAt != nil
                        self.endGameSession(record.id,phase:direct ? .crashed : .failed,message:"Game launch exited with code \(code). See launch diagnostics.")
                    }
                    if title != "Steam" { self.error="\(title) exited with code \(code). Open the latest session log for details." }
                }
                self.activityState.status = code == 0 ? "\(title) launch command finished" : "\(title) launch failed"
                self.markLaunch(title,outcome:code == 0 ? "Launch command accepted" : "Launch exited with code \(code)")
                self.refreshLibrarySnapshot()
            }
        }
        if let presentationError { throw presentationError }
    }

    func disconnectSession() {
        activityState.pendingGameTitle = nil; pendingGameID = nil; gameWindowPeers.removeAll()
        launchContexts.removeAll(); launches.removeAll()
        let nativeIDs = Set(nativeApplications.values.map { $0.0 })
        activityState.activeLaunches = activityState.activeLaunches.filter { nativeIDs.contains($0.key) }
        session.end()
    }

    func runInstaller() {
        guard let profile = selectedProfile, let file = chooseExecutable(title: "Run a Windows installer") else { return }
        Task {
            do {
                try await prepareNonSteamEnvironment(profile)
                try await run(try await runtimeState.runtimeService.launch(profile: profile, program: file), title: file.lastPathComponent, profile: profile)
            }
            catch { self.error = error.localizedDescription }
        }
    }

    func prepareNonSteamEnvironment(_ profile: RuntimeProfile) async throws {
        guard let command = try await runtimeState.runtimeService.prepareNewProfile(profile) else { return }
        let id = UUID()
        let receipt = try await processService.start(command, id: id)
        activityState.latestLog = receipt.logURL
        let exitStatus = try await processService.wait(id)
        guard exitStatus == 0 else { throw PlaydockError.message("The Windows environment could not be prepared. Check the session log.") }
        guard !shuttingDown, selectedProfile?.id == profile.id else { throw CancellationError() }
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
            do { try await runtimeState.runtimeService.createDirectory(AppPaths.logs); NSWorkspace.shared.open(AppPaths.logs) }
            catch { self.error = error.localizedDescription }
        }
    }

    func chooseExecutable(title: String, platform: GamePlatform? = .windows) -> URL? {
        let panel = NSOpenPanel()
        panel.title = title
        panel.allowedContentTypes = platform.map { $0 == .macOS ? [.applicationBundle] : [UTType(filenameExtension: "exe") ?? .data] } ?? [.applicationBundle, UTType(filenameExtension: "exe") ?? .data]
        panel.canChooseDirectories = false
        return panel.runModal() == .OK ? panel.url : nil
    }
}
