import SwiftUI
import AppKit
import PlaydockCore

struct AddGameView: View {
    @ObservedFeatures var model: LauncherModel

    init(model: LauncherModel) {
        self._model = ObservedFeatures(wrappedValue: model, [.runtime, .settings])
    }
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var executable: URL?
    @State private var arguments = ""
    @State private var error: String?
    private var platform: GamePlatform { executable?.pathExtension.lowercased() == "exe" ? .windows : .macOS }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Make room for another adventure").font(.system(size: 22, weight: .semibold))
            Text(executable == nil ? "Choose a game application. Playdock selects how it runs from the file." : platform == .macOS ? "Runs natively on your Mac." :
                 model.selectedProfile.map { "Launch with \($0.runtime.name) in \($0.name)." } ?? "Choose a Windows engine in Engines before adding a Windows game.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            TextField("Game name", text: $name).textFieldStyle(.roundedBorder)
            HStack {
                Text(executable?.path ?? "Choose a game (.app or .exe)").font(.caption).lineLimit(2).truncationMode(.middle)
                Spacer()
                Button("Choose…") {
                    if let file = model.chooseExecutable(title: "Choose a game", platform: nil) {
                        executable = file
                        error = nil
                        if name.isEmpty { name = file.deletingPathExtension().lastPathComponent }
                    }
                }
            }
            TextField("Launch arguments (optional)", text: $arguments).textFieldStyle(.roundedBorder)
            Text("Use quotes around arguments that contain spaces.").font(.caption).foregroundStyle(.secondary)
            if let error { Text(error).foregroundStyle(.red).font(.caption) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Add game") {
                    guard let executable else { return }
                    Task {
                    do { try await model.addGame(name: name, executable: executable, arguments: arguments, platform: platform); dismiss() }
                    catch { self.error = error.localizedDescription }
                    }
                }.buttonStyle(ControllerButtonStyle(style: .borderedProminent)).keyboardShortcut(.defaultAction).disabled(executable == nil || name.isEmpty || platform == .windows && model.selectedProfile == nil)
            }
        }.padding(28).frame(width: 540)
        .background(DialogEscapeHandler { dismiss() }.allowsHitTesting(false))
    }
}

struct AddProfileView: View {
    @ObservedFeatures var model: LauncherModel

    init(model: LauncherModel) {
        self._model = ObservedFeatures(wrappedValue: model, [])
    }
    @Environment(\.dismiss) private var dismiss
    @State private var kind: RuntimeKind = .wine
    @State private var executable: URL?
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Add a compatibility engine").font(.title2)
            Picker("Runtime", selection: $kind) {
                ForEach(RuntimeKind.allCases, id: \.self) { kind in Text(kind.name).tag(kind) }
            }.onChange(of: kind) { _ in executable = nil }
            Text(kind == .crossOver ? "Choose CrossOver.app. Use this engine for non-Steam games and installers." : "Choose the installed wine or wine64 executable. Playdock creates its own Windows environment.")
                .font(.subheadline).foregroundStyle(.secondary)
            chooser("Runtime", path: executable?.path) {
                let panel = NSOpenPanel()
                panel.title = kind == .crossOver ? "Choose CrossOver.app or its bin/wine" : "Choose the installed runtime executable"
                panel.canChooseDirectories = kind == .crossOver
                if panel.runModal() == .OK, var file = panel.url {
                    if kind == .crossOver, file.pathExtension == "app" {
                        file.appendPathComponent("Contents/SharedSupport/CrossOver/bin/wine")
                    }
                    executable = file
                }
            }
            Text("Adding an engine creates a separate Playdock environment. Existing CrossOver bottles are detected automatically in Engines.")
                .font(.caption).foregroundStyle(.secondary)
            if let error { Text(error).foregroundStyle(.red).font(.caption) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Add runtime") { add() }.buttonStyle(ControllerButtonStyle(style: .borderedProminent)).keyboardShortcut(.defaultAction)
                    .disabled(executable == nil)
            }
        }.padding(28).frame(width: 580)
        .background(DialogEscapeHandler { dismiss() }.allowsHitTesting(false))
    }

    private func add() {
        guard let executable else { return }
        Task {
        guard await FileService.shared.isExecutable(executable) else { error = "Choose an executable runtime file."; return }
        if kind == .gptk, !RuntimeDiscovery.isAppleSilicon { error = "GPTK's evaluation environment requires Apple silicon."; return }
        let leaf = executable.lastPathComponent
        if kind != .crossOver, leaf != "wine", leaf != "wine64", !leaf.hasPrefix("gameportingtoolkit") {
            error = "Choose wine, wine64, gameportingtoolkit, or gameportingtoolkit-no-hud."; return
        }
        let runtime = RuntimeInstallation(kind: kind, executable: executable, toolkitWrapper: kind == .gptk && leaf.hasPrefix("gameportingtoolkit"))
        model.addProfile(RuntimeDiscovery.managedProfile(for: runtime))
        dismiss()
        }
    }

    private func chooser(_ label: String, path: String?, action: @escaping () -> Void) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 6) {
                Text(label).font(.headline)
                Text(path ?? "Not selected").font(.caption).foregroundStyle(.secondary).lineLimit(2).truncationMode(.middle)
            }
            Spacer()
            Button("Choose…", action: action)
        }
    }
}
