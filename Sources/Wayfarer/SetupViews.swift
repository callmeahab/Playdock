import SwiftUI
import AppKit
import WayfarerCore

struct AddGameView: View {
    @ObservedObject var model: LauncherModel
    @Environment(\.dismiss) private var dismiss
    @WayfarerState private var name = ""
    @WayfarerState private var executable: URL?
    @WayfarerState private var arguments = ""
    @WayfarerState private var error: String?
    @WayfarerState private var platform: GamePlatform = .macOS

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Make room for another adventure").font(.system(size: 22, weight: .semibold))
            Picker("Platform", selection: $platform) {
                ForEach(GamePlatform.allCases, id: \.self) { Text($0.name).tag($0) }
            }.pickerStyle(.segmented).onChange(of: platform) { _ in executable = nil; error = nil }
            Text(platform == .macOS ? "Choose a Mac game app. It opens natively, with no Windows engine." :
                 model.selectedProfile.map { "Launch with \($0.runtime.name) in \($0.name)." } ?? "Choose a Windows engine in Engines before adding a Windows game.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            TextField("Game name", text: $name).textFieldStyle(.roundedBorder)
            HStack {
                Text(executable?.path ?? (platform == .macOS ? "Choose a Mac game (.app)" : "Choose a Windows game (.exe)")).font(.caption).lineLimit(2).truncationMode(.middle)
                Spacer()
                Button("Choose…") {
                    if let file = model.chooseExecutable(title: platform == .macOS ? "Choose a Mac game" : "Choose a Windows game", platform: platform) {
                        executable = file
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
    @ObservedObject var model: LauncherModel
    @Environment(\.dismiss) private var dismiss
    @WayfarerState private var kind: RuntimeKind = .wine
    @WayfarerState private var executable: URL?
    @WayfarerState private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Add a compatibility engine").font(.title2)
            Picker("Runtime", selection: $kind) {
                ForEach(RuntimeKind.allCases, id: \.self) { kind in Text(kind.name).tag(kind) }
            }.onChange(of: kind) { _ in executable = nil }
            Text(kind == .crossOver ? "Choose CrossOver.app. Wayfarer creates its own bottle for Steam." : "Choose the installed wine or wine64 executable. Wayfarer creates its own Windows environment.")
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
            Text("Adding an engine creates a separate Wayfarer environment. Existing CrossOver Steam bottles are detected automatically in Engines.")
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
