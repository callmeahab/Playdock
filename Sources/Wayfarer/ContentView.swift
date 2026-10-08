import SwiftUI
import AppKit
import WayfarerCore

struct ContentView: View {
    @ObservedObject var model: LauncherModel
    @WayfarerState private var page: AppPage = .home
    @WayfarerState private var addingGame = false
    @WayfarerState private var addingProfile = false

    var body: some View {
        Group {
            if model.showingCouch { CouchView(model: model, page: $page, addGame: { addingGame = true }, addProfile: { addingProfile = true }) }
            else {
                desktop
            }
        }
        .background(WindowMaterial(material: .underWindowBackground).allowsHitTesting(false))
        .environment(\.gameplayQuiet, model.gameplayQuiet)
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
        .sheet(item:$model.windowsAppsProfile,onDismiss:{model.closeWindowsApps()}) { profile in WindowsAppsView(model:model,profile:profile).controllerControls(model.showingCouch) }
        .sheet(isPresented: $addingGame) { AddGameView(model: model).controllerControls(model.showingCouch) }
        .sheet(isPresented: $addingProfile) { AddProfileView(model: model).controllerControls(model.showingCouch) }
        .sheet(item: $model.installationRequest, onDismiss:{ model.cancelInstallation() }) { request in InstallGameView(model: model, request: request).controllerControls(model.showingCouch) }
        .sheet(item:$model.uninstallationRequest,onDismiss:{ model.closeUninstallDialog() }) { request in UninstallGameView(model:model,request:request).controllerControls(model.showingCouch) }
        .sheet(item: $model.steamLaunchPrompt) { prompt in SteamLaunchPromptView(model: model, prompt: prompt).controllerControls(model.showingCouch) }
        .onChange(of: model.libraryRequest) { _ in model.selectedGameID = nil; page = .library }
        .onChange(of: model.downloadsRequest) { _ in model.selectedGameID = nil; page = .downloads }
        .onChange(of: model.sessionRequest) { _ in page = .sessions }
        .onChange(of: model.chatRequest) { _ in page = .chat }
        .onAppear {
            if ProcessInfo.processInfo.arguments.contains("--show-library") { page = .library }
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--show-storage"){page = .storage}
            if ProcessInfo.processInfo.arguments.contains("--show-activity"){page = .sessions}
            if ProcessInfo.processInfo.arguments.contains("--show-quick"){model.showingQuickLauncher=true}
            if ProcessInfo.processInfo.arguments.contains("--show-couch"){model.openCouch()}
            if ProcessInfo.processInfo.arguments.contains("--show-downloads") { page = .downloads }
            if ProcessInfo.processInfo.arguments.contains("--show-windows-apps") {
                Task {
                    while model.refreshing { try? await Task.sleep(for:.milliseconds(100)) }
                    model.manageWindowsApps()
                }
            }
            if ProcessInfo.processInfo.arguments.contains("--show-collections") { model.showingCollections=true }
            if ProcessInfo.processInfo.arguments.contains("--show-steam-bridge") { model.showingSteamBridgeSetup = true }
            if ProcessInfo.processInfo.arguments.contains("--show-diagnostics") { model.showingDiagnostics=true }
            if ProcessInfo.processInfo.arguments.contains("--show-chat") { page = .chat }
            #endif
        }
        .task {
            #if DEBUG
            if let flag = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--launch-installed-game-probe=") }) {
                await model.probeInstalledSteamLaunch(output: URL(fileURLWithPath: String(flag.dropFirst("--launch-installed-game-probe=".count))))
            }
            if let flag = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--single-steam-ui-probe=") }) {
                for _ in 0..<100 {
                    if !model.refreshing { break }
                    try? await Task.sleep(for: .milliseconds(100))
                }
                let result: [String: Any] = ["clients": model.steamClients.map(\.rawValue), "bigScreen": model.showingCouch,
                    "steamRoot": model.steamRoot.path,
                    "macSteamWindowsGame": model.library.contains { $0.installation(for: .windows)?.steamGame != nil },
                    "bridgeProfile": model.steamBridgeProfile.id,
                    "connections": Array(model.steamConnections.keys).map(\.rawValue)]
                if let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]) {
                    try? await FileService.shared.write(data, to: URL(fileURLWithPath: String(flag.dropFirst("--single-steam-ui-probe=".count))))
                }
                NSApp.perform(#selector(NSApplication.terminate(_:)), with: nil, afterDelay: 0)
            }
            if let flag = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--bridge-ui-probe=") || $0.hasPrefix("--bridge-startup-ui-probe=") }) {
                let startup = flag.hasPrefix("--bridge-startup-ui-probe=")
                if !startup { model.showingSteamBridgeSetup = true }
                for _ in 0..<30 {
                    try? await Task.sleep(for: .milliseconds(200))
                    if model.bridgeEnvironment != nil && !model.bridgeChecking { break }
                }
                if ProcessInfo.processInfo.arguments.contains("--bridge-progress-preview") { model.previewBridgeProgress() }
                try? await Task.sleep(for: .milliseconds(500))
                let window = NSApp.windows.first { $0.sheetParent != nil }
                let focus = CouchFocus()
                var result: [String: Any] = ["sheet": window != nil, "bigScreen": model.showingCouch,
                    "controls": focus.controls(in: window).count, "checkedRequirements": model.bridgeEnvironment != nil,
                    "ready": model.bridgeEnvironment?.ready == true, "setupPresented": model.showingSteamBridgeSetup,
                    "connectingBeforeDismissal": !model.connectionBusy.isEmpty]
                if let snapshot = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--bridge-ui-snapshot=") }), let window {
                    let windowID = window.windowNumber, path = String(snapshot.dropFirst("--bridge-ui-snapshot=".count))
                    await Task.detached {
                        let capture = Process()
                        capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                        capture.arguments = ["-x", "-o", "-l", String(windowID), path]
                        try? capture.run(); capture.waitUntilExit()
                    }.value
                }
                if model.showingCouch { result["closePressed"] = focus.pressForProbe(label: "Close", in: window) }
                else if let window, let escape = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                    windowNumber: window.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53) {
                    NSApp.postEvent(escape, atStart: true); result["escapePosted"] = true
                }
                try? await Task.sleep(for: .milliseconds(350))
                result["closed"] = !model.showingSteamBridgeSetup
                if startup {
                    await model.refreshBridgeEnvironment()
                    result["stayedClosedAfterCheck"] = !model.showingSteamBridgeSetup
                }
                if let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]) {
                    let prefix = startup ? "--bridge-startup-ui-probe=" : "--bridge-ui-probe="
                    try? await FileService.shared.write(data, to: URL(fileURLWithPath: String(flag.dropFirst(prefix.count))))
                }
                NSApp.perform(#selector(NSApplication.terminate(_:)), with: nil, afterDelay: 0)
            }
            if let flag = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--ui-responsiveness-probe=") }) {
                await model.measureUIResponsiveness(output: URL(fileURLWithPath: String(flag.dropFirst("--ui-responsiveness-probe=".count))))
            }
            if let flag=ProcessInfo.processInfo.arguments.first(where:{$0.hasPrefix("--show-game-settings=")}) {
                for _ in 0..<30 {
                    if let game=model.library.first(where:{$0.id==String(flag.dropFirst("--show-game-settings=".count))}) { model.featureGame=game; break }
                    try? await Task.sleep(for:.milliseconds(100))
                }
            }
            if ProcessInfo.processInfo.arguments.contains("--show-performance") {
                for _ in 0..<50 {
                    if let game = model.library.first(where: { $0.platforms.contains(.windows) }) { model.featureGame = game; break }
                    try? await Task.sleep(for: .milliseconds(100))
                }
            }
            if let flag = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--show-workshop=") }) {
                for _ in 0..<100 {
                    if !model.refreshing, let game = model.library.first(where: { $0.id == String(flag.dropFirst("--show-workshop=".count)) }) {
                        if model.showingCouch { do { try await Task.sleep(for: .seconds(3)) } catch { return } }
                        model.showWorkshop(game); break
                    }
                    do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
                }
                if let probe = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--workshop-ui-probe=") }) {
                    for _ in 0..<50 {
                        if NSApp.windows.contains(where: { $0.sheetParent != nil }) { break }
                        do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
                    }
                    do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
                    let window = NSApp.windows.first(where: { $0.sheetParent != nil }), focus = CouchFocus()
                    let controls = focus.controls(in: window)
                    var result: [String: Any] = ["bigScreen": model.showingCouch, "sheet": window != nil, "controls": controls.count,
                        "workshopOpen": model.workshopGame != nil, "controllerAvailable": !controls.isEmpty]
                    result["controllerClosesWorkshop"] = focus.pressForProbe(label: "Close", in: window)
                    do { try await Task.sleep(for: .milliseconds(350)) } catch { return }
                    result["closed"] = model.workshopGame == nil
                    if let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]) {
                        try? await FileService.shared.write(data, to: URL(fileURLWithPath: String(probe.dropFirst("--workshop-ui-probe=".count))))
                    }
                }
            }
            if let flag=ProcessInfo.processInfo.arguments.first(where:{$0.hasPrefix("--install-preview=") || $0.hasPrefix("--install-windows-preview=")}) {
                let windows = flag.hasPrefix("--install-windows-preview=")
                let prefix = windows ? "--install-windows-preview=" : "--install-preview="
                for _ in 0..<50 {
                    if let game=model.library.first(where:{$0.id==String(flag.dropFirst(prefix.count))}) {
                        model.install(game,platform: windows ? .windows : .macOS); break
                    }
                    try? await Task.sleep(for:.milliseconds(100))
                }
                if let probe = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--install-ui-probe=") }) {
                    for _ in 0..<100 {
                        if model.installationRequest != nil && !model.installBusy { break }
                        try? await Task.sleep(for: .milliseconds(200))
                    }
                    try? await Task.sleep(for: .milliseconds(500))
                    let result: [String: Any] = ["request": model.installationRequest != nil,
                        "windows": model.installationRequest?.platform == .windows, "prepared": model.installPlan != nil,
                        "canConfirm": model.installPlan?.canConfirm == true, "needsAgreement": model.installPlan?.needsAgreement == true,
                        "agreementIDs": model.installPlan?.eulas.map(\.id) ?? [], "message": model.installMessage]
                    let output = URL(fileURLWithPath: String(probe.dropFirst("--install-ui-probe=".count)))
                    if let window = NSApp.windows.first(where: { $0.sheetParent != nil }) {
                        let windowID = window.windowNumber
                        await Task.detached {
                            let capture = Process(); capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                            capture.arguments = ["-x", "-o", "-l", String(windowID), output.deletingPathExtension().appendingPathExtension("png").path]
                            if (try? capture.run()) != nil { capture.waitUntilExit() }
                        }.value
                    }
                    if let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]) {
                        try? await FileService.shared.write(data, to: output)
                    }
                    model.cancelInstallation()
                    NSApp.perform(#selector(NSApplication.terminate(_:)), with: nil, afterDelay: 0)
                }
            }
            if ProcessInfo.processInfo.arguments.contains("--ui-dismiss-probe") {
                try? await Task.sleep(for:.seconds(2))
                let before=NSApp.windows.filter{$0.sheetParent != nil}.count
                let sheet=NSApp.windows.first(where:{$0.sheetParent != nil})
                NSApp.activate(ignoringOtherApps:true); sheet?.makeKeyAndOrderFront(nil)
                if let event=NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:[],timestamp:ProcessInfo.processInfo.systemUptime,windowNumber:sheet?.windowNumber ?? NSApp.keyWindow?.windowNumber ?? 0,context:nil,characters:"\u{1b}",charactersIgnoringModifiers:"\u{1b}",isARepeat:false,keyCode:53) { NSApp.postEvent(event,atStart:false) }
                try? await Task.sleep(for:.seconds(1))
                let after=NSApp.windows.filter{$0.sheetParent != nil}.count
                print("WAYFARER_DISMISS_PROBE=before:\(before),after:\(after),install:\(model.installationRequest != nil),settings:\(model.featureGame != nil),collections:\(model.showingCollections),diagnostics:\(model.showingDiagnostics)"); fflush(stdout)
            }
            // Read-only visual preview; does not launch Steam.
            if let flag = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--show-game=") }) {
                let id = String(flag.dropFirst("--show-game=".count))
                for _ in 0..<30 {
                    if let game = model.library.first(where: { $0.id == id }) { page = .library; model.showGame(game); break }
                    do { try await Task.sleep(for: .milliseconds(100)) } catch { break }
                }
            }
            #endif
        }
        .task {
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--feature-preview"),ProcessInfo.processInfo.arguments.contains("--feature-probe") {
                var previous=""
                while !Task.isCancelled {
                    try? await Task.sleep(for:.milliseconds(250))
                    guard let data=try? await FileService.shared.read(URL(fileURLWithPath: "/private/tmp/wayfarer-seven-preview/action.json")),let action=try? JSONDecoder().decode(FeaturePreviewAction.self,from:data),action.id != previous else{continue}
                    previous=action.id
                    let previewWindow = NSApp.windows.first { $0.canBecomeMain && $0.sheetParent == nil }
                    switch action.command {
                    case "activate":NSApp.activate(ignoringOtherApps:true);previewWindow?.makeKeyAndOrderFront(nil)
                    case "quit-preview":NSApp.terminate(nil)
                    case "spotlight-next", "spotlight-prev", "discovery-shuffle", "discovery-open":
                        NotificationCenter.default.post(name: Notification.Name("WayfarerHomePreview"), object: action.command)
                    case "home":model.navigate("Home")
                    case "library":model.navigate("Library")
                    case "downloads":model.navigate("Downloads")
                    case "resize-small":previewWindow?.setContentSize(NSSize(width:1060,height:700))
                    case "resize-large":previewWindow?.setContentSize(NSSize(width:1320,height:850))
                    case "quick":model.openQuickLauncher()
                    case "storage":model.navigate("Storage")
                    case "activity":model.navigate("Activity")
                    case "couch":model.openCouch()
                    case "close":model.showingQuickLauncher=false;model.storageGame=nil;model.achievementGame=nil;model.showingCouch=false
                    case "achievements","storage-detail","game-detail":
                        if let game=model.library.first(where:{$0.id==action.gameID}) {
                            if action.command=="achievements"{model.achievementPlatform = .macOS;model.achievementGame=game}
                            else if action.command=="storage-detail"{model.storagePlatform = .macOS;model.storageGame=game}
                            else{model.navigate("Library");try? await Task.sleep(for:.milliseconds(150));model.showGame(game)}
                        }
                    case "keys":
                        NSApp.activate(ignoringOtherApps:true)
                        let window=NSApp.windows.first(where:{$0.sheetParent != nil}) ?? NSApp.mainWindow;window?.makeKeyAndOrderFront(nil)
                        for code in action.keys ?? [] {
                            if let event=NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:[],timestamp:ProcessInfo.processInfo.systemUptime,windowNumber:window?.windowNumber ?? 0,context:nil,characters:code==53 ? "\u{1b}":"",charactersIgnoringModifiers:code==53 ? "\u{1b}":"",isARepeat:false,keyCode:code){NSApp.postEvent(event,atStart:false)}
                        }
                    default:break
                    }
                    print("FEATURE_PROBE=\(action.command),quick=\(model.showingQuickLauncher),storage=\(model.storageGame != nil),achievements=\(model.achievementGame != nil),couch=\(model.showingCouch)");fflush(stdout)
                }
            }
            #endif
        }
        .alert("Wayfarer", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("OK") { model.error = nil }
            if let log = model.latestLog { Button("Open log") { NSWorkspace.shared.open(log); model.error = nil } }
        } message: { Text(model.error ?? "") }
        .controllerControls(model.showingCouch)
    }

    private var desktop: some View {
        HStack(spacing: 0) {
            sidebar
            VStack(spacing: 0) {
                header
                AppWorkspace(model: model, page: $page, addGame: { addingGame = true }, addProfile: { addingProfile = true })
            }.background(LibraryAtmosphere())
        }
    }

    private var sidebar: some View {
        GeometryReader { geometry in
            let compact = geometry.size.height < 900
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 11) {
                    WayfarerMark()
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Wayfarer").font(.system(size: 20, weight: .semibold))
                        Text("A PLACE FOR PLAY").font(.system(size: 8, weight: .semibold)).tracking(1.8).foregroundStyle(WayfarerTheme.accent.opacity(0.7))
                    }
                }
                .padding(.horizontal, 6).padding(.top, 44).padding(.bottom, compact ? 20 : 28)
                .fixedSize(horizontal: false, vertical: true)

                GeometryReader { viewport in
                    ScrollView(.vertical) {
                        VStack(alignment: .leading, spacing: compact ? 16 : 22) {
                            VStack(alignment: .leading, spacing: compact ? 3 : 8) {
                                Text("YOUR SPACE").font(.system(size: 9, weight: .semibold)).tracking(1.6).foregroundStyle(.tertiary).padding(.horizontal, 13).padding(.bottom, 3)
                                ForEach([AppPage.home, .library, .favorites, .downloads]) { navigation($0, compact: compact) }
                                Text("CONNECTED").font(.system(size: 9, weight: .semibold)).tracking(1.6).foregroundStyle(.tertiary).padding(.horizontal, 13).padding(.top, compact ? 12 : 24).padding(.bottom, 3)
                                ForEach([AppPage.chat, .runtimes]) { navigation($0, compact: compact) }
                            }
                            Spacer(minLength: compact ? 8 : 20)
                            SteamConnectionControls(model:model)
                        }
                        .frame(minHeight: viewport.size.height, alignment: .top)
                    }.scrollIndicators(.hidden)
                }
                if !sidebarSessions.isEmpty {
                    SidebarGameSessionView(model: model, records: sidebarSessions, showGame: { game in
                        model.showGame(game); page = .library
                    }, showActivity: {
                        model.selectedGameID = nil; page = .sessions
                    })
                    .padding(.top, 12).fixedSize(horizontal: false, vertical: true)
                    .allowsHitTesting(!isSidebarSessionPreview)
                }
                sidebarFooter.padding(.top, compact ? 12 : 18)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 17)
        }
        .frame(width: 236)
        .background(SidebarAtmosphere())
        .overlay(alignment: .trailing) { Rectangle().fill(.white.opacity(0.025)).frame(width: 1).allowsHitTesting(false) }
    }

    private var isSidebarSessionPreview: Bool {
        #if DEBUG
        return ProcessInfo.processInfo.arguments.contains("--feature-preview") && ProcessInfo.processInfo.arguments.contains { $0.hasPrefix("--sidebar-playing-preview=") }
        #else
        return false
        #endif
    }

    private var sidebarSessions: [GameSessionRecord] {
        #if DEBUG
        if isSidebarSessionPreview,
           let flag = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--sidebar-playing-preview=") }),
           let game = model.library.first(where: { $0.id == String(flag.dropFirst("--sidebar-playing-preview=".count)) }) {
            var record = GameSessionRecord(gameID: game.id, name: game.name, platform: .macOS, environmentID: nil)
            record.id = UUID(uuidString: "A742910E-C215-498F-92D0-703394102166")!
            record.phase = .playing; record.message = "Visual preview only; session controls are inactive."
            return [record]
        }
        #endif
        return model.gameSessions.filter { $0.phase.active }
    }

    private var sidebarFooter: some View {
        HStack {
                Button { page = .sessions } label: { Label("Activity", systemImage: "clock.arrow.circlepath") }.buttonStyle(ControllerButtonStyle(style: .plain))
                Spacer()
                Menu {
                    Button("Settings…") { model.navigate("Settings") }
                    Divider()
                    Toggle("Start Steam in the background", isOn:Binding(get:{model.startsSteamInBackground},set:{model.startsSteamInBackground=$0}))
                    Button("Storage manager"){model.navigate("Storage")}
                    Button("Controller fullscreen"){model.openCouch()}
                    Button("Quick launcher…"){model.openQuickLauncher()}
                    Button("Refresh library") { model.refresh() }
                    Button("Add game…") { addingGame = true }
                    Button("Collections & folders…") { model.showingCollections=true }
                    Button("Launch diagnostics…") { model.showingDiagnostics=true }
                    Button("Open session logs") { model.openLogs() }
                } label: { Label("Settings", systemImage: "gearshape") }
                .menuStyle(.borderlessButton).fixedSize().padding(.vertical, 7).padding(.horizontal, 5)
                .tint(.secondary).help("Library settings")
        }.font(.system(size: 11)).foregroundStyle(.secondary).padding(.horizontal, 10).padding(.bottom, 18)
    }

    private func navigation(_ destination: AppPage, compact: Bool) -> some View {
        Button {
            model.selectedGameID = nil; page = destination
        } label: {
            HStack(spacing: 11) {
                Image(systemName: destination.icon).font(.system(size: 14, weight: .medium)).frame(width: 22)
                    .foregroundStyle(page == destination ? WayfarerTheme.accent : Color.secondary)
                Text(destination.rawValue).font(.system(size: 13, weight: page == destination ? .semibold : .medium))
                Spacer()
                if destination == .library { navCount(model.visibleLibrary.count) }
                if destination == .favorites { navCount(model.libraryPresentation.favoriteCount) }
                if destination == .chat && model.unreadFriendsCount>0 { navCount(model.unreadFriendsCount) }
                if destination == .downloads && !model.transfers.isEmpty { navCount(model.transfers.count) }
            }.padding(.horizontal, 13).padding(.vertical, compact ? 7 : 12)
                .foregroundStyle(page == destination ? Color.white : Color.secondary)
                .background(LinearGradient(colors: [WayfarerTheme.accent.opacity(page == destination ? 0.10 : 0), WayfarerTheme.accent.opacity(page == destination ? 0.025 : 0)], startPoint: .leading, endPoint: .trailing), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius:11).strokeBorder(WayfarerTheme.accent.opacity(page == destination ? 0.08 : 0),lineWidth:1))
                .overlay(alignment: .leading) { if page == destination { Capsule().fill(WayfarerTheme.accent).frame(width: 3, height: 16).padding(.leading, 2) } }
        }.buttonStyle(ControllerButtonStyle(style: .plain))
    }

    private func navCount(_ number: Int) -> some View {
        Text("\(number)").font(.system(size: 10, weight: .medium, design: .rounded)).monospacedDigit()
            .foregroundStyle(.secondary).padding(.horizontal, 6).padding(.vertical, 3)
            .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 5))
    }

    private var header: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Eyebrow(title: page == .home && model.selectedGame == nil ? "Your daily escape" : "Wayfarer / \(page.rawValue)", color: .secondary)
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
            if model.refreshing { ProgressView().controlSize(.small) }
            Button { model.openCouch() } label: { Image(systemName: "gamecontroller").frame(width: 16, height: 16) }
                .buttonStyle(QuietButtonStyle()).help("Controller fullscreen (⌘⇧F)").accessibilityLabel("Controller fullscreen")
            if (page == .home || page == .library || page == .favorites) && model.selectedGame == nil {
                Button { addingGame = true } label: { Image(systemName: "plus").frame(width: 16, height: 16) }.buttonStyle(QuietButtonStyle()).help("Add game").accessibilityLabel("Add game")
            } else {
                Button { model.refresh() } label: { Image(systemName: "arrow.clockwise").frame(width: 16, height: 16) }.buttonStyle(QuietButtonStyle()).help("Refresh (⌘R)").accessibilityLabel("Refresh")
            }
        }.padding(.horizontal, 28).padding(.top, 40).padding(.bottom, 24)
    }

}

#if DEBUG
private struct FeaturePreviewAction:Decodable {let id:String;let command:String;var gameID:String?;var keys:[UInt16]?}
#endif
