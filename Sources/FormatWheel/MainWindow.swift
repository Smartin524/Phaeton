import AppKit
import Combine
import SwiftUI

/// The one window the app opens: it says the app is running and explains how to use it. Closing it
/// does not quit; the app keeps listening for drags, and clicking its Dock icon brings the window back.
@MainActor
final class MainWindow: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private var content: NSHostingView<HomeView>?
    private var changes: AnyCancellable?
    private let status: AppStatus
    private let actions: HomeActions

    init(status: AppStatus, actions: HomeActions) {
        self.status = status
        self.actions = actions
    }

    func show() {
        if window == nil { window = makeWindow() }
        status.refresh()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func close() { window?.close() }

    /// Resizes the window to the content's natural height, keeping its top edge where it is.
    private func fit(_ window: NSWindow, animated: Bool) {
        guard let content else { return }
        content.layoutSubtreeIfNeeded()
        let height = ceil(content.fittingSize.height)
        // The content runs under the title bar (full-size content view), so compare with the whole content area.
        let current = window.contentView?.bounds.height ?? window.frame.height
        guard height > 100, abs(current - height) > 1 else { return }
        var frame = window.frame
        let delta = height - current
        frame.size.height += delta
        frame.origin.y -= delta
        window.setFrame(frame, display: true, animate: animated && window.isVisible)
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 500),
                              styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Phaeton"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.standardWindowButton(.zoomButton)?.isEnabled = false
        window.delegate = self
        let glass = NSVisualEffectView()
        glass.material = .underWindowBackground
        glass.blendingMode = .behindWindow
        glass.state = .active
        let content = NSHostingView(rootView: HomeView(status: status, actions: actions))
        content.frame = glass.bounds
        content.autoresizingMask = [.width, .height]
        glass.addSubview(content)
        window.contentView = glass
        self.content = content
        fit(window, animated: false)
        window.center()
        // A row can appear or go (the accessibility switch, a hint); keep the window as tall as its content.
        changes = status.objectWillChange.sink { [weak self] in
            DispatchQueue.main.async { if let window = self?.window { self?.fit(window, animated: true) } }
        }
        return window
    }
}
