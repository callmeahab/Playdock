import Combine
import Foundation
import PlaydockCore

@MainActor
public final class RuntimeModel: ObservableObject {
    public init() {}
    @Published public var runtimes: [RuntimeInstallation] = []
    @Published public var profiles: [RuntimeProfile] = [] { didSet { changed?() } }
    @Published public var prefixToolsBusy = Set<URL>()
    @Published public var prefixMessages: [URL: String] = [:]
    @Published public var performanceSnapshots: [String: PerformanceEnvironmentSnapshot] = [:]
    @Published public var performanceBusy = Set<String>()
    @Published public var performanceMessages: [String: String] = [:]
    @Published public var capturingPerformanceFor: String?
    @Published public var bridgeEnvironment: SteamIntegrationEnvironment?
    @Published public var bridgeChecking = false
    @Published public var bridgeBusy = false
    @Published public var bridgeProgress = SteamIntegrationProgress("Preparing", canCancel: true)
    @Published public var bridgeMessage: String?
    @Published public var bridgeCheckMessage: String?
    @Published public var bridgeCrossOverPath = ""
    @Published public var windowsAppsProfile: RuntimeProfile?
    @Published public var windowsApps: [RuntimeProcessIdentity.WindowsProcess] = []
    @Published public var windowsAppsBusy = false
    @Published public var windowsAppsLoading = false
    @Published public var windowsAppsCanForceQuit = false
    @Published public var windowsAppsMessage = ""
    public var changed: (() -> Void)?

    public let runtimeService = RuntimeService()
    public let runtimeProcesses = RuntimeProcessService()
    public let performanceEnvironments = PerformanceEnvironmentService()
    public let performanceReportService = PerformanceReportService()
    public let prefixService = GamePrefixService()
    public var performanceCapture: Task<Void, Never>?
    public var automaticProfileID: String?
    public var runtimeFingerprints: [String: String] = [:]
    public var discoveredMacSteamClient: URL?
    public var windowsAppsOperation = UUID()
    public var windowsAppsTask: Task<Void, Never>?
}
