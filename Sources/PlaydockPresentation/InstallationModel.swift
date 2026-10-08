import Combine
import Foundation
import PlaydockCore

@MainActor
public final class InstallationModel: ObservableObject {
    public init() {}
    @Published public var installationRequest: GameInstallationRequest?
    @Published public var uninstallationRequest:GameUninstallationRequest?
    @Published public var uninstallBusy=false
    @Published public var uninstallMessage=""
    @Published public var installDialog = SteamInstallDialogState()
    @Published public var storageFolders: [SteamStorageFolder] = []
    @Published public var storageMessage: String?
    @Published public var storageBusy = false
    @Published public var maintenance:[String:SteamMaintenanceProgress]=[:]
    public var installPlan: SteamInstallPlan? { installDialog.plan }
    public var installBusy: Bool { installDialog.busy }
    public var installMessage: String { installDialog.message }
    public var installRevision: UUID { installDialog.operationID }

    public let installationCoordinator = InstallCoordinator()
    public let maintenanceCoordinator = MaintenanceCoordinator()
    public var installationRevision = 0
}
