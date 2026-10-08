import XCTest
@testable import PlaydockSteamIntegration

final class LaunchSupportTests: XCTestCase {
    private func fixture() throws -> (root: URL, payload: URL, support: URL, tool: URL) {
        let files = FileManager.default
        let root = files.temporaryDirectory.resolvingSymlinksInPath().appending(path: UUID().uuidString)
        let payload = root.appending(path: "payload"), support = root.appending(path: "support"), tool = root.appending(path: "tool")
        for directory in [payload, support, tool] { try files.createDirectory(at: directory, withIntermediateDirectories: true) }
        for name in ["overlay-shim.dylib", "iconmaker", "run"] {
            try Data("new-\(name)".utf8).write(to: payload.appending(path: name))
            try Data("old-\(name)".utf8).write(to: (name == "run" ? tool : support).appending(path: name))
        }
        return (root, payload, support, tool)
    }

    func testRefreshPreservesOpenFilesAndIsIdempotent() throws {
        let fixture = try fixture(); defer { try? FileManager.default.removeItem(at: fixture.root) }
        let shim = fixture.support.appending(path: "overlay-shim.dylib")
        let openShim = try FileHandle(forReadingFrom: shim); defer { try? openShim.close() }
        XCTAssertEqual(try LaunchSupport.update(payload: fixture.payload, support: fixture.support, tool: fixture.tool), 3)
        XCTAssertEqual(try openShim.readToEnd(), Data("old-overlay-shim.dylib".utf8))
        XCTAssertEqual(try Data(contentsOf: shim), Data("new-overlay-shim.dylib".utf8))
        XCTAssertEqual(try Data(contentsOf: fixture.tool.appending(path: "run")), Data("new-run".utf8))
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: fixture.tool.appending(path: "run").path))
        XCTAssertEqual(try LaunchSupport.update(payload: fixture.payload, support: fixture.support, tool: fixture.tool), 0)
    }

    func testRedirectedHelperIsRejectedBeforeAnyReplacement() throws {
        let fixture = try fixture(); defer { try? FileManager.default.removeItem(at: fixture.root) }
        let files = FileManager.default, run = fixture.tool.appending(path: "run")
        let outside = fixture.root.appending(path: "unrelated")
        try Data("keep".utf8).write(to: outside)
        try files.removeItem(at: run)
        try files.createSymbolicLink(at: run, withDestinationURL: outside)
        XCTAssertThrowsError(try LaunchSupport.update(payload: fixture.payload, support: fixture.support, tool: fixture.tool))
        XCTAssertEqual(try Data(contentsOf: fixture.support.appending(path: "overlay-shim.dylib")), Data("old-overlay-shim.dylib".utf8))
        XCTAssertEqual(try Data(contentsOf: outside), Data("keep".utf8))
    }

    func testRedirectedDirectoryAndMissingPayloadAreRejected() throws {
        let fixture = try fixture(); defer { try? FileManager.default.removeItem(at: fixture.root) }
        let alias = fixture.root.appending(path: "alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: fixture.support)
        XCTAssertThrowsError(try LaunchSupport.update(payload: fixture.payload, support: alias, tool: fixture.tool))
        try FileManager.default.removeItem(at: fixture.payload.appending(path: "run"))
        XCTAssertThrowsError(try LaunchSupport.update(payload: fixture.payload, support: fixture.support, tool: fixture.tool))
        XCTAssertEqual(try Data(contentsOf: fixture.support.appending(path: "iconmaker")), Data("old-iconmaker".utf8))
    }
}
