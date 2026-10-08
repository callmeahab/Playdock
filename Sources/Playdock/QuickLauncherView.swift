import SwiftUI
import AppKit
import PlaydockCore

struct NavigationKeys:NSViewRepresentable {
    var action:(UInt16)->Bool
    func makeNSView(context:Context)->NSView{let view=NSView();context.coordinator.view=view;context.coordinator.action=action;context.coordinator.start();return view}
    func updateNSView(_ view:NSView,context:Context){context.coordinator.action=action}
    func makeCoordinator()->Coordinator{Coordinator()}
    static func dismantleNSView(_ view:NSView,coordinator:Coordinator){coordinator.stop()}
    @MainActor final class Coordinator{
        weak var view:NSView?
        var action:((UInt16)->Bool)?
        var monitor:Any?
        func start(){monitor=NSEvent.addLocalMonitorForEvents(matching:.keyDown){[weak self] event in
            let handled = MainActor.assumeIsolated {
                guard let self, NSApp.isActive, event.window == self.view?.window,
                      event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return false }
                return self.action?(event.keyCode) == true
            }
            return handled ? nil : event
        }}
        func stop(){if let monitor{NSEvent.removeMonitor(monitor)};monitor=nil}
        isolated deinit{stop()}
    }
}
struct QuickLauncherView:View {
    @ObservedFeatures var model: LauncherModel

    init(model: LauncherModel) {
        self._model = ObservedFeatures(wrappedValue: model, [.library, .runtime, .settings])
    }
    @Environment(\.dismiss) private var dismiss
    @State private var query=""
    @State private var selected=0
    @FocusState private var searching:Bool
    private let actions=AppPage.allCases.map(\.rawValue)+["Controller fullscreen"]
    private var games:[LibraryGame]{Array(model.quickGames.filter{QuickSearch.matches(query,name:$0.name,tags:model.preferences(for:$0).tags)}.prefix(40))}
    private var routes:[String]{actions.filter{query.isEmpty || QuickSearch.matches(query,name:$0,tags:$0 == "Chat" ? ["friends"]:[])}}
    private var count:Int{games.count+routes.count}
    var body:some View {
        let games = self.games, routes = self.routes
        let count = games.count + routes.count
        return VStack(alignment:.leading,spacing:16){
            HStack{Image(systemName:"magnifyingglass");TextField("Find a game or jump to Downloads, Friends, Storage…",text:$query).textFieldStyle(.plain).focused($searching);Button{model.showingQuickLauncher=false}label:{Image(systemName:"xmark")}.buttonStyle(ControllerButtonStyle(style: .plain)).help("Close (Escape)")}.font(.system(size:17)).padding(12)
            Divider()
            ScrollViewReader{proxy in ScrollView{
                LazyVStack(alignment:.leading,spacing:4){
                    if query.isEmpty && !games.isEmpty{Text("Favorites & recent games").font(.caption).foregroundStyle(.secondary).padding(.horizontal,12)}
                    ForEach(Array(games.enumerated()),id:\.element.id){index,game in
                        row(index:index,title:game.name,subtitle:gameSubtitle(game),game:game,symbol:model.favorites.contains(game.id) ? "heart.fill":"gamecontroller.fill").id("game:"+game.id)
                    }
                    ForEach(Array(routes.enumerated()),id:\.element){index,route in row(index:games.count+index,title:route == "Chat" ? "Friends & chat":route,subtitle:"Go to \(route.lowercased())",symbol:"arrow.turn.down.right").id("route:"+route)}
                    if count==0{Text("No matching games or pages.").foregroundStyle(.secondary).padding(16)}
                }
            }.onChange(of:selected){index in if index>=0,index<count{proxy.scrollTo(index<games.count ? "game:"+games[index].id:"route:"+routes[index-games.count],anchor:.center)}}}
            Text("↑ ↓ to select · Return to open or play · Escape to close · ⌘K").font(.caption).foregroundStyle(.secondary).padding(.horizontal,12)
        }.padding(16).frame(width:740,height:530).background(LibraryAtmosphere())
        .background(NavigationKeys{key in
            switch key{case 125:selected=min(max(0,count-1),selected+1);return true;case 126:selected=max(0,selected-1);return true;case 36,76:activate(selected);return true;case 53:model.showingQuickLauncher=false;return true;default:return false}
        }.frame(width:0,height:0))
        .onAppear{searching=true}
        .onChange(of:model.library.map{ $0.id }){_ in selected=min(selected,max(0,count-1))}
        .onAppear {
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--feature-probe"){print("QUICK_GAMES=\(games.count),library=\(model.quickGames.count)");fflush(stdout)}
            #endif
        }.onChange(of:query){_ in selected=0}
    }
    private func gameSubtitle(_ game:LibraryGame)->String{if let active=model.activeSession(game.id){return "\(active.phase.title) · Bring game forward"};return model.executionInstalled(game) ? "Play · \(model.executionName(game))":"Open game details · Install when online"}
    private func row(index:Int,title:String,subtitle:String,game:LibraryGame? = nil,symbol:String)->some View {
        Button{activate(index)}label:{HStack(spacing:12){if let game{GameArtwork(game:game).frame(width:34,height:44).clipShape(RoundedRectangle(cornerRadius:5))}else{Image(systemName:symbol).frame(width:34,height:44).foregroundStyle(PlaydockTheme.violet)};VStack(alignment:.leading,spacing:4){Text(title).font(.headline);Text(subtitle).font(.caption).foregroundStyle(.secondary)};Spacer();if selected==index{Image(systemName:"return").foregroundStyle(.secondary)}}.padding(12).background(selected==index ? PlaydockTheme.accent.opacity(0.13):Color.clear,in:RoundedRectangle(cornerRadius:10))}.buttonStyle(ControllerButtonStyle(style: .plain))
    }
    private func activate(_ index:Int){
        guard index>=0,index<count else{return};model.showingQuickLauncher=false
        if index<games.count{let game=games[index];if model.executionInstalled(game){model.launch(game)}else{model.navigate("Library");model.showGame(game)}}else{let route=routes[index-games.count];if route=="Controller fullscreen"{model.openCouch()}else{model.navigate(route)}}
    }
}
