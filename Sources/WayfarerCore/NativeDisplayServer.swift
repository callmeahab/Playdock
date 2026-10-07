import Foundation
import Darwin
import Security

// Locks protect descriptor lifetime; blocking socket I/O uses dedicated queues.
public final class NativeDisplayPeer: @unchecked Sendable {
    public let id = UUID()
    public let pid: pid_t
    let fd: Int32
    private let queue = DispatchQueue(label: "app.wayfarer.display.send")
    private let lock = NSLock()
    private var closed = false
    init(fd: Int32, pid: pid_t) { self.fd = fd; self.pid = pid }
    public func send(_ value: [String: Any]) {
        guard var data = try? JSONSerialization.data(withJSONObject: value), data.count <= 65536 else { return }
        data.append(10)
        let frame = data
        queue.async { [self] in
            lock.lock(); defer { lock.unlock() }
            guard !closed else { return }
            frame.withUnsafeBytes { raw in
                var offset = 0
                while offset < raw.count {
                    let written = Darwin.send(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset, 0)
                    if written <= 0 { break }
                    offset += written
                }
            }
        }
    }
    func close() {
        lock.lock(); defer { lock.unlock() }
        guard !closed else { return }; closed = true
        shutdown(fd, SHUT_RDWR); Darwin.close(fd)
    }
}

/// Authenticated metadata/input socket. Configure callbacks before start(); locks protect listener/peer state.
public final class NativeDisplayServer: @unchecked Sendable {
    public let directory: URL
    public let socketPath: String
    public let token: String
    private let listener: Int32
    private let lock = NSLock()
    private var stopped = false
    private var accepted = 0
    private var peers: [UUID: NativeDisplayPeer] = [:]
    public var receive: (@Sendable (NativeDisplayPeer, [String: Any]) -> Void)?
    public var disconnected: (@Sendable (NativeDisplayPeer) -> Void)?

    public init() throws {
        directory = URL(fileURLWithPath: "/private/tmp/wf-\(UUID().uuidString.prefix(12))")
        socketPath = directory.appendingPathComponent("display.sock").path
        var random = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, random.count, &random) == errSecSuccess else { throw CocoaError(.fileWriteUnknown) }
        token = random.map { String(format: "%02x", $0) }.joined()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        listener = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard listener >= 0 else { try? FileManager.default.removeItem(at: directory); throw CocoaError(.fileWriteUnknown) }
        var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let bytes = Array(socketPath.utf8) + [0]
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        let success = withUnsafePointer(to: &address) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard success == 0, Darwin.listen(listener, 16) == 0 else {
            Darwin.close(listener); try? FileManager.default.removeItem(at: directory); throw CocoaError(.fileWriteUnknown)
        }
        chmod(socketPath, 0o600)
    }

    public func start() {
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            while true {
                let fd = Darwin.accept(listener, nil, nil)
                if fd < 0 { break }
                lock.lock(); let reject = stopped || accepted >= 64; if !reject { accepted += 1 }; lock.unlock()
                if reject { Darwin.close(fd); continue }
                DispatchQueue.global(qos: .userInitiated).async { [self] in read(fd) }
            }
        }
    }
    private func read(_ fd: Int32) {
        defer { lock.lock(); accepted -= 1; lock.unlock() }
        var uid: uid_t = 0, gid: gid_t = 0, pid: pid_t = 0
        var length = socklen_t(MemoryLayout<pid_t>.size)
        guard getpeereid(fd, &uid, &gid) == 0, uid == geteuid(),
              getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &pid, &length) == 0, pid > 0 else { Darwin.close(fd); return }
        var noSIGPIPE: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSIGPIPE, socklen_t(MemoryLayout<Int32>.size))
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        timeout.tv_sec = 1
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        let peer = NativeDisplayPeer(fd: fd, pid: pid)
        lock.lock(); let reject = stopped; if !reject { peers[peer.id] = peer }; lock.unlock()
        if reject { peer.close(); return }
        defer {
            peer.close()
            lock.lock(); peers.removeValue(forKey: peer.id); lock.unlock()
            disconnected?(peer)
        }
        var authenticated = false, buffer = Data(), bytes = [UInt8](repeating: 0, count: 8192)
        while true {
            let count = Darwin.recv(fd, &bytes, bytes.count, 0)
            if count <= 0 { return }
            buffer.append(contentsOf: bytes.prefix(count))
            if buffer.count > 65536 { return }
            while let newline = buffer.firstIndex(of: 10) {
                let frame = buffer[..<newline]; buffer.removeSubrange(...newline)
                guard let value = try? JSONSerialization.jsonObject(with: frame) as? [String: Any] else { return }
                if !authenticated {
                    guard value["type"] as? String == "hello", value["version"] as? Int == 1,
                          value["token"] as? String == token, value["pid"] as? Int == Int(pid) else { return }
                    authenticated = true
                    peer.send(["type": "ready", "version": 1])
                    var infinite = timeval(tv_sec: 0, tv_usec: 0)
                    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &infinite, socklen_t(MemoryLayout<timeval>.size))
                } else { receive?(peer, value) }
            }
        }
    }
    public func stop() {
        lock.lock(); if stopped { lock.unlock(); return }
        stopped = true; let active = Array(peers.values); lock.unlock()
        shutdown(listener, SHUT_RDWR); Darwin.close(listener)
        active.forEach { $0.close() }
        try? FileManager.default.removeItem(at: directory)
    }
}
