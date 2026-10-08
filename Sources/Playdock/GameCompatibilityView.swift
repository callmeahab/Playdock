import AppKit
import SwiftUI
import PlaydockCore

struct GameCompatibilityView: View {
    @ObservedFeatures var model: LauncherModel

    init(model: LauncherModel, game: LibraryGame, preferences: Binding<GamePreferences>) {
        self._model = ObservedFeatures(wrappedValue: model, [.runtime, .settings])
        self.game = game
        self._preferences = preferences
    }
    let game: LibraryGame
    @Binding var preferences: GamePreferences
    private var profile: RuntimeProfile? { model.performanceProfile(for: game, environmentID: preferences.environmentID) }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 12) {
                Label("Compatibility runtime", systemImage: "cpu").font(.headline)
                if game.isSteam {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("CrossOver").font(.subheadline.weight(.semibold))
                            if let version = profile.flatMap({ model.runtimeState.performanceSnapshots[$0.id]?.version }), !version.isEmpty {
                                Text("Version \(version)").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Button(model.runtimeState.bridgeEnvironment?.ready == true ? "Configure runtime…" : "Set up runtime…") {
                            model.featureGame = nil
                            Task { try? await Task.sleep(for: .milliseconds(200)); model.showingSteamBridgeSetup = true }
                        }.buttonStyle(QuietButtonStyle()).couchControl("Configure runtime")
                    }
                    Text("Steam games share the managed CrossOver runtime and each has its own prefix. Graphics settings below apply only to this game. Runtime changes in setup apply to all Steam games.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Picker("Runtime & prefix", selection: Binding(get: { preferences.environmentID ?? "original" }, set: { preferences.environmentID = $0 == "original" ? nil : $0 })) {
                        Text("Use this game's original environment").tag("original")
                        if let id = preferences.environmentID, !model.runtimeState.profiles.contains(where: { $0.id == id }) { Text("Saved environment unavailable").tag(id) }
                        ForEach(model.runtimeState.profiles) { Text("\($0.runtime.name) · \($0.name)").tag($0.id) }
                    }
                    Text("The runtime and prefix are selected automatically when you play. Close Windows apps before switching environments.").font(.caption).foregroundStyle(.secondary)
                }
            }.padding(18).glassPanel(radius: 14)
            if let profile {
                GameRuntimeSettingsView(model: model, game: game, profile: profile, preferences: $preferences)
                GamePrefixView(model: model, game: game, preferences: $preferences)
            } else {
                Text("This game's runtime is unavailable. Choose an installed environment.").font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }
}

struct GamePrefixView: View {
    @ObservedFeatures var model: LauncherModel

    init(model: LauncherModel, game: LibraryGame, preferences: Binding<GamePreferences>) {
        self._model = ObservedFeatures(wrappedValue: model, [.runtime, .settings])
        self.game = game
        self._preferences = preferences
    }
    let game: LibraryGame
    @Binding var preferences: GamePreferences
    @State private var snapshot: GamePrefixSnapshot?
    @State private var validation = ""
    private var profile: RuntimeProfile? { model.prefixProfile(for: game, environmentID: preferences.environmentID) }
    private var busy: Bool { profile.map { model.runtimeState.prefixToolsBusy.contains($0.prefix) } ?? false }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Windows prefix", systemImage: "folder").font(.headline)
                Spacer()
                Button("Refresh") { Task { await reload() } }.buttonStyle(QuietButtonStyle()).couchControl("Refresh prefix")
            }
            Text(game.isSteam ? "This game's Windows files, registry, and user folders are kept together in its Steam library." : "This environment's Windows files and registry are shared by the apps that use it.")
                .font(.caption).foregroundStyle(.secondary)
            if let snapshot {
                Text(snapshot.prefix.path).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Open prefix") { open(snapshot.prefix) }.couchControl("Open prefix").disabled(!snapshot.exists)
                    Button("Copy path") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(snapshot.prefix.path, forType: .string) }.couchControl("Copy prefix path")
                    if let drive = snapshot.drive { Button("C: drive") { open(drive) }.couchControl("C: drive") }
                    if let files = snapshot.userFiles { Button("User files") { open(files) }.couchControl("User files") }
                }.buttonStyle(QuietButtonStyle())
                if let log = snapshot.log { Button("Show launch log") { NSWorkspace.shared.activateFileViewerSelecting([log]) }.buttonStyle(QuietButtonStyle()).couchControl("Show launch log") }
                if snapshot.initialized, let profile {
                    HStack {
                        ForEach(PrefixTool.allCases) { tool in
                            Button(tool.name + "…") { run(tool, profile: profile) }.couchControl(tool.name)
                                .disabled(busy || model.activeSession(game.id) != nil || model.runtimeState.bridgeBusy)
                        }
                        if busy { ProgressView().controlSize(.small) }
                    }.buttonStyle(QuietButtonStyle())
                    Text("Wine configuration controls Windows version, DLL overrides, and display settings. Close the game before using these tools.").font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("Launch the game once to create its prefix.").font(.caption).foregroundStyle(.secondary)
                }
            } else if profile != nil {
                ProgressView("Reading prefix…").controlSize(.small)
            } else {
                Text("Install and launch this game once to create its prefix.").font(.caption).foregroundStyle(.secondary)
            }
            if let prefix = profile?.prefix, let message = model.runtimeState.prefixMessages[prefix] { Text(message).font(.caption).foregroundStyle(.secondary) }
            if !validation.isEmpty { Text(validation).font(.caption).foregroundStyle(.secondary) }
        }.padding(18).glassPanel(radius: 14)
        .task(id: profile) { await reload() }
        .onChange(of: busy) { _ in Task { await reload() } }
    }
    private func reload() async {
        snapshot = nil
        guard let profile else { return }
        let result = await model.prefixSnapshot(profile)
        guard !Task.isCancelled, self.profile == profile else { return }
        snapshot = result
    }
    private func open(_ url: URL) {
        if !NSWorkspace.shared.open(url) { validation = "This folder could not be opened. Refresh the prefix and try again." }
    }
    private func run(_ tool: PrefixTool, profile: RuntimeProfile) {
        do {
            var value = preferences; value.saveFolders = model.preferences(for: game).saveFolders
            try model.updatePreferences(value, game: game); validation = ""
            model.openPrefixTool(tool, game: game, profile: profile)
        } catch { validation = error.localizedDescription }
    }
}

struct GameRuntimeSettingsView: View {
    @ObservedFeatures var model: LauncherModel

    init(model: LauncherModel, game: LibraryGame, profile: RuntimeProfile, preferences: Binding<GamePreferences>) {
        self._model = ObservedFeatures(wrappedValue: model, [.runtime, .settings])
        self.game = game
        self.profile = profile
        self._preferences = preferences
    }
    let game: LibraryGame
    let profile: RuntimeProfile
    @Binding var preferences: GamePreferences
    @State private var message = ""
    private var settings: Binding<GamePerformanceProfile> {
        Binding(get: { preferences.effectivePerformance }, set: { preferences.performance = $0 })
    }
    private var environmentBusy: Bool { model.runtimeState.performanceBusy.contains(profile.id) }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Graphics & synchronization").font(.headline)
            if let snapshot = model.runtimeState.performanceSnapshots[profile.id] {
                if snapshot.writable {
                    Picker("Graphics", selection: settings.graphics) {
                        ForEach(snapshot.backends) { Text(profile.nativeSteamBridge && $0 == .inherit ? "Runtime default" : $0.name).tag($0) }
                        if !snapshot.backends.contains(preferences.effectivePerformance.graphics) {
                            Text("Saved backend unavailable").tag(preferences.effectivePerformance.graphics)
                        }
                    }
                    if snapshot.supportsMSync {
                        Picker("MSync", selection: settings.synchronization) {
                            ForEach(PerformanceToggle.allCases) { Text(profile.nativeSteamBridge && $0 == .inherit ? "Runtime default" : $0.name).tag($0) }
                        }
                    }
                    Picker("Metal HUD and timing logs", selection: settings.metalHUD) {
                        ForEach(PerformanceToggle.allCases) { Text(profile.nativeSteamBridge && $0 == .inherit ? "Runtime default" : $0.name).tag($0) }
                    }
                    if profile.nativeSteamBridge == true {
                        Text("Saved settings apply only to this game at its next launch through Mac Steam.").font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text("Current: \(snapshot.variables["CX_GRAPHICS_BACKEND"] ?? "Auto") · MSync \(snapshot.variables["WINEMSYNC"] == "1" ? "on" : "off") · HUD \(snapshot.variables["MTL_HUD_ENABLED"] == "1" ? "on" : "off")")
                            .font(.caption).foregroundStyle(.secondary)
                        Text("These settings affect every app in this Windows environment. Saving remembers this game's choices; applying changes the environment. Close all Windows apps in this environment first. A backup is kept before changes.")
                            .font(.caption).foregroundStyle(.secondary)
                        HStack {
                            Button("Apply to \(profile.name)") {
                                if save() { model.applyPerformanceProfile(preferences.effectivePerformance, game: game, profile: profile) }
                            }.buttonStyle(QuietButtonStyle()).disabled(environmentBusy || snapshot.matches(preferences.effectivePerformance))
                            Button("Reload") { Task { await model.reloadPerformanceEnvironment(profile) } }.buttonStyle(QuietButtonStyle()).disabled(environmentBusy)
                        }
                    }
                    Text("Start with Auto. For DirectX 11, compare DXMT and D3DMetal; for DirectX 12, use a compatible D3DMetal engine. MSync benefits vary by game. Where supported, enable DLSS / MetalFX inside the game and its engine.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("Manage graphics and synchronization in this engine. Quiet mode and imported performance reports are available here.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else if model.runtimeState.performanceMessages[profile.id] == nil { ProgressView("Reading environment settings…").controlSize(.small) }
            else { Button("Retry reading settings") { Task { await model.reloadPerformanceEnvironment(profile) } }.buttonStyle(QuietButtonStyle()) }
            if let text = model.runtimeState.performanceMessages[profile.id] { Text(text).font(.caption).foregroundStyle(.secondary) }
            if !preferences.effectivePerformance.environment.isEmpty {
                Button("Keep current environment settings") {
                    var value = preferences.effectivePerformance
                    value.graphics = .inherit; value.synchronization = .inherit; value.metalHUD = .inherit
                    preferences.performance = value
                }.buttonStyle(QuietButtonStyle())
            }
            if !message.isEmpty { Text(message).font(.caption).foregroundStyle(.secondary) }
        }.padding(18).glassPanel(radius: 14)
        .task(id: profile.id) { await model.reloadPerformanceEnvironment(profile) }
    }
    private func save() -> Bool {
        do {
            var value = preferences; value.saveFolders = model.preferences(for: game).saveFolders
            try model.updatePreferences(value, game: game); message = ""; return true
        } catch { message = error.localizedDescription; return false }
    }
}
