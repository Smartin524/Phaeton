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
        window.minSize = NSSize(width: Self.panelWidth + 220, height: 340)
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

func formatBytes(_ bytes: Int) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
}

// MARK: - Image

private struct Aspect: Hashable {
    let title: String
    let ratio: Double?
    static let all = [Aspect(title: "自由", ratio: nil), Aspect(title: "1:1", ratio: 1), Aspect(title: "4:3", ratio: 4.0 / 3),
                      Aspect(title: "16:9", ratio: 16.0 / 9), Aspect(title: "3:4", ratio: 0.75),
                      Aspect(title: "9:16", ratio: 9.0 / 16)]
}

private struct Compression: Hashable {
    let title: String
    let quality: Double
    static let all = [Compression(title: "原画质", quality: 0.95), Compression(title: "标准", quality: 0.8),
                      Compression(title: "较小", quality: 0.6)]
}

private struct EditKey: Hashable {
    let crop: CGRect
    let compression: Compression
    let loaded: Bool
}

/// A pill button, filling its grid cell: accent fill when selected.
struct Chip: View {
    let title: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 5)
                .foregroundStyle(selected ? Color.white : Color.primary.opacity(0.85))
                .background(Capsule().fill(selected ? Theme.accent : Color.primary.opacity(0.08)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

struct ChipGrid<Content: View>: View {
    let columns: Int
    @ViewBuilder let content: Content

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: columns), spacing: 6) { content }
    }
}

/// A quiet caption above a group of controls.
struct Section<Content: View>: View {
    let caption: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(caption).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            content
        }
    }
}

/// A push button that fills the panel's width.
struct WideButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) { Text(title).frame(maxWidth: .infinity) }
            .controlSize(.regular)
    }
}

/// The fixed-width panel on the right: controls on top, buttons at the bottom.
struct SidePanel<Content: View, Footer: View>: View {
    @ViewBuilder let content: Content
    @ViewBuilder let footer: Footer

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            content
            Spacer(minLength: 8)
            footer
        }
        .padding(16)
        .padding(.top, 12)
        .frame(width: ToolWindows.panelWidth)
        .frame(maxHeight: .infinity)
        .background(Color.primary.opacity(0.05))
        .overlay(alignment: .leading) { Rectangle().fill(Color.primary.opacity(0.10)).frame(width: 0.5) }
    }
}

struct ImageToolView: View {
    let urls: [URL]
    let perform: (String, @escaping ToolWork) -> Void
    let close: () -> Void
    let fit: (CGSize) -> Void

    @State private var session: ImageEditSession?
    @State private var loadError: String?
    @State private var crop = CGRect(x: 0, y: 0, width: 1, height: 1)
    @State private var aspect = Aspect.all[0]
    @State private var compression = Compression.all[0]
    @State private var info = ""
    @State private var page = 0

    private var isBatch: Bool { urls.count > 1 }

    /// PNG (and anything that falls back to PNG) is lossless, so compression does not apply.
    private var isLossy: Bool { ["jpg", "jpeg", "jpe", "heic", "heif"].contains(urls[0].pathExtension.lowercased()) }

    private func makeEdit() -> ImageEdit {
        ImageEdit(crop: isBatch ? nil : crop, scale: 1, format: nil, quality: compression.quality)
    }

    private var pixelSize: CGSize { session?.pixelSize ?? CGSize(width: 1, height: 1) }

    /// Width / height of the crop in pixels, editable. Changing one keeps a fixed ratio.
    private func pixels(horizontal: Bool) -> Binding<Int> {
        Binding(
            get: { Int((horizontal ? crop.width * pixelSize.width : crop.height * pixelSize.height).rounded()) },
            set: { value in
                guard session != nil else { return }
                let limit = horizontal ? Int(pixelSize.width) : Int(pixelSize.height)
                let clamped = max(8, min(value, limit))
                var r = crop
                if horizontal { r.size.width = Double(clamped) / pixelSize.width }
                else { r.size.height = Double(clamped) / pixelSize.height }
                if let ratio = aspect.ratio {   // keep the chosen ratio, shrinking the other side if needed
                    let wpx = r.width * pixelSize.width, hpx = r.height * pixelSize.height
                    if horizontal { r.size.height = min(1, wpx / ratio / pixelSize.height) }
                    else { r.size.width = min(1, hpx * ratio / pixelSize.width) }
                }
                r.origin.x = min(max(0, r.origin.x), 1 - r.width)
                r.origin.y = min(max(0, r.origin.y), 1 - r.height)
                crop = r
            }
        )
    }

    var body: some View {
        HStack(spacing: 0) {
            canvas.padding(.top, 12).padding(.horizontal, 12).padding(.bottom, 12)
            SidePanel {
                Picker("", selection: $page) {
                    Text("裁切").tag(0)
                    Text("更多").tag(1)
                }
                .pickerStyle(.segmented).labelsHidden()
                if page == 1 {
                    ImageMoreTools(urls: urls, perform: perform, close: close)
                } else {
                if isBatch {
                    Text("共 \(urls.count) 张：画质应用到全部，裁切仅支持单张。")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                } else {
                    Section(caption: "比例") {
                        ChipGrid(columns: 3) {
                            ForEach(Aspect.all, id: \.self) { choice in
                                Chip(title: choice.title, selected: aspect == choice) { aspect = choice }
                            }
                        }
                    }
                    Section(caption: "尺寸（像素）") {
                        HStack(spacing: 6) {
                            TextField("", value: pixels(horizontal: true), format: .number.grouping(.never))
                                .textFieldStyle(.roundedBorder).multilineTextAlignment(.center)
                            Text("×").foregroundStyle(.secondary)
                            TextField("", value: pixels(horizontal: false), format: .number.grouping(.never))
                                .textFieldStyle(.roundedBorder).multilineTextAlignment(.center)
                        }
                    }
                }
                if isLossy {
                    Section(caption: "画质") {
                        ChipGrid(columns: 3) {
                            ForEach(Compression.all, id: \.self) { choice in
                                Chip(title: choice.title, selected: compression == choice) { compression = choice }
                            }
                        }
                    }
                }
                if !info.isEmpty {
                    Text(info).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                }
            } footer: {
                HStack(spacing: 8) {
                    Button("重置") {
                        aspect = Aspect.all[0]
                        crop = CGRect(x: 0, y: 0, width: 1, height: 1)
                        compression = Compression.all[0]
                    }
                    .buttonStyle(.plain).foregroundStyle(.secondary).font(.system(size: 12))
                    .opacity(isBatch ? 0 : 1)
                    Spacer(minLength: 4)
                    Button("取消", action: close).keyboardShortcut(.cancelAction)
                    Button("保存", action: save).keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent).disabled(session == nil)
                }
            }
        }
        .ignoresSafeArea()
        .tint(Theme.accent)
        .task {
            let url = urls[0]
            do {
                let loaded = try await Task.detached { try ImageEditSession(source: url) }.value
                session = loaded
                fit(loaded.pixelSize)
            } catch { loadError = error.localizedDescription }
        }
        .task(id: EditKey(crop: crop, compression: compression, loaded: session != nil)) {
            guard let session else { return }
            try? await Task.sleep(nanoseconds: 250_000_000)
            if Task.isCancelled { return }
            let edit = makeEdit()
            let result = try? await Task.detached { try session.estimate(edit) }.value
            if Task.isCancelled { return }
            guard let result else { info = ""; return }
            info = "约 \(formatBytes(result.bytes))（原 \(formatBytes(session.originalBytes))）"
        }
        .onChange(of: aspect) { choice in
            guard let session else { return }
            crop = Self.centeredCrop(aspect: choice.ratio, pixelSize: session.pixelSize)
        }
    }

    @ViewBuilder private var canvas: some View {
        if let session {
            if isBatch {
                Image(decorative: session.preview, scale: 1).resizable().scaledToFit()
            } else {
                CropEditor(image: session.preview, pixelSize: session.pixelSize, crop: $crop, aspect: aspect.ratio)
            }
        } else if let loadError {
            Text(loadError).foregroundStyle(.secondary).frame(maxHeight: .infinity)
        } else {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func save() {
        let edit = makeEdit()
        perform("处理图片") { source, _ in
            try await Task.detached { try ImageEditSession.save(source: source, edit: edit) }.value
        }
        close()
    }

    private static func centeredCrop(aspect: Double?, pixelSize: CGSize) -> CGRect {
        guard let aspect else { return CGRect(x: 0, y: 0, width: 1, height: 1) }
        let imageAspect = pixelSize.width / pixelSize.height
        var w = 1.0, h = 1.0
        if aspect >= imageAspect { h = imageAspect / aspect } else { w = aspect / imageAspect }
        return CGRect(x: (1 - w) / 2, y: (1 - h) / 2, width: w, height: h)
    }
}

/// The image with a draggable crop rectangle. `crop` is normalized to the image.
private struct CropEditor: View {
    let image: CGImage
    let pixelSize: CGSize
    @Binding var crop: CGRect
    let aspect: Double?

    private enum Mode { case move, corner(Int), edge(Int) }   // corners TL TR BR BL; edges top right bottom left
    @State private var mode: Mode?
    @State private var startRect = CGRect.zero
    private let minSide: CGFloat = 28

    var body: some View {
        GeometryReader { geo in
            let fit = Self.fit(pixelSize, in: geo.size)
            let r = rect(in: fit)
            ZStack(alignment: .topLeading) {
                Image(decorative: image, scale: 1).resizable().interpolation(.high)
                    .frame(width: fit.width, height: fit.height).offset(x: fit.minX, y: fit.minY)
                Path { path in path.addRect(fit); path.addRect(r) }
                    .fill(Color.black.opacity(0.5), style: FillStyle(eoFill: true))
                Path { path in
                    for i in 1...2 {
                        let x = r.minX + r.width * CGFloat(i) / 3, y = r.minY + r.height * CGFloat(i) / 3
                        path.move(to: CGPoint(x: x, y: r.minY)); path.addLine(to: CGPoint(x: x, y: r.maxY))
                        path.move(to: CGPoint(x: r.minX, y: y)); path.addLine(to: CGPoint(x: r.maxX, y: y))
                    }
                }
                .stroke(Color.white.opacity(0.35), lineWidth: 0.5)
                Rectangle().stroke(Theme.accent, lineWidth: 1.5)
                    .frame(width: r.width, height: r.height).offset(x: r.minX, y: r.minY)
                // Dots on the corners, short bars in the middle of each edge. With a fixed ratio
                // only the corners resize, so the bars are hidden.
                ForEach(0..<4, id: \.self) { i in
                    let p = corner(i, of: r)
                    Circle().fill(Theme.accent)
                        .overlay(Circle().stroke(Color.white, lineWidth: 1.5))
                        .frame(width: 11, height: 11).offset(x: p.x - 5.5, y: p.y - 5.5)
                }
                if aspect == nil {
                    ForEach(0..<4, id: \.self) { i in
                        let horizontal = i % 2 == 0
                        let p = [CGPoint(x: r.midX, y: r.minY), CGPoint(x: r.maxX, y: r.midY),
                                 CGPoint(x: r.midX, y: r.maxY), CGPoint(x: r.minX, y: r.midY)][i]
                        let size = horizontal ? CGSize(width: 22, height: 6) : CGSize(width: 6, height: 22)
                        Capsule().fill(Theme.accent)
                            .overlay(Capsule().stroke(Color.white, lineWidth: 1.5))
                            .frame(width: size.width, height: size.height)
                            .offset(x: p.x - size.width / 2, y: p.y - size.height / 2)
                    }
                }
                Color.clear.contentShape(Rectangle()).gesture(drag(fit))
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let point): Self.cursor(for: mode ?? hit(point, r)).set()
                        case .ended: NSCursor.arrow.set()
                        }
                    }
            }
        }
    }

    private static func fit(_ pixels: CGSize, in size: CGSize) -> CGRect {
        let available = CGSize(width: max(1, size.width - 12), height: max(1, size.height - 12))
        let scale = min(available.width / pixels.width, available.height / pixels.height)
        let w = pixels.width * scale, h = pixels.height * scale
        return CGRect(x: (size.width - w) / 2, y: (size.height - h) / 2, width: w, height: h)
    }

    private func rect(in fit: CGRect) -> CGRect {
        CGRect(x: fit.minX + crop.minX * fit.width, y: fit.minY + crop.minY * fit.height,
               width: crop.width * fit.width, height: crop.height * fit.height)
    }

    private func corner(_ i: Int, of r: CGRect) -> CGPoint {
        [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY),
         CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY)][i]
    }

    /// Resize cursors on the handles, an open hand inside the box, the arrow elsewhere.
    private static func cursor(for mode: Mode?) -> NSCursor {
        switch mode {
        case .corner(let i):
            if #available(macOS 15.0, *) {
                let positions: [NSCursor.FrameResizePosition] = [.topLeft, .topRight, .bottomRight, .bottomLeft]
                return NSCursor.frameResize(position: positions[i], directions: .all)
            }
            return .crosshair
        case .edge(let i): return i % 2 == 0 ? .resizeUpDown : .resizeLeftRight
        case .move: return .openHand
        case nil: return .arrow
        }
    }

    private func hit(_ p: CGPoint, _ r: CGRect) -> Mode? {
        for i in 0..<4 where hypot(p.x - corner(i, of: r).x, p.y - corner(i, of: r).y) < 18 { return .corner(i) }
        if aspect == nil {   // with a fixed ratio only the corners resize
            let withinX = p.x >= r.minX && p.x <= r.maxX, withinY = p.y >= r.minY && p.y <= r.maxY
            if abs(p.y - r.minY) < 9 && withinX { return .edge(0) }
            if abs(p.x - r.maxX) < 9 && withinY { return .edge(1) }
            if abs(p.y - r.maxY) < 9 && withinX { return .edge(2) }
            if abs(p.x - r.minX) < 9 && withinY { return .edge(3) }
        }
        return r.contains(p) ? .move : nil
    }

    private func drag(_ fit: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if mode == nil {
                    startRect = rect(in: fit)
                    mode = hit(value.startLocation, startRect)
                }
                guard let mode else { return }
                crop = normalized(updated(mode, by: value.translation, in: fit), in: fit)
            }
            .onEnded { _ in mode = nil }
    }

    private func updated(_ mode: Mode, by t: CGSize, in fit: CGRect) -> CGRect {
        var r = startRect
        switch mode {
        case .move:
            r.origin.x = min(max(fit.minX, startRect.minX + t.width), fit.maxX - r.width)
            r.origin.y = min(max(fit.minY, startRect.minY + t.height), fit.maxY - r.height)
        case .corner(let i):
            let anchor = corner((i + 2) % 4, of: startRect)
            var moving = corner(i, of: startRect)
            moving.x = min(max(fit.minX, moving.x + t.width), fit.maxX)
            moving.y = min(max(fit.minY, moving.y + t.height), fit.maxY)
            let sx: CGFloat = moving.x >= anchor.x ? 1 : -1, sy: CGFloat = moving.y >= anchor.y ? 1 : -1
            if let aspect {
                let maxW = min(sx > 0 ? fit.maxX - anchor.x : anchor.x - fit.minX,
                               (sy > 0 ? fit.maxY - anchor.y : anchor.y - fit.minY) * aspect)
                let width = min(max(abs(moving.x - anchor.x), minSide), maxW)
                let height = width / aspect
                r = CGRect(x: sx > 0 ? anchor.x : anchor.x - width, y: sy > 0 ? anchor.y : anchor.y - height,
                           width: width, height: height)
            } else {
                var w = abs(moving.x - anchor.x), h = abs(moving.y - anchor.y)
                w = max(w, minSide); h = max(h, minSide)
                r = CGRect(x: sx > 0 ? anchor.x : anchor.x - w, y: sy > 0 ? anchor.y : anchor.y - h, width: w, height: h)
            }
        case .edge(let i):
            switch i {
            case 0: let y = min(max(fit.minY, startRect.minY + t.height), startRect.maxY - minSide)
                r = CGRect(x: r.minX, y: y, width: r.width, height: startRect.maxY - y)
            case 1: let x = max(min(fit.maxX, startRect.maxX + t.width), startRect.minX + minSide)
                r.size.width = x - startRect.minX
            case 2: let y = max(min(fit.maxY, startRect.maxY + t.height), startRect.minY + minSide)
                r.size.height = y - startRect.minY
            default: let x = min(max(fit.minX, startRect.minX + t.width), startRect.maxX - minSide)
                r = CGRect(x: x, y: r.minY, width: startRect.maxX - x, height: r.height)
            }
        }
        return r
    }

    private func normalized(_ r: CGRect, in fit: CGRect) -> CGRect {
        let x = (r.minX - fit.minX) / fit.width, y = (r.minY - fit.minY) / fit.height
        return CGRect(x: min(max(0, x), 1), y: min(max(0, y), 1),
                      width: min(1, r.width / fit.width), height: min(1, r.height / fit.height))
    }
}

// MARK: - Video

private struct VideoTarget: Hashable {
    let title: String
    let height: Int
    static let all = [VideoTarget(title: "1080p", height: 1080), VideoTarget(title: "720p", height: 720),
                      VideoTarget(title: "480p", height: 480), VideoTarget(title: "原尺寸", height: 0)]
}

func clock(_ seconds: Double) -> String {
    let tenths = Int((max(0, seconds) * 10).rounded())
    return String(format: "%d:%02d.%d", tenths / 600, (tenths / 10) % 60, tenths % 10)
}

/// State of the video editor: the player, the playhead, the chosen segment and the thumbnails.
@MainActor
final class VideoEditorModel: ObservableObject {
    let url: URL
    let player: AVPlayer
    @Published var duration = 0.0
    @Published var start = 0.0
    @Published var end = 0.0
    @Published var current = 0.0
    @Published var playing = false
    @Published var thumbnails: [CGImage?] = []
    @Published var peaks: [Float] = []
    @Published var details = ""
    private var observer: Any?
    static let thumbnailCount = 14

    init(url: URL) {
        self.url = url
        player = AVPlayer(url: url)
        observer = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.05, preferredTimescale: 600),
                                                  queue: .main) { [weak self] time in
            MainActor.assumeIsolated { self?.tick(time.seconds) }
        }
    }

    func shutdown() {
        player.pause()
        if let observer { player.removeTimeObserver(observer) }
        observer = nil
    }

    private func tick(_ seconds: Double) {
        guard seconds.isFinite else { return }
        current = seconds
        playing = player.timeControlStatus != .paused
        // Playing stops at the end of the chosen segment.
        if playing, end > start, seconds >= end { player.pause(); seek(to: start) }
    }

    func seek(to seconds: Double) {
        let t = min(max(0, seconds), duration)
        current = t
        player.seek(to: CMTime(seconds: t, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func togglePlay() {
        if player.timeControlStatus == .paused {
            if current >= end - 0.05 || current < start { seek(to: start) }
            player.play()
        } else {
            player.pause()
        }
    }

    /// Audio files: duration, size and the waveform to draw in the timeline.
    func loadAudio() async {
        let asset = AVURLAsset(url: url)
        let total = (try? await asset.load(.duration).seconds) ?? 0
        guard total > 0 else { return }
        duration = total
        end = total
        let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        details = formatBytes(bytes) + " · " + clock(total)
        peaks = await MediaConverter.waveform(source: url, buckets: 220)
    }

    func load() async -> CGSize? {
        let asset = AVURLAsset(url: url)
        let total = (try? await asset.load(.duration).seconds) ?? 0
        guard total > 0 else { return nil }
        duration = total
        end = total
        let size = try? await asset.loadTracks(withMediaType: .video).first?.load(.naturalSize)
        let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        var text = formatBytes(bytes)
        if let size { text += " · \(Int(size.width))×\(Int(size.height))" }
        details = text + " · " + clock(total)
        thumbnails = Array(repeating: nil, count: Self.thumbnailCount)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 240, height: 240)
        let step = total / Double(Self.thumbnailCount)
        for index in 0..<Self.thumbnailCount {
            let time = CMTime(seconds: min(total - 0.05, total * (Double(index) + 0.5) / Double(Self.thumbnailCount)),
                              preferredTimescale: 600)
            // Close to the requested moment first; if that fails, accept the nearest frame; if even that
            // fails, repeat the previous thumbnail so the strip never has a hole.
            var image: CGImage?
            for tolerance in [CMTime(seconds: step / 2, preferredTimescale: 600), CMTime.positiveInfinity] {
                generator.requestedTimeToleranceBefore = tolerance
                generator.requestedTimeToleranceAfter = tolerance
                image = try? await generator.image(at: time).image
                if image != nil { break }
            }
            thumbnails[index] = image ?? (index > 0 ? thumbnails[index - 1] : nil)
        }
        return size
    }
}

/// The video itself, without the system transport bar (the timeline below replaces it).
private struct PlayerSurface: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .none
        view.player = player
        view.videoGravity = .resizeAspect
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) { view.player = player }
}

/// Thumbnails with a movable start and end, and a playhead you can drag.
/// The strip is inset so the grips have room at both ends, like QuickTime's trim bar.
private struct Timeline: View {
    @ObservedObject var model: VideoEditorModel
    private enum Grab { case start, end, scrub }
    @State private var grab: Grab?
    private let inset: CGFloat = 16      // room for a grip on each side
    private let rail: CGFloat = 3

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width, height = geo.size.height
            let span = max(1, width - inset * 2)
            let x = { (t: Double) -> CGFloat in inset + (model.duration > 0 ? CGFloat(t / model.duration) * span : 0) }
            let sx = x(model.start), ex = x(model.end)
            ZStack(alignment: .topLeading) {
                // thumbnails, or the waveform for audio
                if !model.peaks.isEmpty {
                    Canvas { context, size in
                        let bars = model.peaks.count
                        let step = size.width / CGFloat(bars)
                        for (i, peak) in model.peaks.enumerated() {
                            let h = max(3, CGFloat(peak) * size.height * 0.86)
                            let rect = CGRect(x: CGFloat(i) * step + step * 0.18, y: (size.height - h) / 2,
                                              width: max(1, step * 0.64), height: h)
                            context.fill(Path(roundedRect: rect, cornerRadius: rect.width / 2), with: .color(.primary.opacity(0.6)))
                        }
                    }
                    .frame(width: span, height: height)
                    .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Color.primary.opacity(0.07)))
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                    .offset(x: inset)
                }
                HStack(spacing: 0) {
                    ForEach(0..<model.thumbnails.count, id: \.self) { index in
                        Group {
                            if let image = model.thumbnails[index] {
                                Image(decorative: image, scale: 1).resizable().scaledToFill()
                            } else {
                                Color.primary.opacity(0.08)
                            }
                        }
                        .frame(width: span / CGFloat(max(1, model.thumbnails.count)), height: height)
                        .clipped()
                    }
                }
                .frame(width: span, height: model.peaks.isEmpty ? height : 0)
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                .offset(x: inset)
                // what is cut away
                Rectangle().fill(Color.black.opacity(0.55)).frame(width: max(0, sx - inset), height: height).offset(x: inset)
                Rectangle().fill(Color.black.opacity(0.55)).frame(width: max(0, width - inset - ex), height: height).offset(x: ex)
                // rails along the kept part
                Rectangle().fill(Theme.accent).frame(width: max(0, ex - sx), height: rail).offset(x: sx)
                Rectangle().fill(Theme.accent).frame(width: max(0, ex - sx), height: rail).offset(x: sx, y: height - rail)
                grip(systemName: "chevron.compact.left", height: height).offset(x: sx - 14)
                grip(systemName: "chevron.compact.right", height: height).offset(x: ex)
                // playhead
                Capsule().fill(Color.white).frame(width: 3, height: height + 6)
                    .shadow(color: .black.opacity(0.35), radius: 1.5)
                    .offset(x: x(model.current) - 1.5, y: -3)
                Color.clear.contentShape(Rectangle()).gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            let p = value.startLocation.x
                            if grab == nil {
                                let ds = abs(p - (sx - 7)), de = abs(p - (ex + 7))
                                if ds < 14 && ds <= de { grab = .start }
                                else if de < 14 { grab = .end }
                                else { grab = .scrub }
                            }
                            let t = Double(min(max(0, value.location.x - inset), span) / span) * model.duration
                            switch grab {
                            case .start: model.start = min(t, model.end - 0.1); model.seek(to: model.start)
                            case .end: model.end = max(t, model.start + 0.1); model.seek(to: model.end)
                            default: model.seek(to: t)
                            }
                        }
                        .onEnded { _ in grab = nil }
                )
            }
        }
    }

    /// A rounded handle just outside the kept part, with a chevron pointing at it.
    private func grip(systemName: String, height: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Theme.accent)
            .overlay(Image(systemName: systemName).font(.system(size: 12, weight: .bold)).foregroundStyle(.white))
            .frame(width: 14, height: height)
    }
}

struct VideoToolView: View {
    let urls: [URL]
    let perform: (String, @escaping ToolWork) -> Void
    let close: () -> Void
    let fit: (CGSize) -> Void

    @StateObject private var model: VideoEditorModel
    @State private var page = 0

    private var isBatch: Bool { urls.count > 1 }

    init(urls: [URL], perform: @escaping (String, @escaping ToolWork) -> Void,
         close: @escaping () -> Void, fit: @escaping (CGSize) -> Void) {
        self.urls = urls
        self.perform = perform
        self.close = close
        self.fit = fit
        _model = StateObject(wrappedValue: VideoEditorModel(url: urls[0]))
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 10) {
                PlayerSurface(player: model.player)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .onTapGesture { model.togglePlay() }
                if !isBatch {
                    Timeline(model: model).frame(height: 44).padding(.vertical, 4)
                }
                Text(isBatch ? "共 \(urls.count) 个视频，预览第一个" : model.details)
                    .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            .padding(.top, 12).padding(.horizontal, 12).padding(.bottom, 12)
            SidePanel {
                if !isBatch {
                    Picker("", selection: $page) {
                        Text("剪辑").tag(0)
                        Text("更多").tag(1)
                    }
                    .pickerStyle(.segmented).labelsHidden()
                }
                if page == 1 || isBatch {
                    VideoMoreTools(urls: urls, perform: perform, close: close)
                } else {
                    Section(caption: "片段 · 快速剪切，不重新编码") {
                        HStack {
                            Text(clock(model.start)).font(.system(size: 12).monospacedDigit())
                            Text("→").foregroundStyle(.secondary)
                            Text(clock(model.end)).font(.system(size: 12).monospacedDigit())
                            Spacer(minLength: 4)
                            Text(clock(model.end - model.start)).font(.system(size: 11).monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        HStack(spacing: 6) {
                            WideButton(title: "设为起点") { model.start = min(model.current, model.end - 0.1) }
                            WideButton(title: "设为终点") { model.end = max(model.current, model.start + 0.1) }
                        }
                        WideButton(title: "保存片段", action: saveSegment)
                    }
                    Section(caption: "当前画面") {
                        WideButton(title: "保存为图片", action: saveFrame)
                    }
                }
            } footer: {
                HStack {
                    Spacer()
                    Button("关闭", action: close).keyboardShortcut(.cancelAction)
                }
            }
        }
        .ignoresSafeArea()
        .tint(Theme.accent)
        .onDisappear { model.shutdown() }
        .task {
            if let size = await model.load() { fit(size) }
        }
    }

    private func saveSegment() {
        let start = model.start, end = model.end
        perform("剪切片段") { source, progress in
            try await MediaConverter().trim(source: source, start: start, end: end, progress: progress)
        }
        close()
    }

    /// Several frames can be taken in a row, so the window stays open.
    private func saveFrame() {
        let seconds = model.current
        perform("保存画面") { source, _ in try await MediaConverter.extractFrame(source: source, at: seconds) }
    }
}

// MARK: - Audio

struct AudioToolView: View {
    let urls: [URL]
    let perform: (String, @escaping ToolWork) -> Void
    let close: () -> Void

    @StateObject private var model: VideoEditorModel
    @State private var fadeIn = false
    @State private var fadeOut = false

    private var isBatch: Bool { urls.count > 1 }

    init(urls: [URL], perform: @escaping (String, @escaping ToolWork) -> Void, close: @escaping () -> Void) {
        self.urls = urls
        self.perform = perform
        self.close = close
        _model = StateObject(wrappedValue: VideoEditorModel(url: urls[0]))
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 14) {
                Spacer(minLength: 0)
                Text(clock(model.current))
                    .font(.system(size: 34, weight: .light, design: .rounded).monospacedDigit())
                    .foregroundStyle(.primary)
                if isBatch {
                    Text("音频剪辑一次只能处理一个文件，请只拖一个。").font(.callout).foregroundStyle(.secondary)
                } else {
                    Timeline(model: model).frame(height: 74)
                    Button { model.togglePlay() } label: {
                        Image(systemName: model.playing ? "pause.fill" : "play.fill")
                            .font(.system(size: 17, weight: .semibold)).frame(width: 44, height: 44)
                            .background(Circle().fill(Color.primary.opacity(0.09)))
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.space, modifiers: [])
                }
                Text(model.details).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12).padding(.vertical, 12)
            SidePanel {
                Section(caption: fadeIn || fadeOut ? "片段 · 有淡入淡出，将重新编码为 M4A" : "片段 · 快速剪切，不重新编码") {
                    HStack {
                        Text(clock(model.start)).font(.system(size: 12).monospacedDigit())
                        Text("→").foregroundStyle(.secondary)
                        Text(clock(model.end)).font(.system(size: 12).monospacedDigit())
                        Spacer(minLength: 4)
                        Text(clock(model.end - model.start)).font(.system(size: 11).monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    HStack(spacing: 6) {
                        WideButton(title: "设为起点") { model.start = min(model.current, model.end - 0.1) }
                        WideButton(title: "设为终点") { model.end = max(model.current, model.start + 0.1) }
                    }
                }
                Section(caption: "淡入淡出（各 1 秒）") {
                    HStack(spacing: 6) {
                        Chip(title: "淡入", selected: fadeIn) { fadeIn.toggle() }
                        Chip(title: "淡出", selected: fadeOut) { fadeOut.toggle() }
                    }
                }
                WideButton(title: "保存片段", action: save)
            } footer: {
                HStack {
                    Spacer()
                    Button("关闭", action: close).keyboardShortcut(.cancelAction)
                }
            }
            .disabled(isBatch)
        }
        .ignoresSafeArea()
        .tint(Theme.accent)
        .onDisappear { model.shutdown() }
        .task { await model.loadAudio() }
    }

    private func save() {
        let start = model.start, end = model.end
        let fi = fadeIn ? 1.0 : 0, fo = fadeOut ? 1.0 : 0
        perform("剪切音频") { source, progress in
            try await MediaConverter().trimAudio(source: source, start: start, end: end, fadeIn: fi, fadeOut: fo, progress: progress)
        }
        close()
    }
}
