import SwiftUI
import AppKit
import GameController
import WayfarerCore

@MainActor final class CouchController:ObservableObject {
    @Published var name="Keyboard and mouse"
    var move:((Int,Int)->Void)?
    var select:(()->Void)?
    var back:(()->Void)?
    var favorite:(()->Void)?
    var changeShelf:((Int)->Void)?
    private var timer:Timer?
    private var observers:[NSObjectProtocol]=[]
    private weak var window:NSWindow?
    private var lastDirection=Date.distantPast
    func start(window:NSWindow?){
        stop()
        self.window=window;GCController.shouldMonitorBackgroundEvents=false
        for notification in [Notification.Name.GCControllerDidConnect,Notification.Name.GCControllerDidDisconnect]{observers.append(NotificationCenter.default.addObserver(forName:notification,object:nil,queue:.main){[weak self] _ in Task{@MainActor in self?.attach()}})}
        attach()
        timer=Timer.scheduledTimer(withTimeInterval:0.08,repeats:true){[weak self] _ in Task{@MainActor in self?.poll()}}
    }
    private var acceptsInput:Bool{NSApp.isActive && window?.isKeyWindow==true && window?.attachedSheet==nil}
    private func attach(){
        name=GCController.controllers().first(where:{$0.extendedGamepad != nil})?.vendorName ?? "Keyboard and mouse"
        for controller in GCController.controllers(){
            guard let pad=controller.extendedGamepad else{continue}
            pad.buttonA.pressedChangedHandler={ [weak self] _,_,pressed in if pressed{Task{@MainActor in if self?.acceptsInput==true{self?.select?()}}} }
            pad.buttonB.pressedChangedHandler={ [weak self] _,_,pressed in if pressed{Task{@MainActor in if self?.acceptsInput==true{self?.back?()}}} }
            pad.buttonX.pressedChangedHandler={ [weak self] _,_,pressed in if pressed{Task{@MainActor in if self?.acceptsInput==true{self?.favorite?()}}} }
            pad.buttonMenu.pressedChangedHandler={ [weak self] _,_,pressed in if pressed{Task{@MainActor in if self?.acceptsInput==true{self?.back?()}}} }
            pad.leftShoulder.pressedChangedHandler={ [weak self] _,_,pressed in if pressed{Task{@MainActor in if self?.acceptsInput==true{self?.changeShelf?(-1)}}} }
            pad.rightShoulder.pressedChangedHandler={ [weak self] _,_,pressed in if pressed{Task{@MainActor in if self?.acceptsInput==true{self?.changeShelf?(1)}}} }
        }
    }
    private func poll(){
        guard acceptsInput,Date().timeIntervalSince(lastDirection)>0.18,let pad=GCController.controllers().first(where:{$0.extendedGamepad != nil})?.extendedGamepad else{return}
        let x=abs(pad.dpad.xAxis.value)>0.4 ? pad.dpad.xAxis.value:pad.leftThumbstick.xAxis.value
        let y=abs(pad.dpad.yAxis.value)>0.4 ? pad.dpad.yAxis.value:pad.leftThumbstick.yAxis.value
        guard max(abs(x),abs(y))>0.6 else{return};lastDirection=Date();move?(abs(x)>abs(y) ? (x>0 ? 1:-1):0,abs(y)>=abs(x) ? (y>0 ? -1:1):0)
    }
    func stop(){timer?.invalidate();timer=nil;for observer in observers{NotificationCenter.default.removeObserver(observer)};observers=[];for controller in GCController.controllers(){if let pad=controller.extendedGamepad{pad.buttonA.pressedChangedHandler=nil;pad.buttonB.pressedChangedHandler=nil;pad.buttonX.pressedChangedHandler=nil;pad.buttonMenu.pressedChangedHandler=nil;pad.leftShoulder.pressedChangedHandler=nil;pad.rightShoulder.pressedChangedHandler=nil}}}
    isolated deinit { stop() }
}

private enum CouchShelf: String, CaseIterable {
    case installed = "Ready to play", favorites = "Favorites", all = "All games"
    var symbol: String { switch self { case .installed: "play.circle.fill"; case .favorites: "heart.fill"; case .all: "square.grid.2x2.fill" } }
    var subtitle: String {
        switch self {
        case .installed: "Your installed games. Pick up where you left off."
        case .favorites: "The games you keep coming back to."
        case .all: "Your whole collection, with Mac and Windows together."
        }
    }
}

struct CouchView:View {
    @ObservedObject var model:LauncherModel
    @StateObject private var controller=CouchController()
    @WayfarerState private var selected=0
    @WayfarerState private var selectedID:String?
    @WayfarerState private var enteredFullscreen=false
    @WayfarerState private var hostWindow:NSWindow?
    @WayfarerState private var shelf: CouchShelf = .installed
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var games:[LibraryGame]{model.quickGames.filter { shelf == .all || (shelf == .installed ? $0.isInstalled : model.favorites.contains($0.id)) }}
    private var selection:LibraryGame?{games.indices.contains(selected) ? games[selected]:nil}
    var body:some View {
        let games = self.games
        let game = games.indices.contains(selected) ? games[selected] : games.first
        GeometryReader { geometry in
            let inset: CGFloat = geometry.size.width > 1500 ? 64 : 38
            let coverWidth = min(184, max(124, geometry.size.width * 0.115))
            ZStack {
                backdrop(game)
                VStack(spacing: 0) {
                    header.padding(.top, 28).padding(.bottom, 22)
                    shelves.padding(.bottom, 20)
                    ScrollView(showsIndicators: false) {
                        VStack(alignment: .leading, spacing: 24) {
                            if let game {
                                hero(game, width: geometry.size.width - inset * 2)
                                    .frame(height: max(330, min(460, geometry.size.height * 0.38)))
                            } else { emptyShelf.frame(height: max(250, geometry.size.height * 0.38)) }
                            HStack(alignment: .firstTextBaseline) {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(shelf.rawValue).font(.system(size: 21, weight: .semibold))
                                    Text(shelf.subtitle).font(.system(size: 13)).foregroundStyle(.white.opacity(0.5))
                                }
                                Spacer()
                                Text("\(games.count) \(games.count == 1 ? "game" : "games")")
                                    .font(.system(size: 13, weight: .medium, design: .monospaced)).foregroundStyle(.white.opacity(0.5))
                            }
                            ScrollViewReader { proxy in
                                ScrollView(.horizontal, showsIndicators: false) {
                                    LazyHStack(alignment: .top, spacing: 20) {
                                        ForEach(games) { item in
                                            CouchGameTile(game: item, selected: item.id == game?.id,
                                                          favorite: model.favorites.contains(item.id),
                                                          subtitle: model.activeSession(item.id)?.phase.title ?? (item.isInstalled ? model.quickPlatform(item)?.name ?? "Ready to play" : "In your library"),
                                                          width: coverWidth, choose: { choose(item.id) }).equatable().id(item.id)
                                        }
                                    }.padding(8)
                                }.padding(.horizontal, -8)
                                .onChange(of: selectedID) { id in
                                    guard let id else { return }
                                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.16)) { proxy.scrollTo(id, anchor: .center) }
                                }
                            }
                        }.padding(.bottom, 24)
                    }
                    footer.padding(.vertical, 20)
                }.padding(.horizontal, inset)
            }
        }.frame(maxWidth:.infinity,maxHeight:.infinity)
        .background(NavigationKeys{key in switch key{case 123:move(-1,0);return true;case 124:move(1,0);return true;case 125:changeShelf(1);return true;case 126:changeShelf(-1);return true;case 48:changeShelf(1);return true;case 7:favorite();return true;case 36,76:play();return true;case 53:exit();return true;default:return false}}.frame(width:0,height:0))
        .onAppear{let window=NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first(where:{$0.canBecomeMain && $0.sheetParent==nil});hostWindow=window;NSApp.activate(ignoringOtherApps:true);window?.makeKeyAndOrderFront(nil);enteredFullscreen=window?.styleMask.contains(.fullScreen)==false;if enteredFullscreen{window?.toggleFullScreen(nil)};selectedID=selection?.id;controller.move=move;controller.select=play;controller.back=exit;controller.favorite=favorite;controller.changeShelf=changeShelf;controller.start(window:window)}
        .onDisappear{controller.stop();if enteredFullscreen,hostWindow?.styleMask.contains(.fullScreen)==true{hostWindow?.toggleFullScreen(nil)}}
        .onChange(of:games.map{$0.id}){_ in selected=selectedID.flatMap{id in games.firstIndex{$0.id==id}} ?? min(selected,max(0,games.count-1));selectedID=selection?.id}
        .task {
            #if DEBUG
            guard let flag = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--couch-ui-probe=") }) else { return }
            for _ in 0..<150 {
                if !model.refreshing && !self.games.isEmpty { break }
                do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
            }
            do {
                try await Task.sleep(for: .milliseconds(900))
                let initial = selectedID, installed = self.games.count
                postNavigationKey(124)
                try await Task.sleep(for: .milliseconds(250))
                let moved = selectedID != initial
                postNavigationKey(48)
                try await Task.sleep(for: .milliseconds(250))
                let favorites = shelf == .favorites
                postNavigationKey(48)
                try await Task.sleep(for: .milliseconds(250))
                let result: [String: Any] = ["installedGames": installed, "arrowChangedSelection": moved,
                    "tabOpenedFavorites": favorites, "tabOpenedAllGames": shelf == .all,
                    "allGames": self.games.count, "libraryGames": model.quickGames.count,
                    "enteredFullscreen": hostWindow?.styleMask.contains(.fullScreen) == true]
                let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
                try await FileService.shared.write(data, to: URL(fileURLWithPath: String(flag.dropFirst("--couch-ui-probe=".count))))
            } catch { }
            #endif
        }
    }
    private func move(_ dx:Int,_ dy:Int){
        if dy != 0 { changeShelf(dy); return }
        let games = self.games
        selected=ControllerGrid.destination(index:selected,count:games.count,columns:max(1,games.count),dx:dx,dy:0);selectedID=selection?.id
    }
    private func choose(_ id: String) { guard let index = games.firstIndex(where: { $0.id == id }) else { return }; selected = index; selectedID = id }
    private func changeShelf(_ direction: Int) {
        let all = CouchShelf.allCases, index = all.firstIndex(of: shelf) ?? 0
        selectShelf(all[(index + direction + all.count) % all.count])
    }
    private func selectShelf(_ value: CouchShelf) { shelf = value; selected = selectedID.flatMap { id in games.firstIndex { $0.id == id } } ?? 0; selectedID = selection?.id }
    private func favorite() { if let game = selection { model.toggleFavorite(game) } }
    private func play(){
        if let game=selection {
            selectedID=game.id
            if game.isInstalled { model.launch(game,platform:model.quickPlatform(game)) }
            else { details(game) }
        }
    }
    private func details(_ game: LibraryGame) { model.navigate("Library"); model.showGame(game) }
    private func exit(){model.showingCouch=false}

    #if DEBUG
    private func postNavigationKey(_ code: UInt16) {
        guard let window = hostWindow,
              let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: window.windowNumber, context: nil, characters: code == 48 ? "\t" : "\u{f703}",
                                           charactersIgnoringModifiers: code == 48 ? "\t" : "\u{f703}", isARepeat: false, keyCode: code) else { return }
        NSApp.postEvent(event, atStart: false)
    }
    #endif

    private var header: some View {
        HStack(spacing: 14) {
            WayfarerMark().frame(width: 40, height: 40)
            VStack(alignment: .leading, spacing: 5) {
                Text("WAYFARER").font(.system(size: 14, weight: .bold)).tracking(3)
                Text("Make yourself at home.").font(.system(size: 13)).foregroundStyle(.white.opacity(0.5))
            }
            Spacer()
            Label(controller.name, systemImage: "gamecontroller").font(.system(size: 12)).foregroundStyle(.white.opacity(0.6))
            Button { model.openQuickLauncher() } label: { Image(systemName: "magnifyingglass").frame(width: 22, height: 22) }
                .buttonStyle(QuietButtonStyle()).help("Search your library (⌘K)").accessibilityLabel("Search your library")
            Button(action: exit) { Label("Back to desktop", systemImage: "arrow.down.right.and.arrow.up.left") }.buttonStyle(QuietButtonStyle())
        }
    }
    private var shelves: some View {
        HStack(spacing: 10) {
            ForEach(CouchShelf.allCases, id: \.self) { item in
                Button { selectShelf(item) } label: {
                    Label(item.rawValue, systemImage: item.symbol).font(.system(size: 14, weight: .semibold))
                        .padding(.horizontal, 19).padding(.vertical, 12)
                        .foregroundStyle(shelf == item ? WayfarerTheme.accent : .white.opacity(0.6))
                        .background(shelf == item ? WayfarerTheme.accent.opacity(0.12) : .white.opacity(0.035), in: Capsule())
                        .overlay(Capsule().strokeBorder(shelf == item ? WayfarerTheme.accent.opacity(0.45) : .white.opacity(0.06), lineWidth: 1))
                }.buttonStyle(.plain).accessibilityAddTraits(shelf == item ? .isSelected : [])
            }
            Spacer()
            Text("LB / RB to switch shelves").font(.system(size: 12)).foregroundStyle(.white.opacity(0.35))
        }
    }
    private func backdrop(_ game: LibraryGame?) -> some View {
        ZStack {
            Color(red: 0.025, green: 0.035, blue: 0.055)
            if let game { GameArtwork(game: game, wide: true).opacity(0.24).accessibilityHidden(true) }
            LinearGradient(colors: [Color.black.opacity(0.45), Color(red: 0.025, green: 0.035, blue: 0.055).opacity(0.9)], startPoint: .top, endPoint: .bottom)
            LinearGradient(colors: [Color.black.opacity(0.65), .clear], startPoint: .leading, endPoint: .trailing)
        }.ignoresSafeArea().allowsHitTesting(false)
    }
    private func hero(_ game: LibraryGame, width: CGFloat) -> some View {
        let active = model.activeSession(game.id)
        let accent = GameIdentity.accent(game)
        return GeometryReader { geometry in
            HStack(spacing: 36) {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(spacing: 8) {
                        Circle().fill(accent).frame(width: 6, height: 6)
                        Text(active?.phase.title.uppercased() ?? (game.isInstalled ? "YOUR NEXT ADVENTURE" : "IN YOUR COLLECTION"))
                            .font(.system(size: 11, weight: .bold)).tracking(2).foregroundStyle(accent)
                    }
                    Text(game.name).font(.system(size: min(60, max(36, width * 0.043)), weight: .bold)).tracking(-1.5)
                        .lineLimit(3).minimumScaleFactor(0.75).fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 12) {
                        ForEach(game.platforms, id: \.self) { PlatformBadge(platform: $0) }
                        Text(game.isInstalled ? "Installed · Ready to play" : "Available in your library")
                            .font(.system(size: 13)).foregroundStyle(.white.opacity(0.65))
                    }
                    if let active { Text(active.message).font(.system(size: 13)).foregroundStyle(.white.opacity(0.6)).lineLimit(2) }
                    else if game.lastPlayed > 0 {
                        HStack(spacing: 5) { Text("Last played"); Text(Date(timeIntervalSince1970: game.lastPlayed), style: .relative).lineLimit(1) }
                            .font(.system(size: 13)).foregroundStyle(.white.opacity(0.5))
                    }
                    HStack(spacing: 12) {
                        Button(action: play) {
                            HStack(spacing: 12) {
                                Image(systemName: active != nil || game.isInstalled ? "play.fill" : "arrow.up.right")
                                Text(active != nil ? "Return to game" : game.isInstalled ? "Play now" : "View game")
                                Text("A / ↵").font(.system(size: 11, weight: .semibold)).opacity(0.6)
                            }.font(.system(size: 16, weight: .semibold)).padding(.horizontal, 7).padding(.vertical, 3)
                        }.buttonStyle(PlayButtonStyle()).disabled(model.installing)
                        Button { details(game) } label: { Text("Game details").font(.system(size: 14, weight: .medium)) }.buttonStyle(QuietButtonStyle())
                        Button(action: favorite) { Image(systemName: model.favorites.contains(game.id) ? "heart.fill" : "heart").font(.system(size: 16)) }
                            .buttonStyle(QuietButtonStyle()).help(model.favorites.contains(game.id) ? "Remove from favorites (X)" : "Add to favorites (X)")
                            .accessibilityLabel(model.favorites.contains(game.id) ? "Remove from favorites" : "Add to favorites")
                    }.padding(.top, 5)
                }.frame(maxWidth: .infinity, alignment: .leading)
                GameArtwork(game: game).frame(width: (geometry.size.height - 38) / 1.5, height: geometry.size.height - 38)
                    .clipShape(RoundedRectangle(cornerRadius: 15))
                    .overlay(RoundedRectangle(cornerRadius: 15).strokeBorder(.white.opacity(0.2), lineWidth: 1))
                    .shadow(color: .black.opacity(0.65), radius: 25, y: 15).padding(.trailing, 22).accessibilityHidden(true)
            }.padding(.horizontal, 30).padding(.vertical, 18).frame(maxWidth: .infinity, maxHeight: .infinity)
        }.background(LinearGradient(colors: [.black.opacity(0.35), accent.opacity(0.055)], startPoint: .leading, endPoint: .trailing), in: RoundedRectangle(cornerRadius: 25))
            .overlay(RoundedRectangle(cornerRadius: 25).strokeBorder(.white.opacity(0.09), lineWidth: 1))
    }
    private var emptyShelf: some View {
        VStack(alignment: .leading, spacing: 16) {
            Image(systemName: shelf.symbol).font(.system(size: 34)).foregroundStyle(WayfarerTheme.accent)
            Text(shelf == .favorites ? "Keep your favorites close." : "Your next adventure is waiting.").font(.system(size: 36, weight: .bold))
            Text(shelf == .favorites ? "Choose a game in All games and press X to save it here." : model.refreshing ? "Your games will appear as the library loads." : "Browse your collection and open a game’s details to install it.")
                .font(.system(size: 16)).foregroundStyle(.white.opacity(0.6))
            Button("Browse all games") { selectShelf(.all) }.buttonStyle(PlayButtonStyle())
        }.frame(maxWidth: .infinity, alignment: .leading).padding(30)
    }
    private var footer: some View {
        HStack(spacing: 25) {
            controlHint("↔", "Browse")
            controlHint("LB / RB", "Shelves")
            Spacer()
            controlHint("A / ↵", selection?.isInstalled == false ? "Details" : "Play")
            controlHint("X", "Favorite")
            controlHint("B / Esc", "Back")
        }.overlay(alignment: .top) { Rectangle().fill(.white.opacity(0.08)).frame(height: 1).offset(y: -20) }
    }
    private func controlHint(_ key: String, _ title: String) -> some View {
        HStack(spacing: 9) {
            Text(key).font(.system(size: 11, weight: .bold, design: .rounded)).padding(.horizontal, 8).padding(.vertical, 5)
                .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 6)).foregroundStyle(.white.opacity(0.8))
            Text(title).font(.system(size: 12)).foregroundStyle(.white.opacity(0.5))
        }
    }
}

private struct CouchGameTile: View, Equatable {
    let game: LibraryGame
    let selected: Bool
    let favorite: Bool
    let subtitle: String
    let width: CGFloat
    let choose: () -> Void
    nonisolated static func == (lhs: Self, rhs: Self) -> Bool { lhs.game == rhs.game && lhs.selected == rhs.selected && lhs.favorite == rhs.favorite && lhs.subtitle == rhs.subtitle && lhs.width == rhs.width }
    var body: some View {
        Button(action: choose) {
            VStack(alignment: .leading, spacing: 10) {
                ZStack(alignment: .topTrailing) {
                    GameArtwork(game: game).frame(width: width, height: width * 1.5).clipShape(RoundedRectangle(cornerRadius: 12))
                    if favorite { Image(systemName: "heart.fill").font(.system(size: 12)).foregroundStyle(WayfarerTheme.accent).padding(9).background(.black.opacity(0.6), in: Circle()).padding(8) }
                }.overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(selected ? WayfarerTheme.accent : .white.opacity(0.1), lineWidth: selected ? 3 : 1))
                Text(game.name).font(.system(size: 13, weight: .semibold)).foregroundStyle(selected ? .white : .white.opacity(0.7)).lineLimit(2).frame(height: 34, alignment: .topLeading)
                HStack(spacing: 5) { if selected { Circle().fill(WayfarerTheme.accent).frame(width: 4, height: 4) }; Text(subtitle).lineLimit(1) }
                    .font(.system(size: 11)).foregroundStyle(selected ? WayfarerTheme.accent : .white.opacity(0.4))
            }.frame(width: width, alignment: .leading)
        }.buttonStyle(.plain).help("Select \(game.name)").accessibilityLabel("Select \(game.name)").accessibilityAddTraits(selected ? .isSelected : [])
    }
}
