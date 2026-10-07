import Foundation

/// Separate recursive scans from short file reads.
public actor StorageService {
    public static let shared = StorageService()
    public init() {}
    public func installedSize(at url: URL) throws -> UInt64 {
        try Task.checkCancellation()
        return try InstalledSize.bytes(at: url)
    }
}
