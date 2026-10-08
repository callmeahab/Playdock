import AppKit
import Combine
import WayfarerCore
import Darwin

struct SessionContext: Identifiable, Equatable {
    var id = UUID()
    var profile: RuntimeProfile
    var title: String
    var launch: RuntimeProcessToken? = nil
}

struct SessionWindow: Identifiable, Equatable {
    let peer: NativeDisplayPeer
    let nativeID: Int
    let contextID: UInt32
    let title: String
    let frame: CGRect
    let visible: Bool
    let focused: Bool
    let order: Double
    let program: String
    let presentsNatively: Bool
    var id: String { "\(peer.id):\(nativeID)" }
    var isSteamClient: Bool { ["steam.exe", "steamwebhelper.exe", "explorer.exe"].contains(program.lowercased()) }
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id && lhs.contextID == rhs.contextID && lhs.title == rhs.title && lhs.frame == rhs.frame &&
        lhs.visible == rhs.visible && lhs.focused == rhs.focused && lhs.order == rhs.order &&
        lhs.program == rhs.program && lhs.presentsNatively == rhs.presentsNatively
    }
}

@MainActor
final class EmbeddedSession: ObservableObject {
    @Published private(set) var context: SessionContext?
    @Published private(set) var windows: [SessionWindow] = []
    @Published private(set) var nativeWindows: [SessionWindow] = []
    @Published private(set) var selectedWindowID: String?
    @Published private(set) var message = "Launch a Windows app to open its session."
    @Published private(set) var rendering = false
    @Published private(set) var error: String?
    let surface = SessionSurfaceView()
    let backend = SteamBackend()
    private let runtimeService = RuntimeService()
    var windowArrived: ((SessionWindow) -> Void)?
    var nativeWindowsChanged: (([SessionWindow]) -> Void)?
    private var displayService: NativeDisplayService?
    private var endpoint: NativeDisplayEndpoint?
    private var displayTask: Task<Void, Never>?
    private var displayStop: Task<Void, Never>?
    private var allWindows: [String: SessionWindow] = [:]
    private var startup: Task<Void, Never>?
    private var termination: NSObjectProtocol?
    private var preparationRevision = UUID()
    private var environmentStop: Task<Void, Never>?
    private var quietPresentation = false
    func setQuietPresentation(_ quiet: Bool) {
        guard quietPresentation != quiet else { return }
        quietPresentation = quiet
        var sent = Set<UUID>()
        for window in windows where sent.insert(window.peer.id).inserted { window.peer.send(["kind": "workload", "quiet": quiet]) }
    }

    init() {
        termination = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.end() }
        }
    }

    func begin(_ context: SessionContext, expectsWindow: Bool = true) throws {
        try begin(context, expectsWindow: expectsWindow, stoppedEnvironment: false)
    }

    func prepare(_ context: SessionContext) async throws {
        let initialRevision = preparationRevision
        await environmentStop?.value
        await displayStop?.value
        guard initialRevision == preparationRevision else { throw CancellationError() }
        let profile = context.profile
        let replace = self.context?.profile.id != profile.id || (!profile.reusesExistingEnvironment && endpoint == nil)
        if replace {
            let previous = self.context?.profile
            end(stoppingEnvironment: false)
            let revision = preparationRevision
            if !profile.reusesExistingEnvironment || previous?.reusesExistingEnvironment == false {
                if let previous, !previous.reusesExistingEnvironment, previous.id != profile.id { try await runtimeService.stopOwnedEnvironment(previous) }
                if !profile.reusesExistingEnvironment { try await runtimeService.stopOwnedEnvironment(profile) }
            }
            guard revision == preparationRevision else { throw CancellationError() }
            try await backend.prepare(runtime: profile.runtime)
            guard revision == preparationRevision else { throw CancellationError() }
        } else {
            let revision = preparationRevision
            try await backend.prepare(runtime: profile.runtime)
            guard revision == preparationRevision else { throw CancellationError() }
        }
        try Task.checkCancellation()
        if !profile.reusesExistingEnvironment, endpoint == nil {
            let revision = preparationRevision, service = NativeDisplayService()
            let prepared = try await service.start()
            guard !Task.isCancelled, revision == preparationRevision else { await service.stop(); throw CancellationError() }
            displayService = service; endpoint = prepared
            displayTask = Task { [weak self] in
                for await snapshot in service.snapshots {
                    guard !Task.isCancelled, let self, self.preparationRevision == revision else { return }
                    self.receive(snapshot)
                }
            }
        }
        try begin(context, expectsWindow: false, stoppedEnvironment: true)
    }

    private func begin(_ context: SessionContext, expectsWindow: Bool, stoppedEnvironment: Bool) throws {
        if context.profile.reusesExistingEnvironment {
            if self.context?.profile.id != context.profile.id {
                end(stoppingEnvironment: !stoppedEnvironment)
            }
            self.context=context; startup?.cancel(); startup=nil
            error=nil; message="Using \(context.profile.name). Apps open in their own windows."; return
        }
        guard stoppedEnvironment || self.context?.profile.id == context.profile.id, endpoint != nil else {
            throw WayfarerError.message("Prepare the Windows session before opening it.")
        }
        self.context = context
        error = nil
        if !rendering { message = "Starting \(context.title)…" }
        startup?.cancel()
        guard expectsWindow else { startup = nil; return }
        startup = Task { [weak self] in
            try? await Task.sleep(for: .seconds(60))
            guard !Task.isCancelled, let self, !self.rendering else { return }
            self.message = "Waiting for the Windows runtime…"
            self.error = "No Windows window has arrived. Check the session log and retry."
        }
    }

    func attach(_ command: LaunchCommand, profile: RuntimeProfile) async throws -> LaunchCommand {
        if profile.reusesExistingEnvironment { return command }
        guard let endpoint else {
            throw WayfarerError.message("Wayfarer's native Wine display adapter is missing from this build.")
        }
        let loader = try backend.loader(for: profile.runtime)
        var command = command
        command.environment["WAYFARER_GAME_PRESENTATION"] = "native"
        return try await RuntimePreparationService.shared.attachDisplay(command, runtime: profile.runtime, loader: loader, adapter: backend.adapter(), endpoint: endpoint)
    }

    private func receive(_ snapshot: NativeDisplaySnapshot) {
        guard endpoint != nil else { return }
        let previous = allWindows
        allWindows = Dictionary(uniqueKeysWithValues: snapshot.windows.map { item in
            let descriptor = item.descriptor
            let window = SessionWindow(peer: item.peer, nativeID: descriptor.id, contextID: descriptor.contextID,
                                       title: descriptor.title, frame: descriptor.frame, visible: descriptor.visible,
                                       focused: descriptor.focused, order: descriptor.order, program: item.program,
                                       presentsNatively: descriptor.presentation == .native)
            return (window.id, window)
        })
        if let message = snapshot.error { error = message }
        updateWindows()
        if quietPresentation {
            for item in allWindows.values where !item.presentsNatively && previous[item.id] == nil {
                item.peer.send(["kind": "workload", "quiet": true])
            }
        }
        for item in allWindows.values where item.visible && previous[item.id]?.visible != true && item.frame.width > 20 && item.frame.height > 20 {
            windowArrived?(item)
        }
    }
    private func updateWindows() {
        let visible = allWindows.values.filter { $0.visible && $0.frame.width > 20 && $0.frame.height > 20 }.sorted {
            $0.frame.width * $0.frame.height > $1.frame.width * $1.frame.height
        }
        let embedded = visible.filter { !$0.presentsNatively }, native = visible.filter { $0.presentsNatively }
        if windows != embedded { windows = embedded }
        if nativeWindows != native { nativeWindows = native; nativeWindowsChanged?(native) }
        if !windows.contains(where: { $0.id == selectedWindowID }) {
            selectedWindowID = windows.first(where: { !$0.program.isEmpty && !$0.isSteamClient })?.id ?? windows.first?.id
        }
        let selected = windows.first { $0.id == selectedWindowID }
        surface.show(selected, windows: windows)
        if rendering != (selected != nil) { rendering = selected != nil }
        if rendering { error = nil; message = "\(selected!.title)"; startup?.cancel() }
    }
    func activateNativeWindow(_ id: String) {
        guard let window = nativeWindows.first(where: { $0.id == id }) else { return }
        surface.releaseInput()
        window.peer.send(["kind": "activate", "id": window.nativeID])
    }
    func chooseWindow(_ id: String) { selectedWindowID = id; updateWindows() }
    func retry() { updateWindows() }
    func end(stoppingEnvironment: Bool = true) {
        preparationRevision = UUID()
        startup?.cancel(); startup = nil
        surface.releaseInput(); surface.show(nil, windows: [])
        if stoppingEnvironment, let profile = context?.profile, !profile.reusesExistingEnvironment {
            let previous = environmentStop
            environmentStop = Task {
                await previous?.value
                try? await runtimeService.stopOwnedEnvironment(profile)
            }
        }
        displayTask?.cancel(); displayTask = nil
        if let service = displayService {
            let previous = displayStop
            displayStop = Task { await previous?.value; await service.stop() }
        }
        displayService = nil; endpoint = nil
        allWindows.removeAll(); windows = []; nativeWindows = []; nativeWindowsChanged?([]); selectedWindowID = nil
        context = nil; rendering = false; error = nil; message = "Launch a Windows app to open its session."
    }
    func finishForTermination() async {
        end()
        await environmentStop?.value
        await displayStop?.value
    }
}
