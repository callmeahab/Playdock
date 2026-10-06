import XCTest
@testable import WayfarerCore

final class WindowsAppRecoveryTests: XCTestCase {
    func testWineServiceHostDoesNotCountAsAnApp() {
        for service in ["svchost.exe","services.exe","winedevice.exe","steam.exe","SteamWebHelper.exe"] {
            XCTAssertTrue(WindowsAppRecovery.isInfrastructure(service))
        }
        XCTAssertFalse(WindowsAppRecovery.isInfrastructure("game.exe"))
        XCTAssertFalse(WindowsAppRecovery.isInfrastructure("notepad.exe"))
    }

    func testForceQuitCannotAffectAnAppInAnotherEnvironment() throws {
        try withProcesses([("Selected","game.exe"),("Other","game.exe")]) { root,children in
            let selected=root.appendingPathComponent("Selected"),other=root.appendingPathComponent("Other")
            let app=try XCTUnwrap(WindowsAppRecovery.apps(prefix:selected).first { $0.token.pid==children[0].processIdentifier })
            XCTAssertThrowsError(try WindowsAppRecovery.forceQuit(app,prefix:other))
            XCTAssertTrue(children[0].isRunning)
            XCTAssertTrue(children[1].isRunning)
            XCTAssertFalse(try WindowsAppRecovery.apps(prefix:selected).contains { $0.token.pid==children[1].processIdentifier })
            XCTAssertTrue(try WindowsAppRecovery.forceQuit(app,prefix:selected))
            children[0].waitUntilExit()
            XCTAssertTrue(children[1].isRunning)
        }
    }

    func testAnOldProcessIdentityCannotCloseANewAppWithThatPID() throws {
        try withProcesses([("Selected","game.exe")]) { root,children in
            let prefix=root.appendingPathComponent("Selected")
            let app=try XCTUnwrap(WindowsAppRecovery.apps(prefix:prefix).first { $0.token.pid==children[0].processIdentifier })
            let old=RuntimeProcessIdentity.WindowsProcess(token:RuntimeProcessToken(pid:app.token.pid,startedSeconds:app.token.startedSeconds+1,startedMicroseconds:app.token.startedMicroseconds),program:app.program)
            XCTAssertFalse(try WindowsAppRecovery.forceQuit(old,prefix:prefix))
            XCTAssertTrue(children[0].isRunning)
        }
    }

    func testSteamAndWineServicesCannotBeForceQuitAsApps() throws {
        try withProcesses([("Selected","svchost.exe"),("Selected","steam.exe")]) { root,children in
            let prefix=root.appendingPathComponent("Selected")
            let apps=try WindowsAppRecovery.apps(prefix:prefix)
            let processes=try RuntimeProcessIdentity.windowsProcesses(prefix:prefix)
            for child in children {
                XCTAssertFalse(apps.contains { $0.token.pid==child.processIdentifier })
                let service=try XCTUnwrap(processes.first { $0.token.pid==child.processIdentifier })
                XCTAssertThrowsError(try WindowsAppRecovery.forceQuit(service,prefix:prefix))
                XCTAssertTrue(child.isRunning)
            }
        }
    }

    private func withProcesses(_ entries:[(String,String)],body:(URL,[Process]) throws -> Void) throws {
        let fm=FileManager.default,root=fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at:root,withIntermediateDirectories:true)
        var children:[Process]=[]
        defer {
            for child in children where child.isRunning { child.terminate(); child.waitUntilExit() }
            try? fm.removeItem(at:root)
        }
        for (folder,program) in entries {
            let prefix=root.appendingPathComponent(folder)
            try fm.createDirectory(at:prefix,withIntermediateDirectories:true)
            // Keep the system executable's original signature and path. argv[0]
            // models Wine's Windows program name, as the existing Steam fixtures do.
            let child=Process(); child.executableURL=URL(fileURLWithPath:"/bin/bash")
            child.arguments=["-c","exec -a \"$1\" /bin/sleep 30","fixture","C:\\Games\\\(program)"]
            child.currentDirectoryURL=prefix
            try child.run(); children.append(child)
            for _ in 0..<50 where RuntimeProcessIdentity.windowsProgram(for:child.processIdentifier) != program { Thread.sleep(forTimeInterval:0.01) }
            XCTAssertTrue(child.isRunning,"The process-management fixture must be alive before testing recovery.")
        }
        try body(root,children)
    }
}
