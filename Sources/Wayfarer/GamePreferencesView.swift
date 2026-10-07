import AppKit
import SwiftUI
import WayfarerCore

struct GamePreferencesView: View {
    @ObservedObject var model: LauncherModel
    let game: LibraryGame
    @Environment(\.dismiss) private var dismiss
    @State private var preferences: GamePreferences
    @State private var tags: String
    @State private var tab = 0
    @State private var validation = ""
    init(model: LauncherModel, game: LibraryGame) {
        self.model=model; self.game=game
        let value=model.preferences(for:game)
        _preferences=State(initialValue:value); _tags=State(initialValue:value.tags.joined(separator:", "))
    }
    var body: some View {
        VStack(alignment:.leading,spacing:18) {
            HStack { VStack(alignment:.leading,spacing:5) { Text(game.name).font(.title2.bold()); Text("Make this game your own").foregroundStyle(.secondary) }; Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.cancelAction) }
            Picker("Settings",selection:$tab) { Text("Profile").tag(0); Text("Collections").tag(1); Text("Saves").tag(2) }.pickerStyle(.segmented)
            ScrollView {
                VStack(alignment:.leading,spacing:18) {
                    if tab == 0 { profile }
                    if tab == 1 { organization }
                    if tab == 2 { GameSavesView(model:model,game:game) }
                }.padding(.vertical,8)
            }.frame(minHeight:340)
            if !validation.isEmpty { Text(validation).font(.caption).foregroundStyle(.secondary) }
            if tab != 2 {
                HStack { Spacer(); Button("Save changes") {
                    do { var value=preferences; value.tags=tags.components(separatedBy:","); value.saveFolders=model.preferences(for:game).saveFolders; try model.updatePreferences(value,game:game); validation="Saved" }
                    catch { validation=error.localizedDescription }
                }.buttonStyle(QuietButtonStyle()) }
            }
        }.padding(26).frame(width:620,height:580)
        .background(DialogEscapeHandler { dismiss() }.allowsHitTesting(false))
    }
    private var profile:some View {
        VStack(alignment:.leading,spacing:16) {
            Picker("Preferred version",selection:Binding(get:{preferences.preferredPlatform?.rawValue ?? "automatic"},set:{preferences.preferredPlatform=GamePlatform(rawValue:$0)})) {
                Text("Automatic · native first").tag("automatic")
                ForEach(game.platforms,id:\.self) { Text($0.name).tag($0.rawValue) }
            }
            if game.platforms.contains(.windows) {
                Picker("Windows environment",selection:Binding(get:{preferences.environmentID ?? "current"},set:{preferences.environmentID=$0 == "current" ? nil : $0})) {
                    Text("Use selected environment").tag("current")
                    if let id=preferences.environmentID,!model.profiles.contains(where:{$0.id==id}) { Text("Saved environment unavailable").tag(id) }
                    ForEach(model.profiles) { Text("\($0.runtime.name) · \($0.name)").tag($0.id) }
                }
            }
            Text("Launch options").font(.headline)
            TextField("For example: -novid -windowed",text:$preferences.launchOptions).textFieldStyle(.roundedBorder)
            Text("Options are passed directly to the game. Quoted values stay together. Steam games also retain their Steam launch settings.").font(.caption).foregroundStyle(.secondary)
            Text("The saved environment is selected when you play. A running Windows application must finish before switching environments.").font(.caption).foregroundStyle(.secondary)
        }.padding(20).glassPanel(radius:16)
    }
    private var organization:some View {
        VStack(alignment:.leading,spacing:16) {
            TextField("Tags, separated by commas",text:$tags).textFieldStyle(.roundedBorder)
            Toggle("Hide this game from the main library",isOn:$preferences.hidden)
            Text("Hidden games remain available through the library's Hidden filter.").font(.caption).foregroundStyle(.secondary)
            Divider()
            Text("Collections").font(.headline)
            ForEach(model.collections.filter{$0.rule == .manual}) { collection in
                Toggle(collection.name,isOn:Binding(get:{preferences.collectionIDs.contains(collection.id)},set:{if $0 { preferences.collectionIDs.insert(collection.id) } else { preferences.collectionIDs.remove(collection.id) }}))
            }
            if model.collections.isEmpty { Text("Create collections from your library, then add games here.").font(.caption).foregroundStyle(.secondary) }
            Text("Smart collections update automatically from installation, platform, recent play, favorites, or tags.").font(.caption).foregroundStyle(.secondary)
        }.padding(20).glassPanel(radius:16)
    }
}

struct GameSavesView: View {
    @ObservedObject var model: LauncherModel
    let game: LibraryGame
    @State private var platform: GamePlatform = .macOS
    @State private var restore: SaveBackup?
    private var folders:[URL] { model.saveFolders(game,platform:platform) }
    private var cloud:SteamCloudStatus? { model.cloudStatuses["\(game.id):\(platform.rawValue)"] }
    var body:some View {
        VStack(alignment:.leading,spacing:18) {
            Picker("Save version",selection:$platform) { ForEach(game.platforms,id:\.self) { Text($0.name).tag($0) } }.pickerStyle(.segmented)
            if game.isSteam {
                HStack {
                    VStack(alignment:.leading,spacing:5) { Label(cloud?.title ?? "Steam Cloud status unavailable",systemImage:"icloud"); Text(cloud?.syncTitle ?? "Connect Steam to check synchronization.").font(.caption).foregroundStyle(.secondary) }
                    Spacer(); Button("Refresh") { model.refreshCloud(game,platform:platform) }
                    Button("Open Steam") { model.openSteamClient(platform) }
                }.padding(16).glassPanel(radius:14)
            }
            Text("Save folders").font(.headline)
            ForEach(folders,id:\.self) { folder in
                HStack {
                    Text(folder.path.replacingOccurrences(of:FileManager.default.homeDirectoryForCurrentUser.path,with:"~")).font(.caption).lineLimit(2)
                    Spacer(); Button { var value=model.preferences(for:game); value.saveFolders[model.saveScope(game,platform:platform)]?.removeAll{$0==folder}; try? model.updatePreferences(value,game:game) } label: { Image(systemName:"minus.circle") }.buttonStyle(ControllerButtonStyle(style: .plain)).help("Remove folder from backup settings")
                }
            }
            HStack {
                Button("Choose save folder…") { model.chooseSaveFolder(game,platform:platform) }
                if let suggested=model.suggestedSaveFolder(game,platform:platform),!folders.contains(suggested) {
                    Button("Use Steam save folder") { var value=model.preferences(for:game); value.saveFolders[model.saveScope(game,platform:platform),default:[]].append(suggested); try? model.updatePreferences(value,game:game) }
                }
            }
            Text("Choose folders containing this version's game saves. Backups stay on this Mac and do not change Steam Cloud.").font(.caption).foregroundStyle(.secondary)
            HStack { Button("Create restore point") { model.createSaveBackup(game,platform:platform) }.buttonStyle(QuietButtonStyle()).disabled(folders.isEmpty || model.saveBusy); if model.saveBusy { ProgressView().controlSize(.small) } }
            if !model.saveMessage.isEmpty { Text(model.saveMessage).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true) }
            Divider(); Text("Restore points").font(.headline)
            ForEach(model.saveBackups[model.saveScope(game,platform:platform)] ?? []) { backup in
                HStack {
                    VStack(alignment:.leading,spacing:4) { Text(backup.name).font(.subheadline); Text("\(backup.date.formatted()) · \(backup.files.count) files · \(formatBytes(backup.bytes))").font(.caption).foregroundStyle(.secondary) }
                    Spacer(); Button("Restore…") { restore=backup }.disabled(model.saveBusy || backup.files.isEmpty)
                }.padding(12).glassPanel(radius:12)
            }
        }
        .onAppear { platform=model.preferredGamePlatform(game) ?? game.platforms.first ?? .macOS; reload() }
        .onChange(of:platform) { _ in reload() }
        .alert("Restore these saves?",isPresented:Binding(get:{restore != nil},set:{if !$0 { restore=nil }})) {
            Button("Cancel",role:.cancel) { restore=nil }
            Button("Restore",role:.destructive) { if let backup=restore { model.restoreSaveBackup(backup,game:game,platform:platform) }; restore=nil }
        } message: { Text("Close the game first. Matching save files will be replaced, and a recovery point of your current saves will be kept. Newer files absent from the restore point remain.") }
    }
    private func reload() { model.refreshBackups(game,platform:platform); model.refreshCloud(game,platform:platform) }
}
