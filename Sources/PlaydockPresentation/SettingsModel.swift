import Combine
import Foundation
import PlaydockCore

@MainActor
public final class SettingsModel: ObservableObject {
    public init() {}
    @Published public var configuration = LauncherConfiguration() { didSet { changed?() } }
    public var changed: (() -> Void)?
}
