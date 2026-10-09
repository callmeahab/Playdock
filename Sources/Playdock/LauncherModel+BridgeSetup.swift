import AppKit
import Foundation
import PlaydockCore
import PlaydockPresentation

extension LauncherModel {
    func refreshBridgeEnvironment() async {
        guard !runtimeState.bridgeBusy, !runtimeState.bridgeChecking else { return }
        runtimeState.bridgeChecking = true
        defer {
            runtimeState.bridgeChecking = false
            if initialBridgeCheck, !loadingSettings, !shuttingDown {
                initialBridgeCheck = false
                if InitialSetupPlan.shouldPresentAtLaunch(reviewed: settingsState.configuration.setupReviewedAt != nil, environment: runtimeState.bridgeEnvironment) {
                    showingSteamBridgeSetup = true
                }
                startInitialSteamConnectionIfNeeded()
            }
        }
        do {
            let state: SteamIntegrationEnvironment
            #if DEBUG
            if let preview = try await setupEnvironmentPreview() { state = preview }
            else { state = try await bridgeService.inspect(crossOver: runtimeState.bridgeCrossOverPath.isEmpty ? nil : URL(fileURLWithPath: runtimeState.bridgeCrossOverPath)) }
            #else
            state = try await bridgeService.inspect(crossOver: runtimeState.bridgeCrossOverPath.isEmpty ? nil : URL(fileURLWithPath: runtimeState.bridgeCrossOverPath))
            #endif
            runtimeState.bridgeEnvironment = state
            runtimeState.bridgeCheckMessage = nil
        } catch { runtimeState.bridgeCheckMessage = error.localizedDescription }
    }
    func ensureBridgeReady() async throws {
        let state = try await bridgeService.inspect()
        runtimeState.bridgeEnvironment = state
        guard state.ready else { throw PlaydockError.message(state.problems.first ?? "Repair the Steam–CrossOver bridge before playing Windows games.") }
        try await bridgeService.updateLaunchSupport()
    }
    func chooseBridgeCrossOver() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowedContentTypes = [.applicationBundle]; panel.title = "Choose CrossOver"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        runtimeState.bridgeCrossOverPath = url.path; settingsState.configuration.bridgeCrossOverPath = url.path; save()
    }
    func cancelBridgeSetup() { if runtimeState.bridgeProgress.canCancel { bridgeTask?.cancel() } }
    func runBridgeSetup(_ operation: SteamIntegrationOperation) {
        guard !runtimeState.bridgeBusy, !steamState.busy, !steamState.signingIn, runtimeState.prefixToolsBusy.isEmpty, gameSessions.allSatisfy({ !$0.phase.active }), installationState.installationRequest == nil, installationState.uninstallationRequest == nil,
              !installationState.maintenance.values.contains(where: { !$0.completed && !$0.failed }) else {
            runtimeState.bridgeMessage = "Finish running games and file operations before changing the bridge."; return
        }
        runtimeState.bridgeBusy = true; runtimeState.bridgeMessage = nil
        bridgeClosedSteam = false
        runtimeState.bridgeProgress = SteamIntegrationProgress("Preparing Steam–CrossOver bridge", canCancel: true)
        let chosen = runtimeState.bridgeCrossOverPath.isEmpty ? nil : URL(fileURLWithPath: runtimeState.bridgeCrossOverPath)
        bridgeTask = Task { [weak self] in
            guard let self else { return }
            defer {
                runtimeState.bridgeBusy = false; bridgeTask = nil
                if bridgeClosedSteam { connectSteam() }
                bridgeClosedSteam = false
            }
            do {
                let outcome = try await bridgeService.run(operation, crossOver: chosen, prepareMutation: { [weak self] in
                    try await self?.closeSteamForBridgeSetup()
                    await MainActor.run { self?.bridgeClosedSteam = true }
                }) { [weak self] progress in
                    await MainActor.run { self?.runtimeState.bridgeProgress = progress }
                }
                runtimeState.bridgeEnvironment = outcome.environment; runtimeState.bridgeMessage = outcome.message
                session.end(stoppingEnvironment: false)
                settingsState.configuration.bridgeCrossOverPath = chosen?.path ?? ""; save()
                runtimeState.bridgeBusy = false
                if outcome.restartSteam { bridgeClosedSteam = false; connectSteam() }
                refresh()
            } catch is CancellationError { runtimeState.bridgeMessage = "Setup cancelled before applying changes." }
            catch {
                let message = error.localizedDescription
                if bridgeClosedSteam { runtimeState.bridgeEnvironment = nil }
                runtimeState.bridgeBusy = false
                await refreshBridgeEnvironment()
                runtimeState.bridgeMessage = message
            }
        }
    }

    func finishInitialSetup() {
        showingSteamBridgeSetup = false
        navigate("Library")
    }

    func closeSteamForBridgeSetup() async throws {
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: "com.valvesoftware.steam").filter { !$0.isTerminated }
        if !apps.isEmpty {
            let control = try controlClient(allowDuringBridgeSetup: true)
            guard try await control.runningAppIDs().isEmpty, try await control.snapshot().downloads.allSatisfy({ !$0.active }) else {
                throw PlaydockError.message("Finish Steam games and downloads before changing the bridge.")
            }
        }
        try Task.checkCancellation()
        runtimeState.bridgeProgress = SteamIntegrationProgress("Closing Steam safely", canCancel: false)
        invalidateWorkflows()
        for app in apps { guard app.terminate() else { throw PlaydockError.message("Close Steam, then retry setup.") } }
        for _ in 0..<100 {
            if apps.allSatisfy({ $0.isTerminated }) { break }
            await Task.detached { try? await Task.sleep(for: .milliseconds(200)) }.value
        }
        guard apps.allSatisfy({ $0.isTerminated }) else { throw PlaydockError.message("Steam has not closed. Close it, then retry.") }
    }
}
