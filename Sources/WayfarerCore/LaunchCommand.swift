import Foundation

public struct LaunchCommand: Sendable {
    public var executable: URL
    public var arguments: [String]
    public var environment: [String: String]
    public var workingDirectory: URL?

    public init(executable: URL, arguments: [String], environment: [String: String] = [:], workingDirectory: URL? = nil) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.workingDirectory = workingDirectory
    }

    /// Diagnostic text only; execute the argument array directly.
    public var display: String {
        ([executable.path] + arguments).map { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }.joined(separator: " ")
    }
}

public enum CommandBuilder {
    /// Initialize only empty, app-owned prefixes.
    public static func prepareNewProfile(_ profile: RuntimeProfile) throws -> LaunchCommand? {
        let fm = FileManager.default
        let canonical = profile.prefix.resolvingSymlinksInPath().standardizedFileURL
        guard canonical.path != "/", canonical != fm.homeDirectoryForCurrentUser.resolvingSymlinksInPath().standardizedFileURL else {
            throw WayfarerError.message("Choose a dedicated Windows prefix folder.")
        }
        let registry = profile.prefix.appendingPathComponent("system.reg")
        if fm.fileExists(atPath: registry.path) { return nil }
        guard fm.isExecutableFile(atPath: profile.runtime.executable.path) else { throw WayfarerError.message("The selected runtime is unavailable.") }
        if profile.runtime.kind == .crossOver {
            if fm.fileExists(atPath: profile.prefix.appendingPathComponent("cxbottle.conf").path) { return nil }
            let utility = profile.runtime.executable.deletingLastPathComponent().appendingPathComponent("cxbottle")
            guard fm.isExecutableFile(atPath: utility.path) else { throw WayfarerError.message("This CrossOver installation has no cxbottle utility.") }
            return LaunchCommand(executable: utility, arguments: ["--bottle", profile.prefix.lastPathComponent, "--create", "--template", "win10_64"],
                                 environment: ["CX_BOTTLE_PATH": profile.prefix.deletingLastPathComponent().path])
        }
        let env = ["WINEPREFIX": profile.prefix.path]
        if profile.runtime.kind == .gptk {
            guard RuntimeDiscovery.isAppleSilicon else { throw WayfarerError.message("GPTK requires Apple silicon.") }
            let args = ["-x86_64", profile.runtime.executable.path] + (profile.runtime.toolkitWrapper ? [profile.prefix.path] : []) + ["winecfg.exe", "-v", "win10"]
            return LaunchCommand(executable: URL(fileURLWithPath: "/usr/bin/arch"), arguments: args, environment: env)
        }
        return LaunchCommand(executable: profile.runtime.executable, arguments: ["winecfg.exe", "-v", "win10"], environment: env)
    }

    /// Steam NSIS setup in the selected prefix.
    public static func installSteam(profile: RuntimeProfile, installer: URL) throws -> LaunchCommand {
        var command = try launch(profile: profile, program: installer, arguments: ["/S", #"/D=C:\Steam"#])
        command.workingDirectory = profile.prefix
        return command
    }

    public static func launch(profile: RuntimeProfile, program: URL, arguments: [String] = [], appleSilicon: Bool = RuntimeDiscovery.isAppleSilicon) throws -> LaunchCommand {
        let fm = FileManager.default
        guard fm.isExecutableFile(atPath: profile.runtime.executable.path) else {
            throw WayfarerError.message("\(profile.runtime.name) is unavailable. Choose an installed runtime in Runtimes.")
        }
        guard program.pathExtension.lowercased() == "exe", fm.fileExists(atPath: program.path) else {
            throw WayfarerError.message("The Windows executable is missing: \(program.path)")
        }
        guard profile.prefix.path != "/", profile.prefix.path != fm.homeDirectoryForCurrentUser.path else {
            throw WayfarerError.message("Choose a dedicated Windows prefix folder.")
        }
        var env: [String: String] = ["WINEPREFIX": profile.prefix.path]
        var executable = profile.runtime.executable
        var args: [String]
        switch profile.runtime.kind {
        case .crossOver:
            guard fm.fileExists(atPath: profile.prefix.appendingPathComponent("cxbottle.conf").path) else {
                throw WayfarerError.message("Create this bottle in CrossOver first, then refresh Runtimes.")
            }
            env["CX_BOTTLE_PATH"] = profile.prefix.deletingLastPathComponent().path
            args = ["--bottle", profile.prefix.lastPathComponent, "--wait-children", "--cx-app", WindowsPath.windowsPath(for: program, prefix: profile.prefix)] + arguments
        case .gptk:
            guard appleSilicon else { throw WayfarerError.message("The GPTK evaluation environment requires Apple silicon. Choose CrossOver or Wine on this Mac.") }
            env["WINEESYNC"] = "1"
            if profile.runtime.toolkitWrapper {
                args = [profile.prefix.path, WindowsPath.windowsPath(for: program, prefix: profile.prefix)] + arguments
            } else {
                args = [program.path] + arguments
            }
            // Apple's launcher scripts and evaluation Wine run in the x86_64 environment.
            args = ["-x86_64", executable.path] + args
            executable = URL(fileURLWithPath: "/usr/bin/arch")
        case .wine:
            args = [program.path] + arguments
        }
        return LaunchCommand(executable: executable, arguments: args, environment: env, workingDirectory: program.deletingLastPathComponent())
    }

    public static func steam(profile: RuntimeProfile, executable: URL? = nil, appID: String? = nil, bigPicture: Bool = true, gameArguments: [String] = []) throws -> LaunchCommand {
        guard let steam = executable ?? profile.steamExecutable else {
            throw WayfarerError.message("Steam is not installed in this environment. Install Windows Steam or locate steam.exe in Runtimes.")
        }
        // Embedded Steam needs software CEF rendering; games retain their graphics settings.
        var arguments = profile.reusesExistingSteam ? ["-cef-enable-debugging"] : ["-cef-disable-gpu", "-cef-disable-gpu-compositing", "-cef-enable-debugging"]
        if let appID {
            _ = try NativeGameLaunch.steamURL(appID: appID)
            arguments += ["-silent", "-applaunch", appID] + gameArguments
        } else if bigPicture { arguments += ["-bigpicture", "-windowed"] }
        return try launch(profile: profile, program: steam, arguments: arguments)
    }
}

public enum WindowsPath {
    public static func windowsPath(for file: URL, prefix: URL) -> String {
        let path = file.standardizedFileURL.path
        let drive = prefix.appendingPathComponent("drive_c").standardizedFileURL.path
        if path.hasPrefix(drive + "/") {
            return "C:\\" + path.dropFirst(drive.count + 1).replacingOccurrences(of: "/", with: "\\")
        }
        return "Z:" + path.replacingOccurrences(of: "/", with: "\\")
    }

    public static func hostPath(_ path: String, prefix: URL) -> URL? {
        if path.hasPrefix("/") { return URL(fileURLWithPath: path).standardizedFileURL }
        let chars = Array(path)
        guard chars.count >= 3, chars[1] == ":", chars[2] == "\\" || chars[2] == "/", chars[0].isASCII, chars[0].isLetter else { return nil }
        let letter = String(chars[0]).lowercased()
        let mapping = prefix.appendingPathComponent("dosdevices/\(letter):")
        let base: URL
        if FileManager.default.fileExists(atPath: mapping.path) { base = mapping.resolvingSymlinksInPath() }
        else if letter == "c" { base = prefix.appendingPathComponent("drive_c") }
        else if letter == "z" { base = URL(fileURLWithPath: "/") }
        else { return nil }
        let relative = String(chars.dropFirst(3)).replacingOccurrences(of: "\\", with: "/")
        return base.appendingPathComponent(relative).standardizedFileURL
    }
}

public enum ArgumentParser {
    /// Parse quoted arguments without shell expansion.
    public static func parse(_ text: String) throws -> [String] {
        var result: [String] = [], current = ""
        var quote: Character?, escaped = false, started = false
        for character in text {
            if escaped { current.append(character); escaped = false; started = true; continue }
            if character == "\\", quote != "'" { escaped = true; started = true; continue }
            if let delimiter = quote {
                if character == delimiter { quote = nil } else { current.append(character) }
                continue
            }
            if character == "\"" || character == "'" { quote = character; started = true }
            else if character.isWhitespace {
                if started { result.append(current); current = ""; started = false }
            } else { current.append(character); started = true }
        }
        guard quote == nil, !escaped else { throw WayfarerError.message("Close the quote or escape in the launch arguments.") }
        if started { result.append(current) }
        return result
    }
}
