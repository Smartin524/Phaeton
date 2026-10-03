import AppKit
import SwiftUI
import FormatWheelCore

extension OutputFormat {
    var symbol: String {
        switch self {
        case .png, .jpeg, .heic, .webp: return "photo"
        case .pdf: return "doc.richtext"
        case .m4a, .wav, .aiff, .mp3: return "waveform"
        case .mp4, .mov: return "film"
        case .txt: return "text.alignleft"
        case .rtf, .docx: return "doc.text"
        }
    }
}

/// One sector of the wheel: a target format, or the wrench that opens the tool panel.
enum WheelEntry: Hashable {
    case format(OutputFormat)
    case batch(BatchAction)
    case tools

    var title: String {
        switch self {
        case .format(let format): return format.title
        case .batch(let action): return action.title
        case .tools: return "工具"
        }
    }

    /// The wrench is always at 9 o'clock and the merge / join sector right after it (towards
    /// 10 o'clock), so they are in the same place on every wheel and can be found by feel.
    static func rotation(of entries: [WheelEntry]) -> Double {
        guard let tools = entries.firstIndex(of: .tools) else { return 0 }
        return WheelGeometry().rotation(pinning: tools, count: entries.count)
    }

    var symbol: String {
        switch self {
        case .format(let format): return format.symbol
        case .batch: return "rectangle.stack"
        case .tools: return "wrench.fill"
        }
    }
}

@MainActor
final class WheelState: ObservableObject {
    @Published var hovered: WheelEntry?
    @Published var entries: [WheelEntry] = []
}

/// A wheel-shaped drop target that appears under the pointer during a Shift-drag.
/// The panel is exactly the ring, so the pointer sits at the dead-zone center.
/// Dropping on the last sector, a wrench, opens the editor window instead of converting.
@MainActor
final class DropWheel {
    static let size: CGFloat = 236
    private let panel: NSPanel
    private let state = WheelState()
    private let dropView = DropView(frame: NSRect(x: 0, y: 0, width: size, height: size))
    var onDrop: (([URL], OutputFormat, NSPoint) -> Void)?
    var onBatch: (([URL], BatchAction, NSPoint) -> Void)?
    var onTools: (([URL], FileKind) -> Void)?

    init() {
        panel = NSPanel(contentRect: dropView.frame, styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .popUpMenu
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        let host = NSHostingView(rootView: WheelView(state: state))
        host.frame = dropView.bounds
        host.autoresizingMask = [.width, .height]
        dropView.addSubview(host)
        panel.contentView = dropView
        dropView.onHover = { [weak self] entry in self?.state.hovered = entry }
        dropView.onDrop = { [weak self] urls, entry in
            guard let self else { return }
            let kind = self.dropView.kind
            let center = NSPoint(x: self.panel.frame.midX, y: self.panel.frame.midY)
            self.hide()
            switch entry {
            case .format(let format): self.onDrop?(urls, format, center)
            case .batch(let action): self.onBatch?(urls, action, center)
            case .tools: self.onTools?(urls, kind)
            }
        }
    }

    func show(kind: FileKind, formats: [OutputFormat], batch: BatchAction?, hasTools: Bool,
              at pointer: NSPoint) {
        // Order: formats, the wrench, then merge / join. The wheel is rotated so the wrench is at 9 o'clock.
        let entries = formats.map(WheelEntry.format) + (hasTools ? [.tools] : [])
            + (batch.map { [WheelEntry.batch($0)] } ?? [])
        state.hovered = nil
        state.entries = entries
        dropView.kind = kind
        dropView.entries = entries
        let screen = NSScreen.screens.first { $0.frame.contains(pointer) } ?? NSScreen.main
        let bounds = screen?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let half = Self.size / 2
        let x = max(bounds.minX, min(pointer.x - half, bounds.maxX - Self.size))
        let y = max(bounds.minY, min(pointer.y - half, bounds.maxY - Self.size))
        panel.setFrameOrigin(NSPoint(x: x, y: y))
        panel.orderFrontRegardless()
    }

    func hide() {
        state.hovered = nil
        panel.orderOut(nil)
    }
}

private final class DropView: NSView {
    var kind: FileKind = .image
    var entries: [WheelEntry] = []
    var onHover: ((WheelEntry?) -> Void)?
    var onDrop: (([URL], WheelEntry) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { fatalError() }

    private func entry(for info: NSDraggingInfo) -> WheelEntry? {
        let p = convert(info.draggingLocation, from: nil)
        // SwiftUI geometry is top-left origin; AppKit's is bottom-left.
        return WheelGeometry().index(atX: Double(p.x - bounds.midX), y: Double(bounds.midY - p.y),
                                     count: entries.count, rotation: WheelEntry.rotation(of: entries)).map { entries[$0] }
    }

    private func files(in info: NSDraggingInfo) -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        let urls = (info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL]) ?? []
        return urls.filter { FileKind($0) == kind }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let target = entry(for: sender)
        onHover?(target)
        return target == nil ? [] : .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        let target = entry(for: sender)
        onHover?(target)
        return target == nil ? [] : .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) { onHover?(nil) }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { entry(for: sender) != nil }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let target = entry(for: sender) else { return false }
        let urls = files(in: sender)
        guard !urls.isEmpty else { return false }
        onDrop?(urls, target)
        return true
    }
}

struct WheelView: View {
    @ObservedObject var state: WheelState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false
    private let geometry = WheelGeometry()
    private let side = DropWheel.size

    var body: some View {
        ZStack {
            ring
            ForEach(Array(state.entries.enumerated()), id: \.element) { index, entry in
                sector(index: index, entry: entry)
            }
        }
        .frame(width: side, height: side)
        .scaleEffect(appeared ? 1 : 0.9)
        .opacity(appeared ? 1 : 0)
        .onAppear {
            withAnimation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.8)) { appeared = true }
        }
    }

    /// One piece of glass: Liquid Glass where available, system material otherwise.
    @ViewBuilder private var ring: some View {
        let d = geometry.outerRadius * 2
        if #available(macOS 26.0, *) {
            Circle().fill(.clear).frame(width: d, height: d).glassEffect(.regular, in: Circle())
        } else {
            NativeMaterial()
                .clipShape(Circle())
                .overlay(Circle().stroke(.white.opacity(0.18), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.18), radius: 14, y: 5)
                .frame(width: d, height: d)
        }
    }

    private func sector(index: Int, entry: WheelEntry) -> some View {
        let count = state.entries.count
        let selected = state.hovered == entry
        let rotation = WheelEntry.rotation(of: state.entries)
        let angle = geometry.centerAngle(index: index, count: count, rotation: rotation) * .pi / 180
        let radius = geometry.middleRadius
        return ZStack {
            if count > 1 {
                SpokeDivider(index: index, count: count, rotation: rotation)
                    .stroke(.primary.opacity(0.10), lineWidth: 0.5)
            }
            ZStack {
                RingSector(index: index, count: count, inset: 3, rotation: rotation).fill(Theme.accent)
                RingSector(index: index, count: count, inset: 3, rotation: rotation)
                    .stroke(Theme.accent, style: StrokeStyle(lineWidth: 6, lineJoin: .round))
            }
            .compositingGroup()
            .opacity(selected ? 0.9 : 0)
            VStack(spacing: 2) {
                // With many sectors the wheel is text-only, so labels stay readable.
                // The wrench always keeps its icon.
                if count <= 4 || entry == .tools {
                    Image(systemName: entry.symbol).font(.system(size: 14, weight: .regular))
                }
                if count <= 4 || entry != .tools {
                    Text(entry.title).font(.system(size: count <= 4 ? 10 : 10.5, weight: .semibold))
                }
            }
            .foregroundStyle(selected ? Color.white : Color.primary.opacity(0.85))
            .scaleEffect(selected ? 1.08 : 1)
            .position(x: side / 2 + CGFloat(cos(angle) * radius), y: side / 2 + CGFloat(sin(angle) * radius))
        }
        .frame(width: side, height: side)
        .animation(reduceMotion ? nil : .spring(response: 0.22, dampingFraction: 0.85), value: selected)
    }
}

/// A hairline between neighbouring sectors, so the ring reads as one piece.
private struct SpokeDivider: Shape {
    let index: Int
    let count: Int
    var rotation = 0.0

    func path(in rect: CGRect) -> Path {
        let g = WheelGeometry()
        let angle = (g.centerAngle(index: index, count: count, rotation: rotation) - 180 / Double(count)) * .pi / 180
        let c = CGPoint(x: rect.midX, y: rect.midY)
        var path = Path()
        path.move(to: CGPoint(x: c.x + cos(angle) * (g.innerRadius + 4), y: c.y + sin(angle) * (g.innerRadius + 4)))
        path.addLine(to: CGPoint(x: c.x + cos(angle) * (g.outerRadius - 4), y: c.y + sin(angle) * (g.outerRadius - 4)))
        return path
    }
}

private struct RingSector: Shape {
    let index: Int
    let count: Int
    let inset: Double
    var rotation = 0.0

    func path(in rect: CGRect) -> Path {
        let g = WheelGeometry()
        let center = CGPoint(x: rect.midX, y: rect.midY)
        // Pull every edge in by `inset`; the round-joined stroke adds it back as soft corners.
        let outer = g.outerRadius - inset, inner = g.innerRadius + inset
        let span = 360 / Double(count)
        let start = -90 - span / 2 + Double(index) * span + rotation
        let pad = inset / outer * 180 / .pi, padIn = inset / inner * 180 / .pi
        var path = Path()
        path.addArc(center: center, radius: outer, startAngle: .degrees(start + pad), endAngle: .degrees(start + span - pad), clockwise: false)
        path.addArc(center: center, radius: inner, startAngle: .degrees(start + span - padIn), endAngle: .degrees(start + padIn), clockwise: true)
        path.closeSubpath()
        return path
    }
}
