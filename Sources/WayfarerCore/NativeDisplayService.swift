import Foundation

public struct NativeDisplayEndpoint: Sendable {
    public let socketPath: String
    public let token: String
}
public struct NativeDisplayWindow: Sendable {
    public let peer: NativeDisplayPeer
    public let descriptor: NativeWindowDescriptor
    public let program: String
    public var id: String { "\(peer.id):\(descriptor.id)" }
}
public struct NativeDisplaySnapshot: Sendable {
    public let windows: [NativeDisplayWindow]
    public let error: String?
}

/// Owns session metadata; blocking socket I/O stays on transport queues.
public actor NativeDisplayService {
    private enum Packet: Sendable {
        case message(NativeDisplayPeer, Data)
        case disconnected(NativeDisplayPeer)
    }
    public nonisolated let snapshots: AsyncStream<NativeDisplaySnapshot>
    private let updates: AsyncStream<NativeDisplaySnapshot>.Continuation
    private var server: NativeDisplayServer?
    private var reader: Task<Void, Never>?
    private var windows: [String: NativeDisplayWindow] = [:]
    private var programs: [UUID: String] = [:]
    private var error: String?
    private var stopped = false

    public init() {
        let stream = AsyncStream<NativeDisplaySnapshot>.makeStream(bufferingPolicy: .bufferingNewest(1))
        snapshots = stream.stream; updates = stream.continuation
    }
    public func start() throws -> NativeDisplayEndpoint {
        try Task.checkCancellation()
        guard server == nil, !stopped else { throw WayfarerError.message("This display session has already started or finished.") }
        let server = try NativeDisplayServer()
        let packets = AsyncStream<Packet>.makeStream(bufferingPolicy: .bufferingOldest(512))
        server.receive = { [weak self] peer, value in
            guard let data = try? JSONSerialization.data(withJSONObject: value) else { return }
            if case .dropped = packets.continuation.yield(.message(peer, data)) {
                peer.close()
                Task { await self?.overflow() }
            }
        }
        server.disconnected = { [weak self] peer in
            if case .dropped = packets.continuation.yield(.disconnected(peer)) { Task { await self?.overflow() } }
        }
        self.server = server
        reader = Task {
            for await packet in packets.stream {
                guard !Task.isCancelled else { return }
                receive(packet)
            }
        }
        server.start()
        return NativeDisplayEndpoint(socketPath: server.socketPath, token: server.token)
    }
    private func receive(_ packet: Packet) {
        switch packet {
        case .disconnected(let peer):
            windows = windows.filter { $0.value.peer.id != peer.id }; programs[peer.id] = nil
        case .message(let peer, let data):
            guard let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            if value["type"] as? String == "error" { error = value["message"] as? String }
            else if value["type"] as? String == "closed", let id = value["id"] as? Int { windows["\(peer.id):\(id)"] = nil }
            else if let descriptor = NativeWindowDescriptor(value) {
                if programs[peer.id] == nil { programs[peer.id] = RuntimeProcessIdentity.windowsProgram(for: peer.pid) ?? "" }
                let window = NativeDisplayWindow(peer: peer, descriptor: descriptor, program: programs[peer.id] ?? "")
                guard windows[window.id] != nil || windows.count < 4096 else { peer.close(); return }
                windows[window.id] = window
            } else { return }
        }
        updates.yield(NativeDisplaySnapshot(windows: Array(windows.values), error: error))
    }
    private func overflow() {
        guard !stopped else { return }
        updates.yield(NativeDisplaySnapshot(windows: [], error: "The native display sent too many updates. Reopen its session to reconnect."))
        stop()
    }
    public func stop() {
        stopped = true
        reader?.cancel(); reader = nil
        server?.stop(); server = nil
        windows.removeAll(); programs.removeAll()
        updates.finish()
    }
}
