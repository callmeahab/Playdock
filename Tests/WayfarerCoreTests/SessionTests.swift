import XCTest
import CoreGraphics
@testable import WayfarerCore

final class SessionTests: XCTestCase {
    func testLetterboxClicksAreIgnoredAndCenterMapsToWindowCenter() {
        let bounds = CGRect(x: 0, y: 0, width: 1000, height: 1000)
        let window = CGRect(x: -1200, y: 50, width: 1920, height: 1080)
        XCTAssertNil(SessionGeometry.remotePoint(local: CGPoint(x: 500, y: 50), bounds: bounds, window: window))
        let center = SessionGeometry.remotePoint(local: CGPoint(x: 500, y: 500), bounds: bounds, window: window)
        XCTAssertEqual(center?.x, -240)
        XCTAssertEqual(center?.y, 590)
    }

    func testInputFlipsAppKitCoordinatesAndRespectsNegativeDisplayOrigins() {
        let bounds = CGRect(x: 0, y: 0, width: 1280, height: 720)
        let window = CGRect(x: -1920, y: -1080, width: 1920, height: 1080)
        let top = SessionGeometry.remotePoint(local: CGPoint(x: 0, y: 719), bounds: bounds, window: window)
        XCTAssertEqual(top?.x, -1920)
        XCTAssertEqual(top?.y ?? 0, -1078.5, accuracy: 0.001)
        let bottom = SessionGeometry.remotePoint(local: CGPoint(x: 1279, y: 0), bounds: bounds, window: window)
        XCTAssertEqual(bottom?.y, 0)
    }

    func testDragOutsideSurfaceClampsUntilMouseRelease() {
        let point = SessionGeometry.remotePoint(local: CGPoint(x: -20, y: 300), bounds: CGRect(x: 0, y: 0, width: 200, height: 200), window: CGRect(x: 100, y: 200, width: 800, height: 600), clamp: true)
        XCTAssertEqual(point, CGPoint(x: 100, y: 200))
        XCTAssertNil(SessionGeometry.remotePoint(local: .zero, bounds: .zero, window: .zero))
    }

    func testPreparationLeavesExistingWinePrefixUntouched() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("WayfarerPrep-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("existing".utf8).write(to: directory.appendingPathComponent("system.reg"))
        let runtime = RuntimeInstallation(kind: .wine, executable: URL(fileURLWithPath: "/nonexistent/wine"))
        let profile = RuntimeProfile(runtime: runtime, prefix: directory, name: "Existing")
        XCTAssertNil(try CommandBuilder.prepareNewProfile(profile))
        XCTAssertEqual(try String(contentsOf: directory.appendingPathComponent("system.reg")), "existing")
    }

    func testProcessWindowMatchingRequiresExactPrefix() throws {
        let prefix = FileManager.default.temporaryDirectory.appendingPathComponent("WayfarerIdentity-\(UUID())")
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
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("WayfarerSteamWindow-\(UUID())")
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

    func testWineSteamWindowMatchingRejectsGameInSamePrefix() throws {
        let prefix=FileManager.default.temporaryDirectory.appendingPathComponent("WayfarerSteamPrefix-\(UUID())")
        try FileManager.default.createDirectory(at:prefix,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:prefix) }
        for name in ["steam.exe","SteamWebHelper.exe","MortalKombat.exe"] {
            let process=Process(); process.executableURL=URL(fileURLWithPath:"/bin/zsh")
            process.arguments=["-c","exec -a \"$1\" /bin/sleep 10","fixture","C:\\Steam\\\(name)"]
            process.currentDirectoryURL=prefix
            try process.run()
            defer { if process.isRunning { process.terminate(); process.waitUntilExit() } }
            for _ in 0..<50 where RuntimeProcessIdentity.windowsProgram(for:process.processIdentifier)==nil { usleep(10_000) }
            XCTAssertEqual(RuntimeProcessIdentity.isSteamClient(pid:process.processIdentifier,root:prefix.appendingPathComponent("drive_c/Steam"),prefix:prefix),name != "MortalKombat.exe")
            XCTAssertFalse(RuntimeProcessIdentity.isSteamClient(pid:process.processIdentifier,root:prefix,prefix:prefix.appendingPathComponent("OtherBottle")))
        }
    }
}
