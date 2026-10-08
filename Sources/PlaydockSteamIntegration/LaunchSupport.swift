import Foundation

enum LaunchSupport {
    // Replace launch helpers by rename so running games keep their already-open files.
    @discardableResult
    static func update(payload: URL, support: URL, tool: URL) throws -> Int {
        let files = FileManager.default
        let roots = [payload, support, tool]
        for root in roots {
            guard root.standardizedFileURL == root.resolvingSymlinksInPath().standardizedFileURL,
                  try files.attributesOfItem(atPath: root.path)[.type] as? FileAttributeType == .typeDirectory else {
                throw StepFailure(step: "Launch helpers", detail: "The integration directory is missing or redirected. Repair the integration.")
            }
        }
        let entries = [
            ("overlay-shim.dylib", support.appending(path: "overlay-shim.dylib")),
            ("iconmaker", support.appending(path: "iconmaker")),
            ("run", tool.appending(path: "run")),
        ]
        var replacements: [(URL, Data)] = []
        for (name, destination) in entries {
            let source = payload.appending(path: name)
            let attributes = try files.attributesOfItem(atPath: source.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular,
                  let size = attributes[.size] as? NSNumber, size.intValue > 0, size.intValue < 8 * 1_024 * 1_024 else {
                throw StepFailure(step: "Launch helpers", detail: "The bundled \(name) is invalid. Reinstall Playdock.")
            }
            if files.fileExists(atPath: destination.path) || (try? files.destinationOfSymbolicLink(atPath: destination.path)) != nil {
                guard try files.attributesOfItem(atPath: destination.path)[.type] as? FileAttributeType == .typeRegular else {
                    throw StepFailure(step: "Launch helpers", detail: "The installed \(name) is redirected. Repair the integration.")
                }
            }
            let data = try Data(contentsOf: source)
            if (try? Data(contentsOf: destination)) != data || !files.isExecutableFile(atPath: destination.path) {
                replacements.append((destination, data))
            }
        }
        for (destination, data) in replacements {
            try data.write(to: destination, options: .atomic)
            try files.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destination.path)
        }
        return replacements.count
    }
}
