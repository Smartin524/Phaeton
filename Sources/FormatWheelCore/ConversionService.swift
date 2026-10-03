#if os(macOS)
import CoreGraphics
import Foundation

/// Picks the engine by the kind of the source file.
public struct ConversionService: Sendable {
    public init() {}

    /// Runs synchronous work off the caller's executor. Unlike a bare `Task.detached`, cancelling
    /// the caller cancels the work too; the work checks for it (`Task.checkCancellation()`) before
    /// it writes anything, so a cancelled job leaves no output behind.
    private static func detached<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        let task = Task.detached(operation: work)
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    // MARK: Batch and extra tools

    public func batch(_ action: BatchAction, sources: [URL],
                      progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> URL {
        switch action {
        case .mergeImagesToPDF:
            return try await Self.detached { try PDFTools.mergeImages(sources) }
        case .mergePDFs:
            return try await Self.detached { try PDFTools.mergePDFs(sources) }
        case .joinVideos:
            return try await MediaConverter().join(sources, video: true, progress: progress)
        case .joinAudio:
            return try await MediaConverter().join(sources, video: false, progress: progress)
        }
    }

    public func extractPages(source: URL, pages: String) async throws -> URL {
        try await Self.detached { try PDFTools.extract(source: source, pages: pages) }
    }

    public func splitPDF(source: URL) async throws -> URL {
        try await Self.detached { try PDFTools.splitAll(source: source) }
    }

    /// The main subject of a picture on a transparent background, as PNG.
    public func removeBackground(source: URL) async throws -> URL {
        try await Self.detached {
            try ImageConverter().render(source: source, format: .png, suffix: " 去背景") { image in
                try VisionTools.removeBackground(from: image)
            }
        }
    }

    /// A copy without EXIF, GPS or other metadata (the picture is re-encoded).
    public func stripMetadata(source: URL) async throws -> URL {
        try await Self.detached {
            try ImageConverter().render(source: source, format: Self.sameFormat(as: source), suffix: " 无元数据", quality: 0.97)
        }
    }

    /// A JPEG of at most `bytes`: quality first, then a smaller picture if quality is not enough.
    /// The quality is searched on a downsized copy (cheap, even for 48-megapixel photos) and then
    /// confirmed, and nudged down if needed, on the real picture.
    public func compressImage(source: URL, toBytes bytes: Int) async throws -> URL {
        let original = (try? source.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? Int.max
        guard bytes > 0, bytes < original else { throw ConversionError.alreadySmall }
        return try await Self.detached {
            let converter = ImageConverter()
            let full = try converter.decodeStillImage(source)

            /// The best JPEG quality in 0.2…0.95 for `image` within `limit` bytes, or nil if even 0.2 is too big.
            func quality(for image: CGImage, limit: Int) throws -> Double? {
                var low = 0.2, high = 0.95
                if try converter.encodedSize(of: image, format: .jpeg, quality: low) > limit { return nil }
                for _ in 0..<7 {
                    try Task.checkCancellation()
                    let middle = (low + high) / 2
                    if try converter.encodedSize(of: image, format: .jpeg, quality: middle) <= limit { low = middle } else { high = middle }
                }
                return low
            }

            var scale = 1.0
            while scale >= 0.2 {
                try Task.checkCancellation()
                let image = scale < 0.999 ? try ImageOps.scaled(full, by: scale) : full
                let pixels = Double(image.width * image.height)
                let probeScale = pixels > 4_000_000 ? (4_000_000 / pixels).squareRoot() : 1
                let probe = probeScale < 0.999 ? try ImageOps.scaled(image, by: probeScale) : image
                let share = Double(probe.width * probe.height) / pixels
                if var q = try quality(for: probe, limit: Int(Double(bytes) * share)) {
                    for _ in 0..<5 {
                        try Task.checkCancellation()
                        if try converter.encodedSize(of: image, format: .jpeg, quality: q) <= bytes {
                            let chosen = (scale: scale, quality: q)
                            return try converter.render(source: source, format: .jpeg, suffix: " 压缩", quality: chosen.quality) { picture in
                                chosen.scale < 0.999 ? try ImageOps.scaled(picture, by: chosen.scale) : picture
                            }
                        }
                        q = max(0.2, q * 0.92)
                    }
                }
                scale *= 0.85
            }
            throw ConversionError.exportFailed("无法压缩到这个大小")
        }
    }

    /// Saves the picture as edited in the image editor (crop, resize, quality).
    public func saveImageEdit(source: URL, edit: ImageEdit) async throws -> URL {
        try await Self.detached { try ImageEditSession.save(source: source, edit: edit) }
    }

    public func trimVideo(source: URL, start: Double, end: Double,
                          progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> URL {
        try await MediaConverter().trim(source: source, start: start, end: end, progress: progress)
    }

    public func extractFrame(source: URL, at seconds: Double) async throws -> URL {
        try await MediaConverter.extractFrame(source: source, at: seconds)
    }

    public func trimAudio(source: URL, start: Double, end: Double, fadeIn: Double, fadeOut: Double,
                          progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> URL {
        try await MediaConverter().trimAudio(source: source, start: start, end: end, fadeIn: fadeIn,
                                             fadeOut: fadeOut, progress: progress)
    }

    public func compressVideo(source: URL, height: Int,
                              progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> URL {
        try await MediaConverter().compress(source: source, height: height, progress: progress)
    }

    /// Peak levels of an audio or video file for drawing a waveform.
    public func waveform(source: URL, buckets: Int) async -> [Float] {
        await MediaConverter.waveform(source: source, buckets: buckets)
    }

    /// A rough size for the compressed video, from the export session's own estimate.
    public func estimateCompressedBytes(source: URL, height: Int) async -> Int? {
        await MediaConverter().estimateCompressedBytes(source: source, height: height)
    }

    /// Checks a page-range string such as "1-3,5" against a page count, with the same rules the
    /// extraction uses.
    public func validatePages(_ text: String, pageCount: Int) throws {
        _ = try PDFTools.parsePages(text, pageCount: pageCount)
    }

    public func muteVideo(source: URL, progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> URL {
        try await MediaConverter().mute(source: source, progress: progress)
    }

    public func changeSpeed(source: URL, factor: Double,
                            progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> URL {
        try await MediaConverter().changeSpeed(source: source, factor: factor, progress: progress)
    }

    public func compressVideo(source: URL, toBytes bytes: Int,
                              progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> URL {
        try await MediaConverter().compress(source: source, toBytes: bytes, progress: progress)
    }

    public func recognizeText(source: URL) async throws -> String {
        try await Self.detached {
            let text = try VisionTools.recognizeText(in: ImageConverter().decodeStillImage(source))
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ConversionError.noTextFound }
            return text
        }
    }

    public func readQRCodes(source: URL) async throws -> [String] {
        try await Self.detached { try VisionTools.qrPayloads(in: ImageConverter().decodeStillImage(source)) }
    }

    /// Keep PNG, JPEG and HEIC as they are; anything else (WebP, SVG…) becomes PNG.
    static func sameFormat(as source: URL) -> OutputFormat {
        switch source.pathExtension.lowercased() {
        case "jpg", "jpeg", "jpe": return .jpeg
        case "heic", "heif": return .heic
        default: return .png
        }
    }

    public func convert(source: URL, to format: OutputFormat,
                        progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> URL {
        guard let kind = FileKind(source) else { throw ConversionError.unsupportedFormat }
        switch kind {
        case .image where format == .txt:
            let text = try await recognizeText(source: source)
            let temporary = OutputPublisher.temporaryURL(nextTo: source, fileExtension: "txt")
            do {
                try Data(text.utf8).write(to: temporary, options: .withoutOverwriting)
                return try OutputPublisher.publish(temporary, nextTo: source, fileExtension: "txt")
            } catch {
                OutputPublisher.discard(temporary)
                throw error
            }
        case .image where format == .webp:
            let png = OutputPublisher.temporaryURL(nextTo: source, fileExtension: "png")
            defer { OutputPublisher.discard(png) }
            try await Self.detached { try ImageConverter().writeIntermediatePNG(source: source, to: png) }
            return try await ExternalTools.convert(mode: "webp", input: png, nextTo: source, format: .webp)
        case .image:
            return try await Self.detached { try ImageConverter().convert(source: source, to: format) }
        case .audio, .video:
            return try await MediaConverter().convert(source: source, to: format, progress: progress)
        case .document:
            return try await DocumentConverter().convert(source: source, to: format)
        }
    }
}
#endif
