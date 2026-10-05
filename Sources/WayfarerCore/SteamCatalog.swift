import Foundation

public struct SteamCatalogGame: Codable, Hashable, Sendable {
    public var appID: String
    public var name: String
    public var client: GamePlatform
    public var profileID: String?
    public var artwork: URL?
    public var heroArtwork: URL?
    public init(appID: String, name: String, client: GamePlatform, profileID: String? = nil, artwork: URL? = nil, heroArtwork: URL? = nil) {
        self.appID = appID; self.name = name; self.client = client; self.profileID = profileID
        self.artwork = artwork; self.heroArtwork = heroArtwork
    }
}

public struct SteamCatalogSnapshot: Sendable {
    public let games: [SteamCatalogGame]
    public let missingMetadata: Int
}

/// Steam supplies current licenses. Package metadata supplies app membership; appinfo supplies names and OS support only;
/// metadata, artwork and installed manifests are never treated as licenses.
public enum SteamCatalog {
    public static func boundaryAppID(_ nonce: UUID) -> UInt32 {
        let value = withUnsafeBytes(of: nonce.uuid) { $0.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) } }
        return 1_000_000_000 + value % 1_000_000_000
    }
    public static func commandArguments(nonce: UUID) -> [String] {
        ["-silent", "-console", "-wayfarer-library-request=\(nonce.uuidString)", "+licenses_print", "+licenses_for_app", String(boundaryAppID(nonce))]
    }
    public static func response(_ text: String, nonce: UUID) -> String? {
        let cleaned = text.replacingOccurrences(of: #"\[\d{4}-\d{2}-\d{2}[^\]]*\]\s?"#, with: "", options: .regularExpression)
        let lines = cleaned.components(separatedBy: .newlines)
        guard let begin = lines.firstIndex(where: { $0.hasPrefix("ExecCommandLine:") && $0.lowercased().contains("-wayfarer-library-request=\(nonce.uuidString.lowercased())") && $0.contains("+licenses_print") }),
              let end = lines[(begin+1)...].firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "No active license found for appID \(boundaryAppID(nonce))." }) else { return nil }
        return lines[(begin+1)..<end].joined(separator: "\n")
    }
    public static func activePackageIDs(_ response: String) throws -> Set<UInt32> {
        guard response.utf8.count <= 8_000_000 else { throw WayfarerError.message("Steam's library response is too large.") }
        var ids = Set<UInt32>(), seen = Set<UInt32>()
        for block in response.components(separatedBy: "License packageID ").dropFirst() {
            guard let header = block.firstIndex(of: ":"), let id = UInt32(block[..<header]), seen.insert(id).inserted,
                  let state = block.range(of: " - State"), let purchased = block.range(of: " - Purchased"), state.upperBound < purchased.lowerBound else {
                throw WayfarerError.message("Steam's license response has changed. Open its library and try refreshing again.")
            }
            let status = block[state.upperBound..<purchased.lowerBound]
            if status.components(separatedBy: .newlines).contains(where: { $0.trimmingCharacters(in: .whitespaces) == "Active" }) { ids.insert(id) }
        }
        return ids
    }
    public static func snapshot(response: String, root: URL, client: GamePlatform, profileID: String? = nil) throws -> SteamCatalogSnapshot {
        let packages = try activePackageIDs(response)
        let memberships = try SteamAppInfo.packageApps(Data(contentsOf: root.appendingPathComponent("appcache/packageinfo.vdf")), packageIDs: packages)
        let ids = Set(memberships.values.flatMap { $0 })
        return try metadataSnapshot(ids:ids,root:root,client:client,profileID:profileID,missingPackages:packages.subtracting(memberships.keys).count)
    }
    /// The caller obtains these IDs from the authenticated Steam client's ownership store.
    public static func snapshot(ownedAppIDs:[String],root:URL,client:GamePlatform,profileID:String?=nil) throws -> SteamCatalogSnapshot {
        guard ownedAppIDs.count <= 50_000 else { throw WayfarerError.message("Steam’s library is too large.") }
        let ids=try Set(ownedAppIDs.map { id -> UInt32 in
            _=try NativeGameLaunch.steamURL(appID:id); return UInt32(id)!
        })
        return try metadataSnapshot(ids:ids,root:root,client:client,profileID:profileID,missingPackages:0)
    }
    private static func metadataSnapshot(ids:Set<UInt32>,root:URL,client:GamePlatform,profileID:String?,missingPackages:Int) throws -> SteamCatalogSnapshot {
        let metadata = try SteamAppInfo.read(Data(contentsOf: root.appendingPathComponent("appcache/appinfo.vdf")), appIDs: ids)
        var games: [SteamCatalogGame] = [], missing = missingPackages
        for id in ids {
            guard let info = metadata[id] else { missing += 1; continue }
            guard ["game", "demo"].contains(info.type.lowercased()) else { continue }
            let os = info.osList.lowercased().split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            if os.isEmpty { missing += 1; continue }
            guard os.contains(client == .macOS ? "macos" : "windows") else { continue }
            let appID = String(id)
            games.append(SteamCatalogGame(appID: appID, name: info.name, client: client, profileID: profileID,
                artwork: SteamLibrary.artwork(root: root, appID: appID), heroArtwork: SteamLibrary.artwork(root: root, appID: appID, wide: true)))
        }
        return SteamCatalogSnapshot(games: games.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }, missingMetadata: missing)
    }
    public static func recentAccount(root: URL) -> String? {
        guard let text = try? String(contentsOf: root.appendingPathComponent("config/loginusers.vdf"), encoding: .utf8),
              let parsed = try? VDFParser.parse(text), let users = parsed["users"]?.object else { return nil }
        let identities = users.filter { UInt64($0.key) != nil }
        if let explicit = identities.first(where: { $0.value["MostRecent"]?.string == "1" }) { return explicit.key }
        // Newer clients omit MostRecent. A single cached identity is unambiguous;
        // multiple identities use Steam's most recent login timestamp, rejecting ties.
        if identities.count == 1 { return identities.first?.key }
        let dated = identities.compactMap { id, value -> (String, UInt64)? in
            guard let text = value["Timestamp"]?.string, let timestamp = UInt64(text), timestamp > 0 else { return nil }
            return (id, timestamp)
        }.sorted { $0.1 > $1.1 }
        guard let latest = dated.first, dated.count == 1 || latest.1 > dated[1].1 else { return nil }
        return latest.0
    }
    /// Reads only bytes appended for this request. A request-bounded response prevents
    /// historic console output or a rotated log from becoming a current license list.
    public static func refreshResponse(command: LaunchCommand, root: URL, nonce: UUID) async throws -> String {
        let log = root.appendingPathComponent("logs/console_log.txt")
        let offset = (try? FileManager.default.attributesOfItem(atPath: log.path)[.size] as? UInt64) ?? 0
        let process = Process(); process.executableURL = command.executable; process.arguments = command.arguments
        process.currentDirectoryURL = command.workingDirectory
        process.environment = ProcessInfo.processInfo.environment.merging(command.environment) { _, new in new }
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run()
        for _ in 0..<100 {
            try Task.checkCancellation()
            if let file = try? FileHandle(forReadingFrom: log) {
                defer { try? file.close() }
                let size = (try? file.seekToEnd()) ?? 0
                guard size <= offset + 8_000_000 else { throw WayfarerError.message("Steam's library response is too large.") }
                try file.seek(toOffset: size >= offset ? offset : 0)
                let data = try file.read(upToCount: 8_000_000) ?? Data()
                if let body = response(String(decoding: data, as: UTF8.self), nonce: nonce) { return body }
            }
            if !process.isRunning && process.terminationStatus != 0 { throw WayfarerError.message("Steam could not load the library. Open Steam and sign in, then refresh.") }
            try await Task.sleep(for: .milliseconds(200))
        }
        // Never terminate a client or a running game when a read times out.
        throw WayfarerError.message("Steam did not return its library. Sign in through Steam and refresh the library again.")
    }
}
