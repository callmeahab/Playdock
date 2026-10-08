import SwiftUI
import PlaydockCore

private struct DownloadRow:Identifiable {
    let appID:String, name:String
    let live:SteamLiveDownload?
    let saved:SteamTransfer?
    var id:String { appID }
    var progress:SteamDownloadProgress { SteamDownloadProgress(live:live,saved:saved) }

}

struct DownloadsView: View {
    @ObservedFeatures var model: LauncherModel

    init(model: LauncherModel) {
        self._model = ObservedFeatures(wrappedValue: model, [.downloads, .settings, .steam])
    }
    private var rows:[DownloadRow] {
        var result:[String:DownloadRow]=[:]
        for saved in model.downloadsState.transfers {
            let live=model.steamState.snapshot?.downloads.first { $0.appID==saved.appID }
            let row=DownloadRow(appID:saved.appID,name:saved.name,live:live,saved:saved); result[row.id]=row
        }
        for live in model.steamState.snapshot?.downloads ?? [] {
            let row=DownloadRow(appID:live.appID,name:live.name,live:live,saved:nil)
            if result[row.id]==nil { result[row.id]=row }
        }
        return result.values.sorted {
            let order=model.downloadPolicy().ordered(model.steamState.snapshot?.downloads.map(\.appID) ?? [])
            let a=order.firstIndex(of:$0.appID) ?? Int.max,b=order.firstIndex(of:$1.appID) ?? Int.max
            return a==b ? $0.name.localizedStandardCompare($1.name) == .orderedAscending : a<b
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing:12) {
                if let snapshot=model.steamState.snapshot {
                    VStack(alignment:.leading,spacing:8) {
                        Label("Steam · \(snapshot.mode.title)",systemImage:snapshot.mode == .online ? "network" : "network.slash").font(.system(size:12))
                        if snapshot.mode == .offline {
                            Button("Go online") { model.setSteamMode(offline:false) }.buttonStyle(QuietButtonStyle())
                        } else {
                            Button(snapshot.downloadsPaused ? "Resume downloads" : "Pause downloads") { model.pauseDownloads(paused:!snapshot.downloadsPaused) }
                                .buttonStyle(QuietButtonStyle()).disabled(snapshot.downloads.isEmpty)
                        }
                    }.disabled(model.steamState.busy).padding(16).frame(maxWidth:.infinity,alignment:.leading).glassPanel(radius:14)
                }
            }
            if rows.isEmpty {
                VStack(spacing:13) {
                    Image(systemName:"checkmark.circle").font(.system(size:34,weight:.light)).foregroundStyle(PlaydockTheme.accent)
                    Text("Nothing in the queue").font(.system(size:20,weight:.medium))
                    Text("Choose a game in your library and select Install.").font(.system(size:12)).foregroundStyle(.secondary)
                }.padding(.vertical,60).frame(maxWidth:.infinity).glassPanel(radius:20)
            } else {
                ForEach(rows) { row in
                    VStack(alignment:.leading,spacing:16) {
                        HStack(spacing:12) {
                            Image(systemName:row.live?.paused == true ? "pause.circle" : "arrow.down.circle").font(.system(size:25,weight:.light)).foregroundStyle(PlaydockTheme.accent)
                            VStack(alignment:.leading,spacing:5) {
                                Text(row.name).font(.system(size:14,weight:.semibold))
                                Text("Steam · \(row.progress.phase)").font(.system(size:11)).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if let live=row.live {
                                Menu { Button("Move to top") { model.prioritizeDownload(row.appID,toTop:true) }; Button("Move to bottom") { model.prioritizeDownload(row.appID,toTop:false) } } label: { Image(systemName:"arrow.up.arrow.down") }.menuStyle(.borderlessButton).fixedSize().disabled(model.steamState.busy || model.connectionMode() != .online)
                                Button(live.paused ? "Resume" : "Pause") { model.controlDownload(row.appID,paused:!live.paused) }
                                    .buttonStyle(QuietButtonStyle()).disabled(model.steamState.busy || model.connectionMode() != .online)
                            } else {
                                Button("Connect Steam") { model.connectSteam() }.buttonStyle(QuietButtonStyle())
                            }
                        }
                        if let fraction=row.progress.fraction {
                            ProgressView(value:fraction).tint(PlaydockTheme.accent)
                            HStack { Text("\(formatBytes(row.progress.completed)) of \(formatBytes(row.progress.total))"); Spacer(); Text(fraction,format:.percent.precision(.fractionLength(0))) }
                                .font(.system(size:11)).foregroundStyle(.secondary).monospacedDigit()
                        } else if row.live?.active == true && row.live?.paused != true {
                            ProgressView().controlSize(.small)
                        }
                        HStack(spacing:18) {
                            if let rate=row.progress.networkBytesPerSecond { Label("\(formatBytes(rate))/s",systemImage:"network") }
                            if let rate=row.progress.diskBytesPerSecond,rate>0 { Label("\(formatBytes(rate))/s disk",systemImage:"internaldrive") }
                            Spacer()
                            if let seconds=row.progress.secondsRemaining,seconds>0 { Text(Duration.seconds(seconds).formatted(.units(allowed:[.hours,.minutes,.seconds],width:.abbreviated,maximumUnitCount:2))+" left") }
                        }.font(.system(size:11)).foregroundStyle(.secondary).monospacedDigit()
                        if let detail=row.progress.detail { Text(detail).font(.system(size:11)).foregroundStyle(.secondary) }
                    }.padding(22).glassPanel(radius:17)
                }
            }
            DownloadPolicyView(model: model)
            Text("Steam checks ownership and downloads the files. Installed games appear in your library automatically.").font(.system(size:11)).foregroundStyle(.secondary)
        }.task {
            while !Task.isCancelled {
                model.refreshSteamControls()
                do { try await Task.sleep(for:.seconds(1)) } catch { return }
            }
        }
    }
}
