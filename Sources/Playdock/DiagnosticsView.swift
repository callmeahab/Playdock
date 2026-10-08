import SwiftUI
import PlaydockCore

struct DiagnosticsView:View {
    @ObservedObject var model:LauncherModel
    @Environment(\.dismiss) private var dismiss
    var body:some View {
        VStack(alignment:.leading,spacing:18) {
            HStack { Text("Launch diagnostics").font(.title2.bold()); Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.cancelAction) }
            Text("Review recent launches and export a report with account details, paths, launch options, and runtime logs excluded.").font(.subheadline).foregroundStyle(.secondary)
            HStack { ForEach(GamePlatform.allCases,id:\.self) { client in Label("\(client.name) Steam · \(model.connectionMode(client).title)",systemImage:"network").font(.caption) } }
            ScrollView {
                VStack(alignment:.leading,spacing:12) {
                    ForEach((model.configuration.launchHistory).reversed()) { entry in
                        VStack(alignment:.leading,spacing:5) { Text(entry.name).font(.headline); Text("\(entry.date.formatted()) · \(entry.platform.name) · \(entry.environment)").font(.caption).foregroundStyle(.secondary); Text(DiagnosticReport.redact(entry.outcome)).font(.subheadline).textSelection(.enabled) }.padding(16).frame(maxWidth:.infinity,alignment:.leading).glassPanel(radius:14)
                    }
                    if (model.configuration.launchHistory).isEmpty { Text("Launch a game to record its outcome here.").foregroundStyle(.secondary) }
                }
            }
            HStack { Button("Open local logs") { model.openLogs() }; Spacer(); Button("Export report…") { model.exportDiagnostics() }.buttonStyle(QuietButtonStyle()) }
        }.padding(26).frame(width:680,height:540)
        .background(DialogEscapeHandler { dismiss() }.allowsHitTesting(false))
    }
}
