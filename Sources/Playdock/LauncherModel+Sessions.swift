import AppKit
import Foundation
import PlaydockCore
import PlaydockPresentation

extension LauncherModel {
    var gameSessions:[GameSessionRecord] { settingsState.configuration.gameSessions }
    func activeSession(_ gameID:String)->GameSessionRecord? { gameSessions.last{$0.gameID==gameID && $0.phase.active} }
    func beginGameSession(_ game:LibraryGame,platform:GamePlatform) {
        guard activeSession(game.id)==nil else{return}
        var history=gameSessions
        history.append(GameSessionRecord(gameID:game.id,name:game.name,platform:platform,environmentID:platform == .windows ? (game.isSteam ? RuntimeProfile.steamBridgeID : selectedProfile?.id) : nil))
        settingsState.configuration.gameSessions=Array(history.suffix(200));syncSessionHistory();save()
    }
    func changeSession(_ id:UUID,_ change:(inout GameSessionRecord)->Void) {
        var records = settingsState.configuration.gameSessions
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        let before=records[index];change(&records[index]);guard before != records[index] else{return};settingsState.configuration.gameSessions=records;syncSessionHistory();save()
        if !records[index].phase.active, pendingGameID==records[index].gameID { pendingGameID=nil;activityState.pendingGameTitle=nil }
    }
    func observeGameSession(_ id:UUID,running:Bool?) { changeSession(id){$0.observe(running:running)} }
    func endGameSession(_ id:UUID,phase:GameSessionPhase,message:String) { changeSession(id){$0.phase=phase;$0.endedAt=Date();$0.message=message} }
    func failGameSession(_ gameID:String,message:String) { if let record=activeSession(gameID){endGameSession(record.id,phase:.failed,message:message)} }
    func syncSessionHistory() {
        activityState.sessionHistoryRevision += 1
        let revision = activityState.sessionHistoryRevision, records = gameSessions
        Task { await activityState.sessionCoordinator.synchronize(records, revision: revision) }
        Task { await refreshOptionalWork() }
    }
    func sessionMonitorInput() -> SessionMonitorInput? {
        guard !shuttingDown, !loadingSettings else { return nil }
        let clients = [SessionClientInput(platform: .macOS, root: steamRoot, control: try? controlClient())]
        let paths = SessionMonitorInput.nativeBundleSnapshot(NSWorkspace.shared.runningApplications.filter { !$0.isTerminated }.compactMap { app in app.bundleURL.map { (app.processIdentifier, $0) } })
        return SessionMonitorInput(revision: workflowRevision, historyRevision: activityState.sessionHistoryRevision, records: gameSessions,
            clients: clients, library: library, added: settingsState.configuration.addedGames, environmentID: selectedProfile?.id,
            prefix: selectedProfile?.prefix, nativeBundles: paths)
    }
    func applySessionUpdate(_ update: SessionUpdate) {
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
            if !change.after.phase.active, pendingGameID == change.after.gameID { pendingGameID = nil; activityState.pendingGameTitle = nil }
        }
        if records != gameSessions { settingsState.configuration.gameSessions = Array(records.suffix(200)); syncSessionHistory(); save() }
        for confirmation in update.steamConfirmations {
            guard let record = records.first(where: { $0.id == confirmation.sessionID && $0.phase == .launching }) else { continue }
            let prompt = SteamLaunchPrompt(record: record, launch: confirmation.launch)
            if confirmation.launch.isInformational && activityState.steamLaunchResponseBusy { continue }
            if !confirmation.launch.isInformational && activityState.steamLaunchPrompt != nil { continue }
            guard presentedLaunchConfirmations.insert(prompt.id).inserted else { continue }
            if confirmation.launch.isInformational { respondToSteamLaunch(prompt, response: .acknowledge) }
            else if activityState.steamLaunchPrompt == nil { activityState.steamLaunchPrompt = prompt }
        }
    }
    func monitorGameSessions() async { await activityState.sessionCoordinator.refresh() }
    func bringGameForward(_ record:GameSessionRecord) {
        guard record.phase.active else{return}
        if let peer=gameWindowPeers[record.gameID],let window=activityState.nativeGameWindows.first(where:{$0.peer.id==peer}) { session.activateNativeWindow(window.id);return }
        let installation=library.first{$0.id==record.gameID}?.installation(for:record.platform)
        guard let location = installation?.location else { return }
        let root = steamRoot
        let apps = NSWorkspace.shared.runningApplications
        let paths = Dictionary(uniqueKeysWithValues: apps.compactMap { app in app.bundleURL.map { (app.processIdentifier, $0) } })
        Task {
            let tokens = await runtimeState.runtimeProcesses.gameProcesses(pids: apps.map(\.processIdentifier), bundlePaths: paths, location: location, steamRoot: root)
            guard activeSession(record.gameID)?.id == record.id else { return }
            if let app = apps.first(where: { app in tokens.contains { $0.pid == app.processIdentifier && RuntimeProcessIdentity.token(for: $0.pid) == $0 } }) {
                app.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
            } else {
                changeSession(record.id) { $0.message = "No game window is available yet. Steam is still preparing the launch." }
                if record.gameID.hasPrefix("steam:") { Task { await self.reviewSteamLaunch(record) } }
            }
        }
    }

    func respondToSteamLaunch(_ prompt: SteamLaunchPrompt, response: SteamLaunchResponse) {
        guard !activityState.steamLaunchResponseBusy, activeSession(prompt.record.gameID)?.id == prompt.record.id else { return }
        activityState.steamLaunchResponseBusy = true
        Task {
            defer { activityState.steamLaunchResponseBusy = false }
            do {
                try await controlClient().respondToLaunch(prompt.launch, response: response)
                if activityState.steamLaunchPrompt?.id == prompt.id { activityState.steamLaunchPrompt = nil }
                if response == .cancel { endGameSession(prompt.record.id, phase: .finished, message: "Launch cancelled.") }
                await monitorGameSessions()
            } catch {
                presentedLaunchConfirmations.remove(prompt.id)
                changeSession(prompt.record.id) { $0.message = error.localizedDescription }
                self.error = error.localizedDescription
            }
        }
    }

    func reviewSteamLaunch(_ record: GameSessionRecord) async {
        guard let launch = try? await controlClient().activeGameLaunches().first(where: { "steam:" + $0.appID == record.gameID && $0.waitingForUser }),
              activeSession(record.gameID)?.id == record.id else { return }
        let prompt = SteamLaunchPrompt(record: record, launch: launch)
        if launch.isInformational { respondToSteamLaunch(prompt, response: .acknowledge) }
        else { activityState.steamLaunchPrompt = prompt }
    }

    func stopGame(_ record:GameSessionRecord) {
        guard let current=activeSession(record.gameID),current.id==record.id,current.phase != .stopping else{return}
        changeSession(record.id){$0.phase = .stopping;$0.message="Asking the game to close…"}
        Task {
            do {
                if record.gameID.hasPrefix("steam:") {
                    try await controlClient().terminateGame(appID:String(record.gameID.dropFirst(6)))
                } else {
                    let tokens = await activityState.sessionCoordinator.verifiedTokens(for: record.id)
                    guard activeSession(record.gameID)?.id == record.id else { return }
                    guard !tokens.isEmpty else{throw PlaydockError.message("No verified game process is available. Close the game from its own menu.")}
                    for token in tokens where RuntimeProcessIdentity.token(for:token.pid)==token { _=NSRunningApplication(processIdentifier:token.pid)?.terminate() }
                }
                try await Task.sleep(for:.seconds(8));await monitorGameSessions()
                if activeSession(record.gameID)?.id==record.id { changeSession(record.id){$0.phase = .playing;$0.message="The game is still running. Close it from its menu, or close it from its own window."} }
            } catch {
                guard activeSession(record.gameID)?.id == record.id else { return }
                changeSession(record.id){$0.phase = .disconnected;$0.message=error.localizedDescription}
            }
        }
    }
}
