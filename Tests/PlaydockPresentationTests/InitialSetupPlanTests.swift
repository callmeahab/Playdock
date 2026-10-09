import XCTest
import PlaydockCore
@testable import PlaydockPresentation

final class InitialSetupPlanTests: XCTestCase {
    private func environment(ready: Bool = false, supported: Bool = true, licensed: Bool = true) -> SteamIntegrationEnvironment {
        var state = SteamIntegrationEnvironment()
        state.steamPresent = true; state.steamBuild = "1788652215"; state.steamSupported = true; state.ready = ready
        state.crossOver = [SteamIntegrationCrossOver(path: "/Preview.app", name: "CrossOver Preview", version: "20261006",
            supported: supported, licensed: licensed, supportDetail: "", licenseDetail: "")]
        return state
    }

    private func action(_ state: SteamIntegrationEnvironment?, system: Bool = true, windows: Bool = true,
                        path: String = "", mode: SteamConnectionMode = .unavailable, signingIn: Bool = false) -> InitialSetupPlan.Action {
        InitialSetupPlan(environment: state, supportedSystem: system, windowsEnabled: windows,
                         crossOverPath: path, connection: mode, signingIn: signingIn).action
    }

    func testMissingSteamAndIncompleteSteamHaveDistinctActions() {
        XCTAssertEqual(action(nil), .check)
        XCTAssertEqual(action(SteamIntegrationEnvironment()), .getSteam)
        var incomplete = environment(); incomplete.steamBuild = nil
        XCTAssertEqual(action(incomplete), .openSteam)
    }

    func testAutomaticCrossOverSelectionSkipsAnUnsupportedStableInstallation() {
        var state = environment()
        var stable = state.crossOver[0]; stable.path = "/Stable.app"; stable.supported = false
        state.crossOver.insert(stable, at: 0)
        XCTAssertEqual(action(state), .install)
        XCTAssertEqual(action(state, path: stable.path), .getCrossOver)
        XCTAssertEqual(action(state, path: "/Missing.app"), .getCrossOver)
    }

    func testMissingRuntimeAndActivationAreActionable() {
        var state = environment(); state.crossOver = []
        XCTAssertEqual(action(state), .getCrossOver)
        XCTAssertEqual(action(environment(licensed: false)), .activateCrossOver)
    }

    func testInterruptedOrBrokenSetupUsesRepairInsteadOfInstall() {
        var interrupted = environment(); interrupted.recoveryNeeded = true
        XCTAssertEqual(action(interrupted), .repair)
        var broken = environment(); broken.installed = true
        XCTAssertEqual(action(broken), .repair)
    }

    func testNativeOnlyAndUnsupportedSystemsDoNotRequireCrossOver() {
        var state = environment(); state.crossOver = []
        XCTAssertEqual(action(state, windows: false), .connect)
        XCTAssertEqual(action(state, system: false), .connect)
        state.steamSupported = false
        XCTAssertEqual(action(state), .connect)
        XCTAssertEqual(action(state, mode: .online), .finish)
    }

    func testSignedOutAndOfflineAccountsHaveDifferentNextSteps() {
        let state = environment(ready: true)
        XCTAssertEqual(action(state), .connect)
        XCTAssertEqual(action(state, mode: .signedOut), .signIn)
        XCTAssertEqual(action(state, mode: .offline), .finish)
        XCTAssertEqual(action(state, mode: .online), .finish)
    }

    func testReturningFromSteamSignInConnectsBeforePatchingOrRequestingAnotherLogin() {
        XCTAssertEqual(action(environment(), mode: .signedOut, signingIn: true), .connect)
    }

    func testReviewingSetupSuppressesFuturePromptsIncludingWhenInspectionFails() {
        XCTAssertTrue(InitialSetupPlan.shouldPresentAtLaunch(reviewed: false, environment: nil))
        XCTAssertTrue(InitialSetupPlan.shouldPresentAtLaunch(reviewed: false, environment: environment()))
        XCTAssertFalse(InitialSetupPlan.shouldPresentAtLaunch(reviewed: true, environment: nil))
        XCTAssertFalse(InitialSetupPlan.shouldPresentAtLaunch(reviewed: true, environment: environment()))
        XCTAssertFalse(InitialSetupPlan.shouldPresentAtLaunch(reviewed: false, environment: environment(ready: true)))
    }

    func testSetupReviewIsPersistedAndAbsentForFreshSettings() throws {
        let store = ConfigurationStore(file: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("settings.json"))
        defer { try? FileManager.default.removeItem(at: store.file.deletingLastPathComponent()) }
        XCTAssertNil(try store.load().setupReviewedAt)
        var configuration = LauncherConfiguration(); configuration.setupReviewedAt = Date(timeIntervalSince1970: 100)
        try store.save(configuration)
        XCTAssertEqual(try store.load().setupReviewedAt, configuration.setupReviewedAt)
    }
}
