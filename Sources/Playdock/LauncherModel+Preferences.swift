import AppKit
import Foundation
import PlaydockCore
import PlaydockPresentation

extension LauncherModel {
    func preferences(for game:LibraryGame) -> GamePreferences { settingsState.configuration.gamePreferences[game.id] ?? GamePreferences() }
    var collections:[GameCollection] { settingsState.configuration.collections }
    func updatePreferences(_ preferences:GamePreferences,game:LibraryGame) throws {
        _ = try preferences.arguments()
        if !game.isSteam, let id=preferences.environmentID, !runtimeState.profiles.contains(where:{$0.id==id}) && id != selectedProfile?.id { throw PlaydockError.message("This Windows environment is unavailable. Choose an installed environment.") }
        var value=preferences
        value.tags=Array(NSOrderedSet(array:preferences.tags.map{$0.trimmingCharacters(in:.whitespacesAndNewlines)}.filter{!$0.isEmpty}.map{String($0.prefix(40))})) as? [String] ?? []
        guard value.tags.count<=50 else { throw PlaydockError.message("Use at most 50 tags per game.") }
        settingsState.configuration.gamePreferences[game.id]=value; save()
    }
    func saveCollection(_ collection:GameCollection) throws {
        try GameCollection.validate(collection,in:collections)
        var values=collections; values.removeAll{$0.id==collection.id}; values.append(collection)
        settingsState.configuration.collections=values.sorted{$0.name.localizedStandardCompare($1.name) == .orderedAscending}; save()
    }
    func deleteCollection(_ collection:GameCollection) {
        var values=collections; values.removeAll{$0.id==collection.id}
        for index in values.indices where values[index].parentID==collection.id { values[index].parentID=collection.parentID }
        settingsState.configuration.collections=values
        for id in settingsState.configuration.gamePreferences.keys { settingsState.configuration.gamePreferences[id]?.collectionIDs.remove(collection.id) }
        save()
    }
    func inCollection(_ game:LibraryGame,id:String) -> Bool {
        let ids=GameCollection.descendants(of:id,in:collections)
        return collections.filter{ids.contains($0.id)}.contains{$0.matches(game,preferences:preferences(for:game),favorites:favorites)}
    }
    func launchInSavedEnvironment(_ game: LibraryGame, environment: String) {
        guard let target = runtimeState.profiles.first(where: { $0.id == environment }) else { error = "The saved Windows environment is unavailable. Update this game's profile."; return }
        Task {
            do {
                if let current = selectedProfile {
                    let apps = try await runtimeState.runtimeProcesses.windowsApps(prefix: current.prefix)
                    guard activityState.nativeGameWindows.isEmpty, apps.isEmpty else { throw PlaydockError.message("Close the running Windows application before switching environments.") }
                    guard selectedProfile?.id == current.id else { return }
                }
                selection = target.id
                for _ in 0..<50 {
                    if !libraryState.refreshing && libraryState.presentationTask == nil { break }
                    try await Task.sleep(for: .milliseconds(200))
                }
                guard selectedProfile?.id == target.id, let updated = library.first(where: { $0.id == game.id }) else {
                    error = "This game is not available in its saved environment. Update its environment profile."
                    return
                }
                launch(updated)
            } catch { self.error = error.localizedDescription }
        }
    }
    func markLaunch(_ name:String,outcome:String) {
        if let index=settingsState.configuration.launchHistory.lastIndex(where:{$0.name==name}) { settingsState.configuration.launchHistory[index].outcome=DiagnosticReport.redact(String(outcome.prefix(300))); save() }
    }
    func recordLaunch(_ game:LibraryGame,platform:GamePlatform,outcome:String) {
        var history=settingsState.configuration.launchHistory
        history.append(LaunchDiagnostic(gameID:game.id,name:game.name,platform:platform,environment:platform == .macOS ? "Native Mac" : game.isSteam ? "Steam–CrossOver bridge" : selectedProfile?.runtime.name ?? "Windows",outcome:DiagnosticReport.redact(outcome)))
        settingsState.configuration.launchHistory=Array(history.suffix(100)); save()
    }
    func exportDiagnostics() {
        let panel=NSSavePanel(); panel.nameFieldStringValue="Playdock-diagnostics.txt"; panel.allowedContentTypes=[.plainText]
        guard panel.runModal() == .OK,let url=panel.url else { return }
        let report=DiagnosticReport.make(version:Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Development",os:ProcessInfo.processInfo.operatingSystemVersionString,architecture:RuntimeDiscovery.isAppleSilicon ? "Apple silicon" : "Intel",runtimes:Array(Set(runtimeState.runtimes.map{$0.name})).sorted(),connections:["Mac Steam":connectionMode().title],history:settingsState.configuration.launchHistory)
        Task {
            do { try await FileService.shared.write(Data(report.utf8), to: url); NSWorkspace.shared.activateFileViewerSelecting([url]) }
            catch { self.error = "Could not export diagnostics: \(error.localizedDescription)" }
        }
    }
}
