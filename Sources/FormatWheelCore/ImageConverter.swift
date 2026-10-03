#if os(macOS)
import AppKit
import CoreGraphics
import Darwin
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Converts a single still image without replacing the source or an existing output.
///
/// ImageIO decides which source formats the current macOS release can decode. Animated
/// and multipage inputs are rejected. Images above the pixel limit are rejected rather
/// than silently resized. PNG is losslessly encoded; JPEG is a high-quality, 8-bit sRGB
/// rendering with transparency composited on white. Source EXIF/GPS/XMP is not copied.
public struct ImageConverter: FileConversionEngine, Sendable {
    public let maximumPixelCount: Int

    public init(maximumPixelCount: Int = 100_000_000) {
        self.maximumPixelCount = maximumPixelCount
    }

    /// Size in bytes the image would have when encoded as `format`, without writing anything.
    func encodedSize(of image: CGImage, format: OutputFormat, quality: Double) throws -> Int {
        let prepared = format == .jpeg ? try compositedOnWhite(image) : image
        guard let buffer = CFDataCreateMutable(nil, 0), let consumer = CGDataConsumer(data: buffer) else {
            throw ConversionError.cannotCreateEncoder
        }
        try encodeRaster(prepared, format: format, quality: quality, consumer: consumer)
        return CFDataGetLength(buffer)
    }

    /// Decodes `source` and writes a lossless PNG to a temporary file we own. Used as the
    /// input for tools that cannot read every format ImageIO can (e.g. HEIC → WebP).
    func writeIntermediatePNG(source: URL, to url: URL) throws {
        guard source.isFileURL else { throw ConversionError.notAFileURL }
        try autoreleasepool {
            let image = try decodeStillImage(source)
            try Task.checkCancellation()
            guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
                throw ConversionError.cannotCreateEncoder
            }
            CGImageDestinationAddImage(destination, image, [kCGImagePropertyOrientation: 1] as CFDictionary)
            guard CGImageDestinationFinalize(destination) else { throw ConversionError.encodingFailed }
        }
    }

    /// Creates an output next to `source`. Returns only after encoding, flushing, and
    /// closing have succeeded. The method is synchronous; call off the UI thread.
    public func convert(source: URL, to format: OutputFormat) throws -> URL {
        try render(source: source, format: format)
    }

    /// The general path: decode, optionally transform (crop, shrink), then encode next to the
    /// source with an optional name suffix.
    /// With `onlyIfSmallerThan`, the image is encoded in memory first and nothing is written
    /// unless the result is smaller than that many bytes (used by "compress").
    func render(source: URL, format: OutputFormat, suffix: String = "", quality: Double = 0.95,
                onlyIfSmallerThan limit: Int? = nil,
                transform: ((CGImage) throws -> CGImage)? = nil) throws -> URL {
        guard maximumPixelCount > 0 else { throw ConversionError.invalidPixelLimit }
        guard source.isFileURL else { throw ConversionError.notAFileURL }
        guard Self.rasterTypes[format] != nil || format == .pdf else { throw ConversionError.unsupportedFormat }

        let values: URLResourceValues
        do {
            values = try source.resourceValues(forKeys: [.isRegularFileKey, .isReadableKey])
        } catch {
            throw ConversionError.unreadableSource
        }
        guard values.isRegularFile == true, values.isReadable != false else {
            throw ConversionError.unreadableSource
        }

        return try autoreleasepool {
            var image = try decodeStillImage(source)
            if let transform { image = try transform(image) }
            let prepared = format == .jpeg ? try compositedOnWhite(image) : image
            var encoded: Data?
            if let limit, format != .pdf {
                guard let buffer = CFDataCreateMutable(nil, 0), let memory = CGDataConsumer(data: buffer) else {
                    throw ConversionError.cannotCreateEncoder
                }
                try encodeRaster(prepared, format: format, quality: quality, consumer: memory)
                guard CFDataGetLength(buffer) < limit else { throw ConversionError.alreadySmall }
                encoded = buffer as Data
            }
            // Decoding and transforming are the slow part; stop here if cancelled, before
            // anything is written next to the source.
            try Task.checkCancellation()
            let output = try ReservedOutput.reserve(nextTo: source, format: format, suffix: suffix)
            defer { output.closeReservation() }

            do {
                let consumer = try output.makeConsumer()
                if let encoded {
                    try output.append(encoded)
                    try output.commit()
                    return output.url
                }
                switch format {
                case .pdf:
                    try encodePDF(prepared, consumer: consumer)
                default:
                    try encodeRaster(prepared, format: format, quality: quality, consumer: consumer)
                }
                try output.commit()
                return output.url
            } catch {
                // Never unlink a public pathname after a failure: a different file
                // could have replaced it between an identity check and deletion.
                throw ConversionError.incompleteOutput(output.url, error.localizedDescription)
            }
        }
    }

    /// SVG is not an ImageIO format; AppKit rasterizes it with a transparent background.
    /// Small drawings are scaled up so the longest side is 2048 px (large ones are capped at 4096).
    private func renderSVG(_ url: URL) throws -> CGImage {
        guard let svg = NSImage(contentsOf: url), svg.size.width > 0, svg.size.height > 0 else {
            throw ConversionError.invalidImage
        }
        let longest = max(svg.size.width, svg.size.height)
        let scale = longest < 2048 ? 2048 / longest : min(1, 4096 / longest)
        let width = max(1, Int((svg.size.width * scale).rounded()))
        let height = max(1, Int((svg.size.height * scale).rounded()))
        try validateDimensions(width: width, height: height)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw ConversionError.cannotRenderImage
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        svg.draw(in: NSRect(x: 0, y: 0, width: width, height: height))
        NSGraphicsContext.restoreGraphicsState()
        guard let image = context.makeImage() else { throw ConversionError.cannotRenderImage }
        return image
    }

    func decodeStillImage(_ url: URL) throws -> CGImage {
        if url.pathExtension.lowercased() == "svg" { return try renderSVG(url) }
        let readOptions: [CFString: Any] = [
            kCGImageSourceShouldCache: false,
            kCGImageSourceShouldAllowFloat: false
        ]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, readOptions as CFDictionary) else {
            throw ConversionError.invalidImage
        }
        let frameCount = CGImageSourceGetCount(source)
        guard frameCount > 0 else { throw ConversionError.invalidImage }
        guard frameCount == 1 else { throw ConversionError.multipleImages(frameCount) }
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue else {
            throw ConversionError.invalidImage
        }
        try validateDimensions(width: width, height: height)

        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        guard (1...8).contains(orientation) else { throw ConversionError.invalidImage }

        let decoded: CGImage?
        if orientation == 1 {
            // Avoid a bitmap redraw: this preserves the decoded PNG/TIFF color space,
            // bit depth, and pixel samples whenever the destination can represent them.
            decoded = CGImageSourceCreateImageAtIndex(source, 0, [
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceShouldAllowFloat: false
            ] as CFDictionary)
        } else {
            // ImageIO handles all eight EXIF transforms, including HEIC orientation.
            // "Always" prevents accidentally using a small embedded preview. Asking for
            // the full original dimension applies orientation without downsampling.
            decoded = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: max(width, height),
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceShouldAllowFloat: false
            ] as CFDictionary)
        }
        guard let image = decoded,
              CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete else {
            throw ConversionError.invalidImage
        }
        try validateDimensions(width: image.width, height: image.height)
        let swapsAxes = (5...8).contains(orientation)
        let expectedWidth = swapsAxes ? height : width
        let expectedHeight = swapsAxes ? width : height
        guard image.width == expectedWidth, image.height == expectedHeight else {
            throw ConversionError.unexpectedImageDimensions
        }
        return image
    }

    private func validateDimensions(width: Int, height: Int) throws {
        guard width > 0, height > 0 else { throw ConversionError.invalidImage }
        // Division avoids overflowing Int on a corrupt or malicious image header.
        guard width <= maximumPixelCount / height else {
            throw ConversionError.imageTooLarge(maximumPixelCount)
        }
    }

    private func compositedOnWhite(_ image: CGImage) throws -> CGImage {
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil,
                width: image.width,
                height: image.height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
              ) else {
            throw ConversionError.cannotRenderImage
        }
        let bounds = CGRect(x: 0, y: 0, width: CGFloat(image.width), height: CGFloat(image.height))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(bounds)
        context.interpolationQuality = .none
        context.draw(image, in: bounds)
        guard let opaqueImage = context.makeImage() else { throw ConversionError.cannotRenderImage }
        return opaqueImage
    }

    /// Raster outputs ImageIO can write. WebP is read-only in ImageIO; it goes through ExternalTools.
    static let rasterTypes: [OutputFormat: String] = [
        .png: UTType.png.identifier, .jpeg: UTType.jpeg.identifier, .heic: UTType.heic.identifier,
    ]

    private func encodeRaster(_ image: CGImage, format: OutputFormat, quality: Double, consumer: CGDataConsumer) throws {
        guard let type = Self.rasterTypes[format],
              let destination = CGImageDestinationCreateWithDataConsumer(consumer, type as CFString, 1, nil) else {
            throw ConversionError.cannotCreateEncoder
        }
        var properties: [CFString: Any] = [
            kCGImagePropertyOrientation: 1,
            kCGImageDestinationEmbedThumbnail: false
        ]
        if format == .jpeg || format == .heic {
            properties[kCGImageDestinationLossyCompressionQuality] = quality
        }
        // Deliberately add a CGImage, not AddImageFromSource: no incidental source
        // metadata or auxiliary/depth images are copied. Color profiles remain useful.
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw ConversionError.encodingFailed }
    }

    private func encodePDF(_ image: CGImage, consumer: CGDataConsumer) throws {
        // One image pixel maps to one PDF point. This preserves aspect and avoids an
        // arbitrary page crop or up/downsampling of the embedded raster image.
        var mediaBox = CGRect(x: 0, y: 0, width: CGFloat(image.width), height: CGFloat(image.height))
        guard let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            throw ConversionError.cannotCreateEncoder
        }
        context.beginPDFPage(nil)
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(mediaBox)
        context.interpolationQuality = .none
        context.draw(image, in: mediaBox)
        context.endPDFPage()
        context.closePDF()
    }
}

public enum ConversionError: Error, LocalizedError, Sendable {
    case notAFileURL
    case unreadableSource
    case invalidImage
    case multipleImages(Int)
    case invalidPixelLimit
    case imageTooLarge(Int)
    case unexpectedImageDimensions
    case cannotRenderImage
    case cannotCreateEncoder
    case encodingFailed
    case outputCreationFailed(Int32)
    case outputWriteFailed(Int32)
    case outputChanged
    case incompleteOutput(URL, String)
    case tooManyOutputNames
    case unsupportedFormat
    case noAudioTrack
    case noVideoTrack
    case unreadableMedia
    case exportFailed(String)
    case cancelled
    case noTextFound
    case unreadableDocument
    case extrasNotInstalled
    case tooManyPages(Int)
    case alreadySmall
    case noSubject
    case needsNewerSystem(String)
    case invalidPages(String)
    case notEnoughFiles

    public var errorDescription: String? {
        switch self {
        case .notAFileURL:
            return "请选择保存在这台 Mac 上的图片。"
        case .unreadableSource:
            return "无法读取原文件。请检查文件是否存在，以及是否有访问权限。"
        case .invalidImage:
            return "文件损坏，或 macOS 无法解码此图片。"
        case .multipleImages(let count):
            return "文件包含 \(count) 张图片或动画帧。请选择单张静态图片，避免丢失内容。"
        case .invalidPixelLimit:
            return "图片转换器的像素限制无效。"
        case .imageTooLarge(let limit):
            return "图片超过 \(limit / 1_000_000) 百万像素的安全限制，未缩小或转换。"
        case .unexpectedImageDimensions:
            return "macOS 无法在校正方向时保留图片完整尺寸。"
        case .cannotRenderImage:
            return "macOS 无法绘制此图片，可能没有足够可用内存。"
        case .cannotCreateEncoder, .encodingFailed:
            return "macOS 无法编码所选格式，未保存完整输出。"
        case .outputCreationFailed(let code):
            return "无法在原文件所在文件夹创建输出（系统错误代码：\(code)）。"
        case .outputWriteFailed(let code):
            return "无法完整写入输出（系统错误代码：\(code)）。"
        case .outputChanged:
            return "输出位置在转换过程中发生变化，请重试。"
        case .incompleteOutput(let url, let reason):
            return "\(reason) 可能残留不完整文件：\(url.path)。使用前请检查。"
        case .tooManyOutputNames:
            return "目标文件夹中存在过多同名文件。"
        case .unsupportedFormat:
            return "不支持把此类文件转为所选格式。"
        case .noAudioTrack:
            return "文件里没有音频轨道。"
        case .noVideoTrack:
            return "文件里没有视频轨道。"
        case .unreadableMedia:
            return "macOS 无法读取这个音频或视频文件，可能是系统不支持的格式。"
        case .exportFailed(let reason):
            return "转换失败：\(reason)"
        case .cancelled:
            return "已取消转换。"
        case .noTextFound:
            return "没有识别到文字。"
        case .unreadableDocument:
            return "无法读取这个文档，可能已损坏或格式不受支持。"
        case .noSubject:
            return "没有找到可以抠出的主体。"
        case .needsNewerSystem(let feature):
            return "\(feature)需要 macOS 14 或更高版本。"
        case .invalidPages(let text):
            return "页码无效：\(text)。请输入类似 1-3,5 的页码。"
        case .notEnoughFiles:
            return "至少需要两个文件。"
        case .alreadySmall:
            return "这个文件已经很小，压缩后反而更大，没有生成新文件。"
        case .tooManyPages(let limit):
            return "页数超过 \(limit) 页的上限，未转换。"
        case .extrasNotInstalled:
            return "需要先运行 scripts/install-extras.sh 安装可选组件。"
        }
    }
}

/// The exclusive file descriptor is the only write destination. In particular, do not
/// reserve a path and then pass that path to ImageIO: that would reopen it and introduce
/// a race in which a different file or symlink could be overwritten.
// Internal so descriptor closing and failure retention can be tested with @testable import.
// Failures leave the newly created file in place rather than risk deleting a replacement.
final class ReservedOutput {
    let url: URL
    private var descriptor: Int32
    private let device: dev_t
    private let inode: ino_t
    private var writeError: Int32?
    private let lock = NSLock()

    private init(url: URL, descriptor: Int32, identity: stat) {
        self.url = url
        self.descriptor = descriptor
        self.device = identity.st_dev
        self.inode = identity.st_ino
    }

    static func reserve(nextTo source: URL, format: OutputFormat, suffix: String = "") throws -> ReservedOutput {
        let folder = source.deletingLastPathComponent()
        let stem = source.deletingPathExtension().lastPathComponent + suffix
        for number in 1...10_000 {
            let counter = number == 1 ? "" : " \(number)"
            let candidate = folder.appendingPathComponent("\(stem)\(counter).\(format.fileExtension)", isDirectory: false)
            // O_EXCL is the collision test and reservation in one operation. A source
            // with the same extension is treated as an existing file and skipped.
            let descriptor = candidate.withUnsafeFileSystemRepresentation { path -> Int32 in
                guard let path else { return -1 }
                return Darwin.open(path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, mode_t(0o600))
            }
            if descriptor == -1 {
                let code = errno
                if code == EEXIST { continue }
                throw ConversionError.outputCreationFailed(code)
            }
            var identity = stat()
            var identityResult: Int32
            repeat { identityResult = fstat(descriptor, &identity) } while identityResult == -1 && errno == EINTR
            guard identityResult == 0 else {
                let code = errno
                _ = Darwin.close(descriptor)
                // A just-created descriptor should always support fstat. Leave the
                // empty reservation alone if identity cannot be verified safely.
                throw ConversionError.incompleteOutput(candidate, "无法验证新建输出（系统错误代码：\(code)）。")
            }
            return ReservedOutput(url: candidate, descriptor: descriptor, identity: identity)
        }
        throw ConversionError.tooManyOutputNames
    }

    func makeConsumer() throws -> CGDataConsumer {
        let info = Unmanaged.passRetained(self).toOpaque()
        var callbacks = CGDataConsumerCallbacks(
            putBytes: { info, buffer, count in
                guard let info else { return 0 }
                let optionalBuffer: UnsafeRawPointer? = buffer
                guard let optionalBuffer else { return 0 }
                return Unmanaged<ReservedOutput>.fromOpaque(info).takeUnretainedValue().write(optionalBuffer, count: count)
            },
            releaseConsumer: { info in
                guard let info else { return }
                Unmanaged<ReservedOutput>.fromOpaque(info).release()
            }
        )
        guard let consumer = CGDataConsumer(info: info, cbks: &callbacks) else {
            Unmanaged<ReservedOutput>.fromOpaque(info).release()
            throw ConversionError.cannotCreateEncoder
        }
        return consumer
    }

    func append(_ data: Data) throws {
        let written = data.withUnsafeBytes { raw -> Int in
            guard let base = raw.baseAddress else { return 0 }
            return write(base, count: raw.count)
        }
        guard written == data.count else { throw ConversionError.outputWriteFailed(EIO) }
    }

    private func write(_ buffer: UnsafeRawPointer, count: Int) -> Int {
        lock.lock()
        defer { lock.unlock() }
        guard descriptor >= 0, writeError == nil else { return 0 }
        var written = 0
        while written < count {
            let result = Darwin.write(descriptor, buffer.advanced(by: written), count - written)
            if result > 0 {
                written += result
            } else if result == -1 && errno == EINTR {
                continue
            } else {
                writeError = result == 0 ? EIO : errno
                return written
            }
        }
        return written
    }

    func commit() throws {
        lock.lock()
        defer { lock.unlock() }
        if let writeError { throw ConversionError.outputWriteFailed(writeError) }
        guard descriptor >= 0 else { throw ConversionError.outputWriteFailed(EBADF) }
        var identity = stat()
        guard fstat(descriptor, &identity) == 0 else { throw ConversionError.outputWriteFailed(errno) }
        guard identity.st_size > 0 else { throw ConversionError.encodingFailed }
        guard pathStillRefersToReservation() else { throw ConversionError.outputChanged }
        while fsync(descriptor) == -1 {
            if errno == EINTR { continue }
            throw ConversionError.outputWriteFailed(errno)
        }
        let oldDescriptor = descriptor
        descriptor = -1
        guard Darwin.close(oldDescriptor) == 0 else { throw ConversionError.outputWriteFailed(errno) }
        guard pathStillRefersToReservation() else { throw ConversionError.outputChanged }
    }

    func closeReservation() {
        lock.lock()
        defer { lock.unlock() }
        if descriptor >= 0 {
            _ = Darwin.close(descriptor)
            descriptor = -1
        }
        // Intentionally never unlink by pathname, even after an inode check.
        // A check-then-unlink sequence cannot safely exclude a replacement race.
    }

    private func pathStillRefersToReservation() -> Bool {
        var current = stat()
        let result = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return lstat(path, &current)
        }
        return result == 0 && current.st_dev == device && current.st_ino == inode
    }

    deinit {
        closeReservation()
    }
}
#endif
