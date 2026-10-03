import AppKit
import AVFoundation
import AVKit
import FormatWheelCore
import SwiftUI

typealias ToolProgress = @Sendable (Double) -> Void
typealias ToolWork = @Sendable (URL, @escaping ToolProgress) async throws -> URL

/// Opens the editor window (crop, resize, compress with a preview) for files dropped on the wrench.
@MainActor
final class ToolWindows: NSObject, NSWindowDelegate {
    typealias Perform = ([URL], String, @escaping ToolWork) -> Void
    private var windows: [NSWindow] = []

    func open(_ urls: [URL], kind: FileKind, perform: @escaping Perform) {
        guard let first = urls.first else { return }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 440),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        // No visible title bar; the whole window is frosted glass that follows the system appearance.
        window.title = urls.count == 1 ? first.lastPathComponent : "\(urls.count) 个文件"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        // The panel has Cancel (Esc) and Save, so the traffic lights are only clutter.
        for button: NSWindow.ButtonType in [.closeButton, .miniaturizeButton, .zoomButton] {
            window.standardWindowButton(button)?.isHidden = true
        }
        window.isOpaque = false
        window.backgroundColor = .clear
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: Self.panelWidth + 220, height: 380)
        window.delegate = self
        let close: () -> Void = { [weak window] in window?.close() }
        let run: (String, @escaping ToolWork) -> Void = { label, work in perform(urls, label, work) }
        // The picture sits on the left and the window hugs it; the panel on the right never changes size.
        let fit: (CGSize) -> Void = { [weak window] media in
            guard let window, media.width > 0, media.height > 0 else { return }
            let visible = (window.screen ?? NSScreen.main)?.visibleFrame.size ?? NSSize(width: 1440, height: 900)
            let room = NSSize(width: min(620, visible.width - 80) - Self.panelWidth - 24,
                              height: min(460, visible.height - 140) - 36)
            let scale = min(room.width / media.width, room.height / media.height, 1.5)
            let image = NSSize(width: media.width * scale, height: media.height * scale)
            window.setContentSize(NSSize(width: max(Self.panelWidth + 220, image.width + 24 + Self.panelWidth),
                                         height: max(window.minSize.height, image.height + 36)))
            window.center()
        }
        let glass = NSVisualEffectView()
        glass.material = .underWindowBackground
        glass.blendingMode = .behindWindow
        glass.state = .active
        let content: NSView
        switch kind {
        case .image: content = NSHostingView(rootView: ImageToolView(urls: urls, perform: run, close: close, fit: fit))
        case .document:
            content = NSHostingView(rootView: PDFToolView(urls: urls, perform: run, close: close, fit: fit))
        case .audio:
            window.minSize = NSSize(width: Self.panelWidth + 320, height: 380)
            window.setContentSize(NSSize(width: Self.panelWidth + 420, height: 380))
            content = NSHostingView(rootView: AudioToolView(urls: urls, perform: run, close: close))
        case .video:
            window.minSize = NSSize(width: Self.panelWidth + 300, height: 480)
            content = NSHostingView(rootView: VideoToolView(urls: urls, perform: run, close: close, fit: fit))
        default: return
        }
        content.frame = glass.bounds
        content.autoresizingMask = [.width, .height]
        glass.addSubview(content)
        window.contentView = glass
        window.center()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        windows.append(window)
    }

    /// Width of the control panel on the right, fixed whatever the picture is.
    static let panelWidth: CGFloat = 204

    func windowWillClose(_ notification: Notification) {
        windows.removeAll { $0 === notification.object as? NSWindow }
    }
}
