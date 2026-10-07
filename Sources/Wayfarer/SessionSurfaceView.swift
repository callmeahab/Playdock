import AppKit
import WayfarerCore

/// CALayerHost presents Wine's layer tree directly through WindowServer.
/// There is no image capture, video encoding, or global event injection.
final class SessionSurfaceView: NSView {
    private var primary: SessionWindow?
    private var scene: [SessionWindow] = []
    private var hosts: [String: (UInt32, CALayer)] = [:]
    private var tracking: NSTrackingArea?
    private var pressedKeys = Set<UInt16>()
    private var pressedButtons = Set<Int>()
    private var inputTarget: SessionWindow?
    private var lastPoint = CGPoint.zero
    private var focusObserver: NSObjectProtocol?
    override var acceptsFirstResponder: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    init() {
        super.init(frame: .zero)
        wantsLayer = true; layer = CALayer(); layer?.backgroundColor = NSColor.black.cgColor
        setAccessibilityLabel("Steam session"); setAccessibilityRole(.group)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    func show(_ window: SessionWindow?, windows: [SessionWindow]) {
        let changed = primary?.id != window?.id
        if changed { releaseInput() }
        primary = window
        guard let window else {
            hosts.values.forEach { $0.1.removeFromSuperlayer() }; hosts.removeAll(); scene = []; return
        }
        scene = [window] + windows.filter { $0.id != window.id && $0.order > window.order && $0.frame.intersects(window.frame) }
            .sorted { $0.order < $1.order }
        let ids = Set(scene.map(\.id))
        for id in Array(hosts.keys) where !ids.contains(id) { hosts.removeValue(forKey: id)?.1.removeFromSuperlayer() }
        for item in scene {
            if hosts[item.id]?.0 != item.contextID {
                hosts.removeValue(forKey: item.id)?.1.removeFromSuperlayer()
                guard let host = WFMakeRemoteLayer(item.contextID) else { continue }
                hosts[item.id] = (item.contextID, host)
            }
            if let host = hosts[item.id]?.1 { host.removeFromSuperlayer(); layer?.addSublayer(host) }
        }
        needsLayout = true
        if changed, self.window?.isKeyWindow == true {
            self.window?.makeFirstResponder(self)
            transmit(["kind": "focus"], to: window)
            inputTarget = window
        }
    }
    override func layout() {
        super.layout()
        guard let primary else { return }
        let rect = SessionGeometry.contentRect(source: primary.frame.size, bounds: bounds, maxScale: 1)
        let scale = rect.width / primary.frame.width
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for item in scene {
            guard let host = hosts[item.id]?.1 else { continue }
            host.anchorPoint = .zero
            host.bounds = CGRect(origin: .zero, size: item.frame.size)
            host.transform = CATransform3DMakeScale(scale, scale, 1)
            host.position = CGPoint(x: rect.minX + (item.frame.minX-primary.frame.minX)*scale,
                y: rect.maxY - (item.frame.maxY-primary.frame.minY)*scale)
        }
        CATransaction.commit()
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area); tracking = area
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let focusObserver { NotificationCenter.default.removeObserver(focusObserver) }
        focusObserver = nil
        window?.acceptsMouseMovedEvents = true
        if let window {
            focusObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.releaseInput() }
            }
        }
    }
    isolated deinit { if let focusObserver { NotificationCenter.default.removeObserver(focusObserver) } }
    private func transmit(_ value: [String: Any], to target: SessionWindow) {
        var message = value; message["id"] = target.nativeID; target.peer.send(message)
    }
    private func pointer(_ event: NSEvent) -> SessionWindow? {
        guard let primary else { return nil }
        let point = convert(event.locationInWindow, from: nil)
        guard let global = SessionGeometry.remotePoint(local: point, bounds: bounds, window: primary.frame, clamp: !pressedButtons.isEmpty, maxScale: 1) else { return nil }
        let target = pressedButtons.isEmpty ? scene.reversed().first { $0.frame.contains(global) } : inputTarget
        guard let target else { return nil }
        lastPoint = CGPoint(x: global.x-target.frame.minX, y: global.y-target.frame.minY)
        if [.leftMouseDown, .rightMouseDown, .otherMouseDown].contains(event.type) {
            window?.makeFirstResponder(self)
            transmit(["kind": "focus"], to: target); inputTarget = target
        }
        transmit(["kind": "input", "event": event.type.rawValue, "x": lastPoint.x, "y": lastPoint.y,
                  "dx": event.type == .scrollWheel ? event.scrollingDeltaX : event.deltaX, "dy": event.type == .scrollWheel ? event.scrollingDeltaY : event.deltaY, "button": event.buttonNumber,
                  "flags": event.modifierFlags.rawValue], to: target)
        return target
    }
    override func mouseDown(with event: NSEvent) { if pointer(event) != nil { pressedButtons.insert(0) } }
    override func mouseUp(with event: NSEvent) { _ = pointer(event); pressedButtons.remove(0) }
    override func rightMouseDown(with event: NSEvent) { if pointer(event) != nil { pressedButtons.insert(1) } }
    override func rightMouseUp(with event: NSEvent) { _ = pointer(event); pressedButtons.remove(1) }
    override func otherMouseDown(with event: NSEvent) { if pointer(event) != nil { pressedButtons.insert(event.buttonNumber) } }
    override func otherMouseUp(with event: NSEvent) { _ = pointer(event); pressedButtons.remove(event.buttonNumber) }
    override func mouseMoved(with event: NSEvent) { _ = pointer(event) }
    override func mouseDragged(with event: NSEvent) { _ = pointer(event) }
    override func rightMouseDragged(with event: NSEvent) { _ = pointer(event) }
    override func otherMouseDragged(with event: NSEvent) { _ = pointer(event) }
    override func scrollWheel(with event: NSEvent) { _ = pointer(event) }
    private func key(_ event: NSEvent) {
        guard let target = inputTarget ?? scene.last(where: { $0.focused }) ?? primary else { return }
        transmit(["kind": "input", "event": event.type.rawValue, "code": event.keyCode,
                  "flags": event.modifierFlags.rawValue, "text": event.type == .flagsChanged ? "" : event.characters ?? "",
                  "plainText": event.type == .flagsChanged ? "" : event.charactersIgnoringModifiers ?? ""], to: target)
    }
    override func keyDown(with event: NSEvent) { key(event); pressedKeys.insert(event.keyCode) }
    override func keyUp(with event: NSEvent) { key(event); pressedKeys.remove(event.keyCode) }
    override func flagsChanged(with event: NSEvent) { key(event) }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command), ["q", "h", "w", "m"].contains(event.charactersIgnoringModifiers?.lowercased() ?? "") { return false }
        guard primary != nil, window?.firstResponder === self else { return false }
        keyDown(with: event); return true
    }
    override func resignFirstResponder() -> Bool { releaseInput(); return super.resignFirstResponder() }
    func releaseInput() {
        if let target = inputTarget ?? primary {
            for code in pressedKeys { transmit(["kind": "input", "event": NSEvent.EventType.keyUp.rawValue, "code": code, "flags": 0], to: target) }
            for button in pressedButtons {
                let type: NSEvent.EventType = button == 0 ? .leftMouseUp : button == 1 ? .rightMouseUp : .otherMouseUp
                transmit(["kind": "input", "event": type.rawValue, "x": lastPoint.x, "y": lastPoint.y, "button": button, "flags": 0], to: target)
            }
            transmit(["kind": "blur"], to: target)
        }
        pressedKeys.removeAll(); pressedButtons.removeAll(); inputTarget = nil
    }
}
