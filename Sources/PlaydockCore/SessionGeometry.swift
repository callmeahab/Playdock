import Foundation
import CoreGraphics

public enum SessionGeometry {
    /// The aspect-fit image rectangle in an AppKit view (origin at the bottom left).
    public static func contentRect(source: CGSize, bounds: CGRect, maxScale: CGFloat = .infinity) -> CGRect {
        guard source.width > 0, source.height > 0, bounds.width > 0, bounds.height > 0 else { return .zero }
        let scale = min(maxScale, bounds.width / source.width, bounds.height / source.height)
        let size = CGSize(width: source.width * scale, height: source.height * scale)
        return CGRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2, width: size.width, height: size.height)
    }

    /// Convert AppKit coordinates into the native Wine window's top-left coordinates.
    public static func remotePoint(local: CGPoint, bounds: CGRect, window: CGRect, clamp: Bool = false, maxScale: CGFloat = .infinity) -> CGPoint? {
        let content = contentRect(source: window.size, bounds: bounds, maxScale: maxScale)
        guard content.width > 0, content.height > 0 else { return nil }
        guard clamp || content.contains(local) else { return nil }
        let x = min(max((local.x - content.minX) / content.width, 0), 1)
        let y = min(max((local.y - content.minY) / content.height, 0), 1)
        return CGPoint(x: window.minX + x * window.width, y: window.minY + (1 - y) * window.height)
    }
}
