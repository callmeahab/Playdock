import Foundation

public enum DownloadAction: Sendable {
    case enforce
    case apply(DownloadPolicy)
    case prioritize(String, toTop: Bool)
    case enabled(Bool)
    case pause(String, Bool)
}
public enum DownloadEvent: Sendable {
    case state(DownloadPolicy, ownedPause: Bool)
    case updated(DownloadPolicy, ownedPause: Bool, SteamControlSnapshot)
    case failed(String)
    case finished
}
public struct DownloadSchedulerState: Sendable {
    public let scope: String
    public let policy: DownloadPolicy
    public let ownedPause: Bool
    public let policyChanged: Bool
}

/// Per-client queue and schedule ownership. Manual actions wait for a cancelled
/// scheduler request to leave Steam before issuing their own changes.
public actor DownloadScheduler {
    private var revision = 0
    private var scope: String?
    private var policy = DownloadPolicy()
    private var ownedPause = false
    private var policyChanged = false
    private var task: Task<Void, Never>?
    private var operationID = UUID()
    private var stopped = false
    private var retired: [Task<Void, Never>] = []
    public init() {}
    public func invalidate(revision: Int) {
        guard revision > self.revision else { return }
        self.revision = revision; operationID = UUID(); if let task { retired.append(task) }; task?.cancel(); scope = nil
    }
    public func submit(_ action: DownloadAction, scope: String, revision: Int,
                       policy: DownloadPolicy, ownedPause: Bool,
                       control: any SteamWorkflowControl, publish: @escaping @Sendable (DownloadEvent) async -> Void) {
        guard !stopped, revision >= self.revision else { return }
        if revision > self.revision { invalidate(revision: revision) }
        if case .enforce = action, task != nil, self.scope == scope { return }
        let previous = task
        previous?.cancel()
        if self.scope != scope { self.scope = scope; self.policy = policy; self.ownedPause = ownedPause; policyChanged = false }
        let id = UUID(); operationID = id
        task = Task {
            defer { if operationID == id { task = nil } }
            await previous?.value
            do {
                try Task.checkCancellation()
                switch action {
                case .enforce:
                    let snapshot = try await control.snapshot()
                    try Task.checkCancellation()
                    guard snapshot.mode == .online else { return }
                    if !self.policy.allows(Date()), !snapshot.downloadsPaused, !snapshot.downloads.isEmpty {
                        try await control.enableDownloads(false)
                        if self.scope == scope, self.revision == revision { self.ownedPause = true }
                    } else if self.policy.allows(Date()), self.ownedPause {
                        if snapshot.downloadsPaused { try await control.enableDownloads(true) }
                        if self.scope == scope, self.revision == revision { self.ownedPause = false }
                    }
                case .apply(let policy):
                    try policy.validate(); try await control.applyDownloadPolicy(policy)
                    if self.scope == scope, self.revision == revision { self.policy = policy; policyChanged = true }
                case .prioritize(let appID, let toTop):
                    let snapshot = try await control.snapshot()
                    try Task.checkCancellation()
                    if snapshot.downloads.contains(where: { $0.appID == appID }) {
                        var ordered = self.policy.ordered(snapshot.downloads.map(\.appID)); ordered.removeAll { $0 == appID }
                        if toTop { ordered.insert(appID, at: 0) } else { ordered.append(appID) }
                        try await control.prioritize(appID: appID, index: toTop ? 0 : max(0, ordered.count - 1))
                        if self.scope == scope, self.revision == revision { self.policy.priorityAppIDs = ordered; policyChanged = true }
                    }
                case .enabled(let enabled):
                    // A user's pause/resume releases schedule ownership.
                    self.ownedPause = false
                    await publish(.state(self.policy, ownedPause: false))
                    try Task.checkCancellation()
                    try await control.enableDownloads(enabled)
                case .pause(let appID, let paused):
                    try await control.pause(appID: appID, paused: paused)
                }
                try Task.checkCancellation()
                guard operationID == id else { return }
                await publish(.state(self.policy, ownedPause: self.ownedPause))
                try Task.checkCancellation()
                let snapshot = try await control.snapshot()
                guard !Task.isCancelled, operationID == id, self.scope == scope else { return }
                await publish(.updated(self.policy, ownedPause: self.ownedPause, snapshot))
            } catch {
                guard !Task.isCancelled, operationID == id else { return }
                await publish(.failed(error.localizedDescription))
            }
            guard !Task.isCancelled, operationID == id else { return }
            await publish(.finished)
        }
    }
    public func stop() async {
        stopped = true
        let pending = task
        operationID = UUID(); pending?.cancel()
        await pending?.value
        for task in retired { await task.value }
    }
    public func stateSnapshot() -> DownloadSchedulerState? {
        scope.map { DownloadSchedulerState(scope: $0, policy: policy, ownedPause: ownedPause, policyChanged: policyChanged) }
    }
}
