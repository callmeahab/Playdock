import AppKit
import SwiftUI
import PlaydockCore
import PlaydockPresentation

struct SteamBridgeSetupView: View {
    @ObservedFeatures var model: LauncherModel
    @State private var windowsEnabled = SteamIntegrationSetupService.supportedSystem
    @State private var showingAdvanced = false
    @State private var confirmingRemoval = false

    init(model: LauncherModel) {
        self._model = ObservedFeatures(wrappedValue: model, [.runtime, .steam, .settings])
    }

    private var environment: SteamIntegrationEnvironment? { model.runtimeState.bridgeEnvironment }
    private var crossOver: SteamIntegrationCrossOver? { environment?.selectedCrossOver(path: model.runtimeState.bridgeCrossOverPath) }
    private var busy: Bool { model.runtimeState.bridgeBusy || model.steamState.busy }
    private var plan: InitialSetupPlan {
        InitialSetupPlan(environment: environment, supportedSystem: SteamIntegrationSetupService.supportedSystem,
                         windowsEnabled: windowsEnabled, crossOverPath: model.runtimeState.bridgeCrossOverPath,
                         connection: model.connectionMode(), signingIn: model.steamState.signingIn)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(model.settingsState.configuration.setupReviewedAt == nil ? "Welcome to Playdock" : "Set up Playdock")
                        .font(.title2.weight(.semibold))
                    Text("Your Steam games, together on your Mac.").foregroundStyle(.secondary)
                }
                Spacer()
                Button("Close") { model.showingSteamBridgeSetup = false }
                    .buttonStyle(QuietButtonStyle()).couchControl("Close").keyboardShortcut(.cancelAction)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    setupSteps
                    if let message = model.runtimeState.bridgeMessage ?? model.runtimeState.bridgeCheckMessage {
                        Label(message, systemImage: "info.circle")
                            .font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    if let message = model.steamState.message, !model.steamState.busy {
                        Text(message).font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    DisclosureGroup("Advanced options", isExpanded: $showingAdvanced) { advancedOptions.padding(.top, 12) }
                        .font(.subheadline).tint(PlaydockTheme.accent)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            nextStep
            HStack {
                if plan.action != .finish {
                    Button("Continue for now") { model.finishInitialSetup() }.buttonStyle(QuietButtonStyle())
                        .couchControl("Continue for now")
                        .disabled(model.runtimeState.bridgeBusy)
                }
                Spacer()
                if model.runtimeState.bridgeBusy {
                    if model.runtimeState.bridgeProgress.canCancel {
                        Button("Cancel setup") { model.cancelBridgeSetup() }.buttonStyle(QuietButtonStyle())
                    }
                } else {
                    Button(model.steamState.signingIn ? "I’ve signed in" : plan.action.title, action: performNextStep)
                        .buttonStyle(PlayButtonStyle()).couchControl(model.steamState.signingIn ? "I’ve signed in" : plan.action.title).keyboardShortcut(.defaultAction)
                        .disabled(busy || model.runtimeState.bridgeChecking)
                }
            }
        }.padding(26).frame(width: 680, height: min(520, (NSApp.keyWindow?.screen?.visibleFrame.height ?? 800) - 140))
        .background(DialogEscapeHandler { model.showingSteamBridgeSetup = false }.frame(width: 0, height: 0))
        .task { await model.refreshBridgeEnvironment() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await model.refreshBridgeEnvironment() }
        }
        .onChange(of: model.runtimeState.bridgeCrossOverPath) { _ in Task { await model.refreshBridgeEnvironment() } }
        .alert("Remove Windows support?", isPresented: $confirmingRemoval) {
            Button("Cancel", role: .cancel) {}
            Button("Remove", role: .destructive) { model.runBridgeSetup(.remove) }
        } message: {
            Text("Steam will close and reopen with its original app. Your games, saves, and game environments stay on disk.")
        }
    }

    private var setupSteps: some View {
        VStack(alignment: .leading, spacing: 18) {
            step("Steam", icon: "1.circle", ready: [.online, .offline].contains(model.connectionMode()), detail: steamDetail)
            Divider()
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: environment?.ready == true ? "checkmark.circle.fill" : "2.circle")
                    .font(.title3).foregroundStyle(PlaydockTheme.accent).frame(width: 24)
                VStack(alignment: .leading, spacing: 6) {
                    if SteamIntegrationSetupService.supportedSystem {
                        Toggle("Windows games", isOn: $windowsEnabled).toggleStyle(ControllerToggleStyle(style: .switch)).couchControl("Windows games").font(.headline)
                            .disabled(busy || model.steamState.signingIn || environment?.ready == true)
                    } else { Text("Windows games · Optional").font(.headline) }
                    Text(windowsDetail).font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }.padding(20).glassPanel(radius: 18)
    }

    private func step(_ title: String, icon: String, ready: Bool, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: ready ? "checkmark.circle.fill" : icon).font(.title3).foregroundStyle(PlaydockTheme.accent).frame(width: 24)
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.headline)
                Text(detail).font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var steamDetail: String {
        if model.steamState.signingIn { return "Sign in through Steam’s own window, then return here." }
        if model.steamState.busy { return "Connecting your library in the background…" }
        switch model.connectionMode() {
        case .online: return "Connected. Steam stays in the background while you play."
        case .offline: return "Connected in Offline Mode. Installed games are available."
        case .signedOut: return "Installed. Sign in to access your games."
        case .unavailable:
            guard let environment else { return "Finding Steam…" }
            return environment.steamPresent ? "Found on this Mac. Playdock uses your Steam account." : "Install Steam to connect your game library."
        }
    }

    private var windowsDetail: String {
        if !SteamIntegrationSetupService.supportedSystem { return "Steam support for Windows games needs Apple silicon and macOS 26 or later. You can continue with native Mac games." }
        if environment?.ready == true { return "Ready. Playdock selects CrossOver automatically for Windows games." }
        if !windowsEnabled { return "Set this up later in Engines. Native Mac games are ready to connect." }
        if let environment, environment.steamPresent && !environment.steamSupported && environment.steamBuild != nil {
            return "This Steam build needs updated Windows support. You can continue with native Mac games."
        }
        if let crossOver, crossOver.supported {
            return crossOver.licensed ? "\(crossOver.name) detected. Ready to enable Windows games." : "\(crossOver.name) detected. Open it to activate your license."
        }
        return "CrossOver runs Windows games on your Mac. An activated, compatible Preview is required."
    }

    private var nextStep: some View {
        VStack(alignment: .leading, spacing: 8) {
            if busy || model.runtimeState.bridgeChecking {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small).frame(width: 18, height: 18)
                    Text(model.runtimeState.bridgeBusy ? model.runtimeState.bridgeProgress.message : model.steamState.busy ? model.steamState.message ?? "Connecting Steam…" : "Checking this Mac…")
                        .font(.subheadline.weight(.medium)).fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Text(plan.action == .finish ? "Ready to play" : "Next: \(model.steamState.signingIn ? "connect your library" : plan.action.title)")
                    .font(.headline)
                Text(plan.detail).font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if windowsEnabled && environment?.ready != true && SteamIntegrationSetupService.supportedSystem {
                Text("Enabling Windows games restarts Steam and prepares a separate CrossOver copy. Your games and saves stay in place.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading).glassPanel(radius: 14)
    }

    private var advancedOptions: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let environment, !environment.crossOver.isEmpty {
                Picker("CrossOver", selection: Binding(get: { model.runtimeState.bridgeCrossOverPath }, set: { model.runtimeState.bridgeCrossOverPath = $0; model.settingsState.configuration.bridgeCrossOverPath = $0; model.save() })) {
                    Text(environment.selectedCrossOver(path: nil).map { "Automatic · \($0.name)" } ?? "Automatic").tag("")
                    ForEach(environment.crossOver) { install in Text("\(install.name) \(install.version)\(install.supported ? "" : " · Unsupported")").tag(install.path) }
                }
            }
            HStack {
                Button("Choose CrossOver…") { model.chooseBridgeCrossOver() }.buttonStyle(QuietButtonStyle())
                Button("Check again") { Task { await model.refreshBridgeEnvironment() } }.buttonStyle(QuietButtonStyle())
            }
            if let environment {
                Text("Steam build: \(environment.steamBuild ?? "Not found")").font(.caption).foregroundStyle(.secondary)
                if let crossOver { Text("\(crossOver.name) \(crossOver.version) · \(crossOver.path)").font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                ForEach(environment.problems, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                if environment.installed || environment.recoveryNeeded || environment.recoveryAvailable {
                    HStack {
                        Button("Repair Windows support") { model.runBridgeSetup(.repair) }.buttonStyle(QuietButtonStyle())
                            .disabled(!environment.canSetUp(crossOver: model.runtimeState.bridgeCrossOverPath))
                        Button("Remove Windows support…") { confirmingRemoval = true }.buttonStyle(QuietButtonStyle())
                    }
                }
            }
            HStack {
                Button("Component licenses") {
                    if let url = Bundle.main.resourceURL?.appendingPathComponent("SteamBridge/Licenses/NOTICE") { NSWorkspace.shared.open(url) }
                }
                Button("App Management permission") { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AppBundles")!) }
            }.font(.caption).buttonStyle(ControllerButtonStyle(style: .link))
        }.disabled(busy || model.runtimeState.bridgeChecking)
    }

    private func performNextStep() {
        switch plan.action {
        case .check: Task { await model.refreshBridgeEnvironment() }
        case .getSteam: NSWorkspace.shared.open(URL(string: "https://store.steampowered.com/about/")!)
        case .getCrossOver: NSWorkspace.shared.open(URL(string: "https://www.codeweavers.com/preview")!)
        case .activateCrossOver: if let crossOver { NSWorkspace.shared.open(URL(fileURLWithPath: crossOver.path)) }
        case .openSteam, .signIn: model.openSteamForSignIn()
        case .install: model.runBridgeSetup(.install)
        case .repair: model.runBridgeSetup(.repair)
        case .connect: model.connectSteam()
        case .finish: model.finishInitialSetup()
        }
    }
}
