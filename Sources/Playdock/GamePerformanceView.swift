import SwiftUI
import AppKit
import PlaydockCore

struct GamePerformanceView: View {
    @ObservedFeatures var model: LauncherModel

    init(model: LauncherModel, game: LibraryGame, preferences: Binding<GamePreferences>) {
        self._model = ObservedFeatures(wrappedValue: model, [.runtime, .settings])
        self.game = game
        self._preferences = preferences
    }
    let game: LibraryGame
    @Binding var preferences: GamePreferences
    @State private var scene = ""
    @State private var cache: PerformanceCacheState = .unknown
    @State private var baselineID: UUID?
    @State private var message = ""
    #if DEBUG
    @State private var previewReports: [GamePerformanceReport] = []
    #endif
    private var settings: Binding<GamePerformanceProfile> {
        Binding(get: { preferences.effectivePerformance }, set: { preferences.performance = $0 })
    }
    private var profile: RuntimeProfile? { model.performanceProfile(for: game, environmentID: preferences.environmentID) }
    private var reports: [GamePerformanceReport] {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains(where: { $0.hasPrefix("--performance-ui-probe=") }) {
            return previewReports
        }
        #endif
        return model.performanceReports(for: game)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 12) {
                Toggle("Reduce Playdock's background work while playing", isOn: settings.quietWhilePlaying)
                    .couchControl("Quiet mode")
                Text("Defers library and friends refreshes and artwork decoding when Playdock is in the background. Session tracking and downloads continue. Returning to Playdock resumes normal updates.")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(18).glassPanel(radius: 14)
            VStack(alignment: .leading, spacing: 12) {
                Text("Frame timings").font(.headline)
                TextField("Scene, resolution, and graphics preset", text: $scene).textFieldStyle(.roundedBorder)
                Picker("Shader cache", selection: $cache) {
                    ForEach(PerformanceCacheState.allCases) { Text($0.name).tag($0) }
                }
                Text("Compare the same scene and resolution. Warm runs reuse shaders; cold runs include compilation. Playdock preserves the engine's caches.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    if model.runtimeState.capturingPerformanceFor == game.id {
                        ProgressView().controlSize(.small)
                        Button("Cancel recording") { model.cancelPerformanceCapture() }.buttonStyle(QuietButtonStyle())
                    } else {
                        Button("Record 30 seconds") {
                            if save() { model.capturePerformanceReport(game, scene: scene, cache: cache) }
                        }.buttonStyle(QuietButtonStyle()).disabled(model.activeSession(game.id)?.platform != .windows || model.runtimeState.capturingPerformanceFor != nil)
                    }
                    Button("Import timings…") {
                        if save() { model.importPerformanceReport(game, scene: scene, cache: cache) }
                    }.buttonStyle(QuietButtonStyle()).disabled(model.runtimeState.performanceBusy.contains(game.id))
                }
                Text("Recording requires Metal HUD logging enabled before Steam and the game start. If macOS provides no logs, import a game-only Console text export or CSV headed frame_ms,gpu_ms (milliseconds).")
                    .font(.caption).foregroundStyle(.secondary)
                if let text = model.runtimeState.performanceMessages[game.id] { Text(text).font(.caption).foregroundStyle(.secondary) }
                if !message.isEmpty { Text(message).font(.caption).foregroundStyle(.secondary) }
            }.padding(18).glassPanel(radius: 14)
            if !reports.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Saved reports").font(.headline)
                    Picker("Compare against", selection: $baselineID) {
                        Text("No baseline").tag(nil as UUID?)
                        ForEach(reports) { report in
                            Text("\(report.scene.isEmpty ? "Unnamed run" : report.scene) · \(report.createdAt.formatted(date: .abbreviated, time: .shortened))").tag(Optional(report.id))
                        }
                    }
                    ForEach(reports) { report in
                        reportRow(report)
                    }
                }
            }
        }
        .task(id: profile?.id) { if let profile { await model.reloadPerformanceEnvironment(profile) } }
        #if DEBUG
        .task {
            if let flag = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--performance-ui-probe=") }) {
                await probe(URL(fileURLWithPath: String(flag.dropFirst("--performance-ui-probe=".count))))
            }
        }
        #endif
    }
    private func reportRow(_ report: GamePerformanceReport) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(report.scene.isEmpty ? "Unnamed run" : report.scene).font(.headline)
                    Text("\(report.source.rawValue.capitalized) · \(report.engine) · \(report.cache.name) cache · \(report.frames) frames · \(report.createdAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Export…") { model.exportPerformanceReport(report) }.buttonStyle(QuietButtonStyle())
                Button("Remove", role: .destructive) { model.deletePerformanceReport(report) }.buttonStyle(QuietButtonStyle())
            }
            HStack(spacing: 22) {
                metric("Average FPS", report.averageFPS)
                metric("1% low FPS", report.onePercentLowFPS)
                metric("P95 frame · ms", report.p95FrameMS)
                metric("GPU · ms", report.averageGPUMS)
            }
            Text("Median \(report.medianFrameMS.formatted(.number.precision(.fractionLength(1)))) ms · P99 \(report.p99FrameMS.formatted(.number.precision(.fractionLength(1)))) ms · Thermal state: \(report.thermal)")
                .font(.caption).foregroundStyle(.secondary)
            if let baseline = reports.first(where: { $0.id == baselineID }), baseline.id != report.id {
                if baseline.scene == report.scene, !report.scene.isEmpty, baseline.cache == report.cache, report.cache != .unknown, baseline.environmentID == report.environmentID, baseline.fingerprint == report.fingerprint, baseline.source == report.source {
                    Text("vs baseline: FPS \(delta(report.averageFPS, baseline.averageFPS)) · 1% low \(delta(report.onePercentLowFPS, baseline.onePercentLowFPS)) · P95 frame time \(delta(report.p95FrameMS, baseline.p95FrameMS))")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("Scene, cache state, or engine differs from the baseline. Match these before comparing settings.").font(.caption).foregroundStyle(.secondary)
                }
            }
        }.padding(18).glassPanel(radius: 14)
    }
    private func metric(_ name: String, _ value: Double) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value.formatted(.number.precision(.fractionLength(1)))).font(.title3).monospacedDigit()
            Text(name).font(.caption).foregroundStyle(.secondary)
        }
    }
    private func delta(_ value: Double, _ baseline: Double) -> String {
        guard baseline > 0 else { return "—" }
        let percent = (value / baseline - 1) * 100
        return (percent >= 0 ? "+" : "") + percent.formatted(.number.precision(.fractionLength(1))) + "%"
    }
    private func save() -> Bool {
        do {
            var value = preferences; value.saveFolders = model.preferences(for: game).saveFolders
            try model.updatePreferences(value, game: game); message = ""; return true
        }
        catch { message = error.localizedDescription; return false }
    }
    #if DEBUG
    private func probe(_ output: URL) async {
        previewReports = [10.0, 12.0].compactMap { interval in
            try? GamePerformanceReport(gameID: game.id, scene: "Preview scene · 1080p", cache: .warm, environmentID: profile?.id, engine: "UI test fixture", fingerprint: "fixture",
                settings: GamePerformanceProfile(), effectiveVariables: [:], samples: Array(repeating: PerformanceFrame(interval: interval, gpu: 8), count: 100), thermal: "Unknown (fixture)")
        }
        try? await Task.sleep(for: .seconds(2))
        guard let window = NSApp.windows.first(where: { $0.sheetParent != nil }), let root = window.contentView else { return }
        NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil)
        try? await Task.sleep(for: .milliseconds(300))
        let focus = CouchFocus(), targets = focus.controls(in: window)
        focus.advance(in: window)
        let focused = focus.isActive
        focus.clear()
        let originalQuiet = preferences.effectivePerformance.quietWhilePlaying
        var toggleRoundTrip = false
        if model.showingCouch {
            let first = focus.pressForProbe(label: "Quiet mode", in: window)
            try? await Task.sleep(for: .milliseconds(100))
            let changed = preferences.effectivePerformance.quietWhilePlaying != originalQuiet
            let second = focus.pressForProbe(label: "Quiet mode", in: window)
            toggleRoundTrip = first && changed && second && preferences.effectivePerformance.quietWhilePlaying == originalQuiet
        }
        if let bitmap = root.bitmapImageRepForCachingDisplay(in: root.bounds) {
            root.cacheDisplay(in: root.bounds, to: bitmap)
            if let png = bitmap.representation(using: .png, properties: [:]) {
                try? await FileService.shared.write(png, to: output.deletingPathExtension().appendingPathExtension("png"))
            }
        }
        let snapshot = profile.flatMap { model.runtimeState.performanceSnapshots[$0.id] }
        let result: [String: Any] = ["sheet": true, "couch": model.showingCouch, "controls": targets.count, "controllerFocus": focused,
            "backends": snapshot?.backends.map(\.rawValue) ?? [], "msync": snapshot?.supportsMSync ?? false,
            "reports": reports.count, "fixtureFPS": reports.map(\.averageFPS), "game": game.id,
            "window": window.windowNumber, "pid": ProcessInfo.processInfo.processIdentifier, "toggleRoundTrip": toggleRoundTrip]
        if let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]) { try? await FileService.shared.write(data, to: output) }
    }
    #endif
}
