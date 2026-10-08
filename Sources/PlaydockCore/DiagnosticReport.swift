import Foundation

public enum DiagnosticReport {
    public static func redact(_ text: String, home: String = FileManager.default.homeDirectoryForCurrentUser.path) -> String {
        var result = text.replacingOccurrences(of: home, with: "~")
        let patterns = [
            #"(?i)(?:https?|wss?)://[^\s'\"<>]+"#,
            #"(?i)(?:access[_-]?token|refresh[_-]?token|auth[_-]?token|password|passwd|cookie|authorization|sessionid|steamlogin(?:secure)?|api[_-]?key|PLAYDOCK_DISPLAY_TOKEN)\s*[=:]\s*[^\s,;]+"#,
            #"\b7656119\d{10}\b"#,
            #"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#,
            #"(?i)/Users/[^/\s]+"#,
            #"(?i)(?:[A-Z]:)?[/\\](?:home|users)[/\\][^/\\\s]+"#,
            #"\b(?:\d{1,3}\.){3}\d{1,3}\b"#
        ]
        for pattern in patterns {
            if let expression = try? NSRegularExpression(pattern: pattern) { result = expression.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: "[redacted]") }
        }
        return result
    }
    /// Export allowlisted fields and redact identifiers; omit raw logs and arguments.
    public static func make(version: String, os: String, architecture: String, runtimes: [String], connections: [String: String], history: [LaunchDiagnostic]) -> String {
        var lines = ["Playdock diagnostics", "App: \(version)", "macOS: \(os)", "Architecture: \(architecture)", "Engines: \(runtimes.joined(separator: ", "))", "", "Steam backends"]
        lines += connections.keys.sorted().map { "\($0): \(connections[$0]!)" }
        lines += ["", "Recent launch outcomes"]
        for entry in history.suffix(30).reversed() { lines.append("\(ISO8601DateFormatter().string(from: entry.date)) · \(entry.platform.name) · \(entry.environment) · \(entry.name) · \(entry.outcome)") }
        lines += ["", "This report excludes runtime logs, launch arguments, save files and account information."]
        return redact(lines.joined(separator: "\n"))
    }
}
