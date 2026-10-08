import AppKit
import SwiftUI
import PlaydockCore

struct SteamBridgeSetupView: View {
    @ObservedObject var model: LauncherModel
    @State private var confirming: SteamIntegrationOperation?
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Mac Steam + CrossOver").font(.title2.weight(.semibold))
                    Text("One Steam client for your Mac and Windows games.").foregroundStyle(.secondary)
                }
                Spacer()
                Button("Close") { model.showingSteamBridgeSetup = false }.buttonStyle(QuietButtonStyle()).couchControl("Close").keyboardShortcut(.cancelAction)
            }
            ScrollView {
            VStack(alignment: .leading, spacing: 18) {
            Text("Set up Windows games in your Mac Steam library. Playdock patches Steam, prepares a separate CrossOver runner, and manages your games and settings here.")
                .font(.subheadline)
            if !SteamIntegrationSetupService.supportedSystem {
                Label("Requires Apple silicon and macOS 26 or later.", systemImage: "info.circle").foregroundStyle(.secondary)
            }
            if model.bridgeChecking { ProgressView("Checking Steam and CrossOver…") }
            if let state = model.bridgeEnvironment {
                VStack(alignment: .leading, spacing: 14) {
                    check("Mac Steam", detail: state.steamBuild.map { "Build \($0)" } ?? "Not found", good: state.steamPresent && state.steamSupported)
                    check("Steam–CrossOver bridge", detail: state.ready ? "Installed and verified" : state.installed ? "Needs repair" : "Not installed", good: state.ready)
                    if let install = state.selectedCrossOver(path: model.bridgeCrossOverPath) {
                        check("\(install.name) \(install.version)", detail: install.supported ? "Compatible patch table" : "Version not supported", good: install.supported)
                        check("CrossOver activation", detail: install.licensed ? "Activated" : "Activation needed", good: install.licensed)
                    }
                    if !state.crossOver.isEmpty {
                        Picker("CrossOver", selection: $model.bridgeCrossOverPath) {
                            Text(state.selectedCrossOver(path: nil).map { "Automatic · \($0.name) \($0.version)" } ?? "Automatic").tag("")
                            ForEach(state.crossOver) { install in Text("\(install.name) · \(install.version)\(install.supported ? "" : " · Unsupported")").tag(install.path) }
                        }.labelsHidden().accessibilityLabel("CrossOver installation").disabled(model.bridgeBusy)
                    }
                    HStack {
                        Button("Choose CrossOver…") { model.chooseBridgeCrossOver() }.buttonStyle(QuietButtonStyle()).disabled(model.bridgeBusy)
                        Link("Get compatible CrossOver Preview", destination: URL(string: "https://www.codeweavers.com/preview")!)
                        Spacer()
                        Button("Check again") { Task { await model.refreshBridgeEnvironment() } }.buttonStyle(QuietButtonStyle()).disabled(model.bridgeBusy || model.bridgeChecking)
                    }
                    ForEach(state.problems, id: \.self) { Text($0).font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                }.padding(20).glassPanel(radius: 16)
            }
            if let message = model.bridgeMessage { Text(message).font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            }.frame(maxWidth: .infinity, alignment: .leading)
            }
            if model.bridgeBusy {
                HStack(spacing: 12) {
                    ProgressView().controlSize(.small).frame(width: 18, height: 18)
                    Text(model.bridgeProgress.message).font(.subheadline).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    if model.bridgeProgress.canCancel { Button("Cancel") { model.cancelBridgeSetup() }.buttonStyle(QuietButtonStyle()) }
                }.padding(14).frame(maxWidth: .infinity, alignment: .leading).glassPanel(radius: 12)
            }
            Text("Setup closes and reopens Mac Steam, changes its startup configuration, and signs the modified app. CrossOver activation and Steam sign-in remain with their providers. Steam updates may require a bridge update; automatic Steam updates stay enabled.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                if model.bridgeEnvironment?.installed == true || model.bridgeEnvironment?.recoveryNeeded == true || model.bridgeEnvironment?.recoveryAvailable == true {
                    Button("Remove integration…") { confirming = .remove }.buttonStyle(QuietButtonStyle())
                    Button("Repair integration…") { confirming = .repair }.buttonStyle(QuietButtonStyle())
                }
                Spacer()
                Button(model.bridgeEnvironment?.installed == true ? "Update setup…" : "Set up…") { confirming = .install }
                    .buttonStyle(PlayButtonStyle()).keyboardShortcut(.defaultAction)
                    .disabled(!SteamIntegrationSetupService.supportedSystem || model.bridgeEnvironment?.canSetUp(crossOver: model.bridgeCrossOverPath) != true)
            }.disabled(model.bridgeBusy || model.bridgeChecking)
            HStack {
                Button("Component licenses") {
                    if let url = Bundle.main.resourceURL?.appendingPathComponent("SteamBridge/Licenses/NOTICE") { NSWorkspace.shared.open(url) }
                }
                Spacer()
                Button("App Management permission") { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AppBundles")!) }
            }.font(.caption).buttonStyle(ControllerButtonStyle(style: .link))
        }.padding(26).frame(width: 760, height: 600)
        .background(DialogEscapeHandler { model.showingSteamBridgeSetup = false }.frame(width: 0, height: 0))
        .task { await model.refreshBridgeEnvironment() }
        .onChange(of: model.bridgeCrossOverPath) { _ in Task { await model.refreshBridgeEnvironment() } }
        .alert(confirming?.title ?? "Set up", isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } })) {
            Button("Cancel", role: .cancel) { confirming = nil }
            Button("Continue") { if let operation = confirming { model.runBridgeSetup(operation) }; confirming = nil }
        } message: {
            Text(confirming == .remove ? "Restore Steam's original app and remove the bridge registration? Your games, saves, and game environments will be kept. Steam will close and reopen." : "Set up the Steam–CrossOver bridge? Steam will close and reopen. Playdock keeps a recovery copy; your original CrossOver app stays intact.")
        }
    }
    private func check(_ title: String, detail: String, good: Bool) -> some View {
        HStack {
            Image(systemName: good ? "checkmark.circle.fill" : "circle").foregroundStyle(good ? PlaydockTheme.accent : Color.secondary)
            Text(title).font(.subheadline.weight(.medium))
            Spacer()
            Text(detail).font(.caption).foregroundStyle(.secondary)
        }
    }
}
