import Foundation

/// Retains every verification/move task and cancels obsolete environment work.
public actor MaintenanceCoordinator {
    private var revision = 0
    private var tasks: [String: Task<Void, Never>] = [:]
    private var operations: [String: UUID] = [:]
    private var stopped = false
    private var retired: [Task<Void, Never>] = []
    public init() {}
    public func start(key: String, appID: String, folder: Int?, revision: Int, control: any SteamWorkflowControl,
                      publish: @escaping @Sendable (SteamMaintenanceProgress) async -> Void) {
        guard !stopped, revision >= self.revision else { return }
        if revision > self.revision { invalidate(revision: revision) }
        guard tasks[key] == nil else { return }
        let id = UUID(); operations[key] = id
        tasks[key] = Task {
            defer { if operations[key] == id { tasks[key] = nil; operations[key] = nil } }
            do {
                if let folder { try await control.moveGame(appID: appID, folder: folder) }
                else { try await control.verifyFiles(appID: appID) }
                while !Task.isCancelled {
                    let progress = try await control.maintenanceProgress(appID: appID)
                    guard !Task.isCancelled, operations[key] == id else { return }
                    await publish(progress)
                    if progress.completed || progress.failed { return }
                    try await Task.sleep(for: .seconds(2))
                }
            } catch {
                guard !Task.isCancelled, operations[key] == id else { return }
                await publish(SteamMaintenanceProgress(kind: folder == nil ? "verify" : "move", progress: nil,
                    task: error.localizedDescription, completed: false, failed: true))
            }
        }
    }
    public func invalidate(revision: Int) {
        guard revision > self.revision else { return }
        self.revision = revision; operations.removeAll()
        retired += Array(tasks.values)
        for task in tasks.values { task.cancel() }; tasks.removeAll()
    }
    public func stop() async {
        stopped = true
        let pending = Array(tasks.values) + retired
        invalidate(revision: revision + 1)
        for task in pending { await task.value }
    }
}
