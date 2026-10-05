import SwiftUI
import WayfarerCore

private struct DownloadRow:Identifiable {
    let appID:String, name:String
    let client:GamePlatform
    let live:SteamLiveDownload?
    let saved:SteamTransfer?
    var id:String { "\(client.rawValue):\(appID)" }
    var completed:UInt64 { saved?.phase == .install ? saved!.completed : live?.downloaded ?? saved?.completed ?? 0 }
    var total:UInt64 { saved?.phase == .install ? saved!.total : live?.total ?? saved?.total ?? 0 }
    var phase:String { saved?.phase == .install ? "Installing" : live.map { $0.paused ? "Paused" : $0.active ? "Downloading" : "Queued" } ?? saved?.phase.rawValue ?? "Queued" }
}

struct DownloadsView: View {
    @ObservedObject var model: LauncherModel
    private var rows:[DownloadRow] {
        var result:[String:DownloadRow]=[:]
        for saved in model.transfers {
            let live=model.steamConnections[saved.client]?.downloads.first { $0.appID==saved.appID }
            let row=DownloadRow(appID:saved.appID,name:saved.name,client:saved.client,live:live,saved:saved); result[row.id]=row
        }
        for client in GamePlatform.allCases {
            for live in model.steamConnections[client]?.downloads ?? [] {
                let row=DownloadRow(appID:live.appID,name:live.name,client:client,live:live,saved:nil)
                if result[row.id]==nil { result[row.id]=row }
            }
        }
        return result.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            LibrarySectionTitle(title:"Downloads",subtitle:"Installations and updates, together.")
            HStack(spacing:12) {
                ForEach(GamePlatform.allCases.filter { $0 == .windows || model.includesMacSteam },id:\.self) { client in
                    if let snapshot=model.steamConnections[client] {
                        VStack(alignment:.leading,spacing:8) {
                            Label("\(client.name) Steam · \(snapshot.mode.title)",systemImage:snapshot.mode == .online ? "network" : "network.slash").font(.system(size:12))
                            if snapshot.mode == .offline {
                                Button("Go online") { model.setSteamMode(client,offline:false) }.buttonStyle(QuietButtonStyle())
                            } else {
                                Button(snapshot.downloadsPaused ? "Resume downloads" : "Pause downloads") { model.pauseDownloads(client,paused:!snapshot.downloadsPaused) }
                                    .buttonStyle(QuietButtonStyle()).disabled(snapshot.downloads.isEmpty)
                            }
                        }.disabled(model.connectionBusy.contains(client)).padding(16).frame(maxWidth:.infinity,alignment:.leading).glassPanel(radius:14)
                    }
                }
            }
            if rows.isEmpty {
                VStack(spacing:13) {
                    Image(systemName:"checkmark.circle").font(.system(size:34,weight:.light)).foregroundStyle(WayfarerTheme.accent)
                    Text("Nothing in the queue").font(.system(size:20,weight:.medium))
                    Text("Choose a game in your library and select Install.").font(.system(size:12)).foregroundStyle(.secondary)
                }.padding(.vertical,60).frame(maxWidth:.infinity).glassPanel(radius:20)
            } else {
                ForEach(rows) { row in
                    VStack(alignment:.leading,spacing:16) {
                        HStack(spacing:12) {
                            Image(systemName:row.live?.paused == true ? "pause.circle" : "arrow.down.circle").font(.system(size:25,weight:.light)).foregroundStyle(WayfarerTheme.accent)
                            VStack(alignment:.leading,spacing:5) {
                                Text(row.name).font(.system(size:14,weight:.semibold))
                                Text("\(row.client.name) Steam · \(row.phase)").font(.system(size:11)).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if let live=row.live {
                                Button(live.paused ? "Resume" : "Pause") { model.controlDownload(row.appID,client:row.client,paused:!live.paused) }
                                    .buttonStyle(QuietButtonStyle()).disabled(model.connectionBusy.contains(row.client) || model.connectionMode(row.client) != .online)
                            } else {
                                Button("Connect Steam") { model.connectSteam(row.client) }.buttonStyle(QuietButtonStyle())
                            }
                        }
                        if row.total>0 {
                            ProgressView(value:min(1,Double(row.completed)/Double(row.total))).tint(WayfarerTheme.accent)
                            HStack { Text("\(formatBytes(row.completed)) of \(formatBytes(row.total))"); Spacer(); Text(min(1,Double(row.completed)/Double(row.total)),format:.percent.precision(.fractionLength(0))) }
                                .font(.system(size:11)).foregroundStyle(.secondary).monospacedDigit()
                        } else { Text("Waiting for Steam to report progress.").font(.system(size:11)).foregroundStyle(.secondary) }
                    }.padding(22).glassPanel(radius:17)
                }
            }
            Text("Steam checks ownership and downloads the files. Installed games appear in your library automatically.").font(.system(size:11)).foregroundStyle(.secondary)
        }.task { model.refreshSteamControls() }
    }
}
