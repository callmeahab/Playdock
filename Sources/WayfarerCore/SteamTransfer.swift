import Foundation

/// Manifest snapshot; ownership and live speed come from Steam.
public struct SteamTransfer: Identifiable, Hashable, Sendable {
    public enum Phase: String, Sendable { case download = "Download", install = "Installation", pending = "Pending in Steam" }
    public var appID: String
    public var name: String
    public var library: URL
    public var artwork: URL?
    /// Transfer client, independent of depot compatibility.
    public var client: GamePlatform
    public var downloaded: UInt64
    public var downloadTotal: UInt64
    public var staged: UInt64
    public var stageTotal: UInt64
    public var id: String { "\(client.rawValue):\(library.path):\(appID)" }
    public var phase: Phase {
        if downloadTotal > 0 && downloaded < downloadTotal { return .download }
        if stageTotal > 0 && staged < stageTotal { return .install }
        return .pending
    }
    public var completed: UInt64 { phase == .install ? min(staged, stageTotal) : min(downloaded, downloadTotal) }
    public var total: UInt64 { phase == .install ? stageTotal : downloadTotal }
    public var progress: Double? { total > 0 && phase != .pending ? min(1, Double(completed) / Double(total)) : nil }

    static func from(state: VDFValue, library: URL, artwork: URL?, client: GamePlatform) -> SteamTransfer? {
        guard let id = state["appid"]?.string, let number = UInt32(id), number > 0,
              let name = state["name"]?.string, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let flags = UInt(state["StateFlags"]?.string ?? ""),
              flags & 2 != 0 else { return nil }
        func bytes(_ key: String) -> UInt64 { UInt64(state[key]?.string ?? "") ?? 0 }
        return SteamTransfer(appID: id, name: name, library: library, artwork: artwork, client: client,
                             downloaded: bytes("BytesDownloaded"), downloadTotal: bytes("BytesToDownload"),
                             staged: bytes("BytesStaged"), stageTotal: bytes("BytesToStage"))
    }
}
