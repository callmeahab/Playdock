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
    @Published private(set) var message = "Start Steam to open your session."
    @Published private(set) var rendering = false
    @Published private(set) var error: String?
    let surface = SessionSurfaceView()
    let backend = SteamBackend()
    private let runtimeService = RuntimeService()
    private let runtimeProcesses = RuntimeProcessService()
    var windowArrived: ((SessionWindow) -> Void)?
    var nativeWindowsChanged: (([SessionWindow]) -> Void)?
    private var displayService: NativeDisplayService?
    private var endpoint: NativeDisplayEndpoint?
    private var displayTask: Task<Void, Never>?
    private var displayStop: Task<Void, Never>?
    private var allWindows: [String: SessionWindow] = [:]
    private var prefersSteam = false
    private(set) var prefersChat = false
    private var startup: Task<Void, Never>?
    private var termination: NSObjectProtocol?
    private(set) var steamControlPort: UInt16 = 0
    private var preparationRevision = UUID()
    private var environmentStop: Task<Void, Never>?

    init() {
        termination = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.end() }
        }
    }

    func begin(_ context: SessionContext, expectsWindow: Bool = true) throws {
        try begin(context, expectsWindow: expectsWindow, stoppedEnvironment: false, controlPort: nil)
    }

    func prepare(_ context: SessionContext, controlPort: UInt16? = nil) async throws {
        let initialRevision = preparationRevision
        await environmentStop?.value
        await displayStop?.value
        guard initialRevision == preparationRevision else { throw CancellationError() }
        let profile = context.profile
        let replace = self.context?.profile.id != profile.id || (!profile.reusesExistingSteam && endpoint == nil)
        if replace {
            let previous = self.context?.profile
            end(stoppingEnvironment: false)
            let revision = preparationRevision
            if !profile.reusesExistingSteam || previous?.reusesExistingSteam == false {
                if let previous, !previous.reusesExistingSteam, previous.id != profile.id { try await runtimeService.stopOwnedEnvironment(previous) }
                if !profile.reusesExistingSteam { try await runtimeService.stopOwnedEnvironment(profile) }
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
        let port: UInt16?
        if replace, profile.reusesExistingSteam, controlPort == nil {
            let revision = preparationRevision
            let discovered = await runtimeProcesses.discoverControlPort(profile: profile)
            port = try discovered ?? SteamControlEndpoint.availablePort()
            guard revision == preparationRevision else { throw CancellationError() }
        } else { port = controlPort }
        try Task.checkCancellation()
        if !profile.reusesExistingSteam, endpoint == nil {
            let revision = preparationRevision, service = NativeDisplayService()
            let prepared = try await service.start()
            guard !Task.isCancelled, revision == preparationRevision else { await service.stop(); throw CancellationError() }
            displayService = service; endpoint = prepared
            steamControlPort = try controlPort ?? SteamControlEndpoint.availablePort()
            displayTask = Task { [weak self] in
                for await snapshot in service.snapshots {
                    guard !Task.isCancelled, let self, self.preparationRevision == revision else { return }
                    self.receive(snapshot)
                }
            }
        }
        try begin(context, expectsWindow: false, stoppedEnvironment: true, controlPort: port)
    }

    private func begin(_ context: SessionContext, expectsWindow: Bool, stoppedEnvironment: Bool, controlPort: UInt16?) throws {
        if context.profile.reusesExistingSteam {
            if self.context?.profile.id != context.profile.id {
                end(stoppingEnvironment: !stoppedEnvironment)
                steamControlPort = try controlPort ?? SteamControlEndpoint.availablePort()
            }
            self.context=context; startup?.cancel(); startup=nil
            error=nil; message="Using Steam in \(context.profile.name). Login opens in Steam."; return
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
            self.error = "No Windows window has arrived. Steam may still be updating; check the session log and retry."
        }
    }

    func attach(_ command: LaunchCommand, profile: RuntimeProfile) async throws -> LaunchCommand {
        if profile.reusesExistingSteam {
            var command=command
            if command.arguments.contains(where:{$0.replacingOccurrences(of:"\\",with:"/").lowercased().hasSuffix("/steam.exe")}) {
                command.arguments += ["-devtools-port",String(steamControlPort)]
            }
            return try await backend.attach(command,profile:profile)
        }
        guard let endpoint else {
            throw WayfarerError.message("Wayfarer's native Wine display adapter is missing from this build.")
        }
        let loader = try backend.loader(for: profile.runtime)
        var command = command
        if command.arguments.contains(where: { $0.replacingOccurrences(of:"\\",with:"/").lowercased().hasSuffix("/steam.exe") }) {
            command.arguments += ["-devtools-port",String(steamControlPort)]
        }
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
            selectedWindowID = (prefersSteam ? nil : windows.first(where: { !$0.program.isEmpty && !$0.isSteamClient }))?.id ?? windows.first?.id
        }
        if prefersChat, let chat = windows.first(where: { $0.isSteamClient && ($0.title.localizedCaseInsensitiveContains("friends") || $0.title.localizedCaseInsensitiveContains("chat")) }) { selectedWindowID=chat.id }
        else if prefersSteam, let steam = windows.first(where: { $0.isSteamClient }) { selectedWindowID = steam.id }
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
    func chooseWindow(_ id: String) { prefersSteam = false; prefersChat = false; selectedWindowID = id; updateWindows() }
    func showSteam() { prefersSteam = true; prefersChat = false; updateWindows() }
    func showChat() { prefersSteam = true; prefersChat = true; updateWindows() }
    func retry() { updateWindows() }
    func end(stoppingEnvironment: Bool = true) {
        preparationRevision = UUID()
        startup?.cancel(); startup = nil
        surface.releaseInput(); surface.show(nil, windows: [])
        if stoppingEnvironment, let profile = context?.profile, !profile.reusesExistingSteam {
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
        allWindows.removeAll(); prefersSteam = false; prefersChat = false; windows = []; nativeWindows = []; nativeWindowsChanged?([]); selectedWindowID = nil
        context = nil; rendering = false; error = nil; message = "Start Steam to open your session."
    }
    func finishForTermination() async {
        end()
        await environmentStop?.value
        await displayStop?.value
    }
}
