import AppKit
import Foundation
import PlaydockCore
import PlaydockPresentation

#if DEBUG
extension LauncherModel {
    func setupEnvironmentPreview() async throws -> SteamIntegrationEnvironment? {
        guard let flag = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--setup-environment=") }) else { return nil }
        struct Preview: Decodable { let environment: SteamIntegrationEnvironment; let snapshot: SteamControlSnapshot? }
        let data = try await FileService.shared.read(URL(fileURLWithPath: String(flag.dropFirst("--setup-environment=".count))))
        let preview = try JSONDecoder().decode(Preview.self, from: data)
        steamState.snapshot = preview.snapshot
        return preview.environment
    }

    func previewBridgeProgress() {
        runtimeState.bridgeBusy = true
        runtimeState.bridgeProgress = SteamIntegrationProgress("Preparing CrossOver runner…", canCancel: true)
    }
    // Measure UI heartbeat during navigation and delayed library loading.
    func measureUIResponsiveness(output: URL) async {
        var delays: [Double] = [], loadingSamples = 0, populatedSamples = 0, navigationChanges = 0
        var pageDelays: [String: [Double]] = [:]
        var firstLibrary: Double?, firstInstalled: Double?, installedWhileLoading = false
        let started = ProcessInfo.processInfo.systemUptime
        var nextNavigation = started + 0.5
        let destinations = ["Library", "Home", "Downloads", "Home", "Engines", "Activity", "Storage", "Home"]
        while ProcessInfo.processInfo.systemUptime - started < 12 {
            let expected = ProcessInfo.processInfo.systemUptime + 0.05
            do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
            let now = ProcessInfo.processInfo.systemUptime
            delays.append(max(0, now - expected) * 1000)
            pageDelays[showingQuickLauncher ? "Quick launcher" : navigationDestination, default: []].append(max(0, now - expected) * 1000)
            if libraryState.refreshing { loadingSamples += 1 }
            if !library.isEmpty {
                populatedSamples += 1
                if firstLibrary == nil { firstLibrary = now - started }
            }
            if library.contains(where: \.isInstalled) {
                if firstInstalled == nil { firstInstalled = now - started }
                if libraryState.refreshing { installedWhileLoading = true }
            }
            if now >= nextNavigation {
                navigate(destinations[navigationChanges % destinations.count])
                if navigationChanges % destinations.count == 3 { showingQuickLauncher = true }
                navigationChanges += 1; nextNavigation = now + 0.5
            }
        }
        navigate("Home")
        let sorted = delays.sorted()
        let result: [String: Any] = [
            "samples": delays.count, "loadingSamples": loadingSamples, "populatedSamples": populatedSamples,
            "navigationChanges": navigationChanges, "maxDelayMs": sorted.last ?? 0,
            "firstLibrarySeconds": firstLibrary ?? -1, "firstInstalledSeconds": firstInstalled ?? -1,
            "installedWhileLoading": installedWhileLoading,
            "maxDelayByPageMs": pageDelays.mapValues { $0.max() ?? 0 },
            "p95DelayMs": sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))],
            "games": library.count, "elapsedSeconds": ProcessInfo.processInfo.systemUptime - started
        ]
        if let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]) {
            try? await FileService.shared.write(data, to: output)
        }
        print("UI_RESPONSIVENESS_PROBE_DONE"); fflush(stdout)
    }
}
#endif
