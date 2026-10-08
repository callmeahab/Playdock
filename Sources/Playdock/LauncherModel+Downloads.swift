import AppKit
import Foundation
import PlaydockCore
import PlaydockPresentation

extension LauncherModel {
    func downloadPolicyKey() -> String {
        return "\(steamRoot.path):\(steamState.account ?? "signedOut")"
    }
    func downloadPolicy() -> DownloadPolicy { settingsState.configuration.downloadPolicies[downloadPolicyKey()] ?? DownloadPolicy() }
    func readDownloadPolicy() async -> DownloadPolicy {
        await refreshSteamAccount()
        if let saved=settingsState.configuration.downloadPolicies[downloadPolicyKey()] { return saved }
        var policy=DownloadPolicy()
        if let settings=try? await controlClient().downloadSettings() {
            policy.enabled=settings.scheduled; policy.bandwidthKBps=max(0,settings.bandwidthKBps)
            if settings.startHour != settings.endHour { policy.startHour=settings.startHour; policy.endHour=settings.endHour }
        }
        return policy
    }
    func applyDownloadPolicy(_ policy: DownloadPolicy) { submitDownload(.apply(policy)) }
    func submitDownload(_ action: DownloadAction, scheduled: Bool = false) {
        guard !runtimeState.bridgeBusy, !shuttingDown, !steamState.busy else { return }
        if !scheduled { steamState.busy = true }
        let revision = workflowRevision
        Task { [weak self] in
            guard let self else { return }
            await refreshSteamAccount()
            guard !shuttingDown, workflowRevision == revision else { return }
            let key = downloadPolicyKey()
            let changesPolicy: Bool
            switch action { case .apply, .prioritize: changesPolicy = true; default: changesPolicy = settingsState.configuration.downloadPolicies[key] != nil }
            do {
                let control = try controlClient()
                await downloadsState.scheduler.submit(action, scope: key, revision: revision, policy: downloadPolicy(),
                    ownedPause: settingsState.configuration.scheduledPauses.contains(key) == true, control: control,
                    publish: { [weak self] event in
                        await self?.applyDownloadEvent(event, key: key, revision: revision, scheduled: scheduled, persistPolicy: changesPolicy)
                    })
            } catch {
                if !scheduled { steamState.busy = false }
                downloadsState.policyMessage = error.localizedDescription
            }
        }
    }
    func applyDownloadEvent(_ event: DownloadEvent, key: String, revision: Int, scheduled: Bool, persistPolicy: Bool) {
        guard !shuttingDown, workflowRevision == revision else { return }
        if case .finished = event { if !scheduled { steamState.busy = false }; return }
        guard downloadPolicyKey() == key else { return }
        switch event {
        case .state(let policy, let owned):
            persistDownloadState(policy, owned: owned, key: key, persistPolicy: persistPolicy)
        case .updated(let policy, let owned, let snapshot):
            persistDownloadState(policy, owned: owned, key: key, persistPolicy: persistPolicy)
            publishSteamSnapshot(snapshot)
            if !scheduled { downloadsState.policyMessage = "Saved in Steam" }
        case .failed(let message): downloadsState.policyMessage = scheduled ? "Schedule waiting for Steam" : "Steam could not confirm all changes · \(message)"
        case .finished: break
        }
    }
    func persistDownloadState(_ policy: DownloadPolicy, owned: Bool, key: String, persistPolicy: Bool) {
        var changed = false
        if persistPolicy, settingsState.configuration.downloadPolicies[key] != policy {
            settingsState.configuration.downloadPolicies[key] = policy; changed = true
        }
        if (settingsState.configuration.scheduledPauses.contains(key) == true) != owned {
            if owned { settingsState.configuration.scheduledPauses.insert(key) } else { settingsState.configuration.scheduledPauses.remove(key) }
            changed = true
        }
        if changed { save() }
    }
    func enforceDownloadSchedules() async {
        guard connectionMode() == .online, settingsState.configuration.downloadPolicies[downloadPolicyKey()] != nil else { return }
        submitDownload(.enforce, scheduled: true)
    }
    func prioritizeDownload(_ appID: String, toTop: Bool) {
        guard connectionMode() == .online else { return }
        submitDownload(.prioritize(appID, toTop: toTop))
    }
}
