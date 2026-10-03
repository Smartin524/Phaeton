import AppKit
import SwiftUI

/// The one window the app opens: it says the app is running and explains how to use it. Closing it
/// does not quit; the app keeps listening for drags, and clicking its Dock icon brings the window back.
@MainActor
final class MainWindow: NSObject, NSWindowDelegate {
    private var window: NSWindow?
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

    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 550),
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
        window.center()
        return window
    }
}
