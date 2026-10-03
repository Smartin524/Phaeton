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
