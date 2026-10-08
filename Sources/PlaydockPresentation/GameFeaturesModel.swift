import Combine
import Foundation
import PlaydockCore

@MainActor
public final class GameFeaturesModel: ObservableObject {
    public init() {}
    @Published public var achievementSnapshots:[String:AchievementSnapshot]=[:]
    @Published public var achievementMessages:[String:String]=[:]
    @Published public var achievementBusy=Set<String>()
    @Published public var workshopSnapshots: [String: WorkshopSnapshot] = [:]
    @Published public var workshopMessages: [String: String] = [:]
    @Published public var workshopBusy = Set<String>()
    @Published public var workshopChanging = Set<String>()
    @Published public var suggestedSaveFolders: [String: URL] = [:]
    @Published public var cloudStatuses: [String: SteamCloudStatus] = [:]
    @Published public var saveBackups: [String: [SaveBackup]] = [:]
    @Published public var saveBusy = false
    @Published public var saveMessage = ""

    public let achievementService = AchievementService()
    public let workshopService = WorkshopService()
    public var workshopRevisions: [String: UUID] = [:]
    public let saveService = SaveService()
}
