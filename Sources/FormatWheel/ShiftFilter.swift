import AppKit
import ApplicationServices
import os

/// Diagnostics for the Shift filter. Start-up and failures are stored:
///   /usr/bin/log show --last 10m --predicate 'subsystem == "io.github.smartin524.phaeton"'
/// Each Shift-click is logged at debug level, seen only live:
///   /usr/bin/log stream --level debug --predicate 'subsystem == "io.github.smartin524.phaeton"'
private let log = Logger(subsystem: "io.github.smartin524.phaeton", category: "shift-filter")

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
        guard AXIsProcessTrustedWithOptions(options) else {
            log.notice("start: not trusted for Accessibility")
            return false
        }
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
            userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            log.error("start: trusted, but the event tap could not be created")
            return false
        }
        log.notice("start: event tap running")
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
            log.notice("tap disabled by the system (\(type.rawValue, privacy: .public)); re-enabling")
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
        case .leftMouseDown:
            let flags = event.flags
            if flags.contains(.maskShift),
               flags.intersection([.maskCommand, .maskAlternate, .maskControl]).isEmpty {
                let selected = Self.isSelectedFinderItem(at: event.location)
                log.debug("shift-click: selected Finder item = \(selected, privacy: .public)")
                if selected {
                    stripping = true
                    event.flags.remove(.maskShift)
                }
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
        let lookup = AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &found)
        guard lookup == .success, var element = found else {
            log.debug("no element at the click (AX error \(lookup.rawValue, privacy: .public))")
            return false
        }
        var pid: pid_t = 0
        let owner = AXUIElementGetPid(element, &pid) == .success ? NSRunningApplication(processIdentifier: pid)?.bundleIdentifier : nil
        guard owner == "com.apple.finder" else {
            log.debug("clicked element belongs to \(owner ?? "unknown", privacy: .public), not Finder")
            return false
        }
        var chain: [String] = []
        defer { log.debug("Finder element chain: \(chain.joined(separator: " < "), privacy: .public)") }
        for _ in 0..<6 {
            var role: CFTypeRef?, value: CFTypeRef?
            AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
            let state = AXUIElementCopyAttributeValue(element, kAXSelectedAttribute as CFString, &value)
            chain.append("\(role as? String ?? "?")[selected=\(state == .success ? String(describing: value as? Bool) : "n/a")]")
            if state == .success, let selected = value as? Bool, selected { return true }
            var parent: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, kAXParentAttribute as CFString, &parent) == .success,
                  let next = parent, CFGetTypeID(next) == AXUIElementGetTypeID() else { return false }
            element = next as! AXUIElement
        }
        return false
    }
}
