import XCTest
import Darwin
@testable import WayfarerCore

final class NativeDisplayTests: XCTestCase {
    func testProviderLayoutResolvesCrossOverBinSymlinkAndCopiesServer() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: root) }
        let provider = root.appendingPathComponent("Engine")
        let programs = provider.appendingPathComponent("CrossOver-Hosted Application")
        let staging = root.appendingPathComponent("Prepared")
        try fm.createDirectory(at: programs, withIntermediateDirectories: true)
        try fm.createDirectory(at: provider.appendingPathComponent("lib/wine"), withIntermediateDirectories: true)
        try fm.createDirectory(at: staging.appendingPathComponent("lib/wine"), withIntermediateDirectories: true)
        try fm.createSymbolicLink(atPath: provider.appendingPathComponent("bin").path, withDestinationPath: "CrossOver-Hosted Application")
        let original = Data("server fixture".utf8)
        try original.write(to: programs.appendingPathComponent("wineserver"))
        try Data("launcher fixture".utf8).write(to: programs.appendingPathComponent("wine"))
        try Data("graphics fixture".utf8).write(to: provider.appendingPathComponent("lib/graphics"))
        try NativeRuntime.prepareProviderLayout(provider: provider, staging: staging)
        let server = staging.appendingPathComponent("bin/wineserver")
        XCTAssertEqual(try Data(contentsOf: server), original)
        XCTAssertEqual(try fm.attributesOfItem(atPath: server.path)[.type] as? FileAttributeType, .typeRegular)
        try Data("private change".utf8).write(to: server)
        XCTAssertEqual(try Data(contentsOf: programs.appendingPathComponent("wineserver")), original)
        XCTAssertEqual(staging.appendingPathComponent("bin/wine").resolvingSymlinksInPath(), programs.appendingPathComponent("wine").resolvingSymlinksInPath())
        XCTAssertEqual(try Data(contentsOf: staging.appendingPathComponent("lib/graphics")), Data("graphics fixture".utf8))
    }

    private func connect(_ server: NativeDisplayServer) throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: Array(server.socketPath.utf8) + [0]) }
        let result = withUnsafePointer(to: &address) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard result == 0 else { close(fd); throw CocoaError(.fileReadUnknown) }
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        return fd
    }
    private func write(_ data: Data, to fd: Int32) {
        data.withUnsafeBytes { _ = send(fd, $0.baseAddress, $0.count, 0) }
    }
    private func hello(_ server: NativeDisplayServer, token: String? = nil) throws -> Data {
        var data = try JSONSerialization.data(withJSONObject: ["type": "hello", "version": 1, "pid": getpid(), "token": token ?? server.token])
        data.append(10); return data
    }
    func testAuthenticatedFragmentedMessagesAndPrivateEndpoint() throws {
        let server = try NativeDisplayServer(); defer { server.stop() }
        let attrs = try FileManager.default.attributesOfItem(atPath: server.directory.path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        let received = expectation(description: "Only authenticated metadata")
        server.receive = { peer, value in
            XCTAssertEqual(peer.pid, getpid()); XCTAssertEqual(value["id"] as? Int, 9); received.fulfill()
        }
        server.start()
        let fd = try connect(server); defer { close(fd) }
        let greeting = try hello(server)
        write(greeting.prefix(8), to: fd); write(greeting.dropFirst(8), to: fd)
        var ack = [UInt8](repeating: 0, count: 256)
        let count = recv(fd, &ack, ack.count, 0); XCTAssertGreaterThan(count, 0)
        let frame = Data("{\"type\":\"window\",\"id\":9}\n".utf8)
        write(frame.prefix(12), to: fd); write(frame.dropFirst(12), to: fd)
        wait(for: [received], timeout: 2)
        server.stop(); XCTAssertFalse(FileManager.default.fileExists(atPath: server.socketPath))
    }
    func testWrongTokenIsRejectedBeforeWindowMessages() throws {
        let server = try NativeDisplayServer(); defer { server.stop() }
        server.receive = { _, _ in XCTFail("Unauthenticated display was accepted") }
        server.start(); let fd = try connect(server); defer { close(fd) }
        write(try hello(server, token: "wrong"), to: fd)
        var response = [UInt8](repeating: 0, count: 128)
        XCTAssertEqual(recv(fd, &response, response.count, 0), 0)
    }
    func testNativeAdapterRestoresCrossOverLoaderWithoutLoggingItsSecret() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let adapter = directory.appendingPathComponent("Display adapter.dylib"); try Data([0xcf,0xfa,0xed,0xfe,0x07,0,0,1]).write(to: adapter)
        let runtime = RuntimeInstallation(kind: .crossOver, executable: URL(fileURLWithPath: "/Engine/bin/wine"))
        let command = LaunchCommand(executable: runtime.executable, arguments: ["--bottle", "Wayfarer", "notepad.exe"], environment: ["WAYFARER_GAME_PRESENTATION": "native"])
        let attached = try NativeRuntime.attach(command, runtime: runtime, loader: directory.appendingPathComponent("Wine loader"), adapter: adapter, socket: "/private/tmp/test.sock", token: String(repeating: "a", count: 64))
        XCTAssertEqual(attached.arguments.suffix(3), command.arguments[...])
        XCTAssertTrue(attached.arguments[1].contains("CX_WINELOADER="))
        XCTAssertFalse(attached.display.contains(String(repeating: "a", count: 64)))
        XCTAssertEqual(attached.environment["WAYFARER_GAME_PRESENTATION"], "native")
        XCTAssertEqual(attached.environment["WAYFARER_DISPLAY_TOKEN"], String(repeating: "a", count: 64))
    }
    func testGameWindowMetadataNeverCreatesAnEmptyEmbeddedSurface() {
        let game: [String: Any] = ["type": "window", "id": 1, "context": UInt32(0), "presentation": "native", "title": "Game",
                                  "x": 0.0, "y": 0.0, "width": 1280.0, "height": 720.0, "order": 1.0, "visible": true]
        XCTAssertEqual(NativeWindowDescriptor(game)?.presentation, .native)
        var altered = game; altered["presentation"] = "embedded"
        XCTAssertNil(NativeWindowDescriptor(altered))
        altered["context"] = UInt32(10)
        XCTAssertEqual(NativeWindowDescriptor(altered)?.presentation, .embedded)
        altered["presentation"] = "native"
        XCTAssertNil(NativeWindowDescriptor(altered))
        altered = game; altered["x"] = Double.infinity
        XCTAssertNil(NativeWindowDescriptor(altered))
        altered = game; altered["presentation"] = "unknown"
        XCTAssertNil(NativeWindowDescriptor(altered))
    }

    func testReusedSteamBackendKeepsProviderServerAndGraphicsArguments() throws {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:directory) }
        let adapter=directory.appendingPathComponent("Backend.dylib"); try Data([0xcf,0xfa,0xed,0xfe,0x07,0,0,1]).write(to:adapter)
        let runtime=RuntimeInstallation(kind:.crossOver,executable:URL(fileURLWithPath:"/Provider/bin/wine"))
        let command=LaunchCommand(executable:runtime.executable,arguments:["--bottle","Existing Steam","--cx-app",#"C:\Steam\steam.exe"#,"-silent"],environment:["WINEPREFIX":"/Existing bottle"])
        let attached=try NativeRuntime.attachSteamBackend(command,runtime:runtime,loader:directory.appendingPathComponent("Private loader"),adapter:adapter,directory:directory)
        XCTAssertEqual(attached.environment["WINEPREFIX"],command.environment["WINEPREFIX"])
        XCTAssertEqual(attached.environment["WINESERVER"],"/Provider/bin/wineserver")
        XCTAssertEqual(attached.environment["WAYFARER_STEAM_BACKEND"],directory.path)
        XCTAssertNil(attached.environment["WAYFARER_DISPLAY_SOCKET"])
        XCTAssertEqual(Array(attached.arguments.suffix(command.arguments.count)),command.arguments)
        XCTAssertFalse(attached.arguments.contains("-cef-disable-gpu"))
        XCTAssertFalse(attached.arguments.contains("-k"))
    }
    func testWindowsProcessRecoveryDetectsGamesAndExcludesAnotherPrefix() throws {
        let fm=FileManager.default,root=fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? fm.removeItem(at:root) }
        let selected=root.appendingPathComponent("Selected"),other=root.appendingPathComponent("Other")
        var children:[Process]=[]
        defer { for child in children where child.isRunning { child.terminate(); child.waitUntilExit() } }
        for prefix in [selected,other] {
            try fm.createDirectory(at:prefix,withIntermediateDirectories:true)
            let executable=prefix.appendingPathComponent("active-game.exe")
            try fm.copyItem(at:URL(fileURLWithPath:"/bin/sleep"),to:executable)
            let child=Process(); child.executableURL=executable; child.arguments=["10"]; child.currentDirectoryURL=prefix
            try child.run(); children.append(child)
        }
        let found=try RuntimeProcessIdentity.windowsProcesses(prefix:selected)
        XCTAssertTrue(found.contains { $0.program=="active-game.exe" && $0.token.pid==children[0].processIdentifier })
        XCTAssertFalse(found.contains { $0.token.pid==children[1].processIdentifier })
    }

    func testSmallNativeDialogsAreNotMagnified() {
        let rect = SessionGeometry.contentRect(source: CGSize(width: 300, height: 100), bounds: CGRect(x: 0, y: 0, width: 900, height: 600), maxScale: 1)
        XCTAssertEqual(rect.size, CGSize(width: 300, height: 100))
        XCTAssertEqual(SessionGeometry.remotePoint(local: CGPoint(x: 450, y: 300), bounds: CGRect(x: 0, y: 0, width: 900, height: 600), window: CGRect(x: 0, y: 0, width: 300, height: 100), maxScale: 1), CGPoint(x: 150, y: 50))
    }

    func testSessionResetIsConfinedToOwnedPrefixAndSelectedEngine() throws {
        let fm = FileManager.default
        let directory = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        defer { try? fm.removeItem(at: directory) }
        let engine = directory.appendingPathComponent("Engine")
        let unix = engine.appendingPathComponent("lib/wine/x86_64-unix")
        try fm.createDirectory(at: unix, withIntermediateDirectories: true)
        try fm.createDirectory(at: engine.appendingPathComponent("bin"), withIntermediateDirectories: true)
        for name in ["wine", "ntdll.so", "winemac.so"] { try Data([0xcf, 0xfa, 0xed, 0xfe]).write(to: unix.appendingPathComponent(name)) }
        for file in [unix.appendingPathComponent("wine"), engine.appendingPathComponent("bin/wineserver")] {
            if !fm.fileExists(atPath: file.path) { try Data().write(to: file) }
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
        }
        let home = directory.appendingPathComponent("Home")
        let runtime = RuntimeInstallation(kind: .crossOver, executable: engine.appendingPathComponent("bin/wine"))
        let owned = RuntimeDiscovery.managedProfile(for: runtime, home: home)
        let command = try NativeRuntime.stopCommand(for: owned, home: home)
        XCTAssertEqual(command.executable, engine.appendingPathComponent("bin/wineserver"))
        XCTAssertEqual(command.arguments, ["-k"])
        XCTAssertEqual(command.environment["WINEPREFIX"], owned.prefix.path)
        XCTAssertEqual(command.environment["CX_BOTTLE_PATH"], owned.prefix.deletingLastPathComponent().path)
        let external = RuntimeProfile(runtime: runtime, prefix: directory.appendingPathComponent("Existing Steam"), name: "Existing Steam")
        XCTAssertThrowsError(try NativeRuntime.stopCommand(for: external, home: home))
        try fm.createDirectory(at: owned.prefix.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createDirectory(at: external.prefix, withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: owned.prefix, withDestinationURL: external.prefix)
        XCTAssertThrowsError(try NativeRuntime.stopCommand(for: owned, home: home))
    }
}
