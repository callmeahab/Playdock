import Foundation
import CryptoKit

public enum GraphicsBackend: String, Codable, CaseIterable, Identifiable, Sendable {
    case inherit, automatic = "auto", dxmt, d3dMetal = "d3dmetal", dxvk, wine = "wined3d"
    public var id: String { rawValue }
    public var name: String {
        switch self {
        case .inherit: "Keep environment settings"
        case .automatic: "Automatic"
        case .dxmt: "DXMT · DirectX 11"
        case .d3dMetal: "D3DMetal · DirectX 11 / 12"
        case .dxvk: "DXVK"
        case .wine: "Wine"
        }
    }
}

public enum PerformanceToggle: String, Codable, CaseIterable, Identifiable, Sendable {
    case inherit, enabled, disabled
    public var id: String { rawValue }
    public var name: String {
        switch self { case .inherit: "Keep environment settings"; case .enabled: "On"; case .disabled: "Off" }
    }
    public var value: String? { self == .inherit ? nil : self == .enabled ? "1" : "0" }
}

public struct GamePerformanceProfile: Codable, Equatable, Sendable {
    public var quietWhilePlaying = true
    public var graphics: GraphicsBackend = .inherit
    public var synchronization: PerformanceToggle = .inherit
    public var metalHUD: PerformanceToggle = .inherit
    public init() {}
    public var environment: [String: String] {
        var result: [String: String] = [:]
        if graphics != .inherit { result["CX_GRAPHICS_BACKEND"] = graphics.rawValue }
        if let value = synchronization.value { result["WINEMSYNC"] = value }
        if let value = metalHUD.value {
            result["MTL_HUD_ENABLED"] = value
            result["MTL_HUD_LOGGING_ENABLED"] = value
        }
        return result
    }
    public var steamEnvironment: [String: String] {
        var result = environment
        result["WINEMSYNC"] = synchronization.value ?? "0"
        return result
    }
}

public struct PerformanceWorkload: Equatable, Sendable {
    public var quietGameRunning: Bool
    public var launcherActive: Bool
    public var downloadsActive: Bool
    public init(quietGameRunning: Bool, launcherActive: Bool, downloadsActive: Bool) {
        self.quietGameRunning = quietGameRunning; self.launcherActive = launcherActive; self.downloadsActive = downloadsActive
    }
    public var quiet: Bool { quietGameRunning && !launcherActive }
}

public enum PerformanceWork: CaseIterable, Sendable { case library, steam, social }

/// Coalesce optional work while retaining download controls and session tracking.
public actor PerformanceCoordinator {
    private var deadlines: [PerformanceWork: Date] = [:]
    private var previous: PerformanceWorkload?
    public init() {}
    public func due(_ state: PerformanceWorkload, now: Date = Date()) -> Set<PerformanceWork> {
        if previous != state { deadlines.removeAll(); previous = state }
        var result = Set<PerformanceWork>()
        for work in PerformanceWork.allCases {
            if state.quiet && work != .steam { continue }
            if work == .library && !state.launcherActive && !state.downloadsActive { continue }
            let interval: TimeInterval
            switch work {
            case .social: interval = 15
            case .library: interval = state.downloadsActive ? 5 : 30
            case .steam: interval = state.downloadsActive ? (state.quiet ? 10 : 5) : state.launcherActive ? 5 : 30
            }
            if now >= deadlines[work, default: .distantPast] {
                deadlines[work] = now.addingTimeInterval(interval); result.insert(work)
            }
        }
        return result
    }
}

public struct PerformanceEnvironmentSnapshot: Sendable {
    public let profileID: String
    public let fingerprint: String
    public let version: String
    public let backends: [GraphicsBackend]
    public let supportsMSync: Bool
    public let variables: [String: String]
    public let writable: Bool
    public func matches(_ settings: GamePerformanceProfile) -> Bool {
        settings.environment.allSatisfy { variables[$0.key] == $0.value }
    }
}

/// Edit only named environment keys; preserve provider settings and comments.
public enum BottlePerformanceConfiguration {
    public static func values(_ text: String, section: String = "EnvironmentVariables") -> [String: String] {
        var current = "", values: [String: String] = [:]
        for line in text.components(separatedBy: .newlines) {
            let line = line.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") && line.hasSuffix("]") { current = String(line.dropFirst().dropLast()); continue }
            guard current == section, let pair = pair(line) else { continue }
            values[pair.0] = pair.1
        }
        return values
    }
    private static func pair(_ line: String) -> (String, String)? {
        guard !line.hasPrefix(";"), !line.hasPrefix("#"), let equal = line.firstIndex(of: "=") else { return nil }
        let key = line[..<equal].trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        let value = line[line.index(after: equal)...].trimmingCharacters(in: .whitespaces)
        guard value.hasPrefix("\""), let end = value.dropFirst().firstIndex(of: "\"") else { return nil }
        return (key, String(value[value.index(after: value.startIndex)..<end]))
    }
    public static func updating(_ text: String, variables: [String: String]) throws -> String {
        let allowed: Set<String> = ["CX_GRAPHICS_BACKEND", "WINEMSYNC", "MTL_HUD_ENABLED", "MTL_HUD_LOGGING_ENABLED"]
        guard variables.keys.allSatisfy(allowed.contains), variables.values.allSatisfy({ !$0.contains("\n") && !$0.contains("\r") && !$0.contains("\"") }) else {
            throw PlaydockError.message("Unsupported performance setting.")
        }
        guard !variables.isEmpty else { return text }
        let separator = text.contains("\r\n") ? "\r\n" : "\n"
        let lines = text.components(separatedBy: separator)
        var current = "", inserted = false, sectionCount = 0
        var result: [String] = []
        let entries = variables.sorted { $0.key < $1.key }.map { "\"\($0.key)\" = \"\($0.value)\"" }
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") {
                if current == "EnvironmentVariables" { result += entries; inserted = true }
                current = String(trimmed.dropFirst().dropLast())
                if current == "EnvironmentVariables" { sectionCount += 1 }
            }
            if current == "EnvironmentVariables", let pair = pair(trimmed), variables[pair.0] != nil { continue }
            result.append(line)
        }
        guard sectionCount <= 1 else { throw PlaydockError.message("This environment has duplicate configuration sections. Edit it in CrossOver first.") }
        if !inserted {
            if result.last == "" { result.removeLast() }
            if current != "EnvironmentVariables" { result += ["", "[EnvironmentVariables]"] }
            result += entries; result.append("")
        }
        return result.joined(separator: separator)
    }
}

public actor PerformanceEnvironmentService {
    private let processes = RuntimeProcessService()
    public init() {}
    public func snapshot(_ profile: RuntimeProfile) throws -> PerformanceEnvironmentSnapshot {
        let fm = FileManager.default, config = profile.prefix.appendingPathComponent("cxbottle.conf")
        let data: Data
        if profile.runtime.kind == .crossOver && profile.nativeSteamBridge != true {
            guard let size = (try fm.attributesOfItem(atPath: config.path)[.size] as? NSNumber)?.intValue, size <= 1_000_000 else {
                throw PlaydockError.message("This CrossOver configuration is too large.")
            }
            data = try Data(contentsOf: config)
        } else { data = Data() }
        guard let text = String(data: data, encoding: .utf8) else { throw PlaydockError.message("This environment configuration is not UTF-8.") }
        let root = profile.runtime.executable.resolvingSymlinksInPath().deletingLastPathComponent().deletingLastPathComponent()
        let provider = (try? String(contentsOf: root.appendingPathComponent("etc/crossover.conf"), encoding: .utf8)) ?? ""
        let version = BottlePerformanceConfiguration.values(provider, section: "CrossOver")["ProductVersion"] ?? ""
        let major = Int(version.split(separator: ".").first ?? "") ?? 0
        var backends: [GraphicsBackend] = [.inherit]
        if profile.runtime.kind == .crossOver && major >= 25 {
            backends += [.automatic, .wine]
            if fm.fileExists(atPath: root.appendingPathComponent("lib/dxmt/x86_64-windows/d3d11.dll").path) { backends.append(.dxmt) }
            if fm.fileExists(atPath: root.appendingPathComponent("lib64/apple_gptk").path) { backends.append(.d3dMetal) }
            if fm.fileExists(atPath: root.appendingPathComponent("lib/dxvk/x86_64-windows/d3d11.dll").path) { backends.append(.dxvk) }
        }
        let managed = BottlePerformanceConfiguration.values(text, section: "Bottle")["Updater"]?.isEmpty == false
        return PerformanceEnvironmentSnapshot(profileID: profile.id, fingerprint: SHA256.hash(data: profile.nativeSteamBridge == true ? Data((provider + root.path).utf8) : data).map { String(format: "%02x", $0) }.joined(), version: version,
            backends: backends, supportsMSync: profile.runtime.kind == .crossOver && major >= 26,
            variables: BottlePerformanceConfiguration.values(text), writable: profile.nativeSteamBridge == true || (profile.runtime.kind == .crossOver && !managed && config.resolvingSymlinksInPath() == config.standardizedFileURL && fm.isWritableFile(atPath: config.path)))
    }
    public func validate(_ settings: GamePerformanceProfile, snapshot: PerformanceEnvironmentSnapshot) throws {
        guard snapshot.backends.contains(settings.graphics), settings.synchronization == .inherit || snapshot.supportsMSync,
              settings.metalHUD == .inherit || snapshot.writable else {
            throw PlaydockError.message("This engine does not support the saved performance settings. Update the game's performance profile.")
        }
    }
    public func checkLaunch(_ settings: GamePerformanceProfile, profile: RuntimeProfile) throws {
        let current = try snapshot(profile)
        try validate(settings, snapshot: current)
        if profile.runtime.kind == .crossOver && !current.matches(settings) {
            throw PlaydockError.message("Apply this game's performance profile to its Windows environment in Game settings → Compatibility, then relaunch the game.")
        }
    }
    public func apply(_ settings: GamePerformanceProfile, profile: RuntimeProfile, expected: String, backups: URL = AppPaths.support.appendingPathComponent("PerformanceBackups")) async throws -> URL? {
        guard profile.nativeSteamBridge != true else { throw PlaydockError.message("Bridge performance settings are saved per game and applied at its next launch.") }
        let first = try snapshot(profile)
        try validate(settings, snapshot: first)
        guard first.writable else { throw PlaydockError.message("Edit this environment's performance settings in its engine.") }
        guard first.fingerprint == expected else { throw PlaydockError.message("The environment changed. Reload its settings before applying.") }
        guard !first.matches(settings) else { return nil }
        guard try await processes.windowsProcesses(prefix: profile.prefix).isEmpty, !(try await processes.hasWineServer(prefix: profile.prefix)) else {
            throw PlaydockError.message("Close all Windows apps in this environment, including its Wine server, then apply again. Playdock will not close them for you.")
        }
        try Task.checkCancellation()
        let current = try snapshot(profile)
        guard current.fingerprint == expected, current.writable else { throw PlaydockError.message("The environment changed. Reload its settings before applying.") }
        let file = profile.prefix.appendingPathComponent("cxbottle.conf"), data = try Data(contentsOf: file)
        let updated = try BottlePerformanceConfiguration.updating(String(decoding: data, as: UTF8.self), variables: settings.environment)
        let fm = FileManager.default
        try fm.createDirectory(at: backups, withIntermediateDirectories: true)
        let backup = backups.appendingPathComponent("\(UUID().uuidString)-cxbottle.conf")
        try data.write(to: backup, options: .withoutOverwriting)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path)
        let permissions = try fm.attributesOfItem(atPath: file.path)[.posixPermissions]
        try Data(updated.utf8).write(to: file, options: .atomic)
        if let permissions { try fm.setAttributes([.posixPermissions: permissions], ofItemAtPath: file.path) }
        return backup
    }
}
