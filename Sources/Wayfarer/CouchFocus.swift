import AppKit

@MainActor final class CouchFocus: ObservableObject {
    private var current: CouchFocusTarget?
    private weak var window: NSWindow?
    private var ring: CouchFocusRing?
    private var menuTracking = false
    private var observers: [NSObjectProtocol] = []
    var isActive: Bool { current != nil }
    var isTrackingMenu: Bool { menuTracking }

    init() {
        for (name, tracking) in [(NSMenu.didBeginTrackingNotification, true), (NSMenu.didEndTrackingNotification, false)] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.menuTracking = tracking }
            })
        }
    }
    func clear() {
        current = nil; ring?.removeFromSuperview(); ring = nil; window = nil
    }
    func move(_ dx: Int, _ dy: Int, in window: NSWindow?) {
        if menuTracking { sendKey(dx < 0 ? 123 : dx > 0 ? 124 : dy < 0 ? 126 : 125); return }
        let targets = controls(in: window)
        guard !targets.isEmpty else { window?.selectNextKeyView(nil); return }
        guard self.window === window, let current,
              targets.contains(where: { $0.element === current.element }) else { focus(targets[0], in: window); return }
        if current.role == .slider, dx != 0 {
            if dx > 0 { _ = current.increment() } else { _ = current.decrement() }
            return
        }
        let origin = current.frame.center
        let candidates = targets.filter {
            let point = $0.frame.center
            return dx != 0 ? (point.x - origin.x) * CGFloat(dx) > 6 : (origin.y - point.y) * CGFloat(dy) > 6
        }
        let next = candidates.min {
            score($0.frame.center, origin: origin, dx: dx) < score($1.frame.center, origin: origin, dx: dx)
        }
        if let next { focus(next, in: window) }
        else if dy == 0 || !scroll(dy, in: window) { advance(in: window) }
    }
    func advance(in window: NSWindow?, reverse: Bool = false) {
        let targets = controls(in: window)
        guard !targets.isEmpty else { if reverse { window?.selectPreviousKeyView(nil) } else { window?.selectNextKeyView(nil) }; return }
        let index = current.flatMap { item in targets.firstIndex { $0.element === item.element } }
        focus(targets[((index ?? (reverse ? 0 : -1)) + (reverse ? -1 : 1) + targets.count) % targets.count], in: window)
    }
    @discardableResult func activate(in window: NSWindow?) -> Bool {
        if menuTracking { sendKey(36); return true }
        guard self.window === window, let current,
              controls(in: window).contains(where: { $0.element === current.element }) else { advance(in: window); return false }
        if [.textField, .textArea, .comboBox].contains(current.role) {
            current.focus()
            if let view = current.element as? NSView { window?.makeFirstResponder(view) }
            clear(); return true
        }
        return current.press()
    }
    func cancelMenu() -> Bool {
        guard menuTracking else { return false }; sendKey(53); return true
    }
    func controls(in window: NSWindow?) -> [CouchFocusTarget] {
        guard let window, let root = window.contentView else { return [] }
        var pending: [Any] = [root], visited = Set<ObjectIdentifier>(), result: [CouchFocusTarget] = []
        let bounds = window.convertToScreen(root.bounds)
        let roles: Set<NSAccessibility.Role> = [.button, .checkBox, .radioButton, .popUpButton, .menuButton, .textField, .comboBox, .slider, .disclosureTriangle, .link]
        // Lazy SwiftUI trees can be large. Traverse only on input and cap work per event.
        while let object = pending.popLast(), visited.count < 4096 {
            let id = ObjectIdentifier(object as AnyObject)
            guard visited.insert(id).inserted else { continue }
            if let view = object as? CouchControlView, view.enabled, view.action != nil, view.visibleRect.width > 1, view.visibleRect.height > 1 {
                result.append(CouchFocusTarget(control: view))
            } else if let element = object as? any NSAccessibilityProtocol {
                let frame = element.accessibilityFrame()
                if let role = element.accessibilityRole(), roles.contains(role), element.isAccessibilityEnabled(),
                   frame.width > 1, frame.height > 1, bounds.intersects(frame) { result.append(CouchFocusTarget(native: element)) }
                if object is NSControl { pending.append(contentsOf: (element.accessibilityChildren() ?? []).reversed()) }
            }
            if let view = object as? NSView { pending.append(contentsOf: view.subviews.reversed()) }
        }
        let registered = result.filter(\.registered)
        return result.filter { target in
            target.registered || ![NSAccessibility.Role.button, .checkBox].contains(target.role) ||
                !registered.contains { $0.frame.contains(target.frame.center) }
        }.sorted {
            let lhsRow = floor($0.frame.midY / 12), rhsRow = floor($1.frame.midY / 12)
            return lhsRow == rhsRow ? $0.frame.minX < $1.frame.minX : lhsRow > rhsRow
        }
    }
    @discardableResult func scroll(_ direction: Int, in window: NSWindow?) -> Bool {
        guard let root = window?.contentView else { return false }
        var views = [root], candidates: [NSScrollView] = [], visited = 0
        while let view = views.popLast(), visited < 4096 {
            visited += 1
            if let scroll = view as? NSScrollView, !scroll.isHiddenOrHasHiddenAncestor, (scroll.documentView?.bounds.height ?? 0) > scroll.contentView.bounds.height + 1 { candidates.append(scroll) }
            views.append(contentsOf: view.subviews)
        }
        let scroll = candidates.max { $0.bounds.width * $0.bounds.height < $1.bounds.width * $1.bounds.height }
        guard let scroll, let document = scroll.documentView else { return false }
        let origin = scroll.contentView.bounds.origin
        let distance = CGFloat(direction) * (document.isFlipped ? 1 : -1) * 110
        let y = min(max(0, origin.y + distance), max(0, document.bounds.height - scroll.contentView.bounds.height))
        guard y != origin.y else { return false }
        clear(); scroll.contentView.scroll(to: NSPoint(x: origin.x, y: y)); scroll.reflectScrolledClipView(scroll.contentView)
        return true
    }
    func sendKey(_ code: UInt16, shift: Bool = false) {
        let characters: String = switch code { case 48: "\t"; case 36: "\r"; case 53: "\u{1b}"; case 123: "\u{f702}"; case 124: "\u{f703}"; case 125: "\u{f701}"; default: "\u{f700}" }
        guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: shift ? [.shift] : [], timestamp: ProcessInfo.processInfo.systemUptime,
                                          windowNumber: NSApp.keyWindow?.windowNumber ?? 0, context: nil, characters: characters,
                                          charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code) else { return }
        NSApp.postEvent(event, atStart: false)
    }
    #if DEBUG
    @discardableResult func pressForProbe(label: String, in window: NSWindow?) -> Bool {
        guard let target = controls(in: window).first(where: { $0.label == label || $0.title == label }) else { return false }
        focus(target, in: window); return activate(in: window)
    }
    #endif
    private func score(_ point: NSPoint, origin: NSPoint, dx: Int) -> CGFloat {
        let along = dx == 0 ? abs(point.y - origin.y) : abs(point.x - origin.x)
        let across = dx == 0 ? abs(point.x - origin.x) : abs(point.y - origin.y)
        return along + across * 3
    }
    private func focus(_ element: CouchFocusTarget, in window: NSWindow?) {
        guard let window, let root = window.contentView else { return }
        if self.window !== window { clear() }
        self.window = window; current = element
        let ring = self.ring ?? CouchFocusRing(frame: root.bounds)
        if ring.superview == nil { root.addSubview(ring); self.ring = ring }
        ring.autoresizingMask = [.width, .height]
        ring.focusFrame = root.convert(window.convertFromScreen(element.frame), from: nil).insetBy(dx: -4, dy: -4)
        ring.needsDisplay = true
    }
    isolated deinit { clear(); for observer in observers { NotificationCenter.default.removeObserver(observer) } }
}

@MainActor final class CouchFocusTarget {
    let element: AnyObject
    private let control: CouchControlView?
    private let native: (any NSAccessibilityProtocol)?
    init(control: CouchControlView) { element = control; self.control = control; native = nil }
    init(native: any NSAccessibilityProtocol) { element = native; self.native = native; control = nil }
    var registered: Bool { control != nil }
    var frame: NSRect {
        if let control, let window = control.window { return window.convertToScreen(control.convert(control.bounds, to: nil)) }
        return native?.accessibilityFrame() ?? .zero
    }
    var role: NSAccessibility.Role? { control != nil ? .button : native?.accessibilityRole() }
    var label: String? { control?.controlID.isEmpty == false ? control?.controlID : native?.accessibilityLabel() }
    var title: String? { native?.accessibilityTitle() }
    func focus() { native?.setAccessibilityFocused(true) }
    func press() -> Bool {
        if let control, control.enabled, let action = control.action { action(); return true }
        return native?.accessibilityPerformPress() ?? false
    }
    func increment() -> Bool { native?.accessibilityPerformIncrement() ?? false }
    func decrement() -> Bool { native?.accessibilityPerformDecrement() ?? false }
}

private extension NSRect { var center: NSPoint { NSPoint(x: midX, y: midY) } }
@MainActor private final class CouchFocusRing: NSView {
    var focusFrame = NSRect.zero
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func isAccessibilityElement() -> Bool { false }
    override func draw(_ dirtyRect: NSRect) {
        NSColor(calibratedRed: 0.34, green: 0.87, blue: 0.76, alpha: 1).setStroke()
        let path = NSBezierPath(roundedRect: focusFrame, xRadius: 9, yRadius: 9); path.lineWidth = 3; path.stroke()
    }
}
