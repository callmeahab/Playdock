import SwiftUI
import AppKit
import WayfarerCore

struct GameSessionControls:View {
    @ObservedObject var model:LauncherModel
    let record:GameSessionRecord
    @WayfarerState private var confirmStop=false
    var body:some View {
        HStack(spacing:12){
            Image(systemName:record.phase == .playing ? "play.circle.fill":"clock").foregroundStyle(record.phase == .playing ? Color.green:Color.orange)
            VStack(alignment:.leading,spacing:4){Text("\(record.name) · \(record.phase.title)").font(.headline);Text(record.message).font(.caption).foregroundStyle(.secondary).lineLimit(2)}
            Spacer()
            if record.phase.active {
                Button("Bring forward"){model.bringGameForward(record)}.buttonStyle(QuietButtonStyle())
                Button("Stop…",role:.destructive){confirmStop=true}.buttonStyle(QuietButtonStyle()).disabled(record.phase == .stopping)
            }
        }.padding(16).glassPanel(radius:14)
        .confirmationDialog("Stop \(record.name)? Unsaved progress may be lost.",isPresented:$confirmStop,titleVisibility:.visible){Button("Stop game",role:.destructive){model.stopGame(record)};Button("Cancel",role:.cancel){}}
    }
}
struct SidebarGameSessionView: View {
    @ObservedObject var model: LauncherModel
    let records: [GameSessionRecord]
    let showGame: (LibraryGame) -> Void
    let showActivity: () -> Void
    @WayfarerState private var selectedID: UUID?
    @WayfarerState private var stopRequest: GameSessionRecord?
    private var record: GameSessionRecord? { records.first { $0.id == selectedID } ?? records.last }

    var body: some View {
        if let record {
            let game = model.library.first { $0.id == record.gameID }
            let color = game.map(GameIdentity.accent) ?? WayfarerTheme.accent
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    Circle().fill(record.phase == .playing ? WayfarerTheme.accent : Color.orange).frame(width: 5, height: 5)
                    Text(record.phase == .playing ? "NOW PLAYING" : record.phase == .disconnected ? "GAME SESSION" : record.phase.title.uppercased())
                        .font(.system(size: 8, weight: .semibold)).tracking(1.1).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Menu {
                        if records.count > 1 {
                            Section("Running games") {
                                ForEach(records) { session in
                                    Button { selectedID = session.id } label: {
                                        if session.id == record.id { Label(session.name, systemImage: "checkmark") }
                                        else { Text(session.name) }
                                    }
                                }
                            }
                            Divider()
                        }
                        if let game { Button("Game details") { showGame(game) } }
                        Button("View activity", action: showActivity)
                        Divider()
                        Button("Stop game…", role: .destructive) { stopRequest = record }.disabled(record.phase == .stopping)
                    } label: {
                        Image(systemName: "ellipsis").font(.system(size: 11)).frame(width: 15, height: 12)
                    }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                        .help("Game session options").accessibilityLabel("Options for \(record.name)")
                }
                Button {
                    if let game { showGame(game) } else { showActivity() }
                } label: {
                    HStack(spacing: 10) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 5).fill(color.opacity(0.12))
                            if let game { GameArtwork(game: game) }
                            else { Image(systemName: "gamecontroller.fill").foregroundStyle(color) }
                        }.frame(width: 30, height: 42).clipShape(RoundedRectangle(cornerRadius: 5))
                        VStack(alignment: .leading, spacing: 4) {
                            Text(record.name).font(.system(size: 11, weight: .semibold)).foregroundStyle(.white.opacity(0.9)).lineLimit(2)
                            Text("\(record.platform.name) · \(record.phase.title)").font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.buttonStyle(.plain).help(record.message).accessibilityLabel("View \(record.name), \(record.phase.title)")
                if record.phase == .disconnected {
                    Text(record.message).font(.system(size: 9)).foregroundStyle(.orange).lineLimit(2)
                }
                HStack {
                    Button { model.bringGameForward(record) } label: { Label("Return to game", systemImage: "arrow.up.right") }
                        .buttonStyle(.plain).font(.system(size: 10, weight: .medium))
                        .foregroundStyle(record.phase == .launching || record.phase == .stopping ? Color.secondary : WayfarerTheme.accent)
                        .disabled(record.phase == .launching || record.phase == .stopping)
                        .accessibilityLabel("Return to \(record.name)")
                    Spacer(minLength: 0)
                    if records.count > 1 { Text("\(records.count) active").font(.system(size: 9)).foregroundStyle(.secondary) }
                }
            }.padding(12)
                .background(LinearGradient(colors: [color.opacity(0.09), .white.opacity(0.02)], startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 13))
                .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(color.opacity(0.18), lineWidth: 1))
                .accessibilityElement(children: .contain)
                .confirmationDialog("Stop \(stopRequest?.name ?? "this game")? Unsaved progress may be lost.", isPresented: Binding(get: { stopRequest != nil }, set: { if !$0 { stopRequest = nil } }), titleVisibility: .visible) {
                    if let stopping = stopRequest { Button("Stop game", role: .destructive) { model.stopGame(stopping); stopRequest = nil } }
                    Button("Cancel", role: .cancel) { stopRequest = nil }
                }
        }
    }
}

struct GameActivityView:View {
    @ObservedObject var model:LauncherModel
    var body:some View {
        VStack(alignment:.leading,spacing:16){
            Text("Session history").font(.title2)
            Text("Time recorded while Wayfarer observes your games. Sessions already running when Wayfarer opens are tracked from detection.").font(.caption).foregroundStyle(.secondary)
            if model.gameSessions.isEmpty{Text("Your next game session will appear here.").foregroundStyle(.secondary)}
            ForEach(model.gameSessions.reversed()){record in
                if record.phase.active {GameSessionControls(model:model,record:record)}else{
                    HStack{VStack(alignment:.leading,spacing:5){Text(record.name).font(.headline);Text("\(record.platform.name) · \(record.phase.title)").font(.caption).foregroundStyle(.secondary);if record.phase != .finished{Text(record.message).font(.caption).foregroundStyle(.secondary)}};Spacer();VStack(alignment:.trailing){Text(record.requestedAt,style:.date);Text(record.startedAt==nil ? "Did not start":durationText(record.duration)).foregroundStyle(.secondary)}}.font(.caption).padding(18).glassPanel(radius:14)
                }
            }
            Button("Launch diagnostics…"){model.showingDiagnostics=true}.buttonStyle(QuietButtonStyle())
        }
    }
}
private func durationText(_ seconds:TimeInterval)->String {let minutes=Int(seconds)/60;return minutes>59 ? "\(minutes/60) hr \(minutes%60) min" : "\(minutes) min"}

struct StorageManagerView:View {
    @ObservedObject var model:LauncherModel
    @WayfarerState private var client:GamePlatform = .macOS
    private var folders:[SteamStorageFolder]{model.storageFolders[client] ?? []}
    var body:some View {
        VStack(alignment:.leading,spacing:20){
            HStack{Picker("Steam library",selection:$client){ForEach(GamePlatform.allCases,id:\.self){Text("\($0.name) Steam").tag($0)}}.pickerStyle(.segmented).labelsHidden().frame(width:260);Spacer();Button("Refresh storage"){model.refreshStorage(client)}.buttonStyle(QuietButtonStyle()).disabled(model.storageBusy.contains(client))}
            if model.storageBusy.contains(client){ProgressView("Reading Steam storage…")}
            if let message=model.storageMessages[client]{Label(message,systemImage:"exclamationmark.triangle").foregroundStyle(.secondary);Button("Connect Steam"){model.connectSteam(client)}.buttonStyle(QuietButtonStyle())}
            ForEach(folders){folder in
                VStack(alignment:.leading,spacing:12){HStack{Label(folder.name,systemImage:"externaldrive").font(.headline);Spacer();Text("\(formatBytes(folder.usedBytes)) in games · \(formatBytes(folder.freeBytes)) free").font(.caption).foregroundStyle(.secondary)};Text(folder.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    ForEach(folder.apps.sorted{$0.bytes>$1.bytes}){app in
                        if let game=model.library.first(where:{$0.id=="steam:"+app.id}){
                            HStack{Text(game.name).lineLimit(1);Spacer();Text(formatBytes(app.bytes)).monospacedDigit().foregroundStyle(.secondary);Button("Manage…"){model.storagePlatform=client;model.storageGame=game}.buttonStyle(QuietButtonStyle())}.font(.system(size:12))
                            if let job=model.maintenance[game.id+":"+client.rawValue]{Text(job.task).font(.caption).foregroundStyle(.secondary);if let value=job.progress,!job.failed{ProgressView(value:value)}}
                            Divider()
                        }
                    }
                }.padding(20).glassPanel(radius:16)
            }
            if folders.isEmpty && !model.storageBusy.contains(client){Text("Connect Steam to see its mounted libraries, game sizes, and free space.").foregroundStyle(.secondary)}
            let added=model.library.filter{$0.installations.contains{if case .added = $0{return true};return false}}
            if !added.isEmpty{Text("Added applications").font(.headline);Text("Use Finder to manage added .app and .exe files. Steam’s move and verify controls apply to Steam installations.").font(.caption).foregroundStyle(.secondary);ForEach(added){game in AddedStorageRow(game:game)}}
        }.task{model.refreshStorage(client)}.onChange(of:client){model.refreshStorage($0)}
    }
}
struct GameStorageView:View {
    @ObservedObject var model:LauncherModel
    let game:LibraryGame
    let platform:GamePlatform
    @Environment(\.dismiss) private var dismiss
    @WayfarerState private var destination:Int = -1
    @WayfarerState private var confirmMove=false
    private var key:String{game.id+":"+platform.rawValue}
    private var appID:String{String(game.id.dropFirst(6))}
    private var targets:[SteamStorageFolder]{(model.storageFolders[platform] ?? []).filter{!$0.apps.contains{$0.id==appID}}}
    private var busy:Bool{if let job=model.maintenance[key]{return !job.completed && !job.failed};return false}
    var body:some View {
        VStack(alignment:.leading,spacing:20){
            HStack{VStack(alignment:.leading,spacing:5){Text(game.name).font(.title2).lineLimit(2);Text("\(platform.name) Steam · Storage").foregroundStyle(.secondary)};Spacer();Button("Close"){model.storageGame=nil}.keyboardShortcut(.cancelAction).buttonStyle(QuietButtonStyle())}
            if let installation=game.installation(for:platform)?.steamGame{Text(installation.sizeOnDisk.map{"\(formatBytes($0)) on disk"} ?? "Size not reported");Text(installation.library.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)}
            if let record=model.activeSession(game.id){Label("\(record.phase.title) · Close the game before changing its files.",systemImage:"play.circle").foregroundStyle(.orange)}
            if let progress=model.maintenance[key]{VStack(alignment:.leading,spacing:8){Text(progress.task).font(.caption);if !progress.failed{if let value=progress.progress{ProgressView(value:value)}else if !progress.completed{ProgressView()}}}.padding(14).glassPanel(radius:12)}
            if let message=model.storageMessages[platform]{Text(message).font(.caption).foregroundStyle(.secondary)}
            Divider()
            Text("Verify game files").font(.headline);Text("Steam checks the installation and downloads replacement files when needed.").font(.caption).foregroundStyle(.secondary)
            Button("Verify files"){model.maintainGame(game,platform:platform)}.buttonStyle(QuietButtonStyle()).disabled(busy || model.activeSession(game.id) != nil)
            Divider()
            Text("Move installation").font(.headline)
            Picker("Destination",selection:$destination){Text("Choose a mounted library").tag(-1);ForEach(targets){Text("\($0.name) · \(formatBytes($0.freeBytes)) free").tag($0.id)}}
            if targets.isEmpty{Text("Add another library through Steam’s Storage settings, then refresh.").font(.caption).foregroundStyle(.secondary)}
            HStack{Button("Refresh libraries"){model.refreshStorage(platform)};Button("Move…"){confirmMove=true}.disabled(destination<0 || busy || model.activeSession(game.id) != nil);Spacer();Button("Steam settings"){model.storageGame=nil;model.openSteamClient(platform)}}.buttonStyle(QuietButtonStyle())
        }.padding(28).frame(width:660).background(WayfarerTheme.background)
        .background(DialogEscapeHandler{model.storageGame=nil}.frame(width:0,height:0))
        .task{model.refreshStorage(platform)}
        .confirmationDialog("Move \(game.name) to the selected Steam library? Steam will manage the files.",isPresented:$confirmMove,titleVisibility:.visible){Button("Move installation"){model.maintainGame(game,platform:platform,folder:destination)};Button("Cancel",role:.cancel){}}
    }
}
struct CompatibilityGuidanceView:View {
    @ObservedObject var model:LauncherModel
    let game:LibraryGame
    @WayfarerState private var rating:CompatibilityRating = .playable
    @WayfarerState private var notes=""
    var body:some View {
        VStack(alignment:.leading,spacing:16){
            Text("Compatibility on this Mac").font(.headline)
            if game.platforms.contains(.macOS){Label("A native Mac version is available.",systemImage:"apple.logo").foregroundStyle(WayfarerTheme.accent)}
            if let profile=model.suggestedProfile(game){
                let test=model.compatibilityTests(game).first{$0.environmentID==profile.id && $0.fingerprint==CompatibilityTest.fingerprint(profile) && $0.rating != .broken}
                Text("Suggested: \(profile.runtime.name) · \(profile.name)").font(.subheadline)
                Text(test == nil ? "Untested for this title. Suggested because this environment is available on your Mac." : "Your tested configuration · \(test!.rating.title)").font(.caption).foregroundStyle(test == nil ? Color.secondary:WayfarerTheme.accent)
            }
            ForEach(model.compatibilityTests(game)){test in
                VStack(alignment:.leading,spacing:6){Text("\(test.engine) · \(test.rating.title)").font(.subheadline)
                    let profile=model.profiles.first{$0.id==test.environmentID}
                    Text(profile==nil ? "Environment unavailable" : CompatibilityTest.fingerprint(profile!) != test.fingerprint ? "Engine changed since this test · Retest recommended":"Tested by you on \(test.testedAt.formatted(date:.abbreviated,time:.omitted))").font(.caption).foregroundStyle(.secondary)
                    if !test.notes.isEmpty{Text(test.notes).font(.caption)}
                    Button("Use this configuration"){model.useCompatibility(test,game:game)}.disabled(profile==nil).buttonStyle(QuietButtonStyle())
                }.padding(12).glassPanel(radius:12)
            }
            if let profile=model.selectedProfile{
                Text("Record a test in \(profile.runtime.name) · \(profile.name)").font(.caption).foregroundStyle(.secondary)
                Picker("Result",selection:$rating){ForEach(CompatibilityRating.allCases,id:\.self){Text($0.title).tag($0)}}
                TextField("Tweaks, graphics issues, or controller notes",text:$notes).textFieldStyle(.roundedBorder)
                Button("Save my tested result"){model.recordCompatibility(game,profile:profile,rating:rating,notes:notes);notes=""}.buttonStyle(QuietButtonStyle())
                Text("Only record a result after trying the Windows version. Engine availability alone does not establish game compatibility.").font(.caption).foregroundStyle(.secondary)
            }
        }.padding(20).glassPanel(radius:16)
    }
}
struct AchievementsView:View {
    @ObservedObject var model:LauncherModel
    let game:LibraryGame
    let platform:GamePlatform
    @Environment(\.dismiss) private var dismiss
    private var key:String{game.id+":"+platform.rawValue}
    private var snapshot:AchievementSnapshot?{model.achievementSnapshot(game,platform:platform)}
    var body:some View {
        VStack(alignment:.leading,spacing:18){
            HStack{VStack(alignment:.leading){Text("Achievements").font(.title2);Text("\(game.name) · \(platform.name)").foregroundStyle(.secondary)};Spacer();Button("Refresh"){model.refreshAchievements(game,platform:platform)}.disabled(model.achievementBusy.contains(key));Button("Close"){model.achievementGame=nil}.keyboardShortcut(.cancelAction)}.buttonStyle(QuietButtonStyle())
            if model.achievementBusy.contains(key){ProgressView("Reading from Steam…")}
            if let message=model.achievementMessages[key]{Text(message).font(.caption).foregroundStyle(.secondary)}
            if let snapshot {
                Text("\(snapshot.achievements.filter{$0.achieved}.count) of \(snapshot.achievements.count) unlocked").font(.headline)
                if !snapshot.achievements.isEmpty{ProgressView(value:Double(snapshot.achievements.filter{$0.achieved}.count),total:Double(snapshot.achievements.count))}
                Text("Updated \(snapshot.updatedAt.formatted(date:.abbreviated,time:.shortened)) · Current Steam account").font(.caption).foregroundStyle(.secondary)
                if snapshot.achievements.isEmpty{Text("Steam reports no achievements for this title.").foregroundStyle(.secondary)}
                ScrollView{LazyVStack(alignment:.leading,spacing:12){ForEach(snapshot.achievements.sorted{$0.achieved && !$1.achieved}){achievement in
                    HStack(alignment:.top,spacing:12){Image(systemName:achievement.achieved ? "trophy.fill":"lock.fill").foregroundStyle(achievement.achieved ? WayfarerTheme.accent:Color.secondary);VStack(alignment:.leading,spacing:5){Text(achievement.name).font(.headline);Text(achievement.description).font(.caption).foregroundStyle(.secondary);if let time=achievement.unlockedAt,time>0{Text("Unlocked \(Date(timeIntervalSince1970:time).formatted(date:.abbreviated,time:.omitted))").font(.caption).foregroundStyle(.secondary)};if !achievement.achieved,let progress=achievement.currentProgress,progress>0{Text("Progress: \(progress.formatted())").font(.caption)}};Spacer();if let percent=achievement.globalPercent,percent>0{Text("\(percent.formatted(.number.precision(.fractionLength(1))))% globally").font(.caption).foregroundStyle(.secondary)}}.padding(14).glassPanel(radius:12)
                }}}
            }else if !model.achievementBusy.contains(key){Text("Achievements are unavailable for this account or game. Connect Steam online to try again.").foregroundStyle(.secondary)}
        }.padding(26).frame(width:740,height:580).background(WayfarerTheme.background)
        .background(DialogEscapeHandler{model.achievementGame=nil}.frame(width:0,height:0)).task{model.refreshAchievements(game,platform:platform)}
    }
}

struct AddedStorageRow:View {
    let game:LibraryGame
    @WayfarerState private var size:UInt64?
    @WayfarerState private var measured=false
    var body:some View{HStack{Text(game.name);Spacer();Text(size.map(formatBytes) ?? (measured ? "Size unavailable":"Measuring…")).foregroundStyle(.secondary);if case .added(let added)=game.preferredInstallation,added.effectivePlatform == .windows{Text("Executable only").foregroundStyle(.secondary)}}.font(.system(size:12)).task{if let url=game.preferredInstallation?.location{size=try? await Task.detached(priority:.utility){try InstalledSize.bytes(at:url)}.value};measured=true}}
}
