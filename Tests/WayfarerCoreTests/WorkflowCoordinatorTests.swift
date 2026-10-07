import XCTest
@testable import WayfarerCore

private actor WorkflowGate {
    let entered: XCTestExpectation
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    init(_ entered: XCTestExpectation) { self.entered = entered }
    // Deliberately ignores task cancellation, like a response already in flight.
    func wait() async {
        entered.fulfill()
        guard !released else { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func release() { released = true; for waiter in waiters { waiter.resume() }; waiters = [] }
}

private actor WorkflowControl: SteamWorkflowControl {
    let snapshotGate: WorkflowGate?
    let prepareGate: WorkflowGate?
    let runningGate: WorkflowGate?
    let maintenanceGate: WorkflowGate?
    let enabledGate: WorkflowGate?
    var calls: [String] = []
    var snapshots = 0
    var failSecondSnapshot = false
    var paused = false
    var running: [String] = []
    init(snapshotGate: WorkflowGate? = nil, prepareGate: WorkflowGate? = nil,
         runningGate: WorkflowGate? = nil, maintenanceGate: WorkflowGate? = nil,
         enabledGate: WorkflowGate? = nil,
         failSecondSnapshot: Bool = false, paused: Bool = false) {
        self.snapshotGate = snapshotGate; self.prepareGate = prepareGate; self.runningGate = runningGate
        self.maintenanceGate = maintenanceGate; self.failSecondSnapshot = failSecondSnapshot; self.paused = paused
        self.enabledGate = enabledGate
    }
    func snapshot() async throws -> SteamControlSnapshot {
        snapshots += 1; calls.append("snapshot")
        if snapshots == 1 { await snapshotGate?.wait() }
        if failSecondSnapshot, snapshots == 2 { throw WayfarerError.message("Delayed snapshot failed") }
        return SteamControlSnapshot(mode: .online, folders: [], downloads: [
            SteamLiveDownload(appID: "100", name: "Game", paused: paused, active: !paused, downloaded: 0, total: 100,
                updateState: nil, phaseDownloaded: nil, phaseTotal: nil, networkBytesPerSecond: nil, diskBytesPerSecond: nil, secondsRemaining: nil)
        ], downloadsPaused: paused)
    }
    func plan(_ appID: String) -> SteamInstallPlan {
        SteamInstallPlan(appID: appID, state: 7, requiredBytes: 1, availableBytes: 100, folder: 0,
            currentAppID: UInt32(appID)!, error: 0, detail: "", eulas: [])
    }
    func prepareInstall(appID: String) async throws -> SteamInstallPlan {
        calls.append("prepare:\(appID)")
        if appID == "100" { await prepareGate?.wait() }
        return plan(appID)
    }
    func chooseFolder(appID: String, folder: Int) async throws -> SteamInstallPlan { calls.append("folder:\(appID)"); return plan(appID) }
    func continueInstall(appID: String, agreements: [SteamGameEULA]) async throws -> SteamInstallPlan { calls.append("confirm:\(appID)"); return plan(appID) }
    func cancelInstall(appID: String) async throws { calls.append("cancel:\(appID)") }
    func changeMode(offline: Bool) async throws { calls.append("mode") }
    func enableDownloads(_ enabled: Bool) async throws {
        paused = !enabled; calls.append("enabled:\(enabled)")
        if calls.filter({ $0.hasPrefix("enabled:") }).count == 1 { await enabledGate?.wait() }
    }
    func pause(appID: String, paused: Bool) async throws { calls.append("pause:\(appID)") }
    func applyDownloadPolicy(_ policy: DownloadPolicy) async throws { calls.append("policy") }
    func prioritize(appID: String, index: Int) async throws { calls.append("priority:\(appID)") }
    func moveGame(appID: String, folder: Int) async throws { calls.append("move:\(appID)") }
    func verifyFiles(appID: String) async throws { calls.append("verify:\(appID)") }
    func maintenanceProgress(appID: String) async throws -> SteamMaintenanceProgress {
        await maintenanceGate?.wait()
        return SteamMaintenanceProgress(kind: "verify", progress: 1, task: "Done", completed: true, failed: false)
    }
    func appState(appID: String) async throws -> SteamAppState { SteamAppState(appID: appID, installed: true, owned: true, displayStatus: 0) }
    func uninstall(appID: String) async throws { calls.append("uninstall:\(appID)") }
    func runningAppIDs() async throws -> [String] { calls.append("running"); await runningGate?.wait(); return running }
}

private actor WorkflowEvents {
    var installs: [String] = []
    var downloads: [Bool] = []
    var backend = 0
    var sessions = 0
    var social = 0
    var maintenance = 0
    func install(_ event: InstallationEvent) {
        if case .prepared(let plan, _) = event { installs.append(plan?.appID ?? "error") }
    }
    func download(_ event: DownloadEvent) { if case .state(_, let owned) = event { downloads.append(owned) } }
    func connection(_ event: BackendEvent) { if case .connected = event { backend += 1 } }
    func session(_ update: SessionUpdate) { sessions += update.changes.count }
    func friend(_ update: SocialUpdate) { social += 1 }
    func progress(_ update: SteamMaintenanceProgress) { maintenance += 1 }
}

@MainActor final class WorkflowCoordinatorTests: XCTestCase {
    func testSlowBackendCannotDelayOtherClientAndInvalidatedReplyIsIgnored() async {
        let entered = expectation(description: "slow request entered"), ready = expectation(description: "other client ready")
        let gate = WorkflowGate(entered), events = WorkflowEvents()
        let slow = BackendCoordinator(), fast = BackendCoordinator()
        let slowControl = WorkflowControl(snapshotGate: gate), fastControl = WorkflowControl()
        await slow.refresh(revision: 0, resolve: { slowControl }, publish: { await events.connection($0) })
        await fulfillment(of: [entered], timeout: 2)
        await fast.refresh(revision: 0, resolve: { fastControl }, publish: { event in
            await events.connection(event); if case .connected = event { ready.fulfill() }
        })
        await fulfillment(of: [ready], timeout: 2)
        await slow.invalidate(revision: 1)
        await gate.release(); await slow.stop(); await fast.stop()
        let count = await events.backend
        XCTAssertEqual(count, 1)
    }
    func testCancelWaitsForLateWizardBeforePreparingNextGame() async {
        let entered = expectation(description: "wizard pending"), ready = expectation(description: "next wizard ready")
        let gate = WorkflowGate(entered), control = WorkflowControl(prepareGate: gate), events = WorkflowEvents(), worker = InstallCoordinator()
        await worker.prepare(revision: 1, requestID: UUID(), appID: "100", resolve: { control }, publish: { await events.install($0) })
        await fulfillment(of: [entered], timeout: 2)
        await worker.cancel(revision: 2, appID: "100", control: control)
        await worker.prepare(revision: 3, requestID: UUID(), appID: "200", resolve: { control }, publish: { event in
            await events.install(event); if case .prepared = event { ready.fulfill() }
        })
        await gate.release()
        await fulfillment(of: [ready], timeout: 2)
        await worker.stop()
        let published = await events.installs, calls = await control.calls
        XCTAssertEqual(published, ["200"])
        XCTAssertLessThan(calls.firstIndex(of: "cancel:100")!, calls.firstIndex(of: "prepare:200")!)
    }
    func testCancelArrivingBeforePrepareRejectsTheOlderCommand() async {
        let worker = InstallCoordinator(), events = WorkflowEvents(), control = WorkflowControl()
        await worker.cancel(revision: 2, appID: nil, control: nil)
        await worker.prepare(revision: 1, requestID: UUID(), appID: "100", resolve: { control }, publish: { await events.install($0) })
        await worker.stop()
        let calls = await control.calls, published = await events.installs
        XCTAssertTrue(calls.isEmpty); XCTAssertTrue(published.isEmpty)
    }
    func testClosingUninstallBeforeTheActionPreventsDeletion() async {
        let entered = expectation(description: "uninstall confirmation pending")
        let gate = WorkflowGate(entered), worker = InstallCoordinator(), control = WorkflowControl()
        await worker.uninstall(revision: 1, requestID: UUID(), appID: "100", resolve: { control }, publish: { event in
            if case .starting = event { await gate.wait() }
        })
        await fulfillment(of: [entered], timeout: 2)
        await worker.cancel(revision: 2, appID: nil, control: nil)
        await gate.release(); await worker.stop()
        let calls = await control.calls
        XCTAssertFalse(calls.contains("uninstall:100")); XCTAssertFalse(calls.contains("cancel:100"))
    }
    func testDelayedInvalidationCannotCancelWorkAlreadyStartedInThatRevision() async {
        let entered = expectation(description: "new scope pending"), ready = expectation(description: "new scope ready")
        let gate = WorkflowGate(entered), worker = BackendCoordinator(), control = WorkflowControl(snapshotGate: gate)
        await worker.refresh(revision: 1, resolve: { control }, publish: { event in
            if case .connected = event { ready.fulfill() }
        })
        await fulfillment(of: [entered], timeout: 2)
        await worker.invalidate(revision: 1)
        await gate.release()
        await fulfillment(of: [ready], timeout: 2); await worker.stop()
    }
    func testScheduleOwnershipSurvivesFailureOfTheFollowingSnapshot() async {
        let finished = expectation(description: "schedule finished")
        let worker = DownloadScheduler(), events = WorkflowEvents(), control = WorkflowControl(failSecondSnapshot: true)
        var policy = DownloadPolicy(); policy.enabled = true
        let hour = Calendar.current.component(.hour, from: Date())
        policy.startHour = (hour + 1) % 24; policy.endHour = (hour + 2) % 24
        await worker.submit(.enforce, scope: "account", revision: 0, policy: policy, ownedPause: false, control: control, publish: { event in
            await events.download(event); if case .finished = event { finished.fulfill() }
        })
        await fulfillment(of: [finished], timeout: 2)
        await worker.stop()
        let states = await events.downloads, calls = await control.calls
        XCTAssertEqual(states, [true]); XCTAssertTrue(calls.contains("enabled:false"))
        let saved = await worker.stateSnapshot()
        XCTAssertEqual(saved?.scope, "account"); XCTAssertEqual(saved?.ownedPause, true)
    }
    func testCompletedPauseKeepsOwnershipWhenSupersededByAnotherQueueAction() async {
        let entered = expectation(description: "pause pending"), finished = expectation(description: "manual queue finished")
        let gate = WorkflowGate(entered), worker = DownloadScheduler(), events = WorkflowEvents(), control = WorkflowControl(enabledGate: gate)
        var policy = DownloadPolicy(); policy.enabled = true
        let hour = Calendar.current.component(.hour, from: Date())
        policy.startHour = (hour + 1) % 24; policy.endHour = (hour + 2) % 24
        await worker.submit(.enforce, scope: "account", revision: 0, policy: policy, ownedPause: false, control: control, publish: { await events.download($0) })
        await fulfillment(of: [entered], timeout: 2)
        await worker.submit(.pause("100", true), scope: "account", revision: 0, policy: policy, ownedPause: false, control: control, publish: { event in
            await events.download(event); if case .finished = event { finished.fulfill() }
        })
        await gate.release()
        await fulfillment(of: [finished], timeout: 2); await worker.stop()
        let states = await events.downloads
        XCTAssertEqual(states, [true])
    }
    func testManualPauseReleasesScheduleOwnershipAndDoesNotAutoResume() async {
        let first = expectation(description: "manual finished"), second = expectation(description: "schedule finished")
        let worker = DownloadScheduler(), events = WorkflowEvents(), control = WorkflowControl(paused: true)
        await worker.submit(.enabled(false), scope: "account", revision: 0, policy: DownloadPolicy(), ownedPause: true, control: control, publish: { event in
            await events.download(event); if case .finished = event { first.fulfill() }
        })
        await fulfillment(of: [first], timeout: 2)
        await worker.submit(.enforce, scope: "account", revision: 0, policy: DownloadPolicy(), ownedPause: true, control: control, publish: { event in
            await events.download(event); if case .finished = event { second.fulfill() }
        })
        await fulfillment(of: [second], timeout: 2)
        await worker.stop()
        let calls = await control.calls
        XCTAssertFalse(calls.contains("enabled:true"))
        let states = await events.downloads
        XCTAssertTrue(states.allSatisfy { !$0 })
    }
    func testMissingQueueEntryStillFinishesTheManualOperation() async {
        let finished = expectation(description: "priority finished"), worker = DownloadScheduler(), control = WorkflowControl()
        await worker.submit(.prioritize("missing", toTop: true), scope: "account", revision: 0, policy: DownloadPolicy(), ownedPause: false, control: control, publish: { event in
            if case .finished = event { finished.fulfill() }
        })
        await fulfillment(of: [finished], timeout: 2); await worker.stop()
    }
    func testLateSessionObservationCannotOverwriteAStopRequest() async {
        let entered = expectation(description: "session query entered")
        let gate = WorkflowGate(entered), control = WorkflowControl(runningGate: gate), worker = SessionMonitor(), events = WorkflowEvents()
        var record = GameSessionRecord(gameID: "steam:100", name: "Game", platform: .macOS, environmentID: nil)
        record.observe(running: true)
        let original = record
        let input = SessionMonitorInput(revision: 0, historyRevision: 1, records: [original],
            clients: [SessionClientInput(platform: .macOS, root: URL(fileURLWithPath: "/missing"), control: control)],
            library: [], added: [], environmentID: nil, prefix: nil, nativeBundles: [:])
        await worker.start(input: { input }, publish: { await events.session($0) })
        let poll = Task { await worker.refresh() }
        await fulfillment(of: [entered], timeout: 2)
        record.phase = .stopping
        await worker.synchronize([record], revision: 2)
        await gate.release(); await poll.value; await worker.stop()
        let changes = await events.sessions
        XCTAssertEqual(changes, 0)
    }
    func testUnreadBaselinesAreAccountScopedAndIgnoreUnreadySnapshots() async {
        let worker = SocialCoordinator()
        func snapshot(_ unread: Int) -> SteamFriendsSnapshot {
            SteamFriendsSnapshot(ready: true, friends: [SteamFriend(id: "friend", name: "Friend", state: 1, game: "", unread: unread)])
        }
        let initial = await worker.ingest(snapshot(0), scope: "first")
        let unready = await worker.ingest(SteamFriendsSnapshot(ready: false, friends: []), scope: "first")
        let increased = await worker.ingest(snapshot(1), scope: "first")
        let changed = await worker.ingest(snapshot(9), scope: "second")
        XCTAssertTrue(initial.isEmpty); XCTAssertTrue(unready.isEmpty)
        XCTAssertEqual(increased.map(\.id), ["friend"]); XCTAssertTrue(changed.isEmpty)
        await worker.stop()
    }
    func testInvalidatedSocialAndMaintenanceRepliesCannotPublish() async {
        let socialEntered = expectation(description: "friends pending"), maintenanceEntered = expectation(description: "maintenance pending")
        let socialGate = WorkflowGate(socialEntered), maintenanceGate = WorkflowGate(maintenanceEntered), events = WorkflowEvents()
        let social = SocialCoordinator(), maintenance = MaintenanceCoordinator(), control = WorkflowControl(maintenanceGate: maintenanceGate)
        await social.refresh(scope: "first", revision: 0, mode: .online, fetch: {
            await socialGate.wait(); return SteamFriendsSnapshot(ready: true, friends: [])
        }, publish: { await events.friend($0) })
        await maintenance.start(key: "game", appID: "100", folder: nil, revision: 0, control: control, publish: { await events.progress($0) })
        await fulfillment(of: [socialEntered, maintenanceEntered], timeout: 2)
        await social.invalidate(revision: 1); await maintenance.invalidate(revision: 1)
        await socialGate.release(); await maintenanceGate.release()
        await social.stop(); await maintenance.stop()
        let friends = await events.social, progress = await events.maintenance
        XCTAssertEqual(friends, 0); XCTAssertEqual(progress, 0)
    }
}
