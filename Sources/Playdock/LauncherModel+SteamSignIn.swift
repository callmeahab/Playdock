import AppKit
import Foundation
import PlaydockCore

extension LauncherModel {
    func openSteamForSignIn() {
        guard !shuttingDown, !steamState.busy, steamState.signInTask == nil, !runtimeState.bridgeBusy else { return }
        guard !gameSessions.contains(where: { $0.phase.active }), !installationState.installBusy, !installationState.uninstallBusy,
              installationState.maintenance.values.allSatisfy({ $0.completed || $0.failed }) else {
            steamState.message = "Finish games and file operations before opening Steam for sign-in."
            return
        }
        steamState.signingIn = true
        invalidateWorkflows()
        steamState.busy = true
        steamState.message = "Opening Steam for sign-in…"
        let revision = workflowRevision
        steamState.signInTask = Task { [weak self] in
            guard let self else { return }
            defer { steamState.busy = false; steamState.signInTask = nil }
            do {
                await steamState.coordinator.invalidate(revision: revision)
                let apps = await steamMainApplications()
                if !apps.isEmpty {
                    try await session.backend.prepare()
                    if !(await session.backend.allAttached(apps, root: steamRoot)), apps.allSatisfy({ $0.activationPolicy == .regular }) {
                        for app in apps { app.activate(options: [.activateAllWindows]) }
                        steamState.message = "Sign in through Steam, then connect it here. If Steam was opened outside Playdock, quit Steam after signing in."
                        return
                    }
                    await discoverSteamControl()
                    let control = try controlClient()
                    guard try await control.runningAppIDs().isEmpty, try await control.snapshot().downloads.allSatisfy({ !$0.active }) else {
                        throw PlaydockError.message("Finish Steam games and downloads before signing in again.")
                    }
                    try await runMacSteam(arguments: ["-shutdown"])
                    let processes = runtimeState.runtimeProcesses, root = steamRoot
                    try await steamState.coordinator.waitForExit(attempts: 80, settle: true, check: {
                        try await processes.steamProcesses(root: root).isEmpty
                    })
                }
                try Task.checkCancellation()
                guard !shuttingDown, workflowRevision == revision else { throw CancellationError() }
                let executable = steamRoot.appendingPathComponent("Steam.AppBundle/Steam/Contents/MacOS/steam_osx")
                if await FileService.shared.isExecutable(executable) {
                    try await runMacSteam(background: false)
                } else if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.valvesoftware.steam") {
                    steamState.port = try SteamControlEndpoint.availablePort()
                    let configuration = NSWorkspace.OpenConfiguration()
                    configuration.arguments = ["-cef-enable-debugging", "-devtools-port", String(steamState.port)]
                    _ = try await NSWorkspace.shared.openApplication(at: app, configuration: configuration)
                } else {
                    throw PlaydockError.message("Install Steam, then return to Playdock.")
                }
                steamState.message = "Finish signing in through Steam, then connect it here."
            } catch is CancellationError {
                steamState.signingIn = false
            } catch {
                steamState.signingIn = false
                steamState.message = "Could not open Steam for sign-in. Close Steam and try again. \(error.localizedDescription)"
            }
        }
    }
}
