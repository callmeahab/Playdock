import Combine
import Foundation
import PlaydockCore

@MainActor
public final class SteamConnectionModel: ObservableObject {
    public init() {}
    @Published public var account: String?
    @Published public var snapshot: SteamControlSnapshot?
    @Published public var busy = false
    @Published public var message: String?
    @Published public var signingIn = false
    public var signInTask: Task<Void, Never>?

    public let coordinator = BackendCoordinator()
    public var savedControl: SteamControl?
    public var controlPort: UInt16?
    public var discoveredControlPort: UInt16?
    public var port:UInt16 = 8080
}
