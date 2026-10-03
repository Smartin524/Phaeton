import AppKit
import FormatWheelCore

/// Watches for "hold Shift while dragging supported files" anywhere on screen.
///
/// Passive global mouse monitors only start and stop a short polling loop; the loop
/// itself reads the modifier keys, the button state and the drag pasteboard. Once a
/// file drag begins, macOS may stop delivering mouse-dragged events to other apps, so
/// detection must not depend on them. Pressing Shift late, or releasing and pressing
/// it again, also works; so does dragging an already selected file. No event tap, no Accessibility / Input Monitoring permission.
@MainActor
final class DragMonitor {
    var onBegin: ((FileKind, [URL], NSPoint) -> Void)?
    var onEnd: (() -> Void)?

    private var monitors: [Any] = []
    private var timer: Timer?
    private var baselineChangeCount = 0
    private var active = false

    func start() {
        guard monitors.isEmpty else { return }
        baselineChangeCount = NSPasteboard(name: .drag).changeCount
        let down = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged]) { [weak self] _ in
            MainActor.assumeIsolated { self?.beginPolling() }
        }
        let up = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp) { [weak self] _ in
            MainActor.assumeIsolated { self?.finish() }
        }
        monitors = [down, up].compactMap { $0 }
    }

    func stop() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        finish()
    }

    private func beginPolling() {
        guard timer == nil else { return }
        // The baseline is the state at the last mouse-up, not at this mouse-down: Finder may
        // fill the drag pasteboard at mouse-down for an already selected file, before we run.
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func poll() {
        guard NSEvent.pressedMouseButtons & 1 != 0 else { finish(); return }
        guard !active, NSEvent.modifierFlags.contains(.shift) else { return }
        let pasteboard = NSPasteboard(name: .drag)
        guard pasteboard.changeCount != baselineChangeCount else { return }
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        let urls = (pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL]) ?? []
        // One wheel serves one kind of file: the first supported file decides.
        guard let kind = urls.lazy.compactMap({ FileKind($0) }).first else { return }
        active = true
        onBegin?(kind, urls.filter { FileKind($0) == kind }, NSEvent.mouseLocation)
    }

    private func finish() {
        timer?.invalidate()
        timer = nil
        baselineChangeCount = NSPasteboard(name: .drag).changeCount
        guard active else { return }
        active = false
        onEnd?()
    }
}
