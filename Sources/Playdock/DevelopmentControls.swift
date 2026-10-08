import SwiftUI
import AppKit
import PlaydockCore

extension View {
    @ViewBuilder
    func developmentControls(model: LauncherModel, page: Binding<AppPage>) -> some View {
        #if DEBUG
        modifier(DevelopmentControls(model: model, page: page))
        #else
        self
        #endif
    }
}

#if DEBUG
private struct DevelopmentControls: ViewModifier {
    @ObservedObject var model: LauncherModel
    @Binding var page: AppPage

    func body(content: Content) -> some View {
        content
        .onAppear {
            if ProcessInfo.processInfo.arguments.contains("--show-library") { page = .library }
            if ProcessInfo.processInfo.arguments.contains("--show-storage"){page = .storage}
            if ProcessInfo.processInfo.arguments.contains("--show-activity"){page = .sessions}
            if ProcessInfo.processInfo.arguments.contains("--show-quick"){model.showingQuickLauncher=true}
            if ProcessInfo.processInfo.arguments.contains("--show-couch"){model.openCouch()}
            if ProcessInfo.processInfo.arguments.contains("--show-downloads") { page = .downloads }
            if ProcessInfo.processInfo.arguments.contains("--show-windows-apps") {
                Task {
                    while model.refreshing { try? await Task.sleep(for:.milliseconds(100)) }
                    model.manageWindowsApps()
                }
            }
            if ProcessInfo.processInfo.arguments.contains("--show-collections") { model.showingCollections=true }
            if ProcessInfo.processInfo.arguments.contains("--show-steam-bridge") { model.showingSteamBridgeSetup = true }
            if ProcessInfo.processInfo.arguments.contains("--show-diagnostics") { model.showingDiagnostics=true }
            if ProcessInfo.processInfo.arguments.contains("--show-chat") { page = .chat }
        }
        .task {
            if let flag = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--launch-installed-game-probe=") }) {
                await model.probeInstalledSteamLaunch(output: URL(fileURLWithPath: String(flag.dropFirst("--launch-installed-game-probe=".count))))
            }
            if let flag = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--single-steam-ui-probe=") }) {
                for _ in 0..<100 {
                    if !model.refreshing { break }
                    try? await Task.sleep(for: .milliseconds(100))
                }
                let result: [String: Any] = ["clients": model.steamClients.map(\.rawValue), "bigScreen": model.showingCouch,
                    "steamRoot": model.steamRoot.path,
                    "macSteamWindowsGame": model.library.contains { $0.installation(for: .windows)?.steamGame != nil },
                    "bridgeProfile": model.steamBridgeProfile.id,
                    "connections": Array(model.steamConnections.keys).map(\.rawValue)]
                if let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]) {
                    try? await FileService.shared.write(data, to: URL(fileURLWithPath: String(flag.dropFirst("--single-steam-ui-probe=".count))))
                }
                NSApp.perform(#selector(NSApplication.terminate(_:)), with: nil, afterDelay: 0)
            }
            if let flag = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--bridge-ui-probe=") || $0.hasPrefix("--bridge-startup-ui-probe=") }) {
                let startup = flag.hasPrefix("--bridge-startup-ui-probe=")
                if !startup { model.showingSteamBridgeSetup = true }
                for _ in 0..<30 {
                    try? await Task.sleep(for: .milliseconds(200))
                    if model.bridgeEnvironment != nil && !model.bridgeChecking { break }
                }
                if ProcessInfo.processInfo.arguments.contains("--bridge-progress-preview") { model.previewBridgeProgress() }
                try? await Task.sleep(for: .milliseconds(500))
                let window = NSApp.windows.first { $0.sheetParent != nil }
                let focus = CouchFocus()
                var result: [String: Any] = ["sheet": window != nil, "bigScreen": model.showingCouch,
                    "controls": focus.controls(in: window).count, "checkedRequirements": model.bridgeEnvironment != nil,
                    "ready": model.bridgeEnvironment?.ready == true, "setupPresented": model.showingSteamBridgeSetup,
                    "connectingBeforeDismissal": !model.connectionBusy.isEmpty]
                if let snapshot = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--bridge-ui-snapshot=") }), let window {
                    let windowID = window.windowNumber, path = String(snapshot.dropFirst("--bridge-ui-snapshot=".count))
                    await Task.detached {
                        let capture = Process()
                        capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                        capture.arguments = ["-x", "-o", "-l", String(windowID), path]
                        try? capture.run(); capture.waitUntilExit()
                    }.value
                }
                if model.showingCouch { result["closePressed"] = focus.pressForProbe(label: "Close", in: window) }
                else if let window, let escape = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                    windowNumber: window.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53) {
                    NSApp.postEvent(escape, atStart: true); result["escapePosted"] = true
                }
                try? await Task.sleep(for: .milliseconds(350))
                result["closed"] = !model.showingSteamBridgeSetup
                if startup {
                    await model.refreshBridgeEnvironment()
                    result["stayedClosedAfterCheck"] = !model.showingSteamBridgeSetup
                }
                if let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]) {
                    let prefix = startup ? "--bridge-startup-ui-probe=" : "--bridge-ui-probe="
                    try? await FileService.shared.write(data, to: URL(fileURLWithPath: String(flag.dropFirst(prefix.count))))
                }
                NSApp.perform(#selector(NSApplication.terminate(_:)), with: nil, afterDelay: 0)
            }
            if let flag = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--ui-responsiveness-probe=") }) {
                await model.measureUIResponsiveness(output: URL(fileURLWithPath: String(flag.dropFirst("--ui-responsiveness-probe=".count))))
            }
            if let flag=ProcessInfo.processInfo.arguments.first(where:{$0.hasPrefix("--show-game-settings=")}) {
                for _ in 0..<30 {
                    if let game=model.library.first(where:{$0.id==String(flag.dropFirst("--show-game-settings=".count))}) { model.featureGame=game; break }
                    try? await Task.sleep(for:.milliseconds(100))
                }
            }
            if ProcessInfo.processInfo.arguments.contains("--show-performance") {
                for _ in 0..<50 {
                    if let game = model.library.first(where: { $0.platforms.contains(.windows) }) { model.featureGame = game; break }
                    try? await Task.sleep(for: .milliseconds(100))
                }
            }
            if let flag = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--show-workshop=") }) {
                for _ in 0..<100 {
                    if !model.refreshing, let game = model.library.first(where: { $0.id == String(flag.dropFirst("--show-workshop=".count)) }) {
                        if model.showingCouch { do { try await Task.sleep(for: .seconds(3)) } catch { return } }
                        model.showWorkshop(game); break
                    }
                    do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
                }
                if let probe = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--workshop-ui-probe=") }) {
                    for _ in 0..<50 {
                        if NSApp.windows.contains(where: { $0.sheetParent != nil }) { break }
                        do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
                    }
                    do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
                    let window = NSApp.windows.first(where: { $0.sheetParent != nil }), focus = CouchFocus()
                    let controls = focus.controls(in: window)
                    var result: [String: Any] = ["bigScreen": model.showingCouch, "sheet": window != nil, "controls": controls.count,
                        "workshopOpen": model.workshopGame != nil, "controllerAvailable": !controls.isEmpty]
                    result["controllerClosesWorkshop"] = focus.pressForProbe(label: "Close", in: window)
                    do { try await Task.sleep(for: .milliseconds(350)) } catch { return }
                    result["closed"] = model.workshopGame == nil
                    if let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]) {
                        try? await FileService.shared.write(data, to: URL(fileURLWithPath: String(probe.dropFirst("--workshop-ui-probe=".count))))
                    }
                }
            }
            if let flag=ProcessInfo.processInfo.arguments.first(where:{$0.hasPrefix("--install-preview=") || $0.hasPrefix("--install-windows-preview=")}) {
                let windows = flag.hasPrefix("--install-windows-preview=")
                let prefix = windows ? "--install-windows-preview=" : "--install-preview="
                for _ in 0..<50 {
                    if let game=model.library.first(where:{$0.id==String(flag.dropFirst(prefix.count))}) {
                        model.install(game,platform: windows ? .windows : .macOS); break
                    }
                    try? await Task.sleep(for:.milliseconds(100))
                }
                if let probe = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--install-ui-probe=") }) {
                    for _ in 0..<100 {
                        if model.installationRequest != nil && !model.installBusy { break }
                        try? await Task.sleep(for: .milliseconds(200))
                    }
                    try? await Task.sleep(for: .milliseconds(500))
                    let result: [String: Any] = ["request": model.installationRequest != nil,
                        "windows": model.installationRequest?.platform == .windows, "prepared": model.installPlan != nil,
                        "canConfirm": model.installPlan?.canConfirm == true, "needsAgreement": model.installPlan?.needsAgreement == true,
                        "agreementIDs": model.installPlan?.eulas.map(\.id) ?? [], "message": model.installMessage]
                    let output = URL(fileURLWithPath: String(probe.dropFirst("--install-ui-probe=".count)))
                    if let window = NSApp.windows.first(where: { $0.sheetParent != nil }) {
                        let windowID = window.windowNumber
                        await Task.detached {
                            let capture = Process(); capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                            capture.arguments = ["-x", "-o", "-l", String(windowID), output.deletingPathExtension().appendingPathExtension("png").path]
                            if (try? capture.run()) != nil { capture.waitUntilExit() }
                        }.value
                    }
                    if let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]) {
                        try? await FileService.shared.write(data, to: output)
                    }
                    model.cancelInstallation()
                    NSApp.perform(#selector(NSApplication.terminate(_:)), with: nil, afterDelay: 0)
                }
            }
            if ProcessInfo.processInfo.arguments.contains("--ui-dismiss-probe") {
                try? await Task.sleep(for:.seconds(2))
                let before=NSApp.windows.filter{$0.sheetParent != nil}.count
                let sheet=NSApp.windows.first(where:{$0.sheetParent != nil})
                NSApp.activate(ignoringOtherApps:true); sheet?.makeKeyAndOrderFront(nil)
                if let event=NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:[],timestamp:ProcessInfo.processInfo.systemUptime,windowNumber:sheet?.windowNumber ?? NSApp.keyWindow?.windowNumber ?? 0,context:nil,characters:"\u{1b}",charactersIgnoringModifiers:"\u{1b}",isARepeat:false,keyCode:53) { NSApp.postEvent(event,atStart:false) }
                try? await Task.sleep(for:.seconds(1))
                let after=NSApp.windows.filter{$0.sheetParent != nil}.count
                print("PLAYDOCK_DISMISS_PROBE=before:\(before),after:\(after),install:\(model.installationRequest != nil),settings:\(model.featureGame != nil),collections:\(model.showingCollections),diagnostics:\(model.showingDiagnostics)"); fflush(stdout)
            }
            // Read-only visual preview; does not launch Steam.
            if let flag = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--show-game=") }) {
                let id = String(flag.dropFirst("--show-game=".count))
                for _ in 0..<30 {
                    if let game = model.library.first(where: { $0.id == id }) { page = .library; model.showGame(game); break }
                    do { try await Task.sleep(for: .milliseconds(100)) } catch { break }
                }
            }
        }
    }
}
#endif
