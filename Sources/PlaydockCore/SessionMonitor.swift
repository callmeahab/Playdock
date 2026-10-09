import Foundation

public struct SessionClientInput: Sendable {
    public let platform: GamePlatform
    public let root: URL
    public let control: (any SteamWorkflowControl)?
    public init(platform: GamePlatform, root: URL, control: (any SteamWorkflowControl)?) {
        self.platform = platform; self.root = root; self.control = control
    }
}
public struct SessionMonitorInput: Sendable {
    public static func nativeBundleSnapshot(_ applications: [(pid: Int32, bundle: URL)]) -> [Int32: URL] {
        // LaunchServices can report pending applications and duplicate process IDs.
        applications.reduce(into: [:]) { paths, app in
            if app.pid > 0 { paths[app.pid] = app.bundle }
        }
    }
    public let revision: Int
    public let historyRevision: Int
    public let records: [GameSessionRecord]
    public let clients: [SessionClientInput]
    public let library: [LibraryGame]
    public let added: [AddedGame]
    public let environmentID: String?
    public let prefix: URL?
    public let nativeBundles: [Int32: URL]
    public init(revision: Int, historyRevision: Int, records: [GameSessionRecord], clients: [SessionClientInput],
                library: [LibraryGame], added: [AddedGame], environmentID: String?, prefix: URL?, nativeBundles: [Int32: URL]) {
        self.revision = revision; self.historyRevision = historyRevision; self.records = records; self.clients = clients
        self.library = library; self.added = added; self.environmentID = environmentID; self.prefix = prefix; self.nativeBundles = nativeBundles
    }
}
public struct SessionChange: Sendable {
    public let before: GameSessionRecord?
    public let after: GameSessionRecord
}
public struct SessionUpdate: Sendable {
    public let revision: Int
    public let changes: [SessionChange]
    public let steamConfirmations: [SteamLaunchConfirmation]
}
public struct SteamLaunchConfirmation: Sendable {
    public let sessionID: UUID
    public let launch: SteamGameLaunch
}

/// Reconcile history and process tokens; apply updates only to matching input records.
public actor SessionMonitor {
    private let processes = RuntimeProcessService()
    private var history: [GameSessionRecord] = []
    private var historyRevision = -1
    private var revision = 0
    private var tokens: [UUID: [RuntimeProcessToken]] = [:]
    private var loop: Task<Void, Never>?
    private var poll: Task<Void, Never>?
    private var operation = UUID()
    private var stopped = false
    private var retired: [Task<Void, Never>] = []
    private var input: (@Sendable () async -> SessionMonitorInput?)?
    private var publish: (@Sendable (SessionUpdate) async -> Void)?
    public init() {}
    public func start(input: @escaping @Sendable () async -> SessionMonitorInput?, publish: @escaping @Sendable (SessionUpdate) async -> Void) {
        guard !stopped, loop == nil else { return }
        self.input = input; self.publish = publish
        startLoop()
    }
    static func pollInterval(_ records: [GameSessionRecord]) -> Duration {
        let active = records.filter { $0.phase.active }
        if active.contains(where: { $0.phase != .playing }) { return .seconds(2) }
        return active.isEmpty ? .seconds(15) : .seconds(5)
    }
    private func startLoop() {
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let delay = await self?.interval() else { return }
                do { try await Task.sleep(for: delay) } catch { return }
                await self?.refresh()
            }
        }
    }
    private func interval() -> Duration { Self.pollInterval(history) }
    public func synchronize(_ records: [GameSessionRecord], revision: Int) {
        guard revision >= historyRevision else { return }
        let oldInterval = Self.pollInterval(history)
        historyRevision = revision; history = records
        let active = Set(records.filter { $0.phase.active }.map(\.id))
        tokens = tokens.filter { active.contains($0.key) }
        if loop != nil, oldInterval != Self.pollInterval(records) {
            loop?.cancel()
            startLoop()
        }
    }
    public func register(_ values: [RuntimeProcessToken], for id: UUID) async {
        let verified = await processes.verified(values)
        guard !stopped, history.contains(where: { $0.id == id && $0.phase.active }) else { return }
        tokens[id] = verified
    }
    public func verifiedTokens(for id: UUID) async -> [RuntimeProcessToken] {
        guard history.contains(where: { $0.id == id && $0.phase.active }) else { return [] }
        return await processes.verified(tokens[id] ?? [])
    }
    public func sessions(forPID pid: Int32) -> [UUID] {
        history.filter { $0.phase.active && tokens[$0.id]?.contains(where: { $0.pid == pid }) == true }.map(\.id)
    }
    public func refresh() async {
        guard !stopped, let input, let publish else { return }
        if let poll { await poll.value; return }
        let id = UUID(); operation = id
        let pending = Task {
            guard let snapshot = await input(), !Task.isCancelled else { return }
            guard snapshot.revision >= revision else { return }
            if snapshot.revision > revision { revision = snapshot.revision; tokens = [:] }
            synchronize(snapshot.records, revision: snapshot.historyRevision)
            let results = await observations(snapshot)
            guard !Task.isCancelled, operation == id, snapshot.revision == revision else { return }
            var changes: [SessionChange] = []
            for result in results {
                guard let current = history.first(where: { $0.id == result.before.id }), current == result.before else { continue }
                if let values = result.tokens { tokens[current.id] = values }
                if current != result.after {
                    history[history.firstIndex(where: { $0.id == current.id })!] = result.after
                    if !result.after.phase.active { tokens[current.id] = nil }
                    changes.append(SessionChange(before: current, after: result.after))
                }
            }
            for client in snapshot.clients {
                for gameID in results.discovered[client.platform] ?? [] {
                    guard !history.contains(where: { $0.gameID == gameID && $0.phase.active }),
                          let game = snapshot.library.first(where: { $0.id == gameID }), let installation = game.preferredInstallation else { continue }
                    var record = GameSessionRecord(gameID: game.id, name: game.name, platform: installation.platform,
                        environmentID: installation.platform == .windows ? RuntimeProfile.steamBridgeID : nil)
                    record.observe(running: true); history.append(record)
                    changes.append(SessionChange(before: nil, after: record))
                }
            }
            history = Array(history.suffix(200))
            if !changes.isEmpty || !results.confirmations.isEmpty {
                await publish(SessionUpdate(revision: snapshot.revision, changes: changes, steamConfirmations: results.confirmations))
            }
        }
        poll = pending
        await pending.value
        if operation == id { poll = nil }
    }
    private struct Observation: Sendable {
        let before: GameSessionRecord
        let after: GameSessionRecord
        let tokens: [RuntimeProcessToken]?
    }
    private struct Observations: Sequence, Sendable {
        var values: [Observation] = []
        var discovered: [GamePlatform: [String]] = [:]
        var confirmations: [SteamLaunchConfirmation] = []
        func makeIterator() -> Array<Observation>.Iterator { values.makeIterator() }
    }
    private func observations(_ input: SessionMonitorInput) async -> Observations {
        await withTaskGroup(of: Observations.self, returning: Observations.self) { group in
            for client in input.clients {
                group.addTask {
                    let activity = try? await client.control?.activity()
                    let running = activity?.runningAppIDs
                    let launches = activity?.launches ?? []
                    var result = Observations()
                    let launching = Set(launches.map(\.appID))
                    result.discovered[client.platform] = (running ?? []).filter { !launching.contains($0) }.map { "steam:" + $0 }
                    for record in input.records where record.phase.active && record.gameID.hasPrefix("steam:") {
                        var after = record
                        let isRunning = running.map { $0.contains(String(record.gameID.dropFirst(6))) }
                        let prefix = input.library.first(where: { $0.id == record.gameID })?
                            .installation(for: record.platform)?.steamGame?.bridgePrefix
                        if record.platform == .windows, record.phase != .stopping, let prefix,
                           let failure = await FileService.shared.compatibilityLaunchFailure(prefix: prefix, since: record.requestedAt) {
                            after.phase = record.startedAt == nil ? .failed : .crashed
                            after.endedAt = Date(); after.message = failure
                        } else if let launch = launches.first(where: { "steam:" + $0.appID == record.gameID }), record.phase != .stopping {
                            after.phase = .launching; after.message = launch.message
                            if launch.waitingForUser { result.confirmations.append(SteamLaunchConfirmation(sessionID: record.id, launch: launch)) }
                        } else if isRunning == false, record.startedAt != nil, record.phase != .stopping,
                           let code = await FileService.shared.abnormalGameExit(root: client.root, appID: String(record.gameID.dropFirst(6)), since: record.requestedAt) {
                            after.phase = .crashed; after.endedAt = Date(); after.message = "Steam reported the game exiting with code \(code). See launch diagnostics."
                        } else { after.observe(running: isRunning) }
                        result.values.append(Observation(before: record, after: after, tokens: nil))
                    }
                    return result
                }
            }
            let processes = processes
            group.addTask {
                let records = input.records.filter { $0.phase.active && $0.gameID.hasPrefix("added:") }
                let windows = records.contains(where: { $0.platform == .windows }) && input.prefix != nil ? try? await processes.windowsApps(prefix: input.prefix!) : nil
                var result = Observations()
                for record in records {
                    guard let added = input.added.first(where: { "added:" + $0.id.uuidString == record.gameID }) else { continue }
                    let values: [RuntimeProcessToken]?
                    if record.platform == .macOS {
                        values = await processes.nativeGameProcesses(pids: Array(input.nativeBundles.keys), bundlePaths: input.nativeBundles, location: added.executable)
                    } else if record.environmentID == input.environmentID, let windows {
                        values = await processes.matchingGameProcesses(windows, executable: added.executable)
                    } else { continue }
                    var after = record; after.observe(running: values.map { !$0.isEmpty })
                    result.values.append(Observation(before: record, after: after, tokens: values))
                }
                return result
            }
            var result = Observations()
            for await child in group {
                result.values += child.values; result.confirmations += child.confirmations
                result.discovered.merge(child.discovered) { _, new in new }
            }
            return result
        }
    }
    public func invalidate(revision: Int) {
        guard revision > self.revision else { return }
        self.revision = revision; operation = UUID(); if let poll { retired.append(poll) }; poll?.cancel(); poll = nil; tokens = [:]
    }
    public func stop() async {
        stopped = true
        let tasks = [loop, poll].compactMap { $0 } + retired
        loop?.cancel(); invalidate(revision: revision + 1)
        for task in tasks { await task.value }
        loop = nil; input = nil; publish = nil
    }
}
