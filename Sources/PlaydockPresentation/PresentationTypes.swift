import Foundation
import CoreGraphics
import PlaydockCore

public struct GameInstallationRequest: Identifiable, Sendable {
    public init(game: LibraryGame, platform: GamePlatform, appID: String) {
        self.game = game; self.platform = platform; self.appID = appID
    }
    public let id=UUID()
    public let game: LibraryGame
    public let platform: GamePlatform
    public let appID: String
}
public struct GameUninstallationRequest:Identifiable, Sendable {
    public init(game: LibraryGame, platform: GamePlatform, appID: String, profileID: String?, location: URL) {
        self.game = game; self.platform = platform; self.appID = appID; self.profileID = profileID; self.location = location
    }
    public let id=UUID()
    public let game:LibraryGame
    public let platform:GamePlatform
    public let appID:String
    public let profileID:String?
    public let location:URL
}

public struct SteamLaunchPrompt: Identifiable {
    public init(record: GameSessionRecord, launch: SteamGameLaunch) { self.record = record; self.launch = launch }
    public let record: GameSessionRecord
    public let launch: SteamGameLaunch
    public var id: String { "\(record.id):\(launch.actionID):\(launch.task):\(launch.request ?? "")" }
    public var response: SteamLaunchResponse? {
        switch (launch.task, launch.request) {
        case ("SynchronizingCloud", "syncfailed"): .playWithoutCloud
        case ("SynchronizingCloud", "pendingcloudsessions"): .ignorePendingCloud
        case ("RunningInstallScript", _): .ignoreInstallError
        case ("KickingOtherSession", _): .endOtherSession
        default: nil
        }
    }
    public var button: String {
        switch response {
        case .playWithoutCloud: "Play without syncing"
        case .ignorePendingCloud: "Use this Mac’s saves"
        case .ignoreInstallError: "Continue anyway"
        case .endOtherSession: "End other session and play"
        default: ""
        }
    }
}

public struct SessionWindow: Identifiable, Equatable {
    public init(peer: NativeDisplayPeer, nativeID: Int, title: String, frame: CGRect, visible: Bool, focused: Bool, order: Double, program: String) {
        self.peer = peer; self.nativeID = nativeID; self.title = title; self.frame = frame
        self.visible = visible; self.focused = focused; self.order = order; self.program = program
    }
    public let peer: NativeDisplayPeer
    public let nativeID: Int
    public let title: String
    public let frame: CGRect
    public let visible: Bool
    public let focused: Bool
    public let order: Double
    public let program: String
    public var id: String { "\(peer.id):\(nativeID)" }
    public var isSteamClient: Bool { ["steam.exe", "steamwebhelper.exe", "explorer.exe"].contains(program.lowercased()) }
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id && lhs.title == rhs.title && lhs.frame == rhs.frame &&
        lhs.visible == rhs.visible && lhs.focused == rhs.focused && lhs.order == rhs.order &&
        lhs.program == rhs.program
    }
}
