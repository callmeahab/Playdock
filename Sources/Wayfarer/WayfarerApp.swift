import SwiftUI
import AppKit

typealias WayfarerState<Value> = SwiftUI.State<Value>

@main
struct WayfarerApp: App {
    @StateObject private var model = LauncherModel()

    var body: some Scene {
        WindowGroup("Wayfarer") {
            ContentView(model: model)
                .frame(minWidth: 1060, minHeight: 700)
                .preferredColorScheme(.dark)
                .tint(WayfarerTheme.accent)
        }
        .defaultSize(width: 1320, height: 850)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("Library") {
                Button("Open Steam in Wayfarer") { model.launchSteam() }.keyboardShortcut("p", modifiers: [.command])
                    .disabled(model.selectedProfile == nil || model.installing)
                Button("Refresh Library") { model.refresh() }.keyboardShortcut("r", modifiers: [.command])
                Button("Run Windows Installer…") { model.runInstaller() }.disabled(model.selectedProfile == nil)
                Divider()
                Button("Open Session Logs") { model.openLogs() }
            }
        }
    }
}

enum WayfarerTheme {
    static let background = Color(red: 0.06, green: 0.075, blue: 0.09)
    static let surface = Color(red: 0.105, green: 0.12, blue: 0.135)
    static let raised = Color(red: 0.145, green: 0.17, blue: 0.19)
    static let accent = Color(red: 0.34, green: 0.87, blue: 0.76)
    static let blue = accent
}

struct WayfarerMark: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(LinearGradient(colors: [WayfarerTheme.accent.opacity(0.25), WayfarerTheme.accent.opacity(0.08)], startPoint: .topLeading, endPoint: .bottomTrailing))
            RoundedRectangle(cornerRadius: 13, style: .continuous).strokeBorder(WayfarerTheme.accent.opacity(0.16), lineWidth: 1)
            Image(systemName: "sailboat.fill").font(.system(size: 23, weight: .medium)).foregroundStyle(WayfarerTheme.accent)
        }.frame(width: 46, height: 46)
    }
}
