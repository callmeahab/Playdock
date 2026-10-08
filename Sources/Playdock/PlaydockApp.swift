import SwiftUI
import AppKit

@main
struct PlaydockApp: App {
    @NSApplicationDelegateAdaptor(PlaydockLifecycle.self) private var lifecycle
    @StateObject private var model = LauncherModel()

    var body: some Scene {
        WindowGroup("Playdock") {
            ContentView(model: model)
                .onAppear { lifecycle.model = model }
                .frame(minWidth: 1060, minHeight: 700)
                .preferredColorScheme(.dark)
                .tint(PlaydockTheme.accent)
        }
        .defaultSize(width: 1320, height: 850)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("Library") {
                Button("Quick Launcher…"){model.openQuickLauncher()}.keyboardShortcut("k",modifiers:[.command])
                Button("Controller Fullscreen"){model.showingCouch.toggle()}.keyboardShortcut("f",modifiers:[.command,.shift])
                Button("Storage Manager"){model.navigate("Storage")}
                Button("Refresh Library") { model.refresh() }.keyboardShortcut("r", modifiers: [.command])
                Button("Run Windows Installer…") { model.runInstaller() }.disabled(model.selectedProfile == nil)
                Divider()
                Button("Open Session Logs") { model.openLogs() }
            }
        }
    }
}

@MainActor
final class PlaydockLifecycle: NSObject, NSApplicationDelegate {
    weak var model: LauncherModel?
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model else { return .terminateNow }
        Task {
            await model.prepareForTermination()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

enum PlaydockTheme {
    static let background = Color(red: 0.045, green: 0.055, blue: 0.075)
    static let surface = Color(red: 0.085, green: 0.10, blue: 0.13)
    static let raised = Color(red: 0.13, green: 0.15, blue: 0.19)
    static let accent = Color(red: 0.34, green: 0.87, blue: 0.76)
    static let violet = Color(red: 0.65, green: 0.62, blue: 0.98)
    static let amber = Color(red: 0.98, green: 0.75, blue: 0.44)
    static let blue = Color(red: 0.45, green: 0.70, blue: 0.98)
}

struct PlaydockMark: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(LinearGradient(colors: [PlaydockTheme.accent.opacity(0.25), PlaydockTheme.accent.opacity(0.08)], startPoint: .topLeading, endPoint: .bottomTrailing))
            RoundedRectangle(cornerRadius: 13, style: .continuous).strokeBorder(PlaydockTheme.accent.opacity(0.16), lineWidth: 1)
            Image(systemName: "sailboat.fill").font(.system(size: 23, weight: .medium)).foregroundStyle(PlaydockTheme.accent)
        }.frame(width: 46, height: 46)
    }
}
