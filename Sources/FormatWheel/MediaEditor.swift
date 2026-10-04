import AppKit
import AVFoundation
import AVKit
import FormatWheelCore
import SwiftUI

// Video editor window and the pieces it shares with the audio editor (player model, timeline).

/// State of the video editor: the player, the playhead, the chosen segment and the thumbnails.
@MainActor
final class MediaEditorModel: ObservableObject {
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
        peaks = await ConversionService().waveform(source: url, buckets: 220)
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
struct TrimTimeline: View {
    @ObservedObject var model: MediaEditorModel
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
                grip(systemName: "chevron.compact.left", height: height, left: true).offset(x: sx - 14)
                grip(systemName: "chevron.compact.right", height: height, left: false).offset(x: ex)
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

    /// A handle joined to the rails: round on the outside, square on the inside, so handle and
    /// rails read as one frame. (A 20 pt rounded rectangle cut to 14 pt hides the inner corners.)
    private func grip(systemName: String, height: CGFloat, left: Bool) -> some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Theme.accent)
            .frame(width: 20, height: height)
            .frame(width: 14, height: height, alignment: left ? .leading : .trailing)
            .clipped()
            .overlay(Image(systemName: systemName).font(.system(size: 12, weight: .bold)).foregroundStyle(.white))
    }
}

struct VideoToolView: View {
    let urls: [URL]
    let perform: (String, @escaping ToolWork) -> Void
    let close: () -> Void
    let fit: (CGSize) -> Void

    @StateObject private var model: MediaEditorModel
    @State private var page = 0

    private var isBatch: Bool { urls.count > 1 }

    init(urls: [URL], perform: @escaping (String, @escaping ToolWork) -> Void,
         close: @escaping () -> Void, fit: @escaping (CGSize) -> Void) {
        self.urls = urls
        self.perform = perform
        self.close = close
        self.fit = fit
        _model = StateObject(wrappedValue: MediaEditorModel(url: urls[0]))
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 10) {
                PlayerSurface(player: model.player)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .onTapGesture { model.togglePlay() }
                if !isBatch {
                    TrimTimeline(model: model).frame(height: 44).padding(.vertical, 4)
                }
                Text(isBatch ? "共 \(urls.count) 个视频，预览第一个" : model.details)
                    .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            .padding(.top, ToolWindows.titleBarClearance).padding(.horizontal, 12).padding(.bottom, 12)
            SidePanel {
                if !isBatch {
                    Tabs(titles: ["剪辑", "更多"], selection: $page)
                }
                if page == 1 || isBatch {
                    VideoMoreTools(urls: urls, perform: perform, close: close)
                } else {
                    PanelSection(caption: "片段") {
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
                    PanelSection(caption: "当前画面") {
                        WideButton(title: "保存为图片", action: saveFrame)
                    }
                }
            } footer: {
                HStack {
                    Spacer()
                    Button("关闭", action: close).keyboardShortcut(.cancelAction).buttonStyle(PanelButtonStyle())
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
        let service = ConversionService()
        perform("剪切片段") { source, progress in
            try await service.trimVideo(source: source, start: start, end: end, progress: progress)
        }
        close()
    }

    /// Several frames can be taken in a row, so the window stays open.
    private func saveFrame() {
        let seconds = model.current
        let service = ConversionService()
        perform("保存画面") { source, _ in try await service.extractFrame(source: source, at: seconds) }
    }
}
