import Foundation

public enum PerformanceCacheState: String, Codable, CaseIterable, Identifiable, Sendable {
    case unknown, cold, warm
    public var id: String { rawValue }
    public var name: String { rawValue.capitalized }
}
public enum PerformanceReportSource: String, Codable, Sendable { case recorded, imported }

public struct PerformanceFrame: Sendable, Equatable {
    public let interval: Double
    public let gpu: Double
    public init(interval: Double, gpu: Double) { self.interval = interval; self.gpu = gpu }
}

public struct GamePerformanceReport: Codable, Identifiable, Sendable {
    public var id = UUID()
    public var createdAt = Date()
    public let gameID: String
    public let scene: String
    public let cache: PerformanceCacheState
    public let environmentID: String?
    public let engine: String
    public let fingerprint: String
    public let settings: GamePerformanceProfile
    public let effectiveVariables: [String: String]
    public let frames: Int
    public let duration: Double
    public let averageFPS: Double
    public let onePercentLowFPS: Double
    public let medianFrameMS: Double
    public let p95FrameMS: Double
    public let p99FrameMS: Double
    public let averageGPUMS: Double
    public let thermal: String
    public let source: PerformanceReportSource

    public init(gameID: String, scene: String, cache: PerformanceCacheState, environmentID: String?, engine: String, fingerprint: String,
                settings: GamePerformanceProfile, effectiveVariables: [String: String], samples: [PerformanceFrame], thermal: String, source: PerformanceReportSource = .imported) throws {
        guard samples.count >= 30, samples.count <= 200_000,
              samples.allSatisfy({ $0.interval.isFinite && $0.interval > 0 && $0.interval <= 60_000 && $0.gpu.isFinite && $0.gpu >= 0 && $0.gpu <= 60_000 }) else {
            throw PlaydockError.message("A performance report needs at least 30 valid frames.")
        }
        self.gameID = gameID; self.scene = String(scene.trimmingCharacters(in: .whitespacesAndNewlines).prefix(160)); self.cache = cache
        self.environmentID = environmentID; self.engine = engine; self.fingerprint = fingerprint; self.settings = settings
        let keys: Set<String> = ["CX_GRAPHICS_BACKEND", "WINEMSYNC", "MTL_HUD_ENABLED", "MTL_HUD_LOGGING_ENABLED"]
        self.effectiveVariables = effectiveVariables.filter { keys.contains($0.key) }
        frames = samples.count
        let sorted = samples.map(\.interval).sorted(), sum = sorted.reduce(0, +)
        duration = sum / 1000; averageFPS = Double(frames) * 1000 / sum
        let slow = sorted.suffix(max(1, Int(ceil(Double(frames) * 0.01))))
        onePercentLowFPS = Double(slow.count) * 1000 / slow.reduce(0, +)
        func percentile(_ p: Double) -> Double { sorted[max(0, Int(ceil(Double(sorted.count) * p)) - 1)] }
        medianFrameMS = sorted.count.isMultiple(of: 2) ? (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2 : sorted[sorted.count / 2]
        p95FrameMS = percentile(0.95); p99FrameMS = percentile(0.99)
        averageGPUMS = samples.map(\.gpu).reduce(0, +) / Double(frames)
        self.thermal = thermal
        self.source = source
    }
}

public enum MetalPerformanceLog {
    /// Apple's summary has three metadata fields followed by frame/GPU pairs in milliseconds.
    public static func frames(_ text: String) throws -> [PerformanceFrame] {
        guard text.utf8.count <= 16_000_000 else { throw PlaydockError.message("Use a performance log smaller than 16 MB.") }
        var result: [PerformanceFrame] = [], csv = false, seen = Set<String>()
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.lowercased() == "frame_ms,gpu_ms" { csv = true; continue }
            if let marker = line.range(of: "metal-HUD:", options: .caseInsensitive) {
                let prefix = line[..<marker.lowerBound]
                var process = "default"
                if let bracket = prefix.lastIndex(of: "[") {
                    let tail = prefix[prefix.index(after: bracket)...]
                    let pid = tail.prefix(while: { $0.isNumber })
                    if !pid.isEmpty { process = String(pid) }
                }
                let fields = line[marker.upperBound...].split(separator: ",", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
                guard fields.count >= 5, (fields.count - 3).isMultiple(of: 2), let first = Int64(fields[0]) else { continue }
                for index in stride(from: 3, to: fields.count, by: 2) {
                    let (frame, overflow) = first.addingReportingOverflow(Int64((index - 3) / 2))
                    let key = process + ":" + String(frame)
                    guard !overflow, !seen.contains(key), let interval = Double(fields[index]), let gpu = Double(fields[index + 1]), valid(interval, gpu) else { continue }
                    seen.insert(key); result.append(PerformanceFrame(interval: interval, gpu: gpu))
                }
            } else if csv {
                let fields = line.split(separator: ",", omittingEmptySubsequences: false)
                if fields.count == 2, let interval = Double(fields[0].trimmingCharacters(in: .whitespaces)), let gpu = Double(fields[1].trimmingCharacters(in: .whitespaces)), valid(interval, gpu) {
                    result.append(PerformanceFrame(interval: interval, gpu: gpu))
                }
            }
            guard result.count <= 200_000 else { throw PlaydockError.message("Use a shorter performance capture (at most 200,000 frames).") }
        }
        guard !result.isEmpty else { throw PlaydockError.message("No frame timings found. Import a game-only Metal HUD text log or a CSV with the header frame_ms,gpu_ms.") }
        return result
    }
    private static func valid(_ interval: Double, _ gpu: Double) -> Bool {
        interval.isFinite && interval > 0 && interval <= 60_000 && gpu.isFinite && gpu >= 0 && gpu <= 60_000
    }
}

public actor PerformanceReportService {
    private let processes = ProcessService()
    public init() {}
    public func imported(_ file: URL) async throws -> [PerformanceFrame] {
        let data = try await FileService.shared.read(file)
        try Task.checkCancellation()
        guard let text = String(data: data, encoding: .utf8) else { throw PlaydockError.message("Import a UTF-8 performance log.") }
        return try MetalPerformanceLog.frames(text)
    }
    public func capture(tokens: [RuntimeProcessToken], start: Date, end: Date) async throws -> [PerformanceFrame] {
        let pids = Set(tokens.map(\.pid).filter { $0 > 0 }).sorted()
        guard !pids.isEmpty, pids.count <= 64, end > start, end.timeIntervalSince(start) <= 65 else { throw PlaydockError.message("No verified game process is available for this capture.") }
        let predicate = "eventMessage BEGINSWITH 'metal-HUD:' AND (" + pids.map { "processIdentifier == \($0)" }.joined(separator: " OR ") + ")"
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let command = LaunchCommand(executable: URL(fileURLWithPath: "/usr/bin/log"), arguments: ["show", "--style", "compact", "--info", "--debug", "--start", formatter.string(from: start), "--end", formatter.string(from: end), "--predicate", predicate])
        let receipt = try await processes.start(command, id: UUID())
        // The receipt owns the process identity; cancellation cannot stop a game's process.
        let worker = processes
        let timeout = Task { try await Task.sleep(for: .seconds(15)); await worker.terminate(receipt.id) }
        defer { timeout.cancel() }
        let code = try await withTaskCancellationHandler {
            try await worker.wait(receipt.id)
        } onCancel: { Task { await worker.terminate(receipt.id) } }
        try Task.checkCancellation()
        guard code == 0 else { throw PlaydockError.message("macOS could not read the game's Metal HUD logs. Import a capture from Console instead.") }
        return try await imported(receipt.logURL)
    }
    public func export(_ report: GamePerformanceReport, to file: URL) async throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        try await FileService.shared.write(try encoder.encode(report), to: file)
    }
}
