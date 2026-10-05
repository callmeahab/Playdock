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

struct SessionWindow: Identifiable {
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
    var windowArrived: ((SessionWindow) -> Void)?
    var nativeWindowsChanged: (([SessionWindow]) -> Void)?
    private var server: NativeDisplayServer?
    private var allWindows: [String: SessionWindow] = [:]
    private var peerPrograms: [UUID: String] = [:]
    private var prefersSteam = false
    private(set) var prefersChat = false
    private var startup: Task<Void, Never>?
    private var termination: NSObjectProtocol?
    private(set) var steamControlPort: UInt16 = 0

    init() {
        termination = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.end() }
        }
    }

    func begin(_ context: SessionContext, expectsWindow: Bool = true) throws {
        if context.profile.reusesExistingSteam {
            if self.context?.profile.id != context.profile.id {
                end()
                steamControlPort=try context.profile.steamExecutable.flatMap { SteamControlEndpoint.runningWindowsPort(root:$0.deletingLastPathComponent(),prefix:context.profile.prefix) } ?? SteamControlEndpoint.availablePort()
            }
            self.context=context; startup?.cancel(); startup=nil
            error=nil; message="Using Steam in \(context.profile.name). Login opens in Steam."; return
        }
        if self.context?.profile.id != context.profile.id || server == nil {
            end()
            try NativeRuntime.stopOwnedEnvironment(context.profile)
            let service = try NativeDisplayServer()
            steamControlPort = try SteamControlEndpoint.availablePort()
            service.receive = { [weak self] peer, value in
                DispatchQueue.main.async { self?.receive(peer, value) }
            }
            service.disconnected = { [weak self] peer in
                DispatchQueue.main.async { self?.remove(peer) }
            }
            server = service; service.start()
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

    func attach(_ command: LaunchCommand, profile: RuntimeProfile) throws -> LaunchCommand {
        if profile.reusesExistingSteam {
            var command=command
            if command.arguments.contains(where:{$0.replacingOccurrences(of:"\\",with:"/").lowercased().hasSuffix("/steam.exe")}) {
                command.arguments += ["-devtools-port",String(steamControlPort)]
            }
            return try backend.attach(command,profile:profile)
        }
        guard let server, let adapter = Bundle.main.privateFrameworksURL?.appendingPathComponent("libWayfarerWineDisplay.dylib"),
              FileManager.default.fileExists(atPath: adapter.path) else {
            throw WayfarerError.message("Wayfarer's native Wine display adapter is missing from this build.")
        }
        let loader = try NativeRuntime.prepare(runtime: profile.runtime)
        var command = command
        if command.arguments.contains(where: { $0.replacingOccurrences(of:"\\",with:"/").lowercased().hasSuffix("/steam.exe") }) {
            command.arguments += ["-devtools-port",String(steamControlPort)]
        }
        command.environment["WAYFARER_GAME_PRESENTATION"] = "native"
        return try NativeRuntime.attach(command, runtime: profile.runtime, loader: loader, adapter: NativeRuntime.prepareAdapter(source:adapter), socket: server.socketPath, token: server.token)
    }

    private func receive(_ peer: NativeDisplayPeer, _ value: [String: Any]) {
        guard server != nil else { return }
        if value["type"] as? String == "error" { error = value["message"] as? String; return }
        if value["type"] as? String == "closed", let id = value["id"] as? Int { allWindows.removeValue(forKey: "\(peer.id):\(id)"); updateWindows(); return }
        guard let descriptor = NativeWindowDescriptor(value) else { return }
        if peerPrograms[peer.id] == nil { peerPrograms[peer.id] = RuntimeProcessIdentity.windowsProgram(for: peer.pid) ?? "" }
        let item = SessionWindow(peer: peer, nativeID: descriptor.id, contextID: descriptor.contextID,
            title: descriptor.title, frame: descriptor.frame,
            visible: descriptor.visible, focused: descriptor.focused, order: descriptor.order,
            program: peerPrograms[peer.id] ?? "", presentsNatively: descriptor.presentation == .native)
        let newlyVisible = item.visible && allWindows[item.id]?.visible != true
        allWindows[item.id] = item
        updateWindows()
        if newlyVisible, item.frame.width > 20, item.frame.height > 20 { windowArrived?(item) }
    }
    private func remove(_ peer: NativeDisplayPeer) {
        allWindows = allWindows.filter { $0.value.peer.id != peer.id }; peerPrograms.removeValue(forKey: peer.id); updateWindows()
    }
    private func updateWindows() {
        let visible = allWindows.values.filter { $0.visible && $0.frame.width > 20 && $0.frame.height > 20 }.sorted {
            $0.frame.width * $0.frame.height > $1.frame.width * $1.frame.height
        }
        windows = visible.filter { !$0.presentsNatively }
        nativeWindows = visible.filter { $0.presentsNatively }
        nativeWindowsChanged?(nativeWindows)
        if !windows.contains(where: { $0.id == selectedWindowID }) {
            selectedWindowID = (prefersSteam ? nil : windows.first(where: { !$0.program.isEmpty && !$0.isSteamClient }))?.id ?? windows.first?.id
        }
        if prefersChat, let chat = windows.first(where: { $0.isSteamClient && ($0.title.localizedCaseInsensitiveContains("friends") || $0.title.localizedCaseInsensitiveContains("chat")) }) { selectedWindowID=chat.id }
        else if prefersSteam, let steam = windows.first(where: { $0.isSteamClient }) { selectedWindowID = steam.id }
        let selected = windows.first { $0.id == selectedWindowID }
        surface.show(selected, windows: windows)
        rendering = selected != nil
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
    func end() {
        startup?.cancel(); startup = nil
        surface.releaseInput(); surface.show(nil, windows: [])
        if let profile = context?.profile, !profile.reusesExistingSteam { try? NativeRuntime.stopOwnedEnvironment(profile) }
        server?.stop(); server = nil
        allWindows.removeAll(); peerPrograms.removeAll(); prefersSteam = false; prefersChat = false; windows = []; nativeWindows = []; nativeWindowsChanged?([]); selectedWindowID = nil
        context = nil; rendering = false; error = nil; message = "Start Steam to open your session."
    }
}
