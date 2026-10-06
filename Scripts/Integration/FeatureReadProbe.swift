import Foundation
import WayfarerCore

@main struct FeatureReadProbe {
    static func main() async {
        do { try await run() } catch { print("Backend is reconnecting or unavailable") }
    }
    static func run() async throws {
        guard CommandLine.arguments.count >= 3, let port=UInt16(CommandLine.arguments[1]) else { return }
        let windows=CommandLine.arguments[2]=="windows"
        let home=FileManager.default.homeDirectoryForCurrentUser
        let prefix=home.appendingPathComponent("Library/Application Support/CrossOver/Bottles/Steam")
        let root=windows ? prefix.appendingPathComponent("drive_c/Program Files (x86)/Steam") : home.appendingPathComponent("Library/Application Support/Steam")
        let client=SteamControl(endpoint:SteamControlEndpoint(port:port,root:root,prefix:windows ? prefix : nil))
        let snapshot=try await client.snapshot()
        print("Mode:",snapshot.mode.title)
        for download in snapshot.downloads { print("Transfer:",download.appID,"phase:",download.updateState ?? "unknown","network bytes:",download.downloaded,"of:",download.total,"phase bytes:",download.phaseDownloaded as Any,"of:",download.phaseTotal as Any,"network B/s:",download.networkBytesPerSecond as Any,"disk B/s:",download.diskBytesPerSecond as Any,"paused:",download.paused) }
        print("Capabilities:",try await client.capabilities())
        do { let friends=try await client.friends(); print("Friends ready:",friends.ready,"count:",friends.friends.count,"unread:",friends.unread) } catch { print("Friends unavailable") }
        do { let settings=try await client.downloadSettings(); print("Bandwidth KB/s:",settings.bandwidthKBps,"schedule:",settings.scheduled,"hours:",settings.startHour,settings.endHour) } catch { print("Download settings unavailable") }
        if CommandLine.arguments.count>3 {
            do { let status=try await client.cloudStatus(appID:CommandLine.arguments[3]); print("Cloud:",status.title,"state:",status.state as Any,"progress:",status.progress as Any) } catch { print("Cloud unavailable") }
        }
    }
}
