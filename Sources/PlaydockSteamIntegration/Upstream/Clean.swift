// Adapted from NotProton c3a49486; GPL-3.0. See Sources/PlaydockSteamIntegration/NOTICE.
import Foundation

enum Clean {

    static let backupSuffix = "playdock-orig"

    static func copy(of file: URL) -> URL {
        let backup = file.appendingPathExtension(backupSuffix)
        if FileManager.default.fileExists(atPath: backup.path(percentEncoded: false)) { return backup }
        return file
    }
}
