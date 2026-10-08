import AppKit
import Foundation
import PlaydockCore
import PlaydockPresentation

extension LauncherModel {
    func requestUninstall(_ game:LibraryGame,platform:GamePlatform) {
        guard activeSession(game.id)==nil,!(installationState.maintenance[game.id+":"+platform.rawValue].map{!$0.completed && !$0.failed} ?? false) else{error="Close the game and finish its current file operation before uninstalling.";return}
        guard installationState.installationRequest == nil, installationState.uninstallationRequest == nil, !installationState.uninstallBusy,
              let installation=game.installation(for:platform), let steam=installation.steamGame else { return }
        installationState.uninstallationRequest=GameUninstallationRequest(game:game,platform:platform,appID:steam.appID,profileID:platform == .windows ? RuntimeProfile.steamBridgeID : nil,location:installation.location)
        installationState.uninstallMessage=""
    }

    func confirmUninstall() {
        guard !shuttingDown, let request = installationState.uninstallationRequest, !installationState.uninstallBusy else { return }
        installationState.uninstallBusy = true; installationState.uninstallMessage = "Connecting to Steam…"
        installationState.installationRevision += 1; let revision = installationState.installationRevision, epoch = workflowRevision
        Task { [weak self] in
            guard let self else { return }
            await installationState.installationCoordinator.uninstall(revision: revision, requestID: request.id, appID: request.appID,
                resolve: { [weak self] in
                    guard let self else { throw CancellationError() }
                    return try await self.uninstallationControl(request)
                }, publish: { [weak self] event in
                    await self?.applyUninstallationEvent(event, request: request, revision: epoch)
                })
        }
    }
    func uninstallationControl(_ request: GameUninstallationRequest) async throws -> any SteamWorkflowControl {
        try await steamState.coordinator.installationControl(state: { [weak self] in
            guard let self else { throw CancellationError() }
            return try await self.uninstallationConnectionState(request)
        }, connect: { [weak self] in await self?.connectSteam() })
    }
    func uninstallationConnectionState(_ request: GameUninstallationRequest) throws -> SteamConnectionAvailability {
        guard !shuttingDown, installationState.uninstallationRequest?.id == request.id,
              request.platform == .macOS || request.profileID == RuntimeProfile.steamBridgeID else { throw CancellationError() }
        return SteamConnectionAvailability(control: try? controlClient(), busy: steamState.busy, message: steamState.message)
    }
    func applyUninstallationEvent(_ event: UninstallationEvent, request: GameUninstallationRequest, revision: Int) async {
        guard !shuttingDown, workflowRevision == revision, installationState.uninstallationRequest?.id == request.id else { return }
        switch event {
        case .starting: installationState.uninstallMessage = "Uninstalling \(request.game.name)…"
        case .failed(let message): installationState.uninstallMessage = message; installationState.uninstallBusy = false
        case .finished(let current):
            installationState.uninstallationRequest = nil; installationState.uninstallMessage = ""; installationState.uninstallBusy = false
            if request.platform == .macOS { libraryState.macGames.removeAll { $0.appID == request.appID } }
            else { libraryState.games.removeAll { $0.appID == request.appID } }
            let root = steamRoot
            if current.owned, let account = await libraryService(request.platform).currentAccount(root: root), !shuttingDown, workflowRevision == revision,
               !libraryState.catalog.contains(where: { $0.appID == request.appID && $0.client == request.platform }) {
                libraryState.catalogAccounts[request.platform] = account; libraryState.catalogRoots[request.platform] = root
                libraryState.catalog.append(SteamCatalogGame(appID: request.appID, name: request.game.name, client: request.platform,
                    profileID: request.profileID, artwork: request.game.artwork, heroArtwork: request.game.heroArtwork))
                try? await libraryService(request.platform).saveCatalog(games: libraryState.catalog.filter { $0.client == request.platform }, account: account, root: root, profileID: request.profileID)
            }
            guard !shuttingDown, workflowRevision == revision else { return }
            activityState.status = "Uninstalled \(request.game.name) · \(request.platform.name)"
            refreshLibrarySnapshot(); refreshSteamControls()
        }
    }

    func installationControl(_ request: GameInstallationRequest) async throws -> any SteamWorkflowControl {
        try await steamState.coordinator.installationControl(state: { [weak self] in
            guard let self else { throw CancellationError() }
            return try await self.installationConnectionState(request)
        }, connect: { [weak self] in await self?.connectSteam() })
    }
    func prepareBridgeInstallation(_ request: GameInstallationRequest) async throws {
        guard installationState.installationRequest?.id == request.id, !runtimeState.bridgeBusy else { throw CancellationError() }
        if request.platform == .windows { try await ensureBridgeReady() }
        if runtimeState.bridgeEnvironment?.ready == true { try await controlClient().setCrossOver(appID: request.appID, enabled: request.platform == .windows) }
    }
    func installationConnectionState(_ request: GameInstallationRequest) throws -> SteamConnectionAvailability {
        guard !shuttingDown, installationState.installationRequest?.id == request.id else { throw CancellationError() }
        return SteamConnectionAvailability(control: try? controlClient(), busy: steamState.busy, message: steamState.message)
    }
    func installationPublisher(_ request: GameInstallationRequest, operation: UUID) -> InstallCoordinator.Publish {
        { [weak self] event in await self?.applyInstallationEvent(event, request: request, operation: operation) }
    }
    func applyInstallationEvent(_ event: InstallationEvent, request: GameInstallationRequest, operation: UUID) {
        guard !shuttingDown, installationState.installationRequest?.id == request.id, installationState.installDialog.operationID == operation else { return }
        switch event {
        case .snapshot(let snapshot): publishSteamSnapshot(snapshot)
        case .prepared(let plan, let message): installationState.installDialog.finish(operation, plan: plan, message: message)
        case .started:
            installationState.installationRequest = nil; installationState.installDialog.dismiss(); activityState.status = "Installing \(request.game.name)"
            refreshLibrarySnapshot(); refreshSteamControls(); showDownloads()
        }
    }
    func prepareInstallation() {
        guard !shuttingDown, let request = installationState.installationRequest, !installationState.installBusy else { return }
        let operation = installationState.installDialog.begin("Connecting to Steam…")
        installationState.installationRevision += 1; let revision = installationState.installationRevision
        Task { [weak self] in
            guard let self else { return }
            await installationState.installationCoordinator.prepare(revision: revision, requestID: request.id, appID: request.appID,
                resolve: { [weak self] in
                    guard let self else { throw CancellationError() }
                    let control = try await self.installationControl(request)
                    try await self.prepareBridgeInstallation(request)
                    return control
                }, publish: installationPublisher(request, operation: operation))
        }
    }
    func chooseInstallFolder(_ index: Int) {
        guard !shuttingDown, let request = installationState.installationRequest, !installationState.installBusy else { return }
        let operation = installationState.installDialog.begin("Updating library…", keepPlan: true)
        installationState.installationRevision += 1; let revision = installationState.installationRevision
        Task { await installationState.installationCoordinator.chooseFolder(revision: revision, requestID: request.id, appID: request.appID,
            folder: index, publish: installationPublisher(request, operation: operation)) }
    }
    func confirmInstallation(acceptedAgreements: Bool) {
        guard !shuttingDown, let request = installationState.installationRequest, let plan = installationState.installPlan, plan.canConfirm,
              !installationState.installBusy, !plan.needsAgreement || acceptedAgreements else { return }
        let operation = installationState.installDialog.begin("Starting download…", keepPlan: true)
        installationState.installationRevision += 1; let revision = installationState.installationRevision
        Task { await installationState.installationCoordinator.confirm(revision: revision, requestID: request.id, appID: request.appID,
            acceptedAgreements: acceptedAgreements, publish: installationPublisher(request, operation: operation)) }
    }
    func cancelInstallation() {
        let request = installationState.installationRequest, control = request.flatMap { _ in try? controlClient() }
        installationState.installationRevision += 1; let revision = installationState.installationRevision
        installationState.installationRequest = nil; installationState.installDialog.dismiss()
        Task { await installationState.installationCoordinator.cancel(revision: revision, appID: request?.appID, control: control) }
    }
    func closeUninstallDialog() {
        guard installationState.uninstallationRequest != nil else { return }
        installationState.uninstallationRequest = nil; installationState.uninstallBusy = false
        installationState.installationRevision += 1; let revision = installationState.installationRevision
        Task { await installationState.installationCoordinator.cancel(revision: revision, appID: nil, control: nil) }
    }

    func refreshStorage() {
        guard !installationState.storageBusy else{return};installationState.storageBusy = true
        Task { defer{installationState.storageBusy = false};do {
            let folders=try await controlClient().storageFolders()
            installationState.storageFolders=folders;installationState.storageMessage=nil
        }catch{installationState.storageMessage=error.localizedDescription} }
    }
    func maintainGame(_ game:LibraryGame,platform:GamePlatform,folder:Int?=nil) {
        guard let steam=game.installation(for:platform)?.steamGame else{return}
        let key=game.id+":"+platform.rawValue
        guard installationState.installationRequest==nil,installationState.uninstallationRequest==nil else{installationState.storageMessage="Finish or close the installation confirmation first.";return}
        guard activeSession(game.id)==nil,!downloadsState.transfers.contains(where:{$0.appID==steam.appID}),installationState.maintenance[key]==nil || installationState.maintenance[key]?.completed == true || installationState.maintenance[key]?.failed == true else{installationState.storageMessage="Close the game and finish its download or current file operation first.";return}
        installationState.maintenance[key]=SteamMaintenanceProgress(kind:folder==nil ? "verify":"move",progress:nil,task:"Starting…",completed:false,failed:false)
        let revision = workflowRevision
        Task { [self] in
            do {
                let control = try controlClient()
                await installationState.maintenanceCoordinator.start(key: key, appID: steam.appID, folder: folder, revision: revision, control: control,
                    publish: { [weak self] progress in await self?.applyMaintenance(progress, key: key, platform: platform, revision: revision) })
            } catch { applyMaintenance(SteamMaintenanceProgress(kind: folder == nil ? "verify" : "move", progress: nil,
                task: error.localizedDescription, completed: false, failed: true), key: key, platform: platform, revision: revision) }
        }
    }
    func applyMaintenance(_ progress: SteamMaintenanceProgress, key: String, platform: GamePlatform, revision: Int) {
        guard !shuttingDown, workflowRevision == revision else { return }
        installationState.maintenance[key] = progress
        if progress.failed { installationState.storageMessage = progress.task }
        if progress.completed || progress.failed { refreshLibrarySnapshot(); refreshStorage() }
    }
}
