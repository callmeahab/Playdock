import XCTest
@testable import PlaydockCore

final class SteamControlTests: XCTestCase {
    func testOnlyKnownActionErrorsAreShownWithoutRawSteamExceptionDetails() {
        XCTAssertTrue(SteamControl.actionError("Error: Not enough space\n at internal.js").localizedDescription.contains("not enough free space"))
        let unrelated="Error: private account field"
        XCTAssertFalse(SteamControl.actionError(unrelated).localizedDescription.contains("private account field"))
        XCTAssertEqual(SteamControl.actionError("Error: Steam is not signed in.\n at internal.js").localizedDescription, "Sign in to Steam and try again.")
    }
    func testDebuggerConnectionRemainsLocalAndUsesSelectedClientPort() {
        let port:UInt16 = 49152
        XCTAssertEqual(SteamControlEndpoint.debuggerURL("ws://localhost:8080/devtools/page/shared",port:port)?.absoluteString,"ws://127.0.0.1:49152/devtools/page/shared")
        for address in ["wss://localhost/devtools/page/shared", "ws://example.com/devtools/page/shared", "ws://user:pass@localhost/devtools/page/shared", "ws://localhost/devtools/page/shared?token=x", "ws://localhost/devtools/page/shared#x", "ws://localhost/devtools/page/../other", "ws://localhost/other"] {
            XCTAssertNil(SteamControlEndpoint.debuggerURL(address,port:port),address)
        }
    }
    func testInstallStatesRequireConfigurationOrAgreementsBeforeConfirmation() throws {
        func plan(_ state:Int, required:Int=100, free:Int=200, error:Int=0) throws -> SteamInstallPlan {
            let json:[String:Any] = ["appID":"100","state":state,"requiredBytes":required,"availableBytes":free,"folder":0,"currentAppID":100,"error":error,"detail":"","eulas":[]]
            return try JSONDecoder().decode(SteamInstallPlan.self,from:JSONSerialization.data(withJSONObject:json))
        }
        XCTAssertTrue(try plan(7).canConfirm)
        XCTAssertTrue(try plan(8).canConfirm)
        for state in [0,1,4,6,9,14,15,16] { XCTAssertFalse(try plan(state).canConfirm) }
        XCTAssertFalse(try plan(7,required:300).canConfirm)
        XCTAssertFalse(try plan(7,error:1).canConfirm)
        for state in [0,9,14] { XCTAssertTrue(try plan(state).hasStarted) }
        XCTAssertFalse(try plan(15).hasStarted)
        XCTAssertFalse(try plan(9,error:1).hasStarted)
    }
    func testInstallFailureExplainsUnavailableConnectionInsteadOfOfferingConfirmation() throws {
        let p=try JSONDecoder().decode(SteamInstallPlan.self,from:Data(#"{"appID":"100","state":15,"requiredBytes":100,"availableBytes":200,"folder":0,"currentAppID":100,"error":6,"detail":"","eulas":[]}"#.utf8))
        XCTAssertFalse(p.canConfirm)
        XCTAssertTrue(p.failureMessage?.contains("no internet connection") == true)
        XCTAssertEqual(p.confirmationMessage,p.failureMessage)
    }
    func testInvalidGameAndFolderAreRejectedBeforeAccessingAnyClient() async {
        let client = SteamControl(endpoint:SteamControlEndpoint(port:0,root:URL(fileURLWithPath:"/missing")))
        do { _ = try await client.prepareInstall(appID:"100;quit"); XCTFail("Invalid game accepted") }
        catch { XCTAssertTrue(error.localizedDescription.contains("invalid Steam identifier")) }
        do { _ = try await client.chooseFolder(appID:"100",folder:-1); XCTFail("Invalid folder accepted") }
        catch { XCTAssertTrue(error.localizedDescription.contains("unavailable")) }
        do { try await client.uninstall(appID:"100;quit"); XCTFail("Invalid uninstall accepted") }
        catch { XCTAssertTrue(error.localizedDescription.contains("invalid Steam identifier")) }
        do { _=try await client.appState(appID:"0"); XCTFail("Invalid state request accepted") }
        catch { XCTAssertTrue(error.localizedDescription.contains("invalid Steam identifier")) }
    }
    func testLocalRunningAndUninstallingStatesAreDistinct() throws {
        func state(_ status:Int,installed:Bool=true) throws -> SteamAppState {
            try JSONDecoder().decode(SteamAppState.self,from:JSONSerialization.data(withJSONObject:["appID":"100","installed":installed,"owned":true,"displayStatus":status]))
        }
        XCTAssertTrue(try state(1).isRunning)
        XCTAssertTrue(try state(4).isRunning)
        XCTAssertFalse(try state(11).isRunning)
        XCTAssertTrue(try state(2).isUninstalling)
        XCTAssertFalse(try state(4).isUninstalling)
        XCTAssertFalse(try state(9,installed:false).installed)
        XCTAssertTrue(try state(9,installed:false).owned)
        XCTAssertTrue(SteamControl.actionError("Error: Close this game before uninstalling.\n at internal.js").localizedDescription.contains("Close this game"))
    }
}
