import SwiftUI
import AppKit
import PlaydockCore
import PlaydockPresentation

struct ContentView: View {
    @ObservedFeatures var model: LauncherModel

    init(model: LauncherModel) {
        self._model = ObservedFeatures(wrappedValue: model, [])
    }
    @State private var page: AppPage = .home
    @State private var addingGame = false
    @State private var addingProfile = false

    var body: some View {
        Group {
            if model.showingCouch { CouchView(model: model, page: $page, addGame: { addingGame = true }, addProfile: { addingProfile = true }) }
            else {
                desktop
            }
        }
        .background(WindowMaterial(material: .underWindowBackground).allowsHitTesting(false))
        .modifier(GameplayEnvironment(model: model))
        .background(WindowAppearance().allowsHitTesting(false))
        .ignoresSafeArea(.container, edges: .top)
        .sheet(isPresented:$model.showingQuickLauncher){QuickLauncherView(model:model).controllerControls(model.showingCouch)}
        .sheet(item:$model.storageGame){game in GameStorageView(model:model,game:game,platform:model.storagePlatform).controllerControls(model.showingCouch)}
        .sheet(item:$model.achievementGame){game in AchievementsView(model:model,game:game,platform:model.achievementPlatform).controllerControls(model.showingCouch)}
        .sheet(isPresented: $model.showingSteamBridgeSetup) { SteamBridgeSetupView(model: model).controllerControls(model.showingCouch) }
        .sheet(item: $model.workshopGame) { game in WorkshopView(model: model, game: game).controllerControls(model.showingCouch) }
        .onChange(of:model.navigationRequest){_ in page=AppPage(rawValue:model.navigationDestination) ?? .library}
        .sheet(item:$model.featureGame) { game in GamePreferencesView(model:model,game:game).controllerControls(model.showingCouch) }
        .sheet(isPresented:$model.showingCollections) { CollectionsView(model:model).controllerControls(model.showingCouch) }
        .sheet(isPresented:$model.showingDiagnostics) { DiagnosticsView(model:model).controllerControls(model.showingCouch) }
        .sheet(isPresented: $addingGame) { AddGameView(model: model).controllerControls(model.showingCouch) }
        .sheet(isPresented: $addingProfile) { AddProfileView(model: model).controllerControls(model.showingCouch) }
        .onChange(of: model.libraryRequest) { _ in model.selectedGameID = nil; page = .library }
        .onChange(of: model.downloadsRequest) { _ in model.selectedGameID = nil; page = .downloads }
        .onChange(of: model.sessionRequest) { _ in page = .sessions }
        .onChange(of: model.chatRequest) { _ in page = .chat }
        .modifier(FeatureDialogs(model: model))
        .developmentControls(model: model, page: $page)
        .modifier(AppErrorDialog(model: model))
        .controllerControls(model.showingCouch)
    }

    private var desktop: some View {
        HStack(spacing: 0) {
            AppSidebar(model: model, page: $page, addGame: { addingGame = true })
            VStack(spacing: 0) {
                AppHeader(model: model, page: page, addGame: { addingGame = true })
                AppWorkspace(model: model, page: $page, addGame: { addingGame = true }, addProfile: { addingProfile = true })
            }.background(LibraryAtmosphere())
        }
    }

}
