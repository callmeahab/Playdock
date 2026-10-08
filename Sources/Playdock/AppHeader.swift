import SwiftUI
import AppKit
import PlaydockCore

struct AppHeader: View {
    @ObservedFeatures var model: LauncherModel
    let page: AppPage
    let addGame: () -> Void

    init(model: LauncherModel, page: AppPage, addGame: @escaping () -> Void) {
        _model = ObservedFeatures(wrappedValue: model, [.library])
        self.page = page; self.addGame = addGame
    }

    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Eyebrow(title: page == .home && model.selectedGame == nil ? "Your daily escape" : "Playdock / \(page.rawValue)", color: .secondary)
                Text([.home, .library, .favorites].contains(page) && model.selectedGame != nil ? "Game overview" : page == .home ? "Good to see you." : page.rawValue)
                    .font(.system(size: 28, weight: .bold)).tracking(-0.7).lineLimit(1)
                if page != .home && model.selectedGame == nil { Text(page.subtitle).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1) }
            }
            Spacer(minLength: 12)
            Button { model.openQuickLauncher() } label: {
                HStack(spacing: 9) {
                    Image(systemName: "magnifyingglass")
                    Text("Quick search")
                    Text("⌘K").font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                        .padding(.horizontal, 5).padding(.vertical, 3).background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 4))
                }
            }.buttonStyle(QuietButtonStyle()).help("Quick launcher (⌘K)")
            if model.libraryState.refreshing { ProgressView().controlSize(.small) }
            Button { model.openCouch() } label: { Image(systemName: "gamecontroller").frame(width: 16, height: 16) }
                .buttonStyle(QuietButtonStyle()).help("Controller fullscreen (⌘⇧F)").accessibilityLabel("Controller fullscreen")
            if (page == .home || page == .library || page == .favorites) && model.selectedGame == nil {
                Button { addGame() } label: { Image(systemName: "plus").frame(width: 16, height: 16) }.buttonStyle(QuietButtonStyle()).help("Add game").accessibilityLabel("Add game")
            } else {
                Button { model.refresh() } label: { Image(systemName: "arrow.clockwise").frame(width: 16, height: 16) }.buttonStyle(QuietButtonStyle()).help("Refresh (⌘R)").accessibilityLabel("Refresh")
            }
        }.padding(.horizontal, 28).padding(.top, 40).padding(.bottom, 24)
    }

}
