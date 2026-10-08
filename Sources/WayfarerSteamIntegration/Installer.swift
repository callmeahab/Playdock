import Foundation

enum InstallerResources {
    static let root: URL? = ProcessInfo.processInfo.environment["WAYFARER_STEAM_INTEGRATION_RESOURCES"].map { URL(fileURLWithPath: $0) }
    static func url(forResource name: String, withExtension ext: String?) -> URL? {
        guard let root else { return nil }
        let url = root.appendingPathComponent(name + (ext.map { "." + $0 } ?? ""))
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
}

enum AppVersion { static let bundled = SteamIntegrationRelease.version }
enum AppLog {
    static func note(_ message: String) {
        // Installer diagnostics stay in Wayfarer's per-run log.
        try? FileHandle.standardError.write(contentsOf: Data((message + "\n").utf8))
    }
}

enum SteamIntegrationVerification {
    static func problems(
        app: URL = SupportPaths.Steam.app,
        bridge: URL = SupportPaths.bridge,
        runners: URL = SupportPaths.runners,
        verifyRunner: @Sendable (RunnerBuild, URL) -> [String] = { RunnerPatcher.verify(build: $0, root: $1) },
        license: (URL) -> CrossOverLicense.Status = { CrossOverLicense.check(crossOverRoot: $0) }
    ) -> [String] {
        let files = FileManager.default
        let dylib = app.appending(path: "Contents/MacOS/\(SupportPaths.dylibName)")
        var problems: [String] = []
        if SteamBundle.currentInsert(at: app.appending(path: "Contents/Info.plist")) != dylib.path {
            problems.append("Steam's startup configuration does not load the bridge.")
        }
        if !files.fileExists(atPath: dylib.path) { problems.append("Steam's bridge library is missing.") }
        switch RunnerStore.state(runners: runners, verify: verifyRunner) {
        case .cloned(_, true):
            let status = license(runners.appending(path: "current").resolvingSymlinksInPath())
            if !status.licensed { problems.append(status.detail) }
        case .unpatched(_, let details): problems.append(contentsOf: details)
        case .broken(let detail): problems.append(detail)
        default: problems.append("The patched CrossOver runner is unavailable.")
        }
        let required = ["steamclient.dll", "steamclient64.dll", "tier0_s64.dll", "vstdlib_s64.dll"]
            + BridgePayload.entries.flatMap(\.bridgePaths)
        for name in required where !files.fileExists(atPath: bridge.appending(path: name).path) {
            problems.append("Missing bridge component: \(name).")
        }
        return problems
    }
}

actor SteamIntegrationInstaller {
    private let files = FileManager.default
    private let support = SupportPaths.applicationSupport.appending(path: "Wayfarer/SteamIntegration")
    private var backup: URL { support.appending(path: "Steam.original.app") }
    private var pending: URL { support.appending(path: "transaction.json") }

    func inspect(crossOver: String? = nil) -> SteamIntegrationEnvironment {
        var result = SteamIntegrationEnvironment()
        result.steamPresent = SteamBundle.isPresent
        result.steamBuild = steamBuild()
        result.steamSupported = result.steamBuild.map { SteamIntegrationRelease.steamBuilds.contains($0) } ?? false
        result.installed = SteamBundle.currentInsert()?.split(separator: ":").contains(Substring(SupportPaths.Steam.deployedDylib.path)) == true
        var candidates = CrossOverSource.discover()
        if let crossOver, !candidates.contains(where: { $0.bundle.path == crossOver }) { candidates.append(CrossOverSource.inspect(bundle: URL(fileURLWithPath: crossOver))) }
        result.recoveryNeeded = files.fileExists(atPath: pending.path)
        result.recoveryAvailable = files.fileExists(atPath: backup.path)
        result.crossOver = candidates.map { Self.describe($0, license: CrossOverLicense.check(crossOverRoot: $0.crossOverRoot)) }
        if !result.steamPresent { result.problems.append("Install Mac Steam first.") }
        if !result.steamSupported { result.problems.append("This Steam build is not supported by bridge version \(SteamIntegrationRelease.version).") }
        if let selected = result.selectedCrossOver(path: crossOver) {
            if !selected.supported { result.problems.append(selected.supportDetail) }
            if !selected.licensed { result.problems.append(selected.licenseDetail) }
        } else { result.problems.append("Install CrossOver Preview 20260821 or 20261006, then activate it in CrossOver.") }
        if result.recoveryNeeded { result.problems.append("An interrupted setup needs recovery. Use Repair integration.") }
        if let insert = SteamBundle.currentInsert(), !insert.isEmpty, insert != SupportPaths.Steam.deployedDylib.path {
            result.problems.append("Steam has another integration installed. Restore Steam before setting up this bridge.")
        }
        if result.installed, result.steamSupported {
            let problems = SteamIntegrationVerification.problems()
            result.problems.append(contentsOf: problems)
            result.ready = problems.isEmpty && !result.recoveryNeeded
        }
        return result
    }

    static func describe(_ install: CrossOverInstall, license: CrossOverLicense.Status) -> SteamIntegrationCrossOver {
        let detail: String
        switch install.support {
        case .supported: detail = "Verified patch table available."
        case .unsupportedBuild(let version): detail = "CrossOver \(version) was detected, but this bridge has no compatible patches for it. Use CrossOver Preview 20260821 or 20261006."
        case .unreadable: detail = "CrossOver's version or Wine loader could not be read. Choose a complete CrossOver app."
        }
        return SteamIntegrationCrossOver(path: install.bundle.path, name: install.name, version: install.releaseVersion ?? "Unknown",
            supported: install.isUsable, licensed: license.licensed, supportDetail: detail, licenseDetail: license.detail)
    }

    private func steamBuild() -> String? {
        let directory = SupportPaths.Steam.innerClient.appending(path: "package")
        for name in ["steam_client_signed-2_osx.manifest", "steam_client_signed_osx.manifest", "steam_client_osx.manifest"] {
            let path = directory.appending(path: name)
            guard let data = try? Data(contentsOf: path), data.count < 2_000_000,
                  let text = String(data: data, encoding: .utf8),
                  let regex = try? NSRegularExpression(pattern: #"\"version\"\s+\"([0-9]+)\""#),
                  let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  let range = Range(match.range(at: 1), in: text) else { continue }
            return String(text[range])
        }
        return nil
    }

    func run(_ request: SteamIntegrationHelperRequest) async throws -> SteamIntegrationHelperResult {
        if request.operation == "inspect" { return SteamIntegrationHelperResult(environment: inspect(crossOver: request.crossOver)) }
        if request.operation == "validate-package" {
            _ = try InstallPayload.locate(); _ = try BridgePayload.locate()
            _ = try ValvePackageManifest.bundled()
            for build in SupportedRunners.all { for patch in NtdllPatcher.patches(for: build) { _ = try NtdllPatcher.payload(for: patch) } }
            return SteamIntegrationHelperResult(message: "Verified Wayfarer integration components and detours.")
        }
        guard ["install", "repair", "remove"].contains(request.operation) else { throw failure("Unknown setup operation.") }
        try SteamBundle.requireStopped(step: "Steam–CrossOver setup")
        let wine = try Shell.run("/usr/bin/pgrep", ["-f", #"(^|/)(wineserver(64|-arm64|-x86)?|wine(64)?(-preloader)?)(\s|$)"#])
        guard wine.status == 1 else { throw failure("Close Windows games and Wine apps before changing the integration.") }
        try files.createDirectory(at: support, withIntermediateDirectories: true)
        let lock = open(support.appending(path: "setup.lock").path, O_CREAT | O_RDWR, 0o600)
        guard lock >= 0 else { throw failure("The setup lock could not be opened.") }
        defer { _ = flock(lock, LOCK_UN); close(lock) }
        guard flock(lock, LOCK_EX | LOCK_NB) == 0 else { throw failure("Another Wayfarer instance is changing the bridge. Wait for it to finish.") }
        if request.operation == "remove" { return try await remove(request) }
        if files.fileExists(atPath: pending.path) {
            guard request.operation == "repair" else { throw failure("Use Repair integration to recover the interrupted setup.") }
            try recover()
        }
        let state = inspect()
        guard state.steamPresent, state.steamSupported else { throw failure(state.problems.first ?? "Steam is unavailable.") }
        let chosen = request.crossOver.map { CrossOverSource.inspect(bundle: URL(fileURLWithPath: $0)) }
            ?? CrossOverSource.discover().first { $0.isUsable && CrossOverLicense.check(crossOverRoot: $0.crossOverRoot).licensed }
        guard let chosen, chosen.isUsable else { throw failure("Choose a supported CrossOver Preview installation.") }
        try CrossOverLicense.requireValid(for: chosen)
        try SteamInstaller.assertInsertIsDeployedOrAbsent(at: SupportPaths.Steam.infoPlist, dylib: SupportPaths.Steam.deployedDylib)
        let payload = try InstallPayload.locate(), bridge = try BridgePayload.locate()
        let manifest = try ValvePackageManifest.bundled()
        progress("Downloading Steam components", request)
        _ = try await ValveFetcher.run(manifest: manifest) { phase in Self.report(phase.label, request) }
        progress("Preparing recovery copy", request)
        if !files.fileExists(atPath: backup.path), !state.installed {
            try SteamRepair.verifyValveSignature(SupportPaths.Steam.app)
            let stagedBackup = support.appending(path: "Steam.original.pending.app")
            if files.fileExists(atPath: stagedBackup.path) { try files.removeItem(at: stagedBackup) }
            try files.copyItem(at: SupportPaths.Steam.app, to: stagedBackup)
            try SteamRepair.verifyValveSignature(stagedBackup)
            try files.moveItem(at: stagedBackup, to: backup)
        }
        let rollback = support.appending(path: "Steam.transaction.app")
        if files.fileExists(atPath: rollback.path) { try files.removeItem(at: rollback) }
        try files.copyItem(at: SupportPaths.Steam.app, to: rollback)
        try Data(rollback.path.utf8).write(to: pending, options: .atomic)
        do {
            // Prepare the runner before changing Steam's bundle.
            _ = try BridgePayload.stage(located: bridge)
            _ = try RunnerSetup.run(from: chosen) { phase in Self.report(phase.label, request) }
            _ = try SteamInstaller.run(payload: payload, bridgePayload: bridge, version: SteamIntegrationRelease.version, report: { phase in Self.report(phase.label, request) })
            progress("Verifying installation", request)
            // Keep recovery available until the installed components pass verification.
            let problems = SteamIntegrationVerification.problems()
            guard problems.isEmpty else { throw failure("Installation verification failed: \(problems.joined(separator: " "))") }
            try files.removeItem(at: pending)
            try? files.removeItem(at: rollback)
            return SteamIntegrationHelperResult(environment: inspect(), message: "The Steam–CrossOver bridge is installed. Steam will reopen; sign in if needed.", restartSteam: true)
        } catch {
            do { try recover() }
            catch let recovery { throw failure("\(error.localizedDescription) Recovery also failed: \(recovery.localizedDescription) Use Repair integration.") }
            throw failure("\(error.localizedDescription) Steam was restored.")
        }
    }

    private func remove(_ request: SteamIntegrationHelperRequest) async throws -> SteamIntegrationHelperResult {
        if files.fileExists(atPath: pending.path) { try recover() }
        let insert = SteamBundle.currentInsert()
        guard insert == SupportPaths.Steam.deployedDylib.path || insert == nil || insert == "" else {
            throw failure("Steam has another integration. Remove it with its installer first.")
        }
        progress("Restoring Steam", request)
        if files.fileExists(atPath: backup.path) {
            try SteamRepair.verifyValveSignature(backup)
            let staged = support.appending(path: "Steam.restore.app")
            if files.fileExists(atPath: staged.path) { try files.removeItem(at: staged) }
            try files.copyItem(at: backup, to: staged)
            try SteamRepair.replace(SupportPaths.Steam.app, with: staged)
            if SteamBundle.currentInsert(at: SupportPaths.Steam.innerInfoPlist) == SupportPaths.Steam.deployedDylib.path {
                _ = try SteamRepair.clearInsert(at: SupportPaths.Steam.innerInfoPlist)
            }
            SteamBundle.register()
            try SteamRepair.verifyValveSignature(SupportPaths.Steam.app)
        } else {
            _ = try await SteamRepair.run() { phase in Self.report(phase.label, request) }
        }
        guard SteamBundle.currentInsert() == nil || SteamBundle.currentInsert() == "" else { throw failure("Steam still has an integration configured.") }
        if files.fileExists(atPath: SupportPaths.Steam.compatTool.path) { try files.removeItem(at: SupportPaths.Steam.compatTool) }
        return SteamIntegrationHelperResult(environment: inspect(), message: "Steam is restored. Games, saves, and per-game environments have been kept.", restartSteam: true)
    }

    private func recover() throws {
        let rollback = support.appending(path: "Steam.transaction.app")
        guard files.fileExists(atPath: rollback.path) else { throw failure("The recovery copy is missing. Restore Steam with its installer.") }
        try SteamRepair.replace(SupportPaths.Steam.app, with: rollback)
        try files.removeItem(at: pending)
        SteamBundle.register()
    }

    private func failure(_ message: String) -> StepFailure { StepFailure(step: "Steam–CrossOver setup", detail: message) }
    private func progress(_ message: String, _ request: SteamIntegrationHelperRequest) { Self.report(message, request) }
    nonisolated static func report(_ message: String, _ request: SteamIntegrationHelperRequest) {
        if let data = try? JSONEncoder().encode(SteamIntegrationProgress(message, canCancel: false)) {
            try? data.write(to: URL(fileURLWithPath: request.progress), options: .atomic)
        }
    }
}

@main struct InstallerMain {
    static func main() async {
        do {
            guard CommandLine.arguments.count == 2 else { throw StepFailure(step: "Setup", detail: "Expected a setup request file.") }
            let request = try JSONDecoder().decode(SteamIntegrationHelperRequest.self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
            let result: SteamIntegrationHelperResult
            do { result = try await SteamIntegrationInstaller().run(request) }
            catch {
                let message = (error as? WriteRefused).map { $0.remedy.advice } ?? error.localizedDescription
                result = SteamIntegrationHelperResult(error: message)
            }
            try JSONEncoder().encode(result).write(to: URL(fileURLWithPath: request.output), options: .atomic)
            exit(result.error == nil ? 0 : 1)
        } catch {
            try? FileHandle.standardError.write(contentsOf: Data((error.localizedDescription + "\n").utf8)); exit(1)
        }
    }
}
