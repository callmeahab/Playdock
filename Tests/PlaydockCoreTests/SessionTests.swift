import XCTest
import CoreGraphics
@testable import PlaydockCore

final class SessionTests: XCTestCase {
    func testPreparationLeavesExistingWinePrefixUntouched() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PlaydockPrep-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("existing".utf8).write(to: directory.appendingPathComponent("system.reg"))
        let runtime = RuntimeInstallation(kind: .wine, executable: URL(fileURLWithPath: "/nonexistent/wine"))
        let profile = RuntimeProfile(runtime: runtime, prefix: directory, name: "Existing")
        XCTAssertNil(try CommandBuilder.prepareNewProfile(profile))
        XCTAssertEqual(try String(contentsOf: directory.appendingPathComponent("system.reg")), "existing")
    }

    func testProcessWindowMatchingRequiresExactPrefix() throws {
        let prefix = FileManager.default.temporaryDirectory.appendingPathComponent("PlaydockIdentity-\(UUID())")
        try FileManager.default.createDirectory(at: prefix, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: prefix) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["10"]
        process.environment = ["WINEPREFIX": prefix.path]
        process.currentDirectoryURL = prefix
        try process.run()
        defer { if process.isRunning { process.terminate(); process.waitUntilExit() } }
        XCTAssertTrue(RuntimeProcessIdentity.belongsToPrefix(pid: process.processIdentifier, prefix: prefix))
        XCTAssertFalse(RuntimeProcessIdentity.belongsToPrefix(pid: process.processIdentifier, prefix: prefix.appendingPathComponent("different")))
        XCTAssertFalse(RuntimeProcessIdentity.belongsToPrefix(pid: -1, prefix: prefix))
        let token = RuntimeProcessIdentity.token(for: process.processIdentifier)
        XCTAssertNotNil(token)
        XCTAssertTrue(RuntimeProcessIdentity.belongsToPrefix(pid: process.processIdentifier, prefix: prefix.appendingPathComponent("different"), launch: token))
    }

    func testMacSteamWindowMatchingRejectsGamesAndOtherInstallations() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("PlaydockSteamWindow-\(UUID())")
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        for name in ["steam_osx","Steam Helper","Game"] {
            let executable=root.appendingPathComponent(name)
            try FileManager.default.copyItem(at:URL(fileURLWithPath:"/bin/sleep"),to:executable)
            let process=Process(); process.executableURL=executable; process.arguments=["10"]; process.currentDirectoryURL=root
            try process.run()
            defer { if process.isRunning { process.terminate(); process.waitUntilExit() } }
            XCTAssertEqual(RuntimeProcessIdentity.isSteamClient(pid:process.processIdentifier,root:root),name != "Game")
            XCTAssertFalse(RuntimeProcessIdentity.isSteamClient(pid:process.processIdentifier,root:root.appendingPathComponent("OtherSteam")))
            process.terminate(); process.waitUntilExit()
            XCTAssertNil(RuntimeProcessIdentity.token(for:process.processIdentifier))
        }
    }


}
