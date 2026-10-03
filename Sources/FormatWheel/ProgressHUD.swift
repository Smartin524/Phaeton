import AppKit
import SwiftUI

@MainActor
final class HUDState: ObservableObject {
    enum Phase { case working, done, failed }
    @Published var phase = Phase.working
    @Published var progress: Double?
}

/// A small glass disc with a progress ring, shown where the wheel was while a conversion runs.
/// It appears only if the job lasts a moment, so quick conversions do not flash.
@MainActor
final class ProgressHUD {
    static let size: CGFloat = 92
    private let panel: NSPanel
    private let state = HUDState()
    private var pendingShow: DispatchWorkItem?
    private var pendingHide: DispatchWorkItem?

    init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: Self.size, height: Self.size),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .popUpMenu
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.contentView = NSHostingView(rootView: HUDView(state: state))
    }

    func begin(at center: NSPoint) {
        pendingHide?.cancel()
        pendingShow?.cancel()
        state.phase = .working
        state.progress = nil
        let screen = NSScreen.screens.first { $0.frame.contains(center) } ?? NSScreen.main
        let bounds = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let x = min(max(bounds.minX, center.x - Self.size / 2), bounds.maxX - Self.size)
        let y = min(max(bounds.minY, center.y - Self.size / 2), bounds.maxY - Self.size)
        let work = DispatchWorkItem { [weak self] in
            self?.panel.setFrameOrigin(NSPoint(x: x, y: y))
            self?.panel.orderFrontRegardless()
        }
        pendingShow = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    func update(progress: Double?) { state.progress = progress }

    func end(success: Bool) {
        pendingShow?.cancel()
        pendingShow = nil
        guard panel.isVisible else { return }
        state.phase = success ? .done : .failed
        let work = DispatchWorkItem { [weak self] in self?.panel.orderOut(nil) }
        pendingHide = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)
    }

    func dismiss() {
        pendingShow?.cancel()
        pendingHide?.cancel()
        panel.orderOut(nil)
    }
}

private struct HUDView: View {
    @ObservedObject var state: HUDState
    @State private var spin = false
    private let disc: CGFloat = 76

    var body: some View {
        ZStack {
            background
            switch state.phase {
            case .working: ring
            case .done: symbol("checkmark", .green)
            case .failed: symbol("xmark", .red)
            }
        }
        .frame(width: ProgressHUD.size, height: ProgressHUD.size)
    }

    @ViewBuilder private var background: some View {
        if #available(macOS 26.0, *) {
            Circle().fill(.clear).frame(width: disc, height: disc).glassEffect(.regular, in: Circle())
        } else {
            NativeMaterial().clipShape(Circle()).frame(width: disc, height: disc)
                .overlay(Circle().stroke(.white.opacity(0.18), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.18), radius: 12, y: 4)
        }
    }

    /// A determinate arc when the job reports progress, otherwise a quarter-circle that spins.
    private var ring: some View {
        ZStack {
            Circle().stroke(Color.primary.opacity(0.12), lineWidth: 5)
            if let progress = state.progress {
                Circle().trim(from: 0, to: max(0.02, min(1, progress)))
                    .stroke(Theme.accent, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.easeOut(duration: 0.2), value: progress)
                Text("\(Int(progress * 100))")
                    .font(.system(size: 15, weight: .semibold, design: .rounded).monospacedDigit())
            } else {
                Circle().trim(from: 0, to: 0.28)
                    .stroke(Theme.accent, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    .rotationEffect(.degrees(spin ? 360 : 0))
                    .onAppear { withAnimation(.linear(duration: 0.9).repeatForever(autoreverses: false)) { spin = true } }
            }
        }
        .frame(width: 50, height: 50)
    }

    private func symbol(_ name: String, _ color: Color) -> some View {
        Image(systemName: name).font(.system(size: 26, weight: .semibold)).foregroundStyle(color)
    }
}
