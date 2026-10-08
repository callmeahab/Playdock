import XCTest
@testable import PlaydockCore

final class RuntimeTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("PlaydockTests-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    @discardableResult
    private func file(_ relative: String, content: String = "", executable: Bool = false) throws -> URL {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(content.utf8).write(to: url)
        if executable { try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path) }
        return url
    }

    func testDiscoveryFindsCrossOverGPTKAndWineWithoutDuplicatingSymlinks() throws {
        let cx = try file("Applications/CrossOver Preview.app/Contents/SharedSupport/CrossOver/bin/wine", executable: true)
        let wine = try file("bin/wine", executable: true)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("bin/wine64"), withDestinationURL: wine)
        let gptk = try file("bin/gameportingtoolkit-no-hud", executable: true)
        let discovery = RuntimeDiscovery(home: root, applicationDirectories: [root.appendingPathComponent("Applications")], searchDirectories: [root.appendingPathComponent("bin")], appleSilicon: true)
        let runtimes = discovery.installations()
        XCTAssertEqual(runtimes.map(\.kind), [.crossOver, .gptk, .wine])
        XCTAssertEqual(runtimes.map(\.executable), [cx, gptk, wine])
        var intel = discovery
        intel.appleSilicon = false
        XCTAssertEqual(intel.installations().map(\.kind), [.crossOver, .wine])
    }

    func testCrossOverDiscoversExistingBottlesWithoutChangingTheirFiles() throws {
        let executable = try file("bin/wine", executable: true)
        try file("Library/Application Support/CrossOver/Bottles/Steam/cxbottle.conf")
        try file("Library/Application Support/CrossOver/Bottles/Steam/drive_c/Steam/steam.exe")
        let login = try file("Library/Application Support/CrossOver/Bottles/Steam/drive_c/Steam/config/loginusers.vdf", content: "existing-account-fixture")
        let discovery = RuntimeDiscovery(home: root, applicationDirectories: [], searchDirectories: [])
        let profiles = discovery.profiles(for: [RuntimeInstallation(kind: .crossOver, executable: executable)])
        XCTAssertEqual(profiles.map(\.name), ["Steam", "Playdock"])
        XCTAssertEqual(profiles.first?.prefix, root.appendingPathComponent("Library/Application Support/CrossOver/Bottles/Steam"))
        XCTAssertTrue(profiles.first?.reusesExistingEnvironment == true)
        XCTAssertEqual(RuntimeDiscovery.preferredProfile(profiles, selectedID:nil), profiles.first)
        XCTAssertFalse(FileManager.default.fileExists(atPath:profiles.last!.prefix.path))
        XCTAssertEqual(try String(contentsOf: login), "existing-account-fixture")
    }

    func testWineAndGPTKUseSeparateAppOwnedPrefixes() throws {
        let wine = RuntimeInstallation(kind: .wine, executable: try file("bin/wine", executable: true))
        let gptk = RuntimeInstallation(kind: .gptk, executable: try file("bin/gameportingtoolkit", executable: true), toolkitWrapper: true)
        try file(".wine/system.reg")
        try file(".wine/drive_c/Steam/steam.exe")
        try file("my-game-prefix/system.reg")
        try file("my-game-prefix/drive_c/Steam/steam.exe")
        let profiles = RuntimeDiscovery(home: root).profiles(for: [wine, gptk])
        XCTAssertEqual(profiles.map(\.prefix), ["wine", "gptk"].map { root.appendingPathComponent("Library/Application Support/Playdock/Prefixes/\($0)") })
    }

    func testAutomaticEnvironmentDoesNotDependOnSteamAndExplicitMissingChoiceDoesNotFallback() throws {
        let runtime = RuntimeInstallation(kind: .wine, executable: try file("bin/wine", executable: true))
        let empty = RuntimeProfile(runtime: runtime, prefix: root.appendingPathComponent("empty"), name: "Empty")
        let installed = RuntimeProfile(runtime: runtime, prefix: root.appendingPathComponent("Steam"), name: "Steam")
        try file("Steam/drive_c/Program Files (x86)/Steam/steam.exe")
        XCTAssertEqual(RuntimeDiscovery.preferredProfile([empty, installed], selectedID: nil), empty)
        XCTAssertEqual(RuntimeDiscovery.preferredProfile([empty, installed], selectedID: empty.id), empty)
        XCTAssertNil(RuntimeDiscovery.preferredProfile([empty, installed], selectedID: "missing"))
    }

    func testCrossOverCommandKeepsBottleAndArgumentsIntact() throws {
        let runtime = RuntimeInstallation(kind: .crossOver, executable: try file("CrossOver/bin/wine", executable: true))
        try file("Bottles/Steam Games/cxbottle.conf")
        let program = try file("Bottles/Steam Games/drive_c/Program Files (x86)/Steam/steam.exe")
        let profile = RuntimeProfile(runtime: runtime, prefix: root.appendingPathComponent("Bottles/Steam Games"), name: "Steam Games")
        let command = try CommandBuilder.launch(profile: profile, program: program, arguments: ["--fullscreen"])
        XCTAssertEqual(command.arguments, ["--bottle", "Steam Games", "--wait-children", "--cx-app", WindowsPath.windowsPath(for: program, prefix: profile.prefix), "--fullscreen"])
        XCTAssertEqual(command.environment["CX_BOTTLE_PATH"], root.appendingPathComponent("Bottles").path)
        XCTAssertEqual(command.environment["WINEPREFIX"], profile.prefix.path)
        XCTAssertEqual(command.workingDirectory, program.deletingLastPathComponent())
    }

    func testGPTKWrapperAndBareWineHaveDifferentArgumentContracts() throws {
        let wrapper = try file("bin/gameportingtoolkit-no-hud", executable: true)
        let program = try file("prefix/drive_c/Steam/steam.exe")
        let prefix = root.appendingPathComponent("prefix")
        var profile = RuntimeProfile(runtime: RuntimeInstallation(kind: .gptk, executable: wrapper, toolkitWrapper: true), prefix: prefix, name: "GPTK")
        let wrapped = try CommandBuilder.launch(profile: profile, program: program, arguments: ["-bigpicture"], appleSilicon: true)
        XCTAssertEqual(wrapped.executable.path, "/usr/bin/arch")
        XCTAssertEqual(wrapped.arguments, ["-x86_64", wrapper.path, prefix.path, "C:\\Steam\\steam.exe", "-bigpicture"])
        profile.runtime = RuntimeInstallation(kind: .gptk, executable: try file("gptk/bin/wine64", executable: true))
        let bare = try CommandBuilder.launch(profile: profile, program: program, appleSilicon: true)
        XCTAssertEqual(bare.arguments, ["-x86_64", profile.runtime.executable.path, program.path])
        XCTAssertThrowsError(try CommandBuilder.launch(profile: profile, program: program, appleSilicon: false))
    }

    func testWineLaunchKeepsArgumentsAndDoesNotUseCrossOverFlags() throws {
        let runtime = RuntimeInstallation(kind: .wine, executable: try file("bin/wine", executable: true))
        let profile = RuntimeProfile(runtime: runtime, prefix: root.appendingPathComponent("prefix"), name: "Wine")
        let program = try file("prefix/drive_c/Steam/steam.exe")
        let command = try CommandBuilder.launch(profile: profile, program: program, arguments: ["--fullscreen"])
        XCTAssertEqual(command.arguments, [program.path, "--fullscreen"])
        XCTAssertEqual(command.environment, ["WINEPREFIX": profile.prefix.path])
    }

    func testMissingExecutableAndUninitializedCrossOverBottleAreErrors() throws {
        let runtime = RuntimeInstallation(kind: .crossOver, executable: try file("bin/wine", executable: true))
        let profile = RuntimeProfile(runtime: runtime, prefix: root.appendingPathComponent("prefix"), name: "Missing")
        let program = try file("game.exe")
        XCTAssertThrowsError(try CommandBuilder.launch(profile: profile, program: program))
        XCTAssertThrowsError(try CommandBuilder.launch(profile: profile, program: root.appendingPathComponent("missing.exe")))
    }

    func testArgumentParserPreservesLiteralShellTextAndQuotedEmptyArgument() throws {
        XCTAssertEqual(try ArgumentParser.parse(#"-fullscreen "two words" '' '$(touch /tmp/bad)'"#), ["-fullscreen", "two words", "", "$(touch /tmp/bad)"])
        XCTAssertThrowsError(try ArgumentParser.parse("\"unfinished"))
        XCTAssertThrowsError(try ArgumentParser.parse("trailing\\"))
    }

    func testWindowsDriveMappingsAndExternalExecutable() throws {
        let external = root.appendingPathComponent("External Games")
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        let devices = root.appendingPathComponent("prefix/dosdevices")
        try FileManager.default.createDirectory(at: devices, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: devices.appendingPathComponent("d:"), withDestinationURL: external)
        let prefix = root.appendingPathComponent("prefix")
        XCTAssertEqual(WindowsPath.hostPath(#"D:\SteamLibrary"#, prefix: prefix), external.appendingPathComponent("SteamLibrary"))
        XCTAssertNil(WindowsPath.hostPath(#"Q:\Missing"#, prefix: prefix))
        XCTAssertNil(WindowsPath.hostPath(#"C:relative"#, prefix: prefix))
        XCTAssertEqual(WindowsPath.windowsPath(for: root.appendingPathComponent("game.exe"), prefix: prefix), "Z:" + root.appendingPathComponent("game.exe").path.replacingOccurrences(of: "/", with: "\\"))
    }

    func testSteamLibrariesUseMacPathsAndExcludePartialGamesAndInvalidManifests() throws {
        let steam = root.appendingPathComponent("Steam"), extra = root.appendingPathComponent("External")
        try file("Steam/steamapps/libraryfolders.vdf", content: "\"libraryfolders\" { \"1\" { \"path\" \"\(extra.path)\" } \"2\" { \"path\" \"/missing/library\" } }")
        func manifest(_ id: String, _ name: String, _ flags: Int) -> String {
            "\"AppState\" { \"appid\" \"\(id)\" \"name\" \"\(name)\" \"StateFlags\" \"\(flags)\" \"installdir\" \"Game\(id)\" }"
        }
        for (directory, id, name, flags) in [("Steam", "10", "First game", 4), ("Steam", "11", "Downloading", 2), ("Steam", "228980", "Redistributables", 4), ("External", "10", "Duplicate", 4), ("External", "20", "Second game", 4)] {
            try file(directory + "/steamapps/appmanifest_" + id + ".acf", content: manifest(id, name, flags))
            let executable = try file(directory + "/steamapps/common/Game" + id + "/game.exe")
            try Data([0x4d, 0x5a, 0, 0]).write(to: executable)
        }
        try file("External/steamapps/appmanifest_broken.acf", content: "\"AppState\" { \"name\"")
        let scan = SteamLibrary.scan(root: steam, client: .windows)
        XCTAssertEqual(scan.games.map(\.appID), ["10", "20"])
        XCTAssertEqual(scan.games.map(\.name), ["First game", "Second game"])
        XCTAssertEqual(scan.warnings.count, 2)
        XCTAssertTrue(scan.transfers.isEmpty)
    }

    func testVDFParserHandlesCommentsEscapedQuotesLegacyPathsAndMalformedData() throws {
        let value = try VDFParser.parse(#"""
        // comment
        "Root" { "name" "A \"quoted\" game" "path" "C:\Games" "nested" { "flag" "4" } }
        """#)
        XCTAssertEqual(value["root"]?["name"]?.string, "A \"quoted\" game")
        XCTAssertEqual(value["root"]?["path"]?.string, #"C:\Games"#)
        XCTAssertEqual(value["root"]?["nested"]?["flag"]?.string, "4")
        XCTAssertThrowsError(try VDFParser.parse("\"Root\" {"))
        XCTAssertThrowsError(try VDFParser.parse("}"))
        XCTAssertThrowsError(try VDFParser.parse("\"unterminated"))
    }

    func testConfigurationRoundTripKeepsNonSteamEnvironmentBinding() throws {
        let runtime = RuntimeInstallation(kind: .wine, executable: root.appendingPathComponent("bin/wine"))
        let profile = RuntimeProfile(runtime: runtime, prefix: root.appendingPathComponent("prefix"), name: "Wine")
        var config = LauncherConfiguration()
        config.customProfiles = [profile]
        config.selectedProfileID = profile.id
        config.addedGames = [AddedGame(name: "Test", executable: root.appendingPathComponent("game.exe"), profileID: profile.id)]
        let store = ConfigurationStore(file: root.appendingPathComponent("settings/settings.json"))
        try store.save(config)
        let decoded = try store.load()
        XCTAssertEqual(decoded.customProfiles, [profile])
        XCTAssertEqual(decoded.selectedProfileID, profile.id)
        XCTAssertEqual(decoded.addedGames, config.addedGames)
        try Data("bad json".utf8).write(to: store.file)
        XCTAssertThrowsError(try store.load())
    }

    func testProcessRunnerPassesArgumentsLiterallyAndWritesOutputAndExitCode() throws {
        let script = try file("bin/fixture", content: "#!/bin/sh\nprintf '%s\\n' \"$1\" \"$WINEPREFIX\"\nprintf 'runtime error\\n' >&2\nexit 7\n", executable: true)
        let literal = "a b; $(touch should-not-exist)"
        let finished = expectation(description: "launch exits")
        let launch = try ProcessRunner.start(LaunchCommand(executable: script, arguments: [literal], environment: ["WINEPREFIX": "test-prefix"]), logsDirectory: root.appendingPathComponent("logs")) { code in
            XCTAssertEqual(code, 7)
            finished.fulfill()
        }
        wait(for: [finished], timeout: 5)
        let log = try String(contentsOf: launch.logURL)
        XCTAssertTrue(log.contains(literal + "\ntest-prefix\nruntime error"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("should-not-exist").path))
    }
}
