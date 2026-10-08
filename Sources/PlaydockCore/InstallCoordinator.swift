import Foundation

public enum InstallationEvent: Sendable {
    case snapshot(SteamControlSnapshot)
    case prepared(SteamInstallPlan?, String)
    case started
}
public enum UninstallationEvent: Sendable {
    case starting
    case finished(SteamAppState)
    case failed(String)
}

/// Serializes wizard cleanup; revisions reject preparation that arrives after Cancel.
public actor InstallCoordinator {
    public typealias Resolve = @Sendable () async throws -> any SteamWorkflowControl
    public typealias Publish = @Sendable (InstallationEvent) async -> Void
    private var revision = 0
    private var stopped = false
    private var pending: Task<Void, Never>?
    private var cleanup: Task<Void, Never>?
    private var requestID: UUID?
    private var appID: String?
    private var plan: SteamInstallPlan?
    private var control: (any SteamWorkflowControl)?
    public init() {}

    private func begin(_ revision: Int, requestID: UUID, appID: String) -> Bool {
        guard !stopped, revision > self.revision else { return false }
        self.revision = revision; pending?.cancel()
        if self.requestID != requestID { plan = nil; control = nil }
        self.requestID = requestID; self.appID = appID
        return true
    }
    private func current(_ revision: Int) -> Bool { !stopped && !Task.isCancelled && self.revision == revision }
    public func prepare(revision: Int, requestID: UUID, appID: String, resolve: @escaping Resolve, publish: @escaping Publish) {
        guard begin(revision, requestID: requestID, appID: appID) else { return }
        let cleanup = cleanup
        pending = Task {
            defer { if self.revision == revision { pending = nil } }
            do {
                await cleanup?.value
                try Task.checkCancellation()
                let control = try await resolve()
                guard current(revision) else { return }
                self.control = control
                let snapshot = try await control.snapshot()
                guard current(revision) else { return }
                await publish(.snapshot(snapshot))
                guard current(revision) else { return }
                guard snapshot.mode == .online else {
                    await publish(.prepared(nil, snapshot.mode == .offline ? "Go online to download this game." : "Sign in through Steam, then retry.")); return
                }
                let result = try await control.prepareInstall(appID: appID)
                guard current(revision) else { return }
                plan = result.failureMessage == nil ? result : nil
                await publish(.prepared(plan, result.confirmationMessage))
            } catch {
                if current(revision) { await publish(.prepared(nil, error.localizedDescription)) }
            }
        }
    }
    public func chooseFolder(revision: Int, requestID: UUID, appID: String, folder: Int, publish: @escaping Publish) {
        guard self.requestID == requestID, let control, begin(revision, requestID: requestID, appID: appID) else { return }
        pending = Task {
            defer { if self.revision == revision { pending = nil } }
            do {
                let result = try await control.chooseFolder(appID: appID, folder: folder)
                guard current(revision) else { return }
                plan = result.failureMessage == nil ? result : nil
                await publish(.prepared(plan, result.confirmationMessage))
            } catch { if current(revision) { await publish(.prepared(nil, error.localizedDescription)) } }
        }
    }
    public func confirm(revision: Int, requestID: UUID, appID: String, acceptedAgreements: Bool, publish: @escaping Publish) {
        guard self.requestID == requestID, let control, let plan, plan.canConfirm,
              !plan.needsAgreement || acceptedAgreements, begin(revision, requestID: requestID, appID: appID) else { return }
        pending = Task {
            defer { if self.revision == revision { pending = nil } }
            do {
                let result = try await control.continueInstall(appID: appID, agreements: acceptedAgreements ? plan.eulas : [])
                guard current(revision) else { return }
                if let failure = result.failureMessage { throw PlaydockError.message(failure) }
                if result.hasStarted {
                    self.plan = nil; self.requestID = nil; self.appID = nil
                    await publish(.started)
                } else {
                    self.plan = result
                    await publish(.prepared(result, "Steam needs another confirmation. Review the agreements below or open Steam."))
                }
            } catch { if current(revision) { await publish(.prepared(nil, error.localizedDescription)) } }
        }
    }
    public func cancel(revision: Int, appID: String?, control fallback: (any SteamWorkflowControl)?) {
        guard revision > self.revision else { return }
        self.revision = revision
        let pending = pending, previous = cleanup, control = self.control ?? fallback, target = self.appID ?? appID
        pending?.cancel(); self.pending = nil; plan = nil; requestID = nil; self.appID = nil; self.control = nil
        cleanup = Task {
            await previous?.value; await pending?.value
            if let control, let target { try? await control.cancelInstall(appID: target) }
        }
    }
    public func uninstall(revision: Int, requestID: UUID, appID: String, resolve: @escaping Resolve,
                          publish: @escaping @Sendable (UninstallationEvent) async -> Void) {
        guard begin(revision, requestID: requestID, appID: appID) else { return }
        // Uninstall progress does not own an install wizard.
        self.appID = nil
        let cleanup = cleanup
        pending = Task {
            defer { if self.revision == revision { pending = nil; self.requestID = nil } }
            do {
                await cleanup?.value
                try Task.checkCancellation()
                let control = try await resolve()
                var state: SteamAppState?
                for _ in 0..<20 {
                    try Task.checkCancellation()
                    if let value = try? await control.appState(appID: appID) { state = value; break }
                    try await Task.sleep(for: .milliseconds(500))
                }
                guard current(revision) else { return }
                guard let state else { throw PlaydockError.message("Steam is not connected. Open Steam here to sign in, then retry.") }
                guard !state.isRunning else { throw PlaydockError.message("Close this game before uninstalling it.") }
                await publish(.starting)
                guard current(revision) else { return }
                if state.installed { try await control.uninstall(appID: appID) }
                for _ in 0..<120 {
                    try await Task.sleep(for: .milliseconds(500))
                    if let state = try? await control.appState(appID: appID), !state.installed {
                        guard current(revision) else { return }
                        await publish(.finished(state)); return
                    }
                }
                throw PlaydockError.message("Steam has not finished uninstalling this game. Open Steam to check its progress.")
            } catch { if current(revision) { await publish(.failed(error.localizedDescription)) } }
        }
    }
    public func stop() async {
        cancel(revision: revision + 1, appID: nil, control: nil)
        stopped = true
        await cleanup?.value
    }
}
