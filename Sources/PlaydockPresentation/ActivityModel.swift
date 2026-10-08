import Combine
import Foundation
import PlaydockCore

@MainActor
public final class ActivityModel: ObservableObject {
    public init() {}
    @Published public var gameplayQuiet = false
    @Published public var pendingGameTitle: String?
    @Published public var nativeGameWindows: [SessionWindow] = []
    @Published public var steamLaunchPrompt: SteamLaunchPrompt?
    @Published public var steamLaunchResponseBusy = false
    @Published public var status = "Checking installed runtimes…"
    @Published public var latestLog: URL?
    @Published public var activeLaunches: [UUID: String] = [:]

    public let sessionCoordinator = SessionMonitor()
    public let performanceCoordinator = PerformanceCoordinator()
    public var sessionHistoryRevision = 0
}
