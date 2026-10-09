import AppKit
import Foundation
import PlaydockCore
import PlaydockPresentation

extension LauncherModel {
    func save() {
        guard canSave, !loadingSettings, !shuttingDown else { return }
        settingsRevision += 1
        let revision = settingsRevision, snapshot = settingsState.configuration
        Task {
            do { try await settingsService.save(snapshot, revision: revision) }
            catch { self.error = "Cannot save settings: \(error.localizedDescription)" }
        }
    }

    func prepareForTermination() async {
        shuttingDown = true
        steamState.signInTask?.cancel()
        await steamState.signInTask?.value
        if runtimeState.bridgeProgress.canCancel { bridgeTask?.cancel() }
        await bridgeTask?.value
        refreshTask?.cancel(); libraryState.libraryScanTask?.cancel(); libraryState.catalogRestoreTask?.cancel()
        libraryState.catalogTask?.cancel(); libraryState.presentationTask?.cancel()
        featureMonitor?.cancel(); libraryState.libraryMonitor?.cancel()
        runtimeState.performanceCapture?.cancel()
        activationObservers.forEach { NotificationCenter.default.removeObserver($0) }; activationObservers.removeAll()
        async let backendStop: Void = steamState.coordinator.stop()
        async let installStop: Void = installationState.installationCoordinator.stop()
        async let downloadStop: Void = downloadsState.scheduler.stop()
        async let socialStop: Void = socialState.coordinator.stop()
        async let maintenanceStop: Void = installationState.maintenanceCoordinator.stop()
        async let sessionStop: Void = activityState.sessionCoordinator.stop()
        _ = await (backendStop, installStop, downloadStop, socialStop, maintenanceStop, sessionStop)
        if let state = await downloadsState.scheduler.stateSnapshot() {
            persistDownloadState(state.policy, owned: state.ownedPause, key: state.scope,
                persistPolicy: state.policyChanged || settingsState.configuration.downloadPolicies[state.scope] != nil)
        }
        if canSave, !loadingSettings {
            settingsRevision += 1
            try? await settingsService.save(settingsState.configuration, revision: settingsRevision)
        }
        await session.finishForTermination()
    }

    func openCouch() { showingCouch = true; couchRequest = UUID() }
    func navigate(_ destination:String) { selectedGameID=nil;navigationDestination=destination;navigationRequest=UUID();showingQuickLauncher=false }
    func openQuickLauncher() { guard !showingSteamBridgeSetup, installationState.installationRequest==nil,installationState.uninstallationRequest==nil,featureGame==nil,runtimeState.windowsAppsProfile==nil,storageGame==nil,achievementGame==nil,workshopGame==nil,!showingCollections,!showingDiagnostics else{return};showingQuickLauncher=true }
    func quickPlatform(_ game:LibraryGame)->GamePlatform? { preferredGamePlatform(game) }
}
