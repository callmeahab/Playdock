import XCTest
@testable import WayfarerCore

final class PerformanceTests: XCTestCase {
    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("WayfarerPerformance-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    private func write(_ text: String, to file: URL) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: file)
    }
    private func profile(at root: URL) throws -> RuntimeProfile {
        let engine = root.appendingPathComponent("engine"), prefix = root.appendingPathComponent("bottle")
        try write("[CrossOver]\n\"ProductVersion\" = \"26.3.0\"\n", to: engine.appendingPathComponent("etc/crossover.conf"))
        try write("#!/bin/sh\n", to: engine.appendingPathComponent("bin/wine"))
        try write("[Bottle]\n\"Name\" = \"My bottle\"\n[EnvironmentVariables]\n\"OTHER\" = \"keep\"\n", to: prefix.appendingPathComponent("cxbottle.conf"))
        return RuntimeProfile(runtime: RuntimeInstallation(kind: .crossOver, executable: engine.appendingPathComponent("bin/wine")), prefix: prefix, name: "Test")
    }
    func testOldPreferencesAndConfigurationKeepDefaultQuietMode() throws {
        let old = #"{"launchOptions":"","tags":[],"hidden":false,"collectionIDs":[],"saveFolders":{}}"#
        let value = try JSONDecoder().decode(GamePreferences.self, from: Data(old.utf8))
        XCTAssertNil(value.performance); XCTAssertTrue(value.effectivePerformance.quietWhilePlaying)
        XCTAssertTrue(value.effectivePerformance.environment.isEmpty)
        let config = try JSONDecoder().decode(LauncherConfiguration.self, from: JSONEncoder().encode(LauncherConfiguration()))
        XCTAssertNil(config.performanceReports)
    }
    func testQuietModeSuppressesOptionalWorkAndRestoresItOnActivation() async {
        let actor = PerformanceCoordinator(), now = Date(timeIntervalSince1970: 1000)
        let quiet = PerformanceWorkload(quietGameRunning: true, launcherActive: false, downloadsActive: false)
        let first = await actor.due(quiet, now: now)
        XCTAssertEqual(first, [.steam])
        let early = await actor.due(quiet, now: now.addingTimeInterval(5))
        XCTAssertTrue(early.isEmpty)
        let foreground = await actor.due(PerformanceWorkload(quietGameRunning: true, launcherActive: true, downloadsActive: false), now: now.addingTimeInterval(6))
        XCTAssertEqual(foreground, [.library, .steam, .social])
    }
    func testQuietModeTracksDownloadsWithoutLibraryScans() async {
        let actor = PerformanceCoordinator(), now = Date(timeIntervalSince1970: 1000)
        let quiet = PerformanceWorkload(quietGameRunning: true, launcherActive: false, downloadsActive: true)
        let first = await actor.due(quiet, now: now)
        let early = await actor.due(quiet, now: now.addingTimeInterval(9))
        let next = await actor.due(quiet, now: now.addingTimeInterval(10))
        XCTAssertEqual(first, [.steam]); XCTAssertTrue(early.isEmpty); XCTAssertEqual(next, [.steam])
    }
    func testBottleEditsPreserveOtherSectionsCommentsAndLineEndings() throws {
        let text = "[Bottle]\r\n\"WINEMSYNC\" = \"untouched\"\r\n[EnvironmentVariables]\r\n; comment\r\n\"OTHER\" = \"keep\"\r\n\"WINEMSYNC\" = \"0\"\r\n\"WINEMSYNC\" = \"1\"\r\n[Other]\r\n\"X\" = \"Y\"\r\n"
        let updated = try BottlePerformanceConfiguration.updating(text, variables: ["WINEMSYNC": "0", "CX_GRAPHICS_BACKEND": "dxmt"])
        XCTAssertTrue(updated.contains("[Bottle]\r\n\"WINEMSYNC\" = \"untouched\""))
        XCTAssertTrue(updated.contains("; comment\r\n\"OTHER\" = \"keep\""))
        XCTAssertTrue(updated.contains("[Other]\r\n\"X\" = \"Y\""))
        XCTAssertEqual(BottlePerformanceConfiguration.values(updated)["WINEMSYNC"], "0")
        XCTAssertEqual(BottlePerformanceConfiguration.values(updated)["CX_GRAPHICS_BACKEND"], "dxmt")
        XCTAssertFalse(updated.replacingOccurrences(of: "\r\n", with: "").contains("\n"))
    }
    func testBottleRejectsUnknownKeysInjectionAndDuplicateSections() throws {
        XCTAssertThrowsError(try BottlePerformanceConfiguration.updating("", variables: ["WINEPREFIX": "/elsewhere"]))
        XCTAssertThrowsError(try BottlePerformanceConfiguration.updating("", variables: ["WINEMSYNC": "1\nOTHER=2"]))
        XCTAssertThrowsError(try BottlePerformanceConfiguration.updating("[EnvironmentVariables]\n[Other]\n[EnvironmentVariables]\n", variables: ["WINEMSYNC": "1"]))
        XCTAssertEqual(try BottlePerformanceConfiguration.updating("unchanged", variables: [:]), "unchanged")
    }
    func testCapabilitiesRequireInstalledBackendsAndSupportedVersion() async throws {
        let root = try temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let profile = try profile(at: root), service = PerformanceEnvironmentService()
        let first = try await service.snapshot(profile)
        XCTAssertTrue(first.supportsMSync); XCTAssertFalse(first.backends.contains(.dxmt)); XCTAssertFalse(first.backends.contains(.d3dMetal))
        try write("dll", to: root.appendingPathComponent("engine/lib/dxmt/x86_64-windows/d3d11.dll"))
        try write("dll", to: root.appendingPathComponent("engine/lib64/apple_gptk/wine/x86_64-windows/d3d11.dll"))
        let installed = try await service.snapshot(profile)
        XCTAssertTrue(installed.backends.contains(.dxmt)); XCTAssertTrue(installed.backends.contains(.d3dMetal))
        try write("[CrossOver]\n\"ProductVersion\" = \"24.0\"\n", to: root.appendingPathComponent("engine/etc/crossover.conf"))
        let old = try await service.snapshot(profile)
        XCTAssertEqual(old.backends, [.inherit]); XCTAssertFalse(old.supportsMSync)
    }
    func testSymlinkedBottleCannotBeWritten() async throws {
        let root = try temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let profile = try profile(at: root), service = PerformanceEnvironmentService()
        let file = profile.prefix.appendingPathComponent("cxbottle.conf"), other = root.appendingPathComponent("shared.conf")
        try FileManager.default.moveItem(at: file, to: other)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: other)
        let snapshot = try await service.snapshot(profile)
        XCTAssertFalse(snapshot.writable)
    }
    func testApplyBacksUpAndRejectsStaleConfiguration() async throws {
        let root = try temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let profile = try profile(at: root), service = PerformanceEnvironmentService()
        let file = profile.prefix.appendingPathComponent("cxbottle.conf"), original = try Data(contentsOf: file)
        let snapshot = try await service.snapshot(profile)
        var settings = GamePerformanceProfile(); settings.synchronization = .enabled; settings.metalHUD = .enabled
        let backup = try await service.apply(settings, profile: profile, expected: snapshot.fingerprint, backups: root.appendingPathComponent("backups"))
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(backup)), original)
        let applied = try await service.snapshot(profile)
        XCTAssertTrue(applied.matches(settings)); XCTAssertEqual(applied.variables["OTHER"], "keep")
        let appliedData = try Data(contentsOf: file)
        do { _ = try await service.apply(settings, profile: profile, expected: snapshot.fingerprint); XCTFail("Stale snapshot accepted") }
        catch { XCTAssertTrue(error.localizedDescription.contains("changed")) }
        XCTAssertEqual(try Data(contentsOf: file), appliedData)
    }
    func testLaunchRequiresExplicitlyAppliedProfile() async throws {
        let root = try temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let profile = try profile(at: root), service = PerformanceEnvironmentService()
        try await service.checkLaunch(GamePerformanceProfile(), profile: profile)
        var settings = GamePerformanceProfile(); settings.synchronization = .enabled
        do { try await service.checkLaunch(settings, profile: profile); XCTFail("Unapplied settings accepted") }
        catch { XCTAssertTrue(error.localizedDescription.contains("Apply")) }
    }
    func testHUDParserDeduplicatesFramesAndIgnoresInvalidTimings() throws {
        let line = "2026-10-07 wine[123:456] metal-HUD: 100,64,128,10,8,20,12,0,0,nan,4"
        let samples = try MetalPerformanceLog.frames(line + "\n" + line)
        XCTAssertEqual(samples, [PerformanceFrame(interval: 10, gpu: 8), PerformanceFrame(interval: 20, gpu: 12)])
        let otherProcess = line.replacingOccurrences(of: "wine[123:", with: "wine[124:")
        XCTAssertEqual(try MetalPerformanceLog.frames(line + "\n" + otherProcess).count, 4)
        XCTAssertThrowsError(try MetalPerformanceLog.frames("Metal HUD enabled but no frames"))
    }
    func testCSVParserRequiresExplicitMillisecondHeader() throws {
        XCTAssertThrowsError(try MetalPerformanceLog.frames("16.6,8\n16.6,8"))
        let frames = try MetalPerformanceLog.frames("frame_ms,gpu_ms\n16.6,8\n-1,9\nInfinity,4\n33.3,10\n")
        XCTAssertEqual(frames.count, 2)
    }
    func testReportMeasuresStutterAndOnlyExportsAllowedSettings() throws {
        let frames = Array(repeating: PerformanceFrame(interval: 10, gpu: 8), count: 98) + Array(repeating: PerformanceFrame(interval: 100, gpu: 20), count: 2)
        let report = try GamePerformanceReport(gameID: "game", scene: "Benchmark", cache: .warm, environmentID: "bottle", engine: "CrossOver", fingerprint: "engine", settings: GamePerformanceProfile(),
            effectiveVariables: ["CX_GRAPHICS_BACKEND": "dxmt", "TOKEN": "private"], samples: frames, thermal: "Nominal")
        XCTAssertEqual(report.averageFPS, 100_000 / 1180.0, accuracy: 0.001)
        XCTAssertEqual(report.onePercentLowFPS, 10); XCTAssertEqual(report.medianFrameMS, 10); XCTAssertEqual(report.p95FrameMS, 10); XCTAssertEqual(report.p99FrameMS, 100)
        XCTAssertEqual(report.effectiveVariables, ["CX_GRAPHICS_BACKEND": "dxmt"])
        let restored = try JSONDecoder().decode(GamePerformanceReport.self, from: JSONEncoder().encode(report))
        XCTAssertEqual(restored.id, report.id); XCTAssertEqual(restored.averageFPS, report.averageFPS)
    }
    func testReportRejectsInsufficientAndInvalidFrames() throws {
        func report(_ frames: [PerformanceFrame]) throws {
            _ = try GamePerformanceReport(gameID: "game", scene: "", cache: .unknown, environmentID: nil, engine: "", fingerprint: "", settings: GamePerformanceProfile(), effectiveVariables: [:], samples: frames, thermal: "Unknown")
        }
        XCTAssertThrowsError(try report(Array(repeating: PerformanceFrame(interval: 10, gpu: 8), count: 29)))
        XCTAssertThrowsError(try report(Array(repeating: PerformanceFrame(interval: .nan, gpu: 8), count: 30)))
    }
    func testCancellingOwnedLogQueryUnblocksWait() async throws {
        let root = try temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let service = ProcessService()
        let receipt = try await service.start(LaunchCommand(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["30"]), id: UUID(), logsDirectory: root)
        await service.terminate(receipt.id)
        let status = try await service.wait(receipt.id)
        XCTAssertNotEqual(status, 0)
    }
}
