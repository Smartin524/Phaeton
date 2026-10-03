import AppKit
import ApplicationServices

/// Optional. Finder treats Shift + mouse-down on an already selected item as "deselect",
/// so no drag ever starts. With Accessibility permission this removes the Shift flag from
/// that one click (only when the click lands on a selected Finder item), so Finder starts
/// a normal drag. The physical Shift key stays down, which is what DragMonitor reads.
/// Shift-clicks on unselected items are untouched, so Shift range selection still works.
@MainActor
final class ShiftFilter {
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    fileprivate var stripping = false
    var isRunning: Bool { tap != nil }

    /// Returns false when Accessibility permission is missing (the system prompt is shown).
    func start() -> Bool {
        guard tap == nil else { return true }
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        guard AXIsProcessTrustedWithOptions(options) else { return false }
        let mask = (1 << CGEventType.leftMouseDown.rawValue) | (1 << CGEventType.leftMouseDragged.rawValue)
            | (1 << CGEventType.leftMouseUp.rawValue)
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let filter = Unmanaged<ShiftFilter>.fromOpaque(refcon).takeUnretainedValue()
                return MainActor.assumeIsolated { filter.handle(type, event) }
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return false }
        let runLoopSource = CFMachPortCreateRunLoopSource(nil, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        tap = port
        source = runLoopSource
        return true
    }

    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        source = nil
        stripping = false
    }

    fileprivate func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
        case .leftMouseDown:
            let flags = event.flags
            if flags.contains(.maskShift),
               flags.intersection([.maskCommand, .maskAlternate, .maskControl]).isEmpty,
               Self.isSelectedFinderItem(at: event.location) {
                stripping = true
                event.flags.remove(.maskShift)
            }
        case .leftMouseDragged:
            if stripping { event.flags.remove(.maskShift) }
        case .leftMouseUp:
            if stripping { event.flags.remove(.maskShift) }
            stripping = false
        default:
            break
        }
        return Unmanaged.passUnretained(event)
    }

    /// True when the element under `point`, or one of its few ancestors, is a selected item
    /// belonging to Finder. Any failure answers false, leaving the click untouched.
    private static func isSelectedFinderItem(at point: CGPoint) -> Bool {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.15)
        var found: AXUIElement?
        guard AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &found) == .success,
              var element = found else { return false }
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success,
              NSRunningApplication(processIdentifier: pid)?.bundleIdentifier == "com.apple.finder" else { return false }
        for _ in 0..<5 {
            var value: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, kAXSelectedAttribute as CFString, &value) == .success,
               let selected = value as? Bool, selected { return true }
            var parent: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, kAXParentAttribute as CFString, &parent) == .success,
                  let next = parent, CFGetTypeID(next) == AXUIElementGetTypeID() else { return false }
            element = next as! AXUIElement
        }
        return false
    }
}
