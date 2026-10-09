import PlaydockCore

public struct InitialSetupPlan: Equatable, Sendable {
    public enum Action: Equatable, Sendable {
        case check, getSteam, openSteam, getCrossOver, activateCrossOver, install, repair, connect, signIn, finish

        public var title: String {
            switch self {
            case .check: "Try again"
            case .getSteam: "Get Steam"
            case .openSteam: "Open Steam"
            case .getCrossOver: "Get CrossOver Preview"
            case .activateCrossOver: "Activate CrossOver"
            case .install: "Enable Windows games"
            case .repair: "Repair Windows support"
            case .connect: "Connect Steam"
            case .signIn: "Sign in to Steam"
            case .finish: "Open library"
            }
        }
    }

    public let action: Action
    public let detail: String
    public init(environment: SteamIntegrationEnvironment?, supportedSystem: Bool, windowsEnabled: Bool,
                crossOverPath: String, connection: SteamConnectionMode, signingIn: Bool) {
        guard let environment else {
            action = .check; detail = "Check this Mac for Steam and CrossOver."
            return
        }
        guard environment.steamPresent else {
            action = .getSteam; detail = "Install Steam, then return here. Playdock will find it automatically."
            return
        }
        if signingIn {
            action = .connect; detail = "Finish signing in through Steam, then connect it here."
        } else if environment.steamBuild == nil {
            action = .openSteam; detail = "Let Steam finish installing and sign in to your account, then return here."
        } else if supportedSystem && windowsEnabled && !environment.ready && environment.steamSupported {
            if let install = environment.selectedCrossOver(path: crossOverPath), install.supported {
                if !install.licensed {
                    action = .activateCrossOver; detail = "Activate \(install.name), then return here."
                } else {
                    action = environment.installed || environment.recoveryNeeded ? .repair : .install
                    detail = action == .repair ? "Restore Windows support using \(install.name)." : "Use \(install.name) to run Windows games from your Steam library."
                }
            } else {
                action = .getCrossOver; detail = "Install and activate a compatible CrossOver Preview, then return here."
            }
        } else {
            switch connection {
            case .signedOut: action = .signIn; detail = "Sign in through Steam. Playdock never asks for your password."
            case .unavailable: action = .connect; detail = "Connect your Steam library. Saved games appear while the library refreshes."
            case .online, .offline: action = .finish; detail = "Your Steam library is ready. Games appear as they’re found."
            }
        }
    }

    public static func shouldPresentAtLaunch(reviewed: Bool, environment: SteamIntegrationEnvironment?) -> Bool {
        !reviewed && environment?.ready != true
    }
}
