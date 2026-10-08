import XCTest
@testable import PlaydockSteamIntegration

final class BridgeInstallerTests: XCTestCase {
    func testInstallerAndAppShareThePlaydockRuntimeContract() {
        XCTAssertEqual(SupportPaths.currentRunner, SteamIntegrationPaths.currentRunner)
        XCTAssertEqual(SupportPaths.Steam.deployedDylib.lastPathComponent, SteamIntegrationPaths.dylibName)
        XCTAssertEqual(SupportPaths.Steam.compatTool.lastPathComponent, SteamIntegrationPaths.toolID)
        XCTAssertTrue(SteamIntegrationPaths.toolID.contains("proton"))
        XCTAssertTrue(SupportPaths.support.path.hasSuffix("/Playdock/SteamIntegration"))
    }
    private func scratch() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    func testForeignSteamInjectionIsRejectedAndItsPlistIsPreserved() throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let plist = root.appendingPathComponent("Info.plist"), dylib = root.appendingPathComponent("libPlaydockSteam.dylib")
        try SteamBundle.writeInfoPlist(["LSEnvironment": ["DYLD_INSERT_LIBRARIES": "/other/integration.dylib", "OTHER": "preserved"]], at: plist)
        let before = try Data(contentsOf: plist)
        XCTAssertThrowsError(try SteamInstaller.assertInsertIsDeployedOrAbsent(at: plist, dylib: dylib))
        XCTAssertEqual(try Data(contentsOf: plist), before)
        XCTAssertTrue(try SteamRepair.clearInsert(at: plist))
        XCTAssertNil(SteamBundle.currentInsert(at: plist))
        XCTAssertEqual((SteamBundle.readInfoPlist(at: plist)?["LSEnvironment"] as? [String: String])?["OTHER"], "preserved")
    }
    func testBridgeReplacesEqualSizeStaleBinaryAndThenIsIdempotent() throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("new.dll"), bridge = root.appendingPathComponent("bridge")
        try FileManager.default.createDirectory(at: bridge, withIntermediateDirectories: true)
        try Data("new".utf8).write(to: source)
        let destination = bridge.appendingPathComponent("lsteamclient.dll")
        try Data("old".utf8).write(to: destination)
        let payload = BridgePayload.Located(sources: [(source: source, bridgePaths: ["lsteamclient.dll"])])
        let first = try BridgePayload.stage(located: payload, bridge: bridge)
        XCTAssertFalse(first.staged.isEmpty)
        XCTAssertEqual(try Data(contentsOf: destination), Data("new".utf8))
        XCTAssertTrue(try BridgePayload.stage(located: payload, bridge: bridge).staged.isEmpty)
    }
    func testRecoveryReplacementPreservesOriginalContents() throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appendingPathComponent("Steam.app"), backup = root.appendingPathComponent("Backup.app")
        for directory in [app, backup] { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        try Data("modified".utf8).write(to: app.appendingPathComponent("binary"))
        try Data("original".utf8).write(to: backup.appendingPathComponent("binary"))
        try SteamRepair.replace(app, with: backup)
        XCTAssertEqual(try Data(contentsOf: app.appendingPathComponent("binary")), Data("original".utf8))
    }
    private func completeInstallation(in root: URL) throws -> (app: URL, bridge: URL, runners: URL) {
        let files = FileManager.default
        let app = root.appending(path: "Steam.app"), bridge = root.appending(path: "bridge"), runners = root.appending(path: "runners")
        let dylib = app.appending(path: "Contents/MacOS/\(SupportPaths.dylibName)")
        try files.createDirectory(at: dylib.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("fixture".utf8).write(to: dylib)
        try SteamBundle.writeInfoPlist(["LSEnvironment": ["DYLD_INSERT_LIBRARIES": dylib.path]], at: app.appending(path: "Contents/Info.plist"))
        let target = "crossover-\(SupportedRunners.all[0].id)/CrossOver"
        try files.createDirectory(at: runners.appending(path: target + "/lib/wine"), withIntermediateDirectories: true)
        try files.createSymbolicLink(atPath: runners.appending(path: "current").path, withDestinationPath: target)
        for name in ["steamclient.dll", "steamclient64.dll", "tier0_s64.dll", "vstdlib_s64.dll"] + BridgePayload.entries.flatMap(\.bridgePaths) {
            let file = bridge.appending(path: name)
            try files.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("fixture".utf8).write(to: file)
        }
        return (app, bridge, runners)
    }
    func testFinalVerificationSucceedsWhileRecoveryIsStillAvailable() throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try completeInstallation(in: root)
        let pending = root.appending(path: "transaction.json")
        try Data("Steam.transaction.app".utf8).write(to: pending)
        let problems = SteamIntegrationVerification.problems(app: fixture.app, bridge: fixture.bridge, runners: fixture.runners,
            verifyRunner: { _, _ in [] }, license: { _ in .init(licensed: true, detail: "Activated", diagnostic: "Fixture") })
        XCTAssertTrue(problems.isEmpty, problems.joined(separator: " "))
        XCTAssertEqual(try Data(contentsOf: pending), Data("Steam.transaction.app".utf8))
    }
    func testFinalVerificationReportsMissingArchitectureComponentAndRunnerFailure() throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try completeInstallation(in: root)
        try FileManager.default.removeItem(at: fixture.bridge.appending(path: "aarch64-unix/lsteamclient.so"))
        let problems = SteamIntegrationVerification.problems(app: fixture.app, bridge: fixture.bridge, runners: fixture.runners,
            verifyRunner: { _, _ in ["ntdll.dll is not patched"] }, license: { _ in .init(licensed: true, detail: "Activated", diagnostic: "Fixture") })
        XCTAssertTrue(problems.contains("Missing bridge component: aarch64-unix/lsteamclient.so."))
        XCTAssertTrue(problems.contains("ntdll.dll is not patched"))
    }
    func testUnsupportedCrossOverCannotBeCloned() throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let install = CrossOverSource.inspect(bundle: root.appendingPathComponent("Unknown.app"))
        XCTAssertFalse(install.isUsable)
        XCTAssertThrowsError(try RunnerInstaller.clone(from: install, runners: root.appendingPathComponent("runners")))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("runners").path))
    }
    func testUnsupportedCrossOverStillReportsItsVerifiedLicense() {
        let install = CrossOverInstall(bundle: URL(fileURLWithPath: "/CrossOver.app"), releaseVersion: "26.3", support: .unsupportedBuild("26.3"))
        let license = CrossOverLicense.Status(licensed: true, detail: "CrossOver is activated.", diagnostic: "Verified")
        let result = SteamIntegrationInstaller.describe(install, license: license)
        XCTAssertFalse(result.supported)
        XCTAssertTrue(result.licensed)
        XCTAssertTrue(result.supportDetail.contains("26.3"))
        XCTAssertEqual(result.licenseDetail, license.detail)
    }
}
