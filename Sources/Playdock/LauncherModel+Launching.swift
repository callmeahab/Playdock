import AppKit
import Foundation
import PlaydockCore
import PlaydockPresentation

extension LauncherModel {
    func launch(_ game: LibraryGame) {
        if let active=activeSession(game.id) { bringGameForward(active);return }
        if let prefix = prefixProfile(for: game)?.prefix, runtimeState.prefixToolsBusy.contains(prefix) { error = "Close this game's Windows tools before playing."; return }
        if let operation=installationState.maintenance.first(where:{$0.key.hasPrefix(game.id+":") && !$0.value.completed && !$0.value.failed}) { error="Wait for this game’s \(operation.value.kind == "move" ? "move":"verification") to finish before playing.";return }
        let platform = preferredGamePlatform(game)
        if platform == .windows, !game.isSteam, let environment = performanceProfile(for: game)?.id, environment != selectedProfile?.id {
            launchInSavedEnvironment(game,environment:environment); return
        }
        if installationDisabled(game, platform: platform) { return }
        let target = platform.flatMap { game.installation(for: $0) }
        guard let installation = target else { install(game, platform: platform); return }
        if installation.platform == .windows, let peer = gameWindowPeers[game.id], let window = activityState.nativeGameWindows.first(where: { $0.peer.id == peer }) {
            session.activateNativeWindow(window.id); return
        }
        let arguments:[String]
        do { arguments=try preferences(for:game).arguments() } catch { self.error=error.localizedDescription; return }
        if !game.isSteam && installation.platform == .windows && selectedProfile == nil { error="Choose a Windows environment first.";return }
        Task {
            do {
                if !game.isSteam, installation.platform == .windows, let profile = selectedProfile {
                    try await runtimeState.performanceEnvironments.checkLaunch(preferences(for: game).effectivePerformance, profile: profile)
                    guard selectedProfile?.id == profile.id else { return }
                }
                guard activeSession(game.id) == nil, !shuttingDown else { return }
                beginGameSession(game,platform:installation.platform)
                recordLaunch(game,platform:installation.platform,outcome:"Requested")
                switch installation {
                case .macSteam(let steam): launchMacSteam(steam,arguments:arguments)
                case .macSteamWindows(let steam): launchMacSteam(steam, arguments: arguments, windows: true)
                case .added(var added):
                    if added.platform == .windows, let profile = selectedProfile { added.profileID = profile.id }
                    added.arguments += arguments; launchGame(added)
                }
            } catch { self.error = error.localizedDescription }
        }
    }

    func install(_ game: LibraryGame, platform: GamePlatform?) {
        guard !installationDisabled(game, platform: platform) else { return }
        guard let platform, let offer = game.offer(for: platform) else { error = "Load this Steam account’s library before installing the game."; return }
        if platform == .windows, offer.profileID != RuntimeProfile.steamBridgeID { error = "Refresh this game’s Steam library first."; return }
        guard installationState.installationRequest == nil else { return }
        installationState.installationRequest=GameInstallationRequest(game:game,platform:platform,appID:offer.appID)
        prepareInstallation()
    }
}
