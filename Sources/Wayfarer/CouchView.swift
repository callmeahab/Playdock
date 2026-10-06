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
    private var timer:Timer?
    private var observers:[NSObjectProtocol]=[]
    private weak var window:NSWindow?
    private var lastDirection=Date.distantPast
    func start(window:NSWindow?){
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
        }
    }
    private func poll(){
        guard acceptsInput,Date().timeIntervalSince(lastDirection)>0.18,let pad=GCController.controllers().first(where:{$0.extendedGamepad != nil})?.extendedGamepad else{return}
        let x=abs(pad.dpad.xAxis.value)>0.4 ? pad.dpad.xAxis.value:pad.leftThumbstick.xAxis.value
        let y=abs(pad.dpad.yAxis.value)>0.4 ? pad.dpad.yAxis.value:pad.leftThumbstick.yAxis.value
        guard max(abs(x),abs(y))>0.6 else{return};lastDirection=Date();move?(abs(x)>abs(y) ? (x>0 ? 1:-1):0,abs(y)>=abs(x) ? (y>0 ? -1:1):0)
    }
    func stop(){timer?.invalidate();timer=nil;for observer in observers{NotificationCenter.default.removeObserver(observer)};observers=[];for controller in GCController.controllers(){if let pad=controller.extendedGamepad{pad.buttonA.pressedChangedHandler=nil;pad.buttonB.pressedChangedHandler=nil;pad.buttonX.pressedChangedHandler=nil;pad.buttonMenu.pressedChangedHandler=nil}}}
}
struct CouchView:View {
    @ObservedObject var model:LauncherModel
    @StateObject private var controller=CouchController()
    @WayfarerState private var selected=0
    @WayfarerState private var selectedID:String?
    @WayfarerState private var enteredFullscreen=false
    @WayfarerState private var hostWindow:NSWindow?
    @WayfarerState private var favoritesOnly=false
    private let columns=5
    private var games:[LibraryGame]{model.quickGames.filter{$0.isInstalled && (!favoritesOnly || model.favorites.contains($0.id))}}
    private var selection:LibraryGame?{games.indices.contains(selected) ? games[selected]:nil}
    var body:some View {
        VStack(alignment:.leading,spacing:24){
            HStack{WayfarerMark();VStack(alignment:.leading){Text("Make yourself at home.").font(.system(size:30,weight:.semibold));Text(controller.name).foregroundStyle(.secondary)};Spacer();Button(favoritesOnly ? "All installed":"Favorites"){favoritesOnly.toggle();selected=0}.buttonStyle(QuietButtonStyle());Button("Exit fullscreen"){exit()}.buttonStyle(QuietButtonStyle())}
            ScrollViewReader{proxy in ScrollView{
                LazyVGrid(columns:Array(repeating:GridItem(.flexible(),spacing:22),count:columns),spacing:26){ForEach(Array(games.enumerated()),id:\.element.id){index,game in
                    Button{selected=index;selectedID=game.id;play()}label:{VStack(alignment:.leading,spacing:10){GameArtwork(game:game).aspectRatio(2/3,contentMode:.fit).clipShape(RoundedRectangle(cornerRadius:16)).overlay{RoundedRectangle(cornerRadius:16).stroke(index==selected ? WayfarerTheme.accent:Color.clear,lineWidth:4)};Text(game.name).font(.system(size:18,weight:.semibold)).lineLimit(2);Text(model.activeSession(game.id)?.phase.title ?? model.quickPlatform(game)?.name ?? "Installed").font(.caption).foregroundStyle(.secondary)}.padding(6)}.buttonStyle(.plain).id(index)
                }}.padding(5)
                if games.isEmpty{Text("No installed games in this view. Install a game from the library to play here.").font(.title2).foregroundStyle(.secondary).padding(50)}
            }.onChange(of:selected){proxy.scrollTo($0,anchor:.center)}}
            HStack{Text(selection?.name ?? "Choose a game").font(.title2).lineLimit(1);Spacer();Text("A / Return · Play   X · Favorite   B / Escape · Exit").font(.system(size:16)).foregroundStyle(.secondary)}
            if let game=selection,let active=model.activeSession(game.id){Text("\(active.phase.title) · \(active.message)").font(.caption).foregroundStyle(.secondary)}
        }.padding(38).frame(maxWidth:.infinity,maxHeight:.infinity).background(LibraryAtmosphere())
        .background(NavigationKeys{key in switch key{case 123:move(-1,0);return true;case 124:move(1,0);return true;case 125:move(0,1);return true;case 126:move(0,-1);return true;case 36,76:play();return true;case 53:exit();return true;default:return false}}.frame(width:0,height:0))
        .onAppear{let window=NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first(where:{$0.canBecomeMain && $0.sheetParent==nil});hostWindow=window;NSApp.activate(ignoringOtherApps:true);window?.makeKeyAndOrderFront(nil);enteredFullscreen=window?.styleMask.contains(.fullScreen)==false;if enteredFullscreen{window?.toggleFullScreen(nil)};controller.move=move;controller.select=play;controller.back=exit;controller.favorite={if let game=selection{model.toggleFavorite(game)}};controller.start(window:window)}
        .onDisappear{controller.stop();if enteredFullscreen,hostWindow?.styleMask.contains(.fullScreen)==true{hostWindow?.toggleFullScreen(nil)}}
        .onChange(of:games.map{$0.id}){_ in selected=selectedID.flatMap{id in games.firstIndex{$0.id==id}} ?? min(selected,max(0,games.count-1));selectedID=selection?.id}
    }
    private func move(_ dx:Int,_ dy:Int){selected=ControllerGrid.destination(index:selected,count:games.count,columns:columns,dx:dx,dy:dy);selectedID=selection?.id}
    private func play(){if let game=selection{selectedID=game.id;model.launch(game,platform:model.quickPlatform(game))}}
    private func exit(){model.showingCouch=false}
}
