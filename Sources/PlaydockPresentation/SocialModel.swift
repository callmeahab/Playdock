import Combine
import Foundation
import PlaydockCore

@MainActor
public final class SocialModel: ObservableObject {
    public init() {}
    @Published public var snapshot: SteamFriendsSnapshot?
    @Published public var message: String?
    @Published public var busy = false

    public let coordinator = SocialCoordinator()
}
