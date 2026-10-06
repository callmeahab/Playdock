import Foundation

/// An asynchronous Steam response may arrive after Cancel or a new request.
/// Only the current operation can publish details or enable confirmation.
public struct SteamInstallDialogState {
    public private(set) var operationID = UUID()
    public private(set) var plan: SteamInstallPlan?
    public private(set) var busy = false
    public private(set) var message = ""
    public init() {}
    @discardableResult public mutating func begin(_ message: String, keepPlan: Bool = false) -> UUID {
        operationID = UUID(); busy = true; self.message = message
        if !keepPlan { plan = nil }
        return operationID
    }
    public mutating func finish(_ operation: UUID, plan: SteamInstallPlan? = nil, message: String) {
        guard operationID == operation else { return }
        self.plan = plan; self.message = message; busy = false
    }
    public mutating func dismiss() {
        operationID = UUID(); plan = nil; busy = false; message = ""
    }
}
