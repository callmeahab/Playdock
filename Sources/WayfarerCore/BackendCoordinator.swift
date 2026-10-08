import Foundation

public struct SteamConnectionAvailability: Sendable {
    public let control: (any SteamWorkflowControl)?
    public let busy: Bool
    public let message: String?
    public init(control: (any SteamWorkflowControl)?, busy: Bool, message: String?) {
        self.control = control; self.busy = busy; self.message = message
    }
}
public enum BackendEvent: Sendable {
    case connected(SteamControlSnapshot)
    case disconnected
    case message(String)
    case finished
}

/// Per-client connections and polling; revisions reject stale results.
public actor BackendCoordinator {
    public typealias Resolve = @Sendable () async throws -> any SteamWorkflowControl
    public typealias Publish = @Sendable (BackendEvent) async -> Void
    private var revision = 0
    private var stopped = false
    private var retired: [Task<Void, Never>] = []
    private var poll: Task<Void, Never>?
    private var connection: Task<Void, Never>?
    private var pollID = UUID()
    private var connectionID = UUID()
    private var recovery = BackendRecovery()
    public init() {}

    private func accept(_ revision: Int) -> Bool {
        guard !stopped, revision >= self.revision else { return false }
        if revision > self.revision { invalidate(revision: revision) }
        return true
    }
    public func invalidate(revision: Int) {
        guard revision > self.revision else { return }
        self.revision = revision
        pollID = UUID(); connectionID = UUID()
        retired += [poll, connection].compactMap { $0 }
        poll?.cancel(); connection?.cancel(); poll = nil; connection = nil
        recovery = BackendRecovery()
    }
    public func refresh(revision: Int, resolve: @escaping Resolve, publish: @escaping Publish) {
        guard accept(revision), poll == nil, connection == nil else { return }
        let id = UUID(); pollID = id
        poll = Task {
            defer { if pollID == id { poll = nil } }
            do {
                let control = try await resolve()
                try Task.checkCancellation()
                let snapshot = try await control.snapshot()
                guard !Task.isCancelled, pollID == id, self.revision == revision else { return }
                recovery.connected()
                await publish(.connected(snapshot))
            } catch {
                guard !Task.isCancelled, pollID == id, self.revision == revision else { return }
                recovery.failed()
                await publish(.disconnected)
            }
        }
    }
    public func connect(revision: Int, prepare: @escaping @Sendable () async throws -> Void,
                        resolve: @escaping Resolve, publish: @escaping Publish) {
        guard accept(revision), connection == nil else { return }
        if let poll { retired.append(poll) }
        pollID = UUID(); poll?.cancel(); poll = nil
        let id = UUID(); connectionID = id
        connection = Task {
            defer { if connectionID == id { connection = nil } }
            do {
                try await prepare()
                try Task.checkCancellation()
                var completed = false, lastSnapshot: SteamControlSnapshot?
                for _ in 0..<20 {
                    if let control = try? await resolve(), let snapshot = try? await control.snapshot() {
                        guard !Task.isCancelled, connectionID == id, self.revision == revision else { return }
                        // The UI context starts before Steam restores its online or offline account.
                        lastSnapshot = snapshot
                        if snapshot.mode == .signedOut || snapshot.mode == .unavailable {
                            try await Task.sleep(for: .milliseconds(500))
                            continue
                        }
                        recovery.connected()
                        await publish(.connected(snapshot)); completed = true
                        break
                    }
                    try await Task.sleep(for: .milliseconds(500))
                }
                guard !Task.isCancelled, connectionID == id, self.revision == revision else { return }
                if !completed, let lastSnapshot, lastSnapshot.mode == .signedOut {
                    recovery.connected()
                    await publish(.connected(lastSnapshot))
                } else if !completed {
                    await publish(.message("Steam is still starting. Reconnect its backend to retry."))
                }
            } catch {
                guard !Task.isCancelled, connectionID == id, self.revision == revision else { return }
                await publish(.message(error.localizedDescription))
            }
            guard !Task.isCancelled, connectionID == id, self.revision == revision else { return }
            await publish(.finished)
        }
    }
    public func changeMode(revision: Int, offline: Bool, resolve: @escaping Resolve, publish: @escaping Publish) {
        guard accept(revision), connection == nil else { return }
        if let poll { retired.append(poll) }
        pollID = UUID(); poll?.cancel(); poll = nil
        let id = UUID(); connectionID = id
        connection = Task {
            defer { if connectionID == id { connection = nil } }
            do {
                let control = try await resolve()
                try Task.checkCancellation()
                try await control.changeMode(offline: offline)
                var stable = 0, completed = false
                for _ in 0..<40 {
                    try await Task.sleep(for: .milliseconds(500))
                    if let snapshot = try? await control.snapshot(), snapshot.mode == (offline ? .offline : .online) {
                        stable += 1
                        if stable >= 3 {
                            guard !Task.isCancelled, connectionID == id, self.revision == revision else { return }
                            recovery.connected(); await publish(.connected(snapshot)); completed = true; break
                        }
                    } else { stable = 0 }
                }
                if !completed { throw WayfarerError.message("Steam has not finished changing modes. Open Steam to check its connection.") }
            } catch {
                guard !Task.isCancelled, connectionID == id, self.revision == revision else { return }
                await publish(.message(error.localizedDescription))
            }
            guard !Task.isCancelled, connectionID == id, self.revision == revision else { return }
            await publish(.finished)
        }
    }
    public func retryDecision(revision: Int, safe: Bool, enabled: Bool) -> (retry: Bool, wasConnected: Bool) {
        guard accept(revision) else { return (false, false) }
        let retry = recovery.shouldRetry(safe: safe, enabled: enabled)
        if retry { recovery.attempted() }
        return (retry, recovery.wasConnected)
    }
    public func installationControl(state: @escaping @Sendable () async throws -> SteamConnectionAvailability,
                                    connect: @escaping @Sendable () async -> Void) async throws -> any SteamWorkflowControl {
        let initial = try await state()
        if !initial.busy, let control = initial.control, (try? await control.snapshot()) != nil { return control }
        try Task.checkCancellation()
        await connect()
        for _ in 0..<200 {
            try Task.checkCancellation()
            let current = try await state()
            if !current.busy {
                if let control = current.control, (try? await control.snapshot()) != nil { return control }
                throw WayfarerError.message(current.message ?? "Steam is not connected. Open login, sign in, then retry.")
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw WayfarerError.message("Steam is still connecting. You can close this dialog and try again later.")
    }
    public func waitForExit(attempts: Int, settle: Bool = false,
                            check: @escaping @Sendable () async throws -> Bool) async throws {
        for _ in 0..<attempts {
            try Task.checkCancellation()
            if try await check() {
                if settle { try await Task.sleep(for: .milliseconds(500)) }
                return
            }
            try await Task.sleep(for: .milliseconds(250))
        }
        throw WayfarerError.message("The old Steam client is still closing. Reconnect its backend once it exits.")
    }
    public func waitForConnection(busy: @escaping @Sendable () async throws -> Bool) async throws {
        for _ in 0..<300 {
            try Task.checkCancellation()
            guard !stopped else { throw CancellationError() }
            if try await !busy() { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw WayfarerError.message("Steam is still connecting. Reconnect its backend and try again.")
    }
    public func stop() async {
        stopped = true
        let tasks = [poll, connection].compactMap { $0 } + retired
        invalidate(revision: revision + 1)
        for task in tasks { await task.value }
    }
}
