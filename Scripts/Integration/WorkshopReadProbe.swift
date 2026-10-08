import Foundation
import PlaydockCore

@main struct WorkshopReadProbe {
    static func main() async {
        do { try await run() }
        catch { print("Workshop read unavailable:", error.localizedDescription); exit(1) }
    }
    static func run() async throws {
        if CommandLine.arguments.count == 4, CommandLine.arguments[1] == "--lookup" {
            let service = WorkshopService()
            let item = try await service.lookup(appID: CommandLine.arguments[2], input: CommandLine.arguments[3])
            print("Validated public item:", item.id, "for game:", item.appID, "title:", item.title)
            return
        }
        guard CommandLine.arguments.count >= 3, let port = UInt16(CommandLine.arguments[1]) else { return }
        let appID = CommandLine.arguments[2]
        let home = FileManager.default.homeDirectoryForCurrentUser
        let root = home.appendingPathComponent("Library/Application Support/Steam")
        let control = SteamControl(endpoint: SteamControlEndpoint(port: port, root: root))
        let snapshot = try await control.workshop(appID: appID)
        print("Workshop visible:", snapshot.supported as Any, "subscriptions:", snapshot.items.count)
        print("Capabilities: subscribe=\(snapshot.capabilities.subscribe), disable=\(snapshot.capabilities.disable), reorder=\(snapshot.capabilities.reorder)")
        let service = WorkshopService(cacheDirectory: URL(fileURLWithPath: "/private/tmp/playdock-workshop-read-cache"))
        let resolved = try await service.resolve(snapshot, scope: "read-only-probe", root: root, save: false)
        print("Local items:", resolved.items.count, "downloaded:", resolved.items.filter { $0.download == .downloaded }.count)
        if CommandLine.arguments.count > 3 {
            let item = try await service.lookup(appID: appID, input: CommandLine.arguments[3])
            print("Validated public item:", item.id, "for game:", item.appID, "title:", item.title)
        }
    }
}
