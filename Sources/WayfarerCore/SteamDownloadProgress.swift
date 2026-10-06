import Foundation

/// Live overview counters are authoritative for an active transfer. The queue
/// and on-disk manifest can lag while Steam downloads or prepares disk space.
public struct SteamDownloadProgress: Sendable {
    public let phase: String
    public let completed: UInt64
    public let total: UInt64
    public let networkBytesPerSecond: UInt64?
    public let diskBytesPerSecond: UInt64?
    public let secondsRemaining: Int?
    public let detail: String?
    public var fraction: Double? { total > 0 ? min(1,Double(completed)/Double(total)) : nil }
    public init(live: SteamLiveDownload?, saved: SteamTransfer?) {
        guard let live else {
            phase=saved?.phase == .install ? "Installing" : saved?.phase.rawValue ?? "Waiting for Steam"
            completed=saved?.completed ?? 0; total=saved?.total ?? 0
            networkBytesPerSecond=nil; diskBytesPerSecond=nil; secondsRemaining=nil; detail="Last saved progress · Connect Steam for live updates."
            return
        }
        networkBytesPerSecond=live.active && !live.paused ? live.networkBytesPerSecond : nil
        diskBytesPerSecond=live.active && !live.paused ? live.diskBytesPerSecond : nil
        secondsRemaining=live.active && !live.paused ? live.secondsRemaining : nil
        let labels=["Preallocating":"Preparing disk space","Downloading":"Downloading","Staging":"Installing","Unpacking":"Unpacking","Verifying":"Verifying files","VerifyingInstalledFiles":"Verifying files","VerifyingStagedFiles":"Verifying files","Validating":"Verifying files","Copying":"Copying files","Committing":"Finishing installation","Reconfiguring":"Preparing installation"]
        phase=live.paused ? "Paused" : !live.active ? "Queued" : live.updateState.flatMap{labels[$0]} ?? "Waiting for Steam"
        if live.active, !live.paused, let state=live.updateState, state != "Downloading" {
            completed=live.phaseDownloaded ?? 0; total=live.phaseTotal ?? 0
        } else {
            completed=live.downloaded; total=live.total
        }
        if live.active && !live.paused && live.updateState == "Preallocating" { detail="Steam is reserving disk space before downloading." }
        else if live.active && !live.paused && live.updateState == "Downloading" && (live.networkBytesPerSecond ?? 0) == 0 && (live.diskBytesPerSecond ?? 0) == 0 { detail="Waiting for Steam to transfer data." }
        else { detail=nil }
    }
}
