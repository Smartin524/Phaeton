#if os(macOS)
import CoreGraphics
import Foundation

/// Picks the engine by the kind of the source file.
public struct ConversionService: Sendable {
    public init() {}

    public func apply(_ tool: ToolAction, to source: URL,
                      progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> URL {
        switch tool {
        case .compressVideo(let height):
            return try await MediaConverter().compress(source: source, height: height, progress: progress)
        case .compressImage:
            let original = (try? source.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? Int.max
            return try await Self.detached {
                try ImageConverter().render(source: source, format: .jpeg, suffix: tool.suffix, quality: 0.75,
                                            onlyIfSmallerThan: original) { image in
                    // Very large images are also brought down to 2560 px on the long side.
                    let longest = Double(max(image.width, image.height))
                    return longest > 2560 ? try ImageOps.scaled(image, by: 2560 / longest) : image
                }
            }
        case .halveImage:
            return try await Self.detached {
                try ImageConverter().render(source: source, format: Self.sameFormat(as: source), suffix: tool.suffix,
                                            quality: 0.92) { image in
                    try ImageOps.scaled(image, by: 0.5)
                }
            }
        case .cropImage(let width, let height):
            return try await Self.detached {
                try ImageConverter().render(source: source, format: Self.sameFormat(as: source), suffix: tool.suffix,
                                            quality: 0.92) { image in
                    try ImageOps.cropped(image, aspectWidth: width, aspectHeight: height)
                }
            }
        }
    }

    /// Runs synchronous image work off the caller's executor. Unlike a bare `Task.detached`,
    /// cancelling the caller cancels the work too; ImageConverter checks for it before writing.
    private static func detached<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        let task = Task.detached(operation: work)
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    // MARK: Batch and extra tools

    public func batch(_ action: BatchAction, sources: [URL],
                      progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> URL {
        switch action {
        case .mergeImagesToPDF:
            return try await Task.detached { try PDFTools.mergeImages(sources) }.value
        case .mergePDFs:
            return try await Task.detached { try PDFTools.mergePDFs(sources) }.value
        case .joinVideos:
            return try await MediaConverter().join(sources, video: true, progress: progress)
        case .joinAudio:
            return try await MediaConverter().join(sources, video: false, progress: progress)
        }
    }

    public func extractPages(source: URL, pages: String) async throws -> URL {
        try await Task.detached { try PDFTools.extract(source: source, pages: pages) }.value
    }

    public func splitPDF(source: URL) async throws -> URL {
        try await Task.detached { try PDFTools.splitAll(source: source) }.value
    }

    /// The main subject of a picture on a transparent background, as PNG.
    public func removeBackground(source: URL) async throws -> URL {
        try await Task.detached {
            try ImageConverter().render(source: source, format: .png, suffix: " 去背景") { image in
                try VisionTools.removeBackground(from: image)
            }
        }.value
    }

    /// A copy without EXIF, GPS or other metadata (the picture is re-encoded).
    public func stripMetadata(source: URL) async throws -> URL {
        try await Task.detached {
            try ImageConverter().render(source: source, format: Self.sameFormat(as: source), suffix: " 无元数据", quality: 0.97)
        }.value
    }

    /// A JPEG of at most about `bytes`: quality first, then a smaller picture if quality is not enough.
    public func compressImage(source: URL, toBytes bytes: Int) async throws -> URL {
        let original = (try? source.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? Int.max
        guard bytes > 0, bytes < original else { throw ConversionError.alreadySmall }
        return try await Task.detached {
            let converter = ImageConverter()
            let full = try converter.decodeStillImage(source)
            var scale = 1.0
            var chosen: (scale: Double, quality: Double)?
            while chosen == nil && scale >= 0.2 {
                let image = scale < 0.999 ? try ImageOps.scaled(full, by: scale) : full
                // The largest quality in 0.2…0.95 that still fits, found by bisection.
                var low = 0.2, high = 0.95
                if try converter.encodedSize(of: image, format: .jpeg, quality: low) > bytes {
                    scale *= 0.85
                    continue
                }
                for _ in 0..<7 {
                    let middle = (low + high) / 2
                    if try converter.encodedSize(of: image, format: .jpeg, quality: middle) <= bytes { low = middle } else { high = middle }
                }
                chosen = (scale, low)
            }
            guard let chosen else { throw ConversionError.exportFailed("无法压缩到这个大小") }
            return try converter.render(source: source, format: .jpeg, suffix: " 压缩", quality: chosen.quality) { image in
                chosen.scale < 0.999 ? try ImageOps.scaled(image, by: chosen.scale) : image
            }
        }.value
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
        try await Task.detached {
            let text = try VisionTools.recognizeText(in: ImageConverter().decodeStillImage(source))
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ConversionError.noTextFound }
            return text
        }.value
    }

    public func readQRCodes(source: URL) async throws -> [String] {
        try await Task.detached { try VisionTools.qrPayloads(in: ImageConverter().decodeStillImage(source)) }.value
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
