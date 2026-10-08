import Foundation

public enum SteamIntegrationPaths {
    public static let supportDirectoryName = "Wayfarer/SteamIntegration"
    public static let dylibName = "libWayfarerSteam.dylib"
    // Steam recognizes Proton names when mapping Windows Cloud-save paths.
    public static let toolID = "wayfarer-proton"
    public static var currentRunner: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/" + supportDirectoryName + "/runners/current")
    }
}

public enum SteamIntegrationOperation: String, Codable, Sendable, CaseIterable {
    case install, repair, remove
    public var title: String {
        switch self { case .install: "Set up"; case .repair: "Repair integration"; case .remove: "Remove integration" }
    }
}

public struct SteamIntegrationEnvironment: Codable, Equatable, Sendable {
    public var steamPresent: Bool = false
    public var steamBuild: String?
    public var steamSupported: Bool = false
    public var installed: Bool = false
    public var ready: Bool = false
    public var recoveryNeeded: Bool = false
    public var recoveryAvailable: Bool = false
    public var crossOver: [SteamIntegrationCrossOver] = []
    public var problems: [String] = []
    public init() {}
    public var usableCrossOver: SteamIntegrationCrossOver? { crossOver.first { $0.supported && $0.licensed } }
    public func selectedCrossOver(path: String?) -> SteamIntegrationCrossOver? {
        if let path, !path.isEmpty { return crossOver.first { $0.path == path } }
        return usableCrossOver ?? crossOver.first
    }
    public func canSetUp(crossOver path: String?) -> Bool {
        guard steamPresent, steamSupported, let install = selectedCrossOver(path: path) else { return false }
        return install.supported && install.licensed
    }
}

public struct SteamIntegrationCrossOver: Codable, Equatable, Sendable, Identifiable {
    public var path: String
    public var name: String
    public var version: String
    public var supported: Bool
    public var licensed: Bool
    public var supportDetail: String
    public var licenseDetail: String
    public var id: String { path }
    public init(path: String, name: String, version: String, supported: Bool, licensed: Bool, supportDetail: String, licenseDetail: String) {
        self.path = path; self.name = name; self.version = version; self.supported = supported; self.licensed = licensed
        self.supportDetail = supportDetail; self.licenseDetail = licenseDetail
    }
}

public struct SteamIntegrationHelperRequest: Codable, Sendable {
    public var operation: String
    public var resources: String?
    public var crossOver: String?
    public var output: String
    public var progress: String
    public init(operation: String, resources: String?, crossOver: String?, output: String, progress: String) {
        self.operation = operation; self.resources = resources; self.crossOver = crossOver; self.output = output; self.progress = progress
    }
}

public struct SteamIntegrationHelperResult: Codable, Sendable {
    public var environment: SteamIntegrationEnvironment?
    public var message: String?
    public var error: String?
    public var restartSteam: Bool
    public init(environment: SteamIntegrationEnvironment? = nil, message: String? = nil, error: String? = nil, restartSteam: Bool = false) {
        self.environment = environment; self.message = message; self.error = error; self.restartSteam = restartSteam
    }
}

public struct SteamIntegrationProgress: Codable, Equatable, Sendable {
    public var message: String
    public var canCancel: Bool
    public init(_ message: String, canCancel: Bool) { self.message = message; self.canCancel = canCancel }
}

public enum SteamIntegrationRelease {
    public static let version = "1"
    public static let resourceManifestSHA256 = "3d860e67112f17b89661009fb03f4ca5a6dd409e51e0e7b6e0268c8088e9ec12"
    public static let steamBuilds: Set<String> = ["1788652215", "1790121765", "1790904859"]
}

public enum SteamBridgeInjection {
    public static func libraries(adapter: URL, steamApp: URL = URL(fileURLWithPath: "/Applications/Steam.app")) throws -> String {
        let plist = steamApp.appendingPathComponent("Contents/Info.plist")
        guard FileManager.default.fileExists(atPath: plist.path) else { return adapter.path }
        guard let size = (try FileManager.default.attributesOfItem(atPath: plist.path)[.size] as? NSNumber)?.intValue, size < 1_000_000,
              let info = try PropertyListSerialization.propertyList(from: Data(contentsOf: plist), format: nil) as? [String: Any] else {
            throw WayfarerError.message("Steam’s startup configuration could not be read.")
        }
        let bridge = steamApp.appendingPathComponent("Contents/MacOS/" + SteamIntegrationPaths.dylibName)
        let declared = (info["LSEnvironment"] as? [String: Any])?["DYLD_INSERT_LIBRARIES"] as? String ?? ""
        let components = declared.split(separator: ":").map(String.init)
        guard components.contains(bridge.path) else { return adapter.path }
        guard components == [bridge.path], FileManager.default.fileExists(atPath: bridge.path) else {
            throw WayfarerError.message("Steam’s bridge loading configuration needs repair. Use Engines → Manage Steam–CrossOver bridge.")
        }
        return [adapter.path, bridge.path].joined(separator: ":")
    }
}
