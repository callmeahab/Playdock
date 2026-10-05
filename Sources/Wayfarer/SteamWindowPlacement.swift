import AppKit
import ApplicationServices
import ScreenCaptureKit
import WayfarerCore

/// Move only verified Steam windows underneath Wayfarer while sharing them.
/// Restore their geometry and minimize them when the account panel closes.
@MainActor
final class SteamWindowPlacement {
    private struct Entry {
        let element:AXUIElement
        let original:CGRect
        let token:RuntimeProcessToken
        var current:CGRect
    }
    private var entries:[CGWindowID:Entry]=[:]

    func frame(for window:SCWindow) -> CGRect { entries[window.windowID]?.current ?? window.frame }

    func cover(_ window:SCWindow,host:NSWindow?) {
        guard AXIsProcessTrusted(), let app=window.owningApplication, let token=RuntimeProcessIdentity.token(for:app.processID),
              let host=host ?? NSApp.mainWindow, let hostRect=hostFrame(host.windowNumber) else { return }
        if entries[window.windowID]?.token != token {
            guard let element=findElement(pid:app.processID,frame:window.frame) else { return }
            entries[window.windowID]=Entry(element:element,original:window.frame,token:token,current:window.frame)
        }
        guard var entry=entries[window.windowID] else { return }
        var size=CGSize(width:min(entry.original.width,max(500,hostRect.width-48)),height:min(entry.original.height,max(360,hostRect.height-132)))
        var point=CGPoint(x:hostRect.minX+24,y:hostRect.minY+80)
        let current=readFrame(entry.element) ?? entry.current
        if current.size != size,let value=AXValueCreate(.cgSize,&size) { _=AXUIElementSetAttributeValue(entry.element,kAXSizeAttribute as CFString,value) }
        if current.origin != point,let value=AXValueCreate(.cgPoint,&point) { _=AXUIElementSetAttributeValue(entry.element,kAXPositionAttribute as CFString,value) }
        entry.current=readFrame(entry.element) ?? window.frame
        entries[window.windowID]=entry
        // The source remains rendered, behind Wayfarer; minimizing would stop
        // some Steam versions from producing frames for window sharing.
        if NSApp.isActive { host.orderFront(nil) }
    }

    func restore() {
        for entry in entries.values where RuntimeProcessIdentity.token(for:entry.token.pid)==entry.token {
            NSRunningApplication(processIdentifier:entry.token.pid)?.hide()
        }
        guard AXIsProcessTrusted() else { entries.removeAll(); return }
        for entry in entries.values where RuntimeProcessIdentity.token(for:entry.token.pid)==entry.token {
            var point=entry.original.origin, size=entry.original.size
            _=AXUIElementSetAttributeValue(entry.element,kAXMinimizedAttribute as CFString,kCFBooleanTrue)
            if let value=AXValueCreate(.cgPoint,&point) { _=AXUIElementSetAttributeValue(entry.element,kAXPositionAttribute as CFString,value) }
            if let value=AXValueCreate(.cgSize,&size) { _=AXUIElementSetAttributeValue(entry.element,kAXSizeAttribute as CFString,value) }
        }
        entries.removeAll()
    }

    private func findElement(pid:pid_t,frame:CGRect)->AXUIElement? {
        let application=AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application,0.25)
        var value:CFTypeRef?
        guard AXUIElementCopyAttributeValue(application,kAXWindowsAttribute as CFString,&value) == .success,
              let windows=value as? [AXUIElement] else { return nil }
        let matches=windows.filter { element in
            guard let rect=readFrame(element) else { return false }
            return abs(rect.minX-frame.minX)<3 && abs(rect.minY-frame.minY)<3 && abs(rect.width-frame.width)<3 && abs(rect.height-frame.height)<3
        }
        guard matches.count==1 else { return nil }
        AXUIElementSetMessagingTimeout(matches[0],0.25)
        return matches[0]
    }
    private func readFrame(_ element:AXUIElement)->CGRect? {
        var position:CFTypeRef?, size:CFTypeRef?
        guard AXUIElementCopyAttributeValue(element,kAXPositionAttribute as CFString,&position) == .success,
              AXUIElementCopyAttributeValue(element,kAXSizeAttribute as CFString,&size) == .success,
              let position,let size,CFGetTypeID(position)==AXValueGetTypeID(),CFGetTypeID(size)==AXValueGetTypeID() else { return nil }
        var point=CGPoint.zero, dimensions=CGSize.zero
        guard AXValueGetValue(position as! AXValue,.cgPoint,&point),AXValueGetValue(size as! AXValue,.cgSize,&dimensions) else { return nil }
        return CGRect(origin:point,size:dimensions)
    }
    private func hostFrame(_ number:Int)->CGRect? {
        guard let values=CGWindowListCopyWindowInfo(.optionIncludingWindow,CGWindowID(number)) as? [[String:Any]],
              let bounds=values.first?[kCGWindowBounds as String] as? [String:Any] else { return nil }
        return CGRect(dictionaryRepresentation:bounds as CFDictionary)
    }
}
