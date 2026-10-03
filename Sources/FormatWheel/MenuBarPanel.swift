import AppKit
import SwiftUI

/// The wheel icon in the menu bar and the panel it opens: the app's only "window". There is no Dock
/// icon; the app keeps listening for Shift-drags whether the panel is open or not.
@MainActor
final class MenuBarPanel: NSObject, NSPopoverDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let popover = NSPopover()
    private let status: AppStatus
    /// Polls permissions and the login-item state, only while the panel is open.
    private var timer: Timer?

    init(status: AppStatus, actions: HomeActions) {
        self.status = status
        super.init()
        item.autosaveName = "Phaeton"
        item.button?.image = StatusIcon.make()
        item.button?.target = self
        item.button?.action = #selector(toggle)
        let host = NSHostingController(rootView: HomeView(status: status, actions: actions))
        host.sizingOptions = .preferredContentSize
        popover.contentViewController = host
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
    }

    var isShown: Bool { popover.isShown }

    /// Opens the panel under the icon. Right after launch the icon is not on screen yet, and the
    /// menu bar may still be making room for it; a popover shown then silently fails or ends up beside
    /// the icon. So wait (briefly) until the icon is visible and has stopped moving.
    func show(attempt: Int = 0, lastFrame: NSRect? = nil) {
        guard let button = item.button, !popover.isShown else { return }
        let frame = button.window?.frame ?? .zero
        let settled = button.window?.isVisible == true && frame == lastFrame
        if !settled && attempt < 30 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.show(attempt: attempt + 1, lastFrame: frame)
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

    func close() { popover.performClose(nil) }

    /// A click means the icon is already in place: open at once.
    @objc private func toggle() {
        popover.isShown ? close() : show(lastFrame: item.button?.window?.frame)
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

    func popoverDidShow(_ notification: Notification) {
        timer?.invalidate()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.status.refresh() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func popoverDidClose(_ notification: Notification) {
        timer?.invalidate()
        timer = nil
    }
}
