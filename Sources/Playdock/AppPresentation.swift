import SwiftUI
import AppKit
import PlaydockCore

struct GameplayEnvironment: ViewModifier {
    @ObservedFeatures var model: LauncherModel
    init(model: LauncherModel) { _model = ObservedFeatures(wrappedValue: model, [.activity]) }
    func body(content: Content) -> some View {
        content.environment(\.gameplayQuiet, model.activityState.gameplayQuiet)
    }
}

struct FeatureDialogs: ViewModifier {
    @ObservedFeatures var model: LauncherModel
    init(model: LauncherModel) { _model = ObservedFeatures(wrappedValue: model, [.activity, .installation, .runtime]) }
    func body(content: Content) -> some View {
        content
        .sheet(item:Binding(get: { model.runtimeState.windowsAppsProfile }, set: { model.runtimeState.windowsAppsProfile = $0 }),onDismiss:{model.closeWindowsApps()}) { profile in WindowsAppsView(model:model,profile:profile).controllerControls(model.showingCouch) }
        .sheet(item: Binding(get: { model.installationState.installationRequest }, set: { model.installationState.installationRequest = $0 }), onDismiss:{ model.cancelInstallation() }) { request in InstallGameView(model: model, request: request).controllerControls(model.showingCouch) }
        .sheet(item:Binding(get: { model.installationState.uninstallationRequest }, set: { model.installationState.uninstallationRequest = $0 }),onDismiss:{ model.closeUninstallDialog() }) { request in UninstallGameView(model:model,request:request).controllerControls(model.showingCouch) }
        .sheet(item: Binding(get: { model.activityState.steamLaunchPrompt }, set: { model.activityState.steamLaunchPrompt = $0 })) { prompt in SteamLaunchPromptView(model: model, prompt: prompt).controllerControls(model.showingCouch) }
    }
}

struct AppErrorDialog: ViewModifier {
    @ObservedFeatures var model: LauncherModel
    init(model: LauncherModel) { _model = ObservedFeatures(wrappedValue: model, [.activity]) }
    func body(content: Content) -> some View {
        content
        .alert("Playdock", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("OK") { model.error = nil }
            if let log = model.activityState.latestLog { Button("Open log") { NSWorkspace.shared.open(log); model.error = nil } }
        } message: { Text(model.error ?? "") }
    }
}
