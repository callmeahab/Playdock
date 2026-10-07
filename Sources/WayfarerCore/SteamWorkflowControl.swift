import Foundation

/// The workflow boundary exposes operations rather than a concrete network
/// transport, allowing cancellation and late-response races to be exercised.
public protocol SteamWorkflowControl: Sendable {
    func snapshot() async throws -> SteamControlSnapshot
    func changeMode(offline: Bool) async throws
    func prepareInstall(appID: String) async throws -> SteamInstallPlan
    func chooseFolder(appID: String, folder: Int) async throws -> SteamInstallPlan
    func continueInstall(appID: String, agreements: [SteamGameEULA]) async throws -> SteamInstallPlan
    func cancelInstall(appID: String) async throws
    func enableDownloads(_ enabled: Bool) async throws
    func pause(appID: String, paused: Bool) async throws
    func applyDownloadPolicy(_ policy: DownloadPolicy) async throws
    func prioritize(appID: String, index: Int) async throws
    func moveGame(appID: String, folder: Int) async throws
    func verifyFiles(appID: String) async throws
    func maintenanceProgress(appID: String) async throws -> SteamMaintenanceProgress
    func runningAppIDs() async throws -> [String]
    func appState(appID: String) async throws -> SteamAppState
    func uninstall(appID: String) async throws
}

extension SteamControl: SteamWorkflowControl {}
