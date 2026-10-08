import Combine
import Foundation
import PlaydockCore

@MainActor
public final class DownloadsModel: ObservableObject {
    public init() {}
    @Published public var transfers: [SteamTransfer] = []
    @Published public var policyMessage: String?

    public let scheduler = DownloadScheduler()
}
