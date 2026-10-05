import AppKit
import AVFoundation
import ApplicationServices
import WayfarerCore

struct SteamSharedInputTarget {
    var pid: pid_t
    var windowID: CGWindowID
    var frame: CGRect
    var token:RuntimeProcessToken?
    var isCurrent:Bool { token != nil && RuntimeProcessIdentity.token(for:pid)==token }
}

final class SteamSharedSurfaceView: NSView {
    private let video = AVSampleBufferDisplayLayer()
    var target: SteamSharedInputTarget? { didSet { if oldValue?.windowID != target?.windowID || oldValue?.token != target?.token { releaseInput(to: oldValue) } } }
    var inputEnabled = false { didSet { if !inputEnabled { releaseInput() } } }
    var permissionCheck: () -> Bool = { false }
    private var pressedKeys = Set<UInt16>()
    private var pressedButtons = Set<CGMouseButton>()
    private var lastPoint: CGPoint?
    private var tracking: NSTrackingArea?
    override var acceptsFirstResponder: Bool { true }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer = CALayer()
        layer?.backgroundColor = NSColor.black.cgColor
        video.videoGravity = .resizeAspect
        layer?.addSublayer(video)
        setAccessibilityLabel("Steam session")
        setAccessibilityRole(.group)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layout() { super.layout(); video.frame = bounds }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }
    override func viewDidMoveToWindow() { window?.acceptsMouseMovedEvents = true }

    func display(_ sample: CMSampleBuffer) {
        if video.status == .failed { video.flush() }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true) as? [NSMutableDictionary] {
            attachments.first?[kCMSampleAttachmentKey_DisplayImmediately] = true
        }
        video.enqueue(sample)
    }
    func clear() { video.flushAndRemoveImage() }

    @discardableResult
    private func forward(_ event: NSEvent, pointer: Bool = false) -> Bool {
        guard inputEnabled, permissionCheck(), let target, target.isCurrent, let cg = event.cgEvent?.copy() else { return false }
        if pointer {
            let local = convert(event.locationInWindow, from: nil)
            guard let point = SessionGeometry.remotePoint(local: local, bounds: bounds, window: target.frame, clamp: !pressedButtons.isEmpty) else { return false }
            cg.location = point
            lastPoint = point
        }
        cg.setIntegerValueField(.eventTargetUnixProcessID, value: Int64(target.pid))
        cg.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(target.windowID))
        cg.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(target.windowID))
        cg.postToPid(target.pid)
        return true
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        if forward(event, pointer: true) { pressedButtons.insert(.left) }
    }
    override func mouseUp(with event: NSEvent) { if pressedButtons.contains(.left) { forward(event, pointer: true) }; pressedButtons.remove(.left) }
    override func rightMouseDown(with event: NSEvent) { window?.makeFirstResponder(self); if forward(event, pointer: true) { pressedButtons.insert(.right) } }
    override func rightMouseUp(with event: NSEvent) { if pressedButtons.contains(.right) { forward(event, pointer: true) }; pressedButtons.remove(.right) }
    override func otherMouseDown(with event: NSEvent) { window?.makeFirstResponder(self); if forward(event, pointer: true) { pressedButtons.insert(.center) } }
    override func otherMouseUp(with event: NSEvent) { if pressedButtons.contains(.center) { forward(event, pointer: true) }; pressedButtons.remove(.center) }
    override func mouseMoved(with event: NSEvent) { forward(event, pointer: true) }
    override func mouseDragged(with event: NSEvent) { forward(event, pointer: true) }
    override func rightMouseDragged(with event: NSEvent) { forward(event, pointer: true) }
    override func otherMouseDragged(with event: NSEvent) { forward(event, pointer: true) }
    override func scrollWheel(with event: NSEvent) { forward(event, pointer: true) }
    override func keyDown(with event: NSEvent) { if forward(event) { pressedKeys.insert(event.keyCode) } }
    override func keyUp(with event: NSEvent) { forward(event); pressedKeys.remove(event.keyCode) }
    override func flagsChanged(with event: NSEvent) {
        if forward(event), event.keyCode != 57 { pressedKeys.insert(event.keyCode) }
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // Preserve Wayfarer's standard app controls. Other key equivalents belong to Steam.
        if event.modifierFlags.contains(.command), ["q", "h", "w", "m"].contains(event.charactersIgnoringModifiers?.lowercased() ?? "") { return false }
        guard inputEnabled, window?.firstResponder === self else { return false }
        guard forward(event) else { return false }
        pressedKeys.insert(event.keyCode)
        return true
    }
    override func resignFirstResponder() -> Bool { releaseInput(); return super.resignFirstResponder() }

    func releaseInput(to previous: SteamSharedInputTarget? = nil) {
        guard let target = previous ?? target else { pressedKeys.removeAll(); pressedButtons.removeAll(); return }
        if permissionCheck() && target.isCurrent {
            for key in pressedKeys {
                let event = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: false)
                event?.flags = []
                if [54, 55, 56, 58, 59, 60, 61, 62, 63].contains(key) { event?.type = .flagsChanged }
                event?.postToPid(target.pid)
            }
            for button in pressedButtons {
                let type: CGEventType = button == .left ? .leftMouseUp : button == .right ? .rightMouseUp : .otherMouseUp
                let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: lastPoint ?? target.frame.origin, mouseButton: button)
                event?.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(target.windowID))
                event?.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(target.windowID))
                event?.postToPid(target.pid)
            }
        }
        pressedKeys.removeAll()
        pressedButtons.removeAll()
        lastPoint = nil
    }
}
