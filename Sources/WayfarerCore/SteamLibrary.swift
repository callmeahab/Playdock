import Foundation

/// Valve's text KeyValues format, including nested objects, comments and escaped quotes.
public indirect enum VDFValue: Equatable, Sendable {
    case string(String)
    case object([String: VDFValue])

    public subscript(_ key: String) -> VDFValue? {
        guard case .object(let values) = self else { return nil }
        return values.first { $0.key.lowercased() == key.lowercased() }?.value
    }
    public var string: String? { if case .string(let value) = self { return value }; return nil }
    public var object: [String: VDFValue]? { if case .object(let value) = self { return value }; return nil }
}

public enum VDFParser {
    private enum Token { case text(String), open, close }

    public static func parse(_ source: String) throws -> VDFValue {
        let characters = Array(source)
        var tokens: [Token] = []
        var index = 0
        while index < characters.count {
            let character = characters[index]
            if character.isWhitespace || character == "\u{FEFF}" { index += 1; continue }
            if character == "/", index + 1 < characters.count, characters[index + 1] == "/" {
                while index < characters.count && characters[index] != "\n" { index += 1 }
                continue
            }
            if character == "{" { tokens.append(.open); index += 1; continue }
            if character == "}" { tokens.append(.close); index += 1; continue }
            var text = ""
            if character == "\"" {
                index += 1
                var closed = false
                while index < characters.count {
                    let next = characters[index]
                    index += 1
                    if next == "\"" { closed = true; break }
                    if next == "\\", index < characters.count {
                        let escaped = characters[index]
                        if escaped == "\\" || escaped == "\"" { text.append(escaped); index += 1 }
                        else { text.append(next) } // Preserve Windows paths with literal backslashes.
                    } else { text.append(next) }
                }
                guard closed else { throw WayfarerError.message("Unterminated VDF string.") }
            } else {
                while index < characters.count, !characters[index].isWhitespace, characters[index] != "{", characters[index] != "}" {
                    text.append(characters[index]); index += 1
                }
            }
            tokens.append(.text(text))
        }
        var position = 0
        func object(nested: Bool, depth: Int) throws -> VDFValue {
            guard depth < 64 else { throw WayfarerError.message("VDF nesting is too deep.") }
            var entries: [String: VDFValue] = [:]
            while position < tokens.count {
                if case .close = tokens[position] {
                    guard nested else { throw WayfarerError.message("Unexpected VDF closing brace.") }
                    position += 1
                    return .object(entries)
                }
                guard case .text(let key) = tokens[position] else { throw WayfarerError.message("Expected a VDF key.") }
                position += 1
                guard position < tokens.count else { throw WayfarerError.message("Missing VDF value.") }
                switch tokens[position] {
                case .text(let value): entries[key] = .string(value); position += 1
                case .open: position += 1; entries[key] = try object(nested: true, depth: depth + 1)
                case .close: throw WayfarerError.message("Missing VDF value.")
                }
            }
            guard !nested else { throw WayfarerError.message("Unclosed VDF object.") }
            return .object(entries)
        }
        return try object(nested: false, depth: 0)
    }
}

public struct SteamLibraryScan: Sendable {
    public var games: [SteamGame]
    public var warnings: [String]
    public var transfers: [SteamTransfer]
    public init(games: [SteamGame], warnings: [String], transfers: [SteamTransfer] = []) {
        self.games = games; self.warnings = warnings; self.transfers = transfers
    }
}

public enum SteamLibrary {
    private static let notGames: Set<String> = [
        "228980", "858280", "961940", "1054830", "1070560", "1113280", "1245040", "1391110", "1420170", "1493710",
        "1580130", "1628350", "1887720", "2180100", "2348590", "2805730", "3029110", "3127680", "3658110", "4183110",
        "4185400", "4427310", "4628710", "4628740", "4690330",
    ]

    public static func scan(steamExecutable: URL, prefix: URL, onProgress: (@Sendable (SteamLibraryScan) -> Void)? = nil) -> SteamLibraryScan {
        scan(root: steamExecutable.deletingLastPathComponent(), prefix: prefix, onProgress: onProgress)
    }

    public static func scanMac(root: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Steam")) -> SteamLibraryScan {
        guard FileManager.default.fileExists(atPath: root.appendingPathComponent("steamapps").path) else {
            return SteamLibraryScan(games: [], warnings: [])
        }
        return scan(root: root, prefix: nil)
    }

    /// Complete snapshots arrive in small batches. Dropping an older pending
    /// snapshot is safe, and keeps large libraries from flooding the UI queue.
    public static func updates(root: URL, prefix: URL?) -> AsyncStream<SteamLibraryScan> {
        SteamLibraryService(client: prefix == nil ? .macOS : .windows).updates(root: root, prefix: prefix)
    }

    public static func scan(root: URL, prefix: URL?, onProgress: (@Sendable (SteamLibraryScan) -> Void)? = nil) -> SteamLibraryScan {
        let fm = FileManager.default
        var libraries = [root]
        var warnings: [String] = []
        let foldersFile = root.appendingPathComponent("steamapps/libraryfolders.vdf")
        if fm.fileExists(atPath: foldersFile.path) {
            do {
                let folders = try VDFParser.parse(String(contentsOf: foldersFile, encoding: .utf8))["libraryfolders"]?.object ?? [:]
                for (key, value) in folders.sorted(by: { $0.key < $1.key }) where UInt(key) != nil {
                    if let path = value["path"]?.string ?? value.string {
                        let host = prefix.flatMap { WindowsPath.hostPath(path, prefix: $0) }
                            ?? (prefix == nil && path.hasPrefix("/") ? URL(fileURLWithPath: path) : nil)
                        if let host { libraries.append(host) }
                        else { warnings.append("Unmapped Steam library: \(path)") }
                    }
                }
            } catch { warnings.append("Cannot read libraryfolders.vdf: \(error.localizedDescription)") }
        }
        var seenLibraries = Set<String>(), games: [String: SteamGame] = [:], transfers: [SteamTransfer] = []
        var lastPublication: Date?
        func snapshot() -> SteamLibraryScan {
            SteamLibraryScan(games: games.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }, warnings: warnings,
                             transfers: transfers.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending })
        }
        func publishProgress() {
            guard let onProgress, !Task.isCancelled,
                  !games.isEmpty || !transfers.isEmpty || !warnings.isEmpty else { return }
            let now = Date()
            guard lastPublication == nil || now.timeIntervalSince(lastPublication!) >= 0.1 else { return }
            lastPublication = now
            onProgress(snapshot())
        }
        for library in libraries {
            if Task.isCancelled { break }
            guard seenLibraries.insert(library.resolvingSymlinksInPath().path).inserted else { continue }
            let apps = library.appendingPathComponent("steamapps")
            guard fm.fileExists(atPath: apps.path) else {
                warnings.append("Steam library is unavailable: \(library.path)"); continue
            }
            do {
                let files = try fm.contentsOfDirectory(at: apps, includingPropertiesForKeys: nil)
                for manifest in files.sorted(by: { $0.path < $1.path })
                where manifest.lastPathComponent.hasPrefix("appmanifest_") && manifest.pathExtension == "acf" {
                    if Task.isCancelled { break }
                    defer { publishProgress() }
                    do {
                        guard let state = try VDFParser.parse(String(contentsOf: manifest, encoding: .utf8))["AppState"],
                              let id = state["appid"]?.string, let number = UInt32(id), number > 0, !notGames.contains(id),
                              let name = state["name"]?.string, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                              let flags = UInt(state["StateFlags"]?.string ?? "") else { continue }
                        if let transfer = SteamTransfer.from(state: state, library: library, artwork: artwork(root: root, appID: id), client: prefix == nil ? .macOS : .windows) {
                            transfers.append(transfer)
                        }
                        guard flags & 4 != 0, games[id] == nil else { continue }
                        var installation: URL?
                        if let directory = state["installdir"]?.string, !directory.isEmpty,
                           directory != ".", directory != "..", !directory.contains("/"), !directory.contains("\\") {
                            installation = apps.appendingPathComponent("common").appendingPathComponent(directory)
                        }
                        // An installed manifest alone does not prove it is a Mac
                        // depot: copied Windows libraries can also live here.
                        if prefix == nil {
                            guard let installation, containsMacApplication(in: installation) else { continue }
                        }
                        games[id] = SteamGame(appID: id, name: name, library: library, artwork: artwork(root: root, appID: id),
                                              lastPlayed: Double(state["LastPlayed"]?.string ?? "") ?? 0, installDirectory: installation,
                                              heroArtwork: artwork(root: root, appID: id, wide: true),
                                              sizeOnDisk: UInt64(state["SizeOnDisk"]?.string ?? ""), requiresUpdate: flags & 2 != 0)
                    } catch { warnings.append("Cannot read \(manifest.lastPathComponent): \(error.localizedDescription)") }
                }
            } catch { warnings.append("Cannot read Steam library \(library.path): \(error.localizedDescription)") }
        }
        return snapshot()
    }

    private static func containsMacApplication(in directory: URL) -> Bool {
        let fm = FileManager.default
        guard let iterator = fm.enumerator(at: directory, includingPropertiesForKeys: [.isDirectoryKey],
                                          options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return false }
        var visited = 0
        for case let file as URL in iterator {
            visited += 1
            if visited > 512 { break }
            if file.pathExtension.lowercased() == "app", let bundle = Bundle(url: file),
               let executable = bundle.executableURL, fm.isExecutableFile(atPath: executable.path),
               let handle = try? FileHandle(forReadingFrom: executable) {
                defer { try? handle.close() }
                let header = (try? handle.read(upToCount: 4)) ?? Data()
                let magic = Array(header)
                if [[0xcf,0xfa,0xed,0xfe], [0xce,0xfa,0xed,0xfe], [0xfe,0xed,0xfa,0xcf],
                    [0xfe,0xed,0xfa,0xce], [0xca,0xfe,0xba,0xbe], [0xca,0xfe,0xba,0xbf],
                    [0xbe,0xba,0xfe,0xca], [0xbf,0xba,0xfe,0xca]].contains(magic.map(Int.init)) { return true }
            }
            if iterator.level >= 3 { iterator.skipDescendants() }
        }
        return false
    }

    static func artwork(root: URL, appID: String, wide: Bool = false) -> URL? {
        let cache = root.appendingPathComponent("appcache/librarycache")
        let app = cache.appendingPathComponent(appID)
        let children = (try? FileManager.default.contentsOfDirectory(at: app, includingPropertiesForKeys: nil)) ?? []
        let directories = [app] + children.sorted { $0.path < $1.path }
        let names = wide ? ["library_hero.jpg", "library_hero.png", "library_header.jpg", "header.jpg"] : ["library_600x900.jpg", "library_600x900.png", "library_capsule.jpg", "header.jpg"]
        for name in names {
            for directory in directories {
                let file = directory.appendingPathComponent(name)
                if FileManager.default.fileExists(atPath: file.path) { return file }
            }
        }
        let legacy = cache.appendingPathComponent("\(appID)_\(wide ? "library_hero" : "library_600x900").jpg")
        return FileManager.default.fileExists(atPath: legacy.path) ? legacy : nil
    }
}
