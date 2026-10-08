import AppKit
import Foundation
import PlaydockCore
import PlaydockPresentation

extension LauncherModel {
    func refreshCloud(_ game:LibraryGame,platform:GamePlatform) {
        guard game.isSteam else { return }; let key="\(game.id):\(platform.rawValue)",account=downloadPolicyKey()
        featuresState.cloudStatuses.removeValue(forKey:key)
        Task { [weak self] in
            guard let self else { return }
            if let state=try? await self.controlClient().cloudStatus(appID:String(game.id.dropFirst(6))),self.downloadPolicyKey() == account { self.featuresState.cloudStatuses[key]=state }
        }
    }
    func suggestedSaveFolder(_ game: LibraryGame, platform: GamePlatform) -> URL? {
        featuresState.suggestedSaveFolders[saveScope(game, platform: platform)]
    }
    func windowsPrefix(for game: LibraryGame) -> URL? {
        if game.isSteam { return game.installation(for: .windows)?.steamGame?.bridgePrefix }
        return performanceProfile(for: game)?.prefix
    }
    func saveScope(_ game:LibraryGame,platform:GamePlatform) -> String {
        let environment = game.isSteam ? RuntimeProfile.steamBridgeID : performanceProfile(for: game)?.id ?? "unavailable"
        return "\(game.id):\(platform.rawValue):\(platform == .windows ? environment : "native")"
    }
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
        let key = saveScope(game, platform: platform), root = steamRoot
        let account = steamState.account
        Task {
            let backups = (try? await featuresState.saveService.list(gameID: key)) ?? []
            let suggested = game.isSteam ? await featuresState.saveService.suggestedFolder(root: root, account: account, appID: String(game.id.dropFirst(6))) : nil
            guard key == saveScope(game, platform: platform), steamState.account == account else { return }
            featuresState.saveBackups[key] = backups; featuresState.suggestedSaveFolders[key] = suggested
        }
    }
    func createSaveBackup(_ game:LibraryGame,platform:GamePlatform) {
        guard !featuresState.saveBusy else { return }; let folders=saveFolders(game,platform:platform),scope=saveScope(game,platform:platform); featuresState.saveBusy=true; featuresState.saveMessage="Creating restore point…"
        Task { [weak self] in
            do {
                guard let self else { return }
                let backup = try await self.featuresState.saveService.create(gameID: scope, name: game.name, folders: folders)
                self.featuresState.saveMessage="Restore point created · \(backup.files.count) files"; self.refreshBackups(game,platform:platform)
            } catch { self?.featuresState.saveMessage=error.localizedDescription }
            self?.featuresState.saveBusy=false
        }
    }
    func restoreSaveBackup(_ backup:SaveBackup,game:LibraryGame,platform:GamePlatform) {
        guard !featuresState.saveBusy else { return }; featuresState.saveBusy=true; featuresState.saveMessage="Checking game and restore point…"
        Task { [weak self] in
            guard let self else { return }; defer { self.featuresState.saveBusy=false }
            do {
                guard backup.gameID==self.saveScope(game,platform:platform),Set(backup.folders)==Set(self.saveFolders(game,platform:platform)) else { throw PlaydockError.message("Add this restore point’s original save folders before restoring it.") }
                guard game.isSteam || platform != .windows || self.preferences(for:game).environmentID == nil || self.preferences(for:game).environmentID == self.selectedProfile?.id else { throw PlaydockError.message("Select this game’s saved Windows environment in Engines before restoring saves.") }
                if game.isSteam { let state=try await self.controlClient().appState(appID:String(game.id.dropFirst(6))); guard !state.isRunning else { throw PlaydockError.message("Close the game before restoring its saves.") } }
                else if let installation=game.installation(for:platform) {
                    if platform == .macOS { guard !NSWorkspace.shared.runningApplications.contains(where:{$0.bundleURL==installation.location}) else { throw PlaydockError.message("Close the game before restoring its saves.") } }
                    else if let profile = self.selectedProfile {
                        let processes = try await runtimeState.runtimeProcesses.windowsProcesses(prefix: profile.prefix)
                        let running = processes.contains { $0.program == installation.location.lastPathComponent.lowercased() }
                        guard !running else { throw PlaydockError.message("Close the game before restoring its saves.") }
                    }
                }
                try await featuresState.saveService.restore(backup)
                self.featuresState.saveMessage="Saves restored. Previous saves are kept in a recovery point."; self.refreshBackups(game,platform:platform)
            } catch { self.featuresState.saveMessage=error.localizedDescription }
        }
    }

    func achievementScope(_ client:GamePlatform)->String? {
        guard connectionMode() != .signedOut,let account = steamState.account else{return nil}
        return client.rawValue+":"+steamRoot.path+":"+account+":"+(client == .windows ? RuntimeProfile.steamBridgeID : "")
    }
    func achievementSnapshot(_ game:LibraryGame,platform:GamePlatform)->AchievementSnapshot? {
        guard let scope=achievementScope(platform),let snapshot=featuresState.achievementSnapshots[game.id+":"+platform.rawValue],snapshot.scope==scope else{return nil};return snapshot
    }
    func refreshAchievements(_ game:LibraryGame,platform:GamePlatform) {
        guard game.id.hasPrefix("steam:"),let scope=achievementScope(platform) else{return}
        let id=String(game.id.dropFirst(6)),key=game.id+":"+platform.rawValue
        guard !featuresState.achievementBusy.contains(key) else{return}
        featuresState.achievementBusy.insert(key)
        Task {defer{featuresState.achievementBusy.remove(key)};do {
            if let saved = try? await featuresState.achievementService.load(scope: scope, appID: id), scope == achievementScope(platform) { featuresState.achievementSnapshots[key] = saved }
            guard scope == achievementScope(platform), !Task.isCancelled else { return }
            if connectionMode() == .unavailable || connectionMode() == .signedOut {
                featuresState.achievementMessages[key] = "Saved achievements. Connect Steam to refresh."
                return
            }
            let items=try await controlClient().achievements(appID:id);guard scope==achievementScope(platform) else{return}
            let snapshot=AchievementSnapshot(scope:scope,appID:id,updatedAt:Date(),achievements:items,offline:connectionMode() == .offline);featuresState.achievementSnapshots[key]=snapshot;featuresState.achievementMessages[key]=snapshot.offline == true ? "Steam’s offline achievement data. Go online to update it.":nil;try await featuresState.achievementService.save(snapshot)
        }catch{if scope==achievementScope(platform){featuresState.achievementMessages[key]=error.localizedDescription}}}
    }

    func workshopScope(_ platform: GamePlatform) -> String? {
        let account = connectionMode() == .signedOut ? "local" : steamState.account ?? "local"
        return platform.rawValue + ":" + steamRoot.path + ":" + account
    }
    func workshopSnapshot(_ game: LibraryGame, platform: GamePlatform) -> WorkshopSnapshot? {
        let key = game.id + ":" + platform.rawValue
        guard let snapshot = featuresState.workshopSnapshots[key], snapshot.scope == workshopScope(platform) else { return nil }
        return snapshot
    }
    func showWorkshop(_ game: LibraryGame) {
        workshopGame = game
    }
    func refreshWorkshop(_ game: LibraryGame, platform: GamePlatform, afterChange: Bool = false) async {
        let key = game.id + ":" + platform.rawValue
        guard game.isSteam, let scope = workshopScope(platform),
              (afterChange || !featuresState.workshopBusy.contains(key)), !featuresState.workshopChanging.contains(key) else { return }
        let revision = UUID(); featuresState.workshopRevisions[key] = revision
        featuresState.workshopBusy.insert(key)
        defer { featuresState.workshopBusy.remove(key) }
        let id = String(game.id.dropFirst(6))
        let cache = steamState.account != nil && connectionMode() != .signedOut
        func current() -> Bool { !Task.isCancelled && featuresState.workshopRevisions[key] == revision && workshopGame?.id == game.id && preferredGamePlatform(game) == platform && workshopScope(platform) == scope }
        do {
            if workshopSnapshot(game, platform: platform) == nil {
                if let saved = try? await featuresState.workshopService.initial(scope: scope, appID: id, root: steamRoot, useCache: cache) {
                    guard current() else { return }; featuresState.workshopSnapshots[key] = saved
                }
            }
            guard current() else { return }
            let live = try await controlClient().workshop(appID: id)
            guard current() else { return }
            let snapshot = try await featuresState.workshopService.resolve(live, scope: scope, root: steamRoot, save: cache)
            guard current() else { return }
            featuresState.workshopSnapshots[key] = snapshot; featuresState.workshopMessages[key] = nil
        } catch is CancellationError { }
        catch {
            if current() {
                if var previous = featuresState.workshopSnapshots[key], previous.scope == scope, previous.source == .steam {
                    previous.source = .saved; previous.capabilities = WorkshopCapabilities(); featuresState.workshopSnapshots[key] = previous
                }
                featuresState.workshopMessages[key] = error.localizedDescription
            }
        }
    }
    func lookupWorkshop(_ game: LibraryGame, platform: GamePlatform, input: String) async throws -> WorkshopItemDetails {
        let scope = workshopScope(platform)
        let item = try await featuresState.workshopService.lookup(appID: String(game.id.dropFirst(6)), input: input)
        guard !Task.isCancelled, workshopGame?.id == game.id, preferredGamePlatform(game) == platform, workshopScope(platform) == scope else { throw CancellationError() }
        return item
    }
    func changeWorkshop(_ game: LibraryGame, platform: GamePlatform, action: WorkshopAction) async -> Bool {
        let key = game.id + ":" + platform.rawValue
        guard let scope = workshopScope(platform), workshopGame?.id == game.id, preferredGamePlatform(game) == platform,
              !featuresState.workshopChanging.contains(key), let snapshot = workshopSnapshot(game, platform: platform), snapshot.source == .steam else { return false }
        featuresState.workshopChanging.insert(key); featuresState.workshopMessages[key] = nil
        featuresState.workshopRevisions[key] = UUID()
        var success = false
        do {
            await refreshSteamAccount()
            guard !Task.isCancelled, workshopScope(platform) == scope, workshopGame?.id == game.id, preferredGamePlatform(game) == platform else { throw CancellationError() }
            if case .subscribe(let id, true) = action {
                _ = try await featuresState.workshopService.lookup(appID: String(game.id.dropFirst(6)), input: id)
            }
            guard !Task.isCancelled, workshopScope(platform) == scope else { throw CancellationError() }
            try await controlClient().changeWorkshop(appID: String(game.id.dropFirst(6)), action: action)
            success = true
        } catch is CancellationError { }
        catch { if workshopScope(platform) == scope { featuresState.workshopMessages[key] = error.localizedDescription } }
        featuresState.workshopChanging.remove(key)
        let message = featuresState.workshopMessages[key]
        if workshopScope(platform) == scope { await refreshWorkshop(game, platform: platform, afterChange: true) }
        if !success, let message, workshopScope(platform) == scope { featuresState.workshopMessages[key] = message }
        return success
    }
    func browseWorkshop(_ game: LibraryGame, platform: GamePlatform, itemID: String? = nil) {
        do {
            let url = try WorkshopIdentifier.browserURL(appID: String(game.id.dropFirst(6)), itemID: itemID)
            workshopGame = nil
            NSWorkspace.shared.open(url)
        } catch { self.error = error.localizedDescription }
    }
}
