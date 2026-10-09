import Foundation

public struct RuntimeDiscovery {
    public var home: URL
    public var applicationDirectories: [URL]
    public var searchDirectories: [URL]
    public var appleSilicon: Bool

    public init(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        applicationDirectories: [URL]? = nil,
        searchDirectories: [URL]? = nil,
        appleSilicon: Bool = RuntimeDiscovery.isAppleSilicon
    ) {
        self.home = home
        self.applicationDirectories = applicationDirectories ?? [URL(fileURLWithPath: "/Applications"), home.appendingPathComponent("Applications"), home]
        let path = ProcessInfo.processInfo.environment["PATH", default: ""].split(separator: ":").map { URL(fileURLWithPath: String($0)) }
        self.searchDirectories = searchDirectories ?? [
            URL(fileURLWithPath: "/opt/homebrew/bin"), URL(fileURLWithPath: "/usr/local/bin"),
            URL(fileURLWithPath: "/opt/homebrew/opt/game-porting-toolkit/bin"), URL(fileURLWithPath: "/usr/local/opt/game-porting-toolkit/bin"),
        ] + path
        self.appleSilicon = appleSilicon
    }

    public static var isAppleSilicon: Bool {
        #if arch(arm64)
        return true
        #else
        // Host tools may run under Rosetta on Apple silicon.
        var translated: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname("sysctl.proc_translated", &translated, &size, nil, 0) == 0 && translated == 1
        #endif
    }

    public func installations() -> [RuntimeInstallation] {
        var found: [RuntimeInstallation] = []
        func add(_ kind: RuntimeKind, _ file: URL, wrapper: Bool = false) {
            guard FileManager.default.isExecutableFile(atPath: file.path) else { return }
            let runtime = RuntimeInstallation(kind: kind, executable: file, toolkitWrapper: wrapper)
            if !found.contains(where: { $0.kind == kind && $0.executable.resolvingSymlinksInPath() == file.resolvingSymlinksInPath() }) { found.append(runtime) }
        }
        for directory in applicationDirectories {
            // Discover renamed and versioned .app bundles as well as the standard names.
            let children = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
            let apps = Set(children.filter { $0.pathExtension == "app" } + [directory.appendingPathComponent("CrossOver.app")])
            for app in apps.sorted(by: { $0.path < $1.path }) {
                add(.crossOver, app.appendingPathComponent("Contents/SharedSupport/CrossOver/bin/wine"))
                for name in ["wine", "wine64"] {
                    add(.wine, app.appendingPathComponent("Contents/Resources/wine/bin/\(name)"))
                }
            }
        }
        for directory in searchDirectories {
            if appleSilicon {
                for name in ["gameportingtoolkit-no-hud", "gameportingtoolkit"] {
                    add(.gptk, directory.appendingPathComponent(name), wrapper: true)
                }
                if directory.path.contains("game-porting-toolkit") {
                    for name in ["wine64", "wine"] { add(.gptk, directory.appendingPathComponent(name)) }
                }
            }
            for name in ["wine", "wine64"] {
                let file = directory.appendingPathComponent(name)
                let resolved = file.resolvingSymlinksInPath().path
                if resolved.contains("CrossOver/") || resolved.contains("game-porting-toolkit") { continue }
                add(.wine, file)
            }
        }
        return found.sorted {
            let priority: [RuntimeKind: Int] = [.crossOver: 0, .gptk: 1, .wine: 2]
            if priority[$0.kind] != priority[$1.kind] { return priority[$0.kind]! < priority[$1.kind]! }
            if $0.toolkitWrapper != $1.toolkitWrapper { return $0.toolkitWrapper }
            return $0.executable.path < $1.executable.path
        }
    }

    public func profiles(for runtimes: [RuntimeInstallation]) -> [RuntimeProfile] {
        var result:[RuntimeProfile]=[]
        let bottles=home.appendingPathComponent("Library/Application Support/CrossOver/Bottles")
        let directories=(try? FileManager.default.contentsOfDirectory(at:bottles,includingPropertiesForKeys:nil)) ?? []
        for runtime in runtimes where runtime.kind == .crossOver {
            for bottle in directories.sorted(by:{$0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending}) {
                guard FileManager.default.fileExists(atPath:bottle.appendingPathComponent("cxbottle.conf").path) else { continue }
                let profile=RuntimeProfile(runtime:runtime,prefix:bottle,name:bottle.lastPathComponent,reuseExisting:true)
                result.append(profile)
            }
        }
        return result+runtimes.map { Self.managedProfile(for:$0,home:home) }
    }

    public static func managedProfile(for runtime: RuntimeInstallation, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> RuntimeProfile {
        let root = home.appendingPathComponent("Library/Application Support/Playdock/Prefixes/\(runtime.kind.rawValue)")
        let prefix = runtime.kind == .crossOver ? root.appendingPathComponent("Playdock") : root
        return RuntimeProfile(runtime: runtime, prefix: prefix, name: "Playdock")
    }

    public static func preferredProfile(_ profiles: [RuntimeProfile], selectedID: String?) -> RuntimeProfile? {
        // An unavailable explicit choice never silently launches another environment.
        if let selectedID { return profiles.first { $0.id == selectedID } }
        return profiles.first
    }
}
