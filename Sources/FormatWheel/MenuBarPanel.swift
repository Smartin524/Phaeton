import AppKit
import SwiftUI

/// The wheel icon in the menu bar and the panel it opens: the app's only "window". There is no Dock
/// icon; the app keeps listening for Shift-drags whether the panel is open or not.
///
/// The icon can be turned off. The panel then opens as a small window in the middle of the screen
/// whenever the app is opened again (Finder, Spotlight, Launchpad), and can turn the icon back on.
@MainActor
final class MenuBarPanel: NSObject, NSPopoverDelegate, NSWindowDelegate {
    static let iconKey = "ShowMenuBarIcon"

    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let popover = NSPopover()
    private let status: AppStatus
    private let actions: HomeActions
    /// The panel as a window, used while the icon is hidden.
    private var window: NSWindow?
    /// Polls permissions and the login-item state, only while the panel is open.
    private var timer: Timer?

    init(status: AppStatus, actions: HomeActions) {
        self.status = status
        self.actions = actions
        super.init()
        item.autosaveName = "Phaeton"
        item.button?.image = StatusIcon.make()
        item.button?.target = self
        item.button?.action = #selector(toggle)
        item.isVisible = status.showsMenuBarIcon
        let host = NSHostingController(rootView: HomeView(status: status, actions: actions))
        host.sizingOptions = .preferredContentSize
        popover.contentViewController = host
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
    }

    var isShown: Bool { popover.isShown || window?.isVisible == true }

    /// Opens the panel: under the icon, or in the middle of the screen when the icon is hidden.
    func show() {
        if status.showsMenuBarIcon { showPopover() } else { showWindow() }
    }

    func close() {
        popover.performClose(nil)
        window?.close()
    }

    /// Shows or hides the menu-bar icon. Hiding it moves the open panel to the middle of the screen,
    /// so it is clear where the panel lives from now on.
    func setIconVisible(_ visible: Bool) {
        item.isVisible = visible
        if !visible && popover.isShown {
            popover.performClose(nil)
            showWindow()
        }
    }

    /// Opens the panel under the icon. Right after launch the icon is not on screen yet, and the
    /// menu bar may still be making room for it; a popover shown then silently fails or ends up beside
    /// the icon. So wait (briefly) until the icon is visible and has stopped moving.
    private func showPopover(attempt: Int = 0, lastFrame: NSRect? = nil) {
        guard let button = item.button, !popover.isShown else { return }
        let frame = button.window?.frame ?? .zero
        let settled = button.window?.isVisible == true && frame == lastFrame
        if !settled && attempt < 30 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.showPopover(attempt: attempt + 1, lastFrame: frame)
            }
            return
        }
        status.refresh()
        // The hosting controller reports its size only after a first layout, and a popover without a
        // size does not open; measure the content first.
        if let view = popover.contentViewController?.view {
            view.layoutSubtreeIfNeeded()
            popover.contentSize = view.fittingSize
        }
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    private func showWindow() {
        let window = self.window ?? makeWindow()
        self.window = window
        status.refresh()
        if !window.isVisible { window.center() }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        startPolling()
    }

    private func makeWindow() -> NSWindow {
        let host = NSHostingController(rootView: HomeView(status: status, actions: actions))
        host.sizingOptions = .preferredContentSize
        let window = NSWindow(contentViewController: host)
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        // Like the popover: it goes away when another app is used, and comes back when this one is opened.
        window.hidesOnDeactivate = true
        // The panel has its own Close button; the traffic lights would only crowd its header.
        for button: NSWindow.ButtonType in [.closeButton, .miniaturizeButton, .zoomButton] {
            window.standardWindowButton(button)?.isHidden = true
        }
        window.delegate = self
        return window
    }

    /// A click means the icon is already in place: open at once.
    @objc private func toggle() {
        popover.isShown ? close() : showPopover(lastFrame: item.button?.window?.frame)
    }

    /// Shows the progress in the menu bar while a job runs: the wheel stays, a percentage follows it.
    func showProgress(_ progress: Double?, running: Bool) {
        let title = running ? (progress.map { " \(Int($0 * 100))%" } ?? " …") : ""
        if item.button?.title != title {
            item.length = running ? NSStatusItem.variableLength : NSStatusItem.squareLength
            item.button?.title = title
            item.button?.imagePosition = running ? .imageLeading : .imageOnly
        }
    }

    private func startPolling() {
        timer?.invalidate()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.status.refresh() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stopPolling() {
        guard !isShown else { return }
        timer?.invalidate()
        timer = nil
    }

    func popoverDidShow(_ notification: Notification) { startPolling() }
    func popoverDidClose(_ notification: Notification) { stopPolling() }

    func windowWillClose(_ notification: Notification) {
        // Checked after the window has gone, so isShown no longer counts it.
        DispatchQueue.main.async { [weak self] in self?.stopPolling() }
    }
}
