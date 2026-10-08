import AppKit
import SwiftUI
import WayfarerCore

struct WorkshopView: View {
    @ObservedObject var model: LauncherModel
    let game: LibraryGame
    @State private var search = ""
    @State private var link = ""
    @State private var reviewed: WorkshopItemDetails?
    @State private var lookupMessage: String?
    @State private var lookingUp = false
    @State private var lookupTask: Task<Void, Never>?
    @State private var removing: WorkshopItem?
    private var platform: GamePlatform { model.preferredGamePlatform(game) ?? .macOS }
    private var key: String { game.id + ":" + platform.rawValue }
    private var snapshot: WorkshopSnapshot? { model.workshopSnapshot(game, platform: platform) }
    private var changing: Bool { model.workshopChanging.contains(key) }
    private var canChange: Bool { snapshot?.source == .steam && model.connectionMode(platform) == .online && model.activeSession(game.id) == nil && !changing }
    private var items: [WorkshopItem] {
        (snapshot?.items ?? []).filter { search.isEmpty || QuickSearch.matches(search, name: $0.title, tags: [$0.id, $0.summary]) }
    }
    private var subscriptions: [WorkshopItem] { snapshot?.items.filter { $0.subscribed == true } ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            HStack(spacing: 12) {
                Button { model.browseWorkshop(game, platform: platform) } label: {
                    Label("Browse Steam Workshop", systemImage: "puzzlepiece.extension")
                }.buttonStyle(QuietButtonStyle()).disabled(snapshot?.supported == false)
                Spacer()
                if model.connectionMode(platform) != .online {
                    Button(model.connectionMode(platform) == .signedOut ? "Sign in to Steam" : "Connect Steam") { model.connectSteam(platform) }
                        .buttonStyle(QuietButtonStyle()).disabled(model.connectionBusy.contains(platform))
                }
                if model.workshopBusy.contains(key) { ProgressView().controlSize(.small) }
                Button("Refresh") { Task { await model.refreshWorkshop(game, platform: platform) } }
                    .buttonStyle(QuietButtonStyle()).disabled(model.workshopBusy.contains(key) || changing)
            }
            status
            if snapshot?.supported != false || !(snapshot?.items.isEmpty ?? true) {
                addItem
                HStack {
                    Text("\(snapshot?.source == .local ? "Subscriptions unknown" : "\(subscriptions.count) subscribed") · \(snapshot?.items.filter { $0.download == .downloaded }.count ?? 0) downloaded")
                        .font(.subheadline.weight(.medium))
                    Spacer()
                    TextField("Filter mods", text: $search).textFieldStyle(.roundedBorder).frame(width: 230)
                }
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        if items.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(search.isEmpty ? "Your mods will appear here" : "No matching mods").font(.headline)
                                Text(search.isEmpty ? "Browse Workshop to find mods, or paste an item link above. Steam handles downloads and updates." : "Try another name or item ID.")
                                    .font(.subheadline).foregroundStyle(.secondary)
                            }.padding(22).frame(maxWidth: .infinity, alignment: .leading).glassPanel(radius: 16)
                        }
                        ForEach(items) { item in row(item) }
                    }.padding(.bottom, 8)
                }
                Text("Subscriptions belong to your Steam account. Downloads, local enable state and load order apply to this installation; some games use their own mod manager.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.padding(24).frame(width: 860, height: 690)
        .background(DialogEscapeHandler { model.workshopGame = nil }.frame(width: 0, height: 0))
        .task(id: platform) {
            await model.refreshWorkshop(game, platform: platform)
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
                if NSApp.isActive { await model.refreshWorkshop(game, platform: platform) }
            }
        }
        .onChange(of: link) { _ in reviewed = nil; lookupMessage = nil; lookupTask?.cancel(); lookingUp = false }
        .onChange(of: platform) { _ in reviewed = nil; lookupMessage = nil; removing = nil; lookupTask?.cancel(); lookingUp = false }
        .onDisappear { lookupTask?.cancel() }
        .alert("Unsubscribe from this mod?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            Button("Cancel", role: .cancel) { removing = nil }
            Button("Unsubscribe", role: .destructive) {
                if let item = removing { change(.subscribe(item.id, false)) }; removing = nil
            }
        } message: { Text("Steam will remove \(removing?.title ?? "this item") from your subscriptions and manage its downloaded files.") }
    }
    private var header: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Workshop & mods").font(.title2.weight(.semibold))
                Text(game.name).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Text(model.executionName(game)).font(.subheadline).foregroundStyle(.secondary)
            Button("Close") { model.workshopGame = nil }.buttonStyle(QuietButtonStyle()).couchControl("Close").keyboardShortcut(.cancelAction)
        }
    }
    @ViewBuilder private var status: some View {
        if snapshot?.supported == false {
            Label("Steam reports no public Workshop for this game.", systemImage: "info.circle").foregroundStyle(.secondary)
        }
        if let snapshot, snapshot.source != .steam {
            Label(snapshot.source == .saved ? "Saved subscriptions from \(snapshot.updatedAt.formatted(date: .abbreviated, time: .shortened)). Connect Steam to refresh and make changes." : "Downloaded files on this Mac. Connect Steam to read your subscriptions.", systemImage: "clock")
                .font(.caption).foregroundStyle(.secondary)
        }
        if let message = model.workshopMessages[key] { Text(message).font(.caption).foregroundStyle(.secondary) }
        if model.activeSession(game.id) != nil { Label("Close the game to change its mods.", systemImage: "gamecontroller").font(.caption).foregroundStyle(.secondary) }
        if changing { ProgressView("Waiting for Steam to confirm…").font(.caption) }
        if let snapshot, !snapshot.missingDependencies.isEmpty {
            Label("Some mods have required items you have not subscribed to. Review their requirements in Steam.", systemImage: "exclamationmark.triangle")
                .font(.caption).foregroundStyle(.orange)
        }
    }
    private var addItem: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                TextField("Paste a Workshop item link or ID", text: $link).textFieldStyle(.roundedBorder)
                    .onSubmit { review() }
                Button(lookingUp ? "Loading…" : "Review item") { review() }.buttonStyle(QuietButtonStyle()).disabled(link.isEmpty || lookingUp || changing)
            }
            if let item = reviewed {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.title).font(.subheadline.weight(.semibold))
                        Text("Workshop item \(item.id)").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("View in browser") { model.browseWorkshop(game, platform: platform, itemID: item.id) }.buttonStyle(QuietButtonStyle())
                    Button(subscriptions.contains { $0.id == item.id } ? "Subscribed" : "Subscribe") { change(.subscribe(item.id, true)) }
                        .buttonStyle(QuietButtonStyle()).disabled(!canChange || snapshot?.capabilities.subscribe != true || subscriptions.contains { $0.id == item.id })
                }
            }
            if let lookupMessage { Text(lookupMessage).font(.caption).foregroundStyle(.secondary) }
        }.padding(16).glassPanel(radius: 16)
    }
    private func row(_ item: WorkshopItem) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: item.enabled == false ? "puzzlepiece.extension" : "puzzlepiece.extension.fill")
                    .font(.system(size: 24)).foregroundStyle(item.enabled == false ? Color.secondary : WayfarerTheme.accent)
                    .frame(width: 32, height: 32)
                VStack(alignment: .leading, spacing: 5) {
                    Text(item.title).font(.headline)
                    if !item.summary.isEmpty { Text(item.summary).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                    Text([item.download.title, item.size.map(formatBytes), item.subscribed == false ? "Not subscribed" : item.subscribed == nil ? "Subscription unknown" : nil].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if let order = item.loadOrder { Text("\(order + 1)").font(.system(.subheadline, design: .monospaced)).foregroundStyle(.secondary) }
            }
            HStack(spacing: 10) {
                if item.subscribed == true {
                    Button(item.enabled == false ? "Enable locally" : "Disable locally") { change(.enabled(item.id, item.enabled == false)) }
                        .buttonStyle(QuietButtonStyle()).disabled(!canChange || snapshot?.capabilities.disable != true || item.enabled == nil)
                    Button { move(item, offset: -1) } label: { Image(systemName: "arrow.up") }
                        .buttonStyle(QuietButtonStyle()).accessibilityLabel("Move \(item.title) earlier")
                        .disabled(!canChange || snapshot?.capabilities.reorder != true || subscriptions.first?.id == item.id)
                    Button { move(item, offset: 1) } label: { Image(systemName: "arrow.down") }
                        .buttonStyle(QuietButtonStyle()).accessibilityLabel("Move \(item.title) later")
                        .disabled(!canChange || snapshot?.capabilities.reorder != true || subscriptions.last?.id == item.id)
                }
                Button("View in browser") { model.browseWorkshop(game, platform: platform, itemID: item.id) }.buttonStyle(QuietButtonStyle())
                if let location = item.location {
                    Button("Show files") { NSWorkspace.shared.activateFileViewerSelecting([location]) }.buttonStyle(QuietButtonStyle())
                }
                Spacer()
                if item.subscribed == true {
                    Button("Unsubscribe…", role: .destructive) { removing = item }.buttonStyle(QuietButtonStyle())
                        .disabled(!canChange || snapshot?.capabilities.subscribe != true)
                }
            }
        }.padding(16).glassPanel(radius: 16)
    }
    private func review() {
        guard !lookingUp else { return }
        lookingUp = true; reviewed = nil; lookupMessage = nil
        let input = link, client = platform
        lookupTask = Task {
            defer { if input == link, client == platform { lookingUp = false } }
            do {
                let item = try await model.lookupWorkshop(game, platform: client, input: input)
                guard !Task.isCancelled, input == link, client == platform else { return }
                reviewed = item
            } catch is CancellationError { }
            catch { if !Task.isCancelled, input == link, client == platform { lookupMessage = error.localizedDescription } }
        }
    }
    private func change(_ action: WorkshopAction) {
        let client = platform
        Task { _ = await model.changeWorkshop(game, platform: client, action: action) }
    }
    private func move(_ item: WorkshopItem, offset: Int) {
        let previous = subscriptions.map(\.id)
        guard let index = previous.firstIndex(of: item.id), previous.indices.contains(index + offset) else { return }
        var next = previous; next.swapAt(index, index + offset)
        change(.reorder(previous, next))
    }
}
