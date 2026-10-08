import AppKit
import PlaydockCore
import PlaydockPresentation
import Darwin

struct SessionContext: Identifiable, Equatable {
    var id = UUID()
    var profile: RuntimeProfile
    var title: String
    var launch: RuntimeProcessToken? = nil
}

@MainActor
final class NativeSession {
    private(set) var context: SessionContext?
    private(set) var nativeWindows: [SessionWindow] = []
    let backend = SteamBackend()
    private let runtimeService = RuntimeService()
    var windowArrived: ((SessionWindow) -> Void)?
    var nativeWindowsChanged: (([SessionWindow]) -> Void)?
    private var displayService: NativeDisplayService?
    private var endpoint: NativeDisplayEndpoint?
    private var displayTask: Task<Void, Never>?
    private var displayStop: Task<Void, Never>?
    private var allWindows: [String: SessionWindow] = [:]
    private var preparationRevision = UUID()
    private var environmentStop: Task<Void, Never>?
    func begin(_ context: SessionContext) throws {
        guard self.context?.profile.id == context.profile.id,
              context.profile.reusesExistingEnvironment || endpoint != nil else {
            throw PlaydockError.message("Prepare the Windows session before opening it.")
        }
        self.context = context
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
        self.context = context
    }

    func attach(_ command: LaunchCommand, profile: RuntimeProfile) async throws -> LaunchCommand {
        if profile.reusesExistingEnvironment { return command }
        guard let endpoint else {
            throw PlaydockError.message("Playdock's native Wine display adapter is missing from this build.")
        }
        let loader = try backend.loader(for: profile.runtime)
        var command = command
        command.environment["PLAYDOCK_GAME_PRESENTATION"] = "native"
        return try await RuntimePreparationService.shared.attachDisplay(command, runtime: profile.runtime, loader: loader, adapter: backend.adapter(), endpoint: endpoint)
    }

    private func receive(_ snapshot: NativeDisplaySnapshot) {
        guard endpoint != nil else { return }
        let previous = allWindows
        allWindows = Dictionary(uniqueKeysWithValues: snapshot.windows.map { item in
            let descriptor = item.descriptor
            let window = SessionWindow(peer: item.peer, nativeID: descriptor.id, title: descriptor.title, frame: descriptor.frame, visible: descriptor.visible,
                                       focused: descriptor.focused, order: descriptor.order, program: item.program)
            return (window.id, window)
        })
        updateWindows()
        for item in allWindows.values where item.visible && previous[item.id]?.visible != true && item.frame.width > 20 && item.frame.height > 20 {
            windowArrived?(item)
        }
    }
    private func updateWindows() {
        let visible = allWindows.values.filter { $0.visible && $0.frame.width > 20 && $0.frame.height > 20 }.sorted {
            $0.frame.width * $0.frame.height > $1.frame.width * $1.frame.height
        }
        if nativeWindows != visible { nativeWindows = visible; nativeWindowsChanged?(visible) }
    }
    func activateNativeWindow(_ id: String) {
        guard let window = nativeWindows.first(where: { $0.id == id }) else { return }
        window.peer.send(["kind": "activate", "id": window.nativeID])
    }
    func end(stoppingEnvironment: Bool = true) {
        preparationRevision = UUID()
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
        allWindows.removeAll(); nativeWindows = []; nativeWindowsChanged?([])
        context = nil
    }
    func finishForTermination() async {
        end()
        await environmentStop?.value
        await displayStop?.value
    }
}
