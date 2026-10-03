#if os(macOS)
import CoreGraphics
import Foundation

/// What the interactive image editor asks for. The crop rectangle is normalized (0…1) in
/// the upright image, origin at the top left.
public struct ImageEdit: Equatable, Sendable {
    public var crop: CGRect?
    public var scale: Double
    /// nil keeps PNG / JPEG / HEIC and turns anything else into PNG.
    public var format: OutputFormat?
    public var quality: Double

    public init(crop: CGRect? = nil, scale: Double = 1, format: OutputFormat? = nil, quality: Double = 0.85) {
        self.crop = crop
        self.scale = scale
        self.format = format
        self.quality = quality
    }

    func outputFormat(for source: URL) -> OutputFormat { format ?? ConversionService.sameFormat(as: source) }

    func apply(to image: CGImage) throws -> CGImage {
        var result = image
        if let crop, crop != CGRect(x: 0, y: 0, width: 1, height: 1) {
            let w = Double(image.width), h = Double(image.height)
            result = try ImageOps.cropped(image, toPixels: CGRect(x: crop.minX * w, y: crop.minY * h,
                                                                  width: crop.width * w, height: crop.height * h))
        }
        if scale < 0.999 { result = try ImageOps.scaled(result, by: scale) }
        return result
    }
}

/// Holds the decoded image for the editor window: a preview, exact output estimates, and the save.
public final class ImageEditSession: @unchecked Sendable {
    public let source: URL
    public let preview: CGImage
    public let pixelSize: CGSize
    public let originalBytes: Int
    private let full: CGImage

    public init(source: URL) throws {
        self.source = source
        let converter = ImageConverter()
        full = try converter.decodeStillImage(source)
        pixelSize = CGSize(width: full.width, height: full.height)
        let longest = Double(max(full.width, full.height))
        preview = longest > 1600 ? try ImageOps.scaled(full, by: 1600 / longest) : full
        originalBytes = (try? source.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    }

    /// The output size and an estimate of its file size. Past about 8 megapixels the estimate is
    /// taken from a downsized copy and scaled up by pixel count: close enough for "about", and it
    /// keeps a 48-megapixel photo from costing hundreds of megabytes on every crop drag.
    public func estimate(_ edit: ImageEdit) throws -> (size: CGSize, bytes: Int) {
        try autoreleasepool {
            let result = try edit.apply(to: full)
            let pixels = Double(result.width * result.height)
            let limit = 8_000_000.0
            let probe = pixels > limit ? try ImageOps.scaled(result, by: (limit / pixels).squareRoot()) : result
            var bytes = try ImageConverter().encodedSize(of: probe, format: edit.outputFormat(for: source),
                                                         quality: edit.quality)
            if probe !== result { bytes = Int(Double(bytes) * pixels / Double(probe.width * probe.height)) }
            return (CGSize(width: result.width, height: result.height), bytes)
        }
    }

    /// Writes the edited copy next to the source with an " 编辑" suffix.
    public static func save(source: URL, edit: ImageEdit) throws -> URL {
        try ImageConverter().render(source: source, format: edit.outputFormat(for: source), suffix: " 编辑",
                                    quality: edit.quality) { try edit.apply(to: $0) }
    }
}
#endif
