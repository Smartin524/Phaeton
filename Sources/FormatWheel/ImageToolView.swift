import AppKit
import FormatWheelCore
import SwiftUI

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

/// Runs the size estimate one at a time and only for the latest edit, so dragging the crop box
/// never piles up full-size encodes.
@MainActor
final class EstimateGate: ObservableObject {
    private var running = false
    private var latest: (session: ImageEditSession, edit: ImageEdit, deliver: (String) -> Void)?

    func request(_ session: ImageEditSession, _ edit: ImageEdit, deliver: @escaping (String) -> Void) {
        latest = (session, edit, deliver)
        guard !running else { return }
        running = true
        Task {
            while let job = latest {
                latest = nil
                let result = try? await Task.detached { try job.session.estimate(job.edit) }.value
                job.deliver(result.map { "约 \(formatBytes($0.bytes))（原 \(formatBytes(job.session.originalBytes))）" } ?? "")
            }
            running = false
        }
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
    @StateObject private var estimates = EstimateGate()

    private var isBatch: Bool { urls.count > 1 }

    /// PNG (and anything that falls back to PNG) is lossless, so compression does not apply.
    private var isLossy: Bool { ["jpg", "jpeg", "jpe", "heic", "heif"].contains(urls[0].pathExtension.lowercased()) }

    /// Nothing to save yet: no crop and no change of quality. (Re-saving an untouched picture would
    /// only produce a copy that is no smaller, often bigger.)
    private var isUnchanged: Bool {
        let cropped = !isBatch && crop != CGRect(x: 0, y: 0, width: 1, height: 1)
        let recompressed = isLossy && compression != Compression.all[0]
        return !cropped && !recompressed
    }

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
                Tabs(titles: ["裁切", "更多"], selection: $page)
                if page == 1 {
                    ImageMoreTools(urls: urls, perform: perform, close: close)
                } else {
                if isBatch {
                    Text("共 \(urls.count) 张：画质应用到全部，裁切仅支持单张。")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                } else {
                    PanelSection(caption: "比例") {
                        ChipGrid(columns: 3) {
                            ForEach(Aspect.all, id: \.self) { choice in
                                Chip(title: choice.title, selected: aspect == choice) { aspect = choice }
                            }
                        }
                    }
                    PanelSection(caption: "尺寸（像素）") {
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
                    PanelSection(caption: "画质") {
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
                if !isLossy {
                    Text("PNG 等无损格式没有画质选项，裁切后的文件可能比原文件大。")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                }
            } footer: {
                if page == 1 {
                    HStack { Spacer(); Button("关闭", action: close).keyboardShortcut(.cancelAction).buttonStyle(PanelButtonStyle()) }
                } else {
                HStack(spacing: 8) {
                    Button("重置") {
                        aspect = Aspect.all[0]
                        crop = CGRect(x: 0, y: 0, width: 1, height: 1)
                        compression = Compression.all[0]
                    }
                    .buttonStyle(.plain).foregroundStyle(.secondary).font(.system(size: 12))
                    .opacity(isBatch ? 0 : 1)
                    Spacer(minLength: 4)
                    Button("取消", action: close).keyboardShortcut(.cancelAction).buttonStyle(PanelButtonStyle())
                    Button("保存", action: save).keyboardShortcut(.defaultAction)
                        .buttonStyle(PanelButtonStyle(prominent: true)).disabled(session == nil || isUnchanged)
                }
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
            estimates.request(session, makeEdit()) { info = $0 }
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
        let service = ConversionService()
        perform("处理图片") { source, _ in try await service.saveImageEdit(source: source, edit: edit) }
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

