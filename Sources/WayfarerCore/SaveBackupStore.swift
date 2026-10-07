import Foundation
import CryptoKit

public struct SaveBackup: Codable, Identifiable, Sendable {
    public var id: UUID
    public var gameID: String
    public var name: String
    public var date: Date
    public var folders: [URL]
    public var files: [Entry]
    public var bytes: UInt64 { files.reduce(0) { let sum=$0.addingReportingOverflow($1.bytes); return sum.overflow ? UInt64.max : sum.partialValue } }
    public struct Entry: Codable, Sendable { public let folder: Int; public let path: String; public let bytes: UInt64; public let hash: String }
}

/// Backs up selected save folders without following symlinks.
public struct SaveBackupStore: Sendable {
    public var root: URL
    public init(root: URL = AppPaths.support.appendingPathComponent("SaveBackups")) { self.root = root }
    private func gameRoot(_ gameID: String) -> URL { root.appendingPathComponent(SHA256.hash(data: Data(gameID.utf8)).map { String(format: "%02x", $0) }.joined()) }
    private func directory(_ backup: SaveBackup) -> URL { gameRoot(backup.gameID).appendingPathComponent(backup.id.uuidString) }
    public func list(gameID: String) throws -> [SaveBackup] {
        let folder = gameRoot(gameID)
        guard FileManager.default.fileExists(atPath: folder.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).compactMap { url in
            guard UUID(uuidString: url.lastPathComponent) != nil,
                  let data = try? Data(contentsOf: url.appendingPathComponent("manifest.json")), data.count < 4_000_000,
                  let backup = try? JSONDecoder().decode(SaveBackup.self, from: data), backup.gameID == gameID, backup.id.uuidString == url.lastPathComponent else { return nil }
            return backup
        }.sorted { $0.date > $1.date }
    }
    public static func validateFolder(_ folder: URL) throws {
        let canonical = folder.standardizedFileURL
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL
        var isDirectory: ObjCBool = false
        guard canonical.isFileURL, canonical.path != "/", canonical != home, canonical == canonical.resolvingSymlinksInPath().standardizedFileURL,
              FileManager.default.fileExists(atPath: canonical.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw WayfarerError.message("Choose a save folder, rather than your home folder or a symbolic link.")
        }
        let protectedNames = ["Steam", "config", "userdata", "Wayfarer"]
        guard !protectedNames.contains(canonical.lastPathComponent) else { throw WayfarerError.message("Choose this game's save subfolder, not the entire Steam or Wayfarer directory.") }
    }
    public func create(gameID: String, name: String, folders: [URL], allowEmpty: Bool = false) throws -> SaveBackup {
        let fm = FileManager.default
        let unique = Array(Set(folders.map(\.standardizedFileURL))).sorted { $0.path < $1.path }
        guard !unique.isEmpty, unique.count <= 20 else { throw WayfarerError.message("Choose between 1 and 20 save folders.") }
        for folder in unique {
            try Self.validateFolder(folder)
            guard !root.standardizedFileURL.path.hasPrefix(folder.path+"/"),!folder.path.hasPrefix(root.standardizedFileURL.path+"/"),root.standardizedFileURL != folder else { throw WayfarerError.message("Save folders cannot contain, or be inside, Wayfarer's backup directory.") }
        }
        try fm.createDirectory(at: gameRoot(gameID), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let id = UUID(), staging = gameRoot(gameID).appendingPathComponent(".pending-\(UUID().uuidString)")
        try fm.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: staging) }
        var files: [SaveBackup.Entry] = [], total: UInt64 = 0
        for (index, folder) in unique.enumerated() {
            var enumerationError: Error?
            guard let enumerator = fm.enumerator(at: folder, includingPropertiesForKeys: [.isSymbolicLinkKey, .isRegularFileKey, .isDirectoryKey], options: [], errorHandler: { _, error in enumerationError = error; return false }) else { throw CocoaError(.fileReadUnknown) }
            for case let item as URL in enumerator {
                let values = try item.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey, .isDirectoryKey])
                guard values.isSymbolicLink != true else { throw WayfarerError.message("Save folders containing symbolic links cannot be backed up.") }
                if values.isDirectory == true { continue }
                guard values.isRegularFile == true else { throw WayfarerError.message("This save folder contains an unsupported file.") }
                let source = item.standardizedFileURL
                guard source.path.hasPrefix(folder.path+"/") else { throw WayfarerError.message("The save folder changed during backup. Retry with the game closed.") }
                let relative = String(source.path.dropFirst(folder.path.count + 1))
                try Self.validateRelative(relative)
                let destination = staging.appendingPathComponent("files/\(index)/\(relative)")
                try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                let before = try Self.digest(source)
                total += before.0
                guard total <= 2_147_483_648, files.count < 10000 else { throw WayfarerError.message("The save snapshot exceeds 2 GB or 10,000 files. Choose a smaller save folder.") }
                try fm.copyItem(at: source, to: destination)
                let copied = try Self.digest(destination), after = try Self.digest(source)
                guard before == copied, before == after else { throw WayfarerError.message("Save files changed during backup. Close the game and retry.") }
                files.append(.init(folder: index, path: relative, bytes: copied.0, hash: copied.1))
            }
            if let error = enumerationError { throw error }
        }
        guard allowEmpty || !files.isEmpty else { throw WayfarerError.message("These save folders contain no files yet.") }
        let backup = SaveBackup(id: id, gameID: gameID, name: String(name.prefix(100)), date: Date(), folders: unique, files: files)
        try JSONEncoder().encode(backup).write(to: staging.appendingPathComponent("manifest.json"), options: .atomic)
        try fm.moveItem(at: staging, to: directory(backup))
        return backup
    }
    /// Verify first, back up current files, and preserve files absent from the snapshot.
    @discardableResult public func restore(_ backup: SaveBackup) throws -> SaveBackup {
        guard backup.folders.count <= 20, !backup.folders.isEmpty, backup.files.count <= 10000, !backup.files.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
        let base = directory(backup)
        guard base.standardizedFileURL == base.resolvingSymlinksInPath().standardizedFileURL else { throw CocoaError(.fileReadCorruptFile) }
        for folder in backup.folders { try Self.validateFolder(folder) }
        var keys = Set<String>()
        for file in backup.files {
            guard backup.folders.indices.contains(file.folder), keys.insert("\(file.folder):\(file.path)").inserted else { throw CocoaError(.fileReadCorruptFile) }
            try Self.validateRelative(file.path)
            let source = base.appendingPathComponent("files/\(file.folder)/\(file.path)")
            guard source.standardizedFileURL == source.resolvingSymlinksInPath().standardizedFileURL,
                  try Self.digest(source) == (file.bytes, file.hash) else { throw WayfarerError.message("This restore point is damaged. Your current saves are unchanged.") }
            try Self.validateTarget(backup.folders[file.folder].appendingPathComponent(file.path), in: backup.folders[file.folder])
        }
        let recovery = try create(gameID: backup.gameID, name: "Before restore", folders: backup.folders, allowEmpty: true)
        do { try copyFiles(backup) }
        catch { try? copyFiles(recovery); throw WayfarerError.message("Restore failed. A recovery point of your previous saves is available.") }
        return recovery
    }
    private func copyFiles(_ backup: SaveBackup) throws {
        for file in backup.files {
            let target = backup.folders[file.folder].appendingPathComponent(file.path)
            try Self.validateTarget(target, in: backup.folders[file.folder])
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            let source = directory(backup).appendingPathComponent("files/\(file.folder)/\(file.path)")
            try Data(contentsOf: source).write(to: target, options: .atomic)
        }
    }
    private static func validateRelative(_ path: String) throws {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\0"), path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { throw CocoaError(.fileReadCorruptFile) }
    }
    private static func validateTarget(_ target: URL, in folder: URL) throws {
        guard target.standardizedFileURL.path.hasPrefix(folder.standardizedFileURL.path + "/"), target.standardizedFileURL == target.resolvingSymlinksInPath().standardizedFileURL else { throw WayfarerError.message("The save destination contains a symbolic link. Restore was stopped.") }
    }
    private static func digest(_ url: URL) throws -> (UInt64, String) {
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        var hash = SHA256(), bytes: UInt64 = 0
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
            bytes += UInt64(data.count)
            guard bytes <= 536_870_912 else { throw WayfarerError.message("An individual save file exceeds 512 MB.") }
            hash.update(data: data)
        }
        return (bytes, hash.finalize().map { String(format: "%02x", $0) }.joined())
    }
}
