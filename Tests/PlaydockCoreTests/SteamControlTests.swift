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

private final class ChannelOwner: @unchecked Sendable {
    private let lock = NSLock()
    private var generation: UInt64 = 1
    func token() -> RuntimeProcessToken {
        lock.lock(); defer { lock.unlock() }
        return RuntimeProcessToken(pid: 100, startedSeconds: generation, startedMicroseconds: 0)
    }
    func replace() { lock.lock(); generation += 1; lock.unlock() }
    func matches(_ token: RuntimeProcessToken) -> Bool { token == self.token() }
}
private actor ChannelSocket: SteamControlSocket {
    let entered: XCTestExpectation?
    let fail: Bool
    let protocolError: Bool
    private var hold: Bool
    private var waiter: CheckedContinuation<Data, any Error>?
    private var response = Data()
    var requests: [Int] = []
    var closed = false
    init(hold: Bool = false, fail: Bool = false, protocolError: Bool = false, entered: XCTestExpectation? = nil) {
        self.hold = hold; self.fail = fail; self.protocolError = protocolError; self.entered = entered
    }
    func send(_ text: String) throws {
        let request = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        let id = try XCTUnwrap(request["id"] as? Int)
        let params = try XCTUnwrap(request["params"] as? [String: Any])
        requests.append(id)
        response = try JSONSerialization.data(withJSONObject: ["id": id, "result": ["result": ["value": params["expression"] as? String ?? ""]]])
        if protocolError { response = try JSONSerialization.data(withJSONObject: ["id": id, "error": ["code": -32000, "message": "Execution context was destroyed"]]) }
    }
    func receive() async throws -> Data {
        if fail || closed { throw URLError(.networkConnectionLost) }
        if hold {
            entered?.fulfill()
            return try await withCheckedThrowingContinuation { waiter = $0 }
        }
        return response
    }
    func release() { hold = false; waiter?.resume(returning: response); waiter = nil }
    func close() { closed = true; waiter?.resume(throwing: URLError(.cancelled)); waiter = nil }
}
private actor ChannelFactory {
    let owner: ChannelOwner
    let first: ChannelSocket
    var sockets: [ChannelSocket] = []
    init(owner: ChannelOwner, first: ChannelSocket = ChannelSocket()) { self.owner = owner; self.first = first }
    func connect() -> (RuntimeProcessToken, any SteamControlSocket) {
        let socket = sockets.isEmpty ? first : ChannelSocket()
        sockets.append(socket)
        return (owner.token(), socket)
    }
}
@MainActor final class SteamControlChannelTests: XCTestCase {
    func testConcurrentRequestsReuseOneConnectionAndMatchTheirResponses() async throws {
        let owner = ChannelOwner()
        let factory = ChannelFactory(owner: owner)
        let channel = SteamControlChannel(isCurrent: owner.matches, connect: { await factory.connect() })
        let responses = try await withThrowingTaskGroup(of: String.self) { group in
            for i in 0..<12 { group.addTask { String(decoding: try await channel.evaluate("request-\(i)"), as: UTF8.self) } }
            var result: [String] = []
            for try await response in group { result.append(response) }
            return result
        }
        XCTAssertEqual(responses.count, 12)
        for i in 0..<12 { XCTAssertTrue(responses.contains { $0.contains("request-\(i)\"") }) }
        let sockets = await factory.sockets
        XCTAssertEqual(sockets.count, 1)
        let requests = await sockets[0].requests
        XCTAssertEqual(requests, Array(1...12))
        await channel.close()
    }
    func testReplacedOwnerRequiresFreshAuthentication() async throws {
        let owner = ChannelOwner(), first = ChannelSocket()
        let factory = ChannelFactory(owner: owner, first: first)
        let channel = SteamControlChannel(isCurrent: owner.matches, connect: { await factory.connect() })
        _ = try await channel.evaluate("first")
        owner.replace()
        let stale = await channel.identity()
        XCTAssertNil(stale)
        _ = try await channel.evaluate("second")
        let sockets = await factory.sockets, closed = await first.closed
        XCTAssertEqual(sockets.count, 2); XCTAssertTrue(closed)
        await channel.close()
    }
    func testTransportFailureDoesNotReplayAMutation() async throws {
        let owner = ChannelOwner(), first = ChannelSocket(fail: true)
        let factory = ChannelFactory(owner: owner, first: first)
        let channel = SteamControlChannel(isCurrent: owner.matches, connect: { await factory.connect() })
        do { _ = try await channel.evaluate("mutation"); XCTFail("Expected disconnect") } catch {}
        let before = await factory.sockets, requests = await first.requests
        XCTAssertEqual(before.count, 1); XCTAssertEqual(requests.count, 1)
        _ = try await channel.evaluate("fresh read")
        let after = await factory.sockets
        XCTAssertEqual(after.count, 2)
        await channel.close()
    }
    func testCancellingQueuedRequestPreservesActiveConnection() async throws {
        let entered = expectation(description: "First request is waiting")
        let owner = ChannelOwner(), first = ChannelSocket(hold: true, entered: entered)
        let factory = ChannelFactory(owner: owner, first: first)
        let channel = SteamControlChannel(isCurrent: owner.matches, connect: { await factory.connect() })
        let active = Task { try await channel.evaluate("first") }
        await fulfillment(of: [entered], timeout: 2)
        let queued = Task { try await channel.evaluate("cancelled") }
        queued.cancel()
        await first.release()
        _ = try await active.value
        do { _ = try await queued.value; XCTFail("Cancelled request executed") } catch is CancellationError {} catch { XCTFail("\(error)") }
        _ = try await channel.evaluate("after")
        let sockets = await factory.sockets, closed = await first.closed, requests = await first.requests
        XCTAssertEqual(sockets.count, 1); XCTAssertFalse(closed); XCTAssertEqual(requests.count, 2)
        await channel.close()
    }
    func testTimeoutClosesSocketAndNextRequestReconnects() async throws {
        let owner = ChannelOwner(), first = ChannelSocket(hold: true)
        let factory = ChannelFactory(owner: owner, first: first)
        let channel = SteamControlChannel(timeout: .milliseconds(20), isCurrent: owner.matches, connect: { await factory.connect() })
        do { _ = try await channel.evaluate("timeout"); XCTFail("Expected timeout") } catch {}
        _ = try await channel.evaluate("fresh")
        let sockets = await factory.sockets, closed = await first.closed
        XCTAssertEqual(sockets.count, 2); XCTAssertTrue(closed)
        await channel.close()
        do { _ = try await channel.evaluate("closed"); XCTFail("Closed channel accepted work") } catch {}
    }
    func testCancellingActiveRequestDisconnectsAndAllowsFreshReads() async throws {
        let entered = expectation(description: "Active request is waiting")
        let owner = ChannelOwner(), first = ChannelSocket(hold: true, entered: entered)
        let factory = ChannelFactory(owner: owner, first: first)
        let channel = SteamControlChannel(isCurrent: owner.matches, connect: { await factory.connect() })
        let request = Task { try await channel.evaluate("cancel active") }
        await fulfillment(of: [entered], timeout: 2)
        request.cancel()
        do { _ = try await request.value; XCTFail("Cancelled request completed") } catch {}
        _ = try await channel.evaluate("fresh read")
        let sockets = await factory.sockets, closed = await first.closed
        XCTAssertEqual(sockets.count, 2); XCTAssertTrue(closed)
        await channel.close()
    }
    func testDestroyedContextReconnectsBeforeTheNextRequest() async throws {
        let owner = ChannelOwner(), first = ChannelSocket(protocolError: true)
        let factory = ChannelFactory(owner: owner, first: first)
        let channel = SteamControlChannel(isCurrent: owner.matches, connect: { await factory.connect() })
        do { _ = try await channel.evaluate("first"); XCTFail("Destroyed context accepted") } catch {}
        _ = try await channel.evaluate("fresh context")
        let sockets = await factory.sockets, closed = await first.closed
        XCTAssertEqual(sockets.count, 2); XCTAssertTrue(closed)
        await channel.close()
    }
}
