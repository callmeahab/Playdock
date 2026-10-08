import Foundation
import CoreGraphics

/// Bounded metadata for native Windows app windows.
public struct NativeWindowDescriptor: Sendable {
    public let id: Int
    public let title: String
    public let frame: CGRect
    public let visible: Bool
    public let focused: Bool
    public let order: Double

    public init?(_ value: [String: Any]) {
        guard value["type"] as? String == "window", let id = value["id"] as? Int, id > 0,
              let x = value["x"] as? Double, let y = value["y"] as? Double,
              let width = value["width"] as? Double, let height = value["height"] as? Double,
              x.isFinite, y.isFinite, width.isFinite, height.isFinite,
              width >= 0, height >= 0, width <= 32768, height <= 32768,
              let order = value["order"] as? Double, order.isFinite else { return nil }
        self.id = id
        title = (value["title"] as? String).flatMap { $0.isEmpty ? nil : String($0.prefix(1024)) } ?? "Windows app"
        frame = CGRect(x: x, y: y, width: width, height: height)
        visible = value["visible"] as? Bool ?? false
        focused = value["focused"] as? Bool ?? false
        self.order = order
    }
}
