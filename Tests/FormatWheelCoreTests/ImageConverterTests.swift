#if os(macOS)
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import FormatWheelCore

final class ImageConverterTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("FormatWheel-Tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let folder { try FileManager.default.removeItem(at: folder) }
        folder = nil
    }

    func testPNGPreservesPixelsAlphaDimensionsAndOriginal() throws {
        let source = folder.appendingPathComponent("sample.tiff")
        let image = try makeImage(width: 2, height: 2, rgba: [
            255, 0, 0, 255,   0, 255, 0, 128,
            0, 0, 255, 255,   0, 0, 0, 0
        ])
        try save(image, type: .tiff, at: source)
        let original = try Data(contentsOf: source)
        let sourcePixels = try rgbaBytes(of: readImage(source))

        let output = try ImageConverter().convert(source: source, to: .png)

        XCTAssertEqual(output.deletingLastPathComponent(), source.deletingLastPathComponent())
        XCTAssertEqual(output.pathExtension, "png")
        XCTAssertEqual(try Data(contentsOf: source), original)
        let converted = try readImage(output)
        XCTAssertEqual(converted.width, 2)
        XCTAssertEqual(converted.height, 2)
        XCTAssertEqual(try rgbaBytes(of: converted), sourcePixels)
    }

    func testUnrotated16BitPNGDoesNotReduceBitDepth() throws {
        let source = folder.appendingPathComponent("sixteen-bit.png")
        let bytes: [UInt8] = [0, 0, 0x12, 0x34, 0xAB, 0xCD, 0xFF, 0xFF]
        let provider = try XCTUnwrap(CGDataProvider(data: Data(bytes) as CFData))
        let image = try XCTUnwrap(CGImage(
            width: 2, height: 2, bitsPerComponent: 16, bitsPerPixel: 16, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue | CGBitmapInfo.byteOrder16Big.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        ))
        try save(image, type: .png, at: source)
        let original = try readImage(source)
        XCTAssertEqual(original.bitsPerComponent, 16)

        let output = try ImageConverter().convert(source: source, to: .png)
        let converted = try readImage(output)
        XCTAssertEqual(converted.bitsPerComponent, 16)
        XCTAssertEqual(converted.width, original.width)
        XCTAssertEqual(converted.height, original.height)
        XCTAssertEqual(try rgbaBytes(of: converted), try rgbaBytes(of: original))
    }

    func testJPEGFlattensTransparentPixelsOntoWhite() throws {
        let source = folder.appendingPathComponent("transparent.png")
        let image = try makeImage(width: 16, height: 16, rgba: Array(repeating: [UInt8](arrayLiteral: 0, 0, 0, 0), count: 256).flatMap { $0 })
        try save(image, type: .png, at: source)
        let original = try Data(contentsOf: source)

        let output = try ImageConverter().convert(source: source, to: .jpeg)
        let pixels = try rgbaBytes(of: readImage(output))

        XCTAssertEqual(output.pathExtension, "jpg")
        XCTAssertEqual(try Data(contentsOf: source), original)
        for index in stride(from: 0, to: pixels.count, by: 4) {
            XCTAssertGreaterThanOrEqual(pixels[index], 250)
            XCTAssertGreaterThanOrEqual(pixels[index + 1], 250)
            XCTAssertGreaterThanOrEqual(pixels[index + 2], 250)
            XCTAssertEqual(pixels[index + 3], 255)
        }
    }

    func testExistingOutputAndSourceAreNeverOverwritten() throws {
        let source = folder.appendingPathComponent("sample.tiff")
        try save(solidImage(), type: .tiff, at: source)
        let existing = folder.appendingPathComponent("sample.png")
        let sentinel = Data("Existing file: do not overwrite".utf8)
        try sentinel.write(to: existing)
        let original = try Data(contentsOf: source)

        let first = try ImageConverter().convert(source: source, to: .png)
        let second = try ImageConverter().convert(source: source, to: .png)

        XCTAssertNotEqual(first, existing)
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(try Data(contentsOf: existing), sentinel)
        XCTAssertEqual(try Data(contentsOf: source), original)
        XCTAssertNoThrow(try readImage(first))
        XCTAssertNoThrow(try readImage(second))
    }

    func testConvertingPNGToPNGCreatesAnotherFile() throws {
        let source = folder.appendingPathComponent("already.png")
        try save(solidImage(), type: .png, at: source)
        let original = try Data(contentsOf: source)

        let output = try ImageConverter().convert(source: source, to: .png)

        XCTAssertNotEqual(output, source)
        XCTAssertEqual(try Data(contentsOf: source), original)
        XCTAssertEqual(try rgbaBytes(of: readImage(output)), try rgbaBytes(of: readImage(source)))
    }

    func testExistingSymlinkIsNotFollowedOrOverwritten() throws {
        let source = folder.appendingPathComponent("sample.tiff")
        try save(solidImage(), type: .tiff, at: source)
        let target = folder.appendingPathComponent("valuable.txt")
        let sentinel = Data("Keep me".utf8)
        try sentinel.write(to: target)
        let symlink = folder.appendingPathComponent("sample.png")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: target)

        let output = try ImageConverter().convert(source: source, to: .png)

        XCTAssertNotEqual(output, symlink)
        XCTAssertEqual(try Data(contentsOf: target), sentinel)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: symlink.path), target.path)
    }

    func testConcurrentConversionsReserveDifferentFiles() throws {
        let source = folder.appendingPathComponent("parallel.tiff")
        try save(solidImage(), type: .tiff, at: source)
        let results = ConcurrentResults()
        DispatchQueue.concurrentPerform(iterations: 8) { _ in
            do {
                results.append(.success(try ImageConverter().convert(source: source, to: .png)))
            } catch {
                results.append(.failure(error))
            }
        }
        let outputs = try results.values.map { try $0.get() }
        XCTAssertEqual(Set(outputs).count, 8)
        for output in outputs { XCTAssertNoThrow(try readImage(output)) }
    }

    func testFailedReservationRetainsPartialOutputRatherThanUnlinkingPublicPath() throws {
        let source = folder.appendingPathComponent("failure.tiff")
        try save(solidImage(), type: .tiff, at: source)
        let original = try Data(contentsOf: source)
        let reservation = try ReservedOutput.reserve(nextTo: source, format: .png)
        let consumer = try reservation.makeConsumer()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithDataConsumer(consumer, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try solidImage(), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        XCTAssertGreaterThan(try Data(contentsOf: reservation.url).count, 0)

        // Simulate a thrown error after bytes have been written but before commit.
        reservation.closeReservation()

        XCTAssertTrue(FileManager.default.fileExists(atPath: reservation.url.path))
        XCTAssertEqual(try Data(contentsOf: source), original)
    }

    func testClosingFailedReservationDoesNotDeleteAReplacementFile() throws {
        let source = folder.appendingPathComponent("replaced.tiff")
        try save(solidImage(), type: .tiff, at: source)
        let reservation = try ReservedOutput.reserve(nextTo: source, format: .png)
        try FileManager.default.removeItem(at: reservation.url)
        let replacement = Data("Another file now owns this path".utf8)
        try replacement.write(to: reservation.url)

        reservation.closeReservation()

        XCTAssertEqual(try Data(contentsOf: reservation.url), replacement)
    }

    func testInvalidInputLeavesNoOutput() throws {
        let source = folder.appendingPathComponent("broken.heic")
        let original = Data("This is not an image".utf8)
        try original.write(to: source)

        XCTAssertThrowsError(try ImageConverter().convert(source: source, to: .png)) { error in
            guard case ConversionError.invalidImage = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertEqual(try Data(contentsOf: source), original)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), [source.lastPathComponent])
    }

    func testMultipleTIFFPagesAreRejectedWithoutLosingPages() throws {
        let source = folder.appendingPathComponent("multipage.tiff")
        let image = try solidImage()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(source as CFURL, UTType.tiff.identifier as CFString, 2, nil))
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let original = try Data(contentsOf: source)

        XCTAssertThrowsError(try ImageConverter().convert(source: source, to: .pdf)) { error in
            guard case ConversionError.multipleImages(2) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertEqual(try Data(contentsOf: source), original)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), [source.lastPathComponent])
    }

    func testAnimatedGIFIsRejected() throws {
        let source = folder.appendingPathComponent("animated.gif")
        let image = try solidImage()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(source as CFURL, UTType.gif.identifier as CFString, 2, nil))
        for _ in 0..<2 {
            CGImageDestinationAddImage(destination, image, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.1]] as CFDictionary)
        }
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        XCTAssertThrowsError(try ImageConverter().convert(source: source, to: .png)) { error in
            guard case ConversionError.multipleImages = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testPixelLimitRejectsRatherThanDownsampling() throws {
        let source = folder.appendingPathComponent("too-large.png")
        try save(solidImage(width: 4, height: 4), type: .png, at: source)

        XCTAssertThrowsError(try ImageConverter(maximumPixelCount: 15).convert(source: source, to: .png)) { error in
            guard case ConversionError.imageTooLarge(15) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), [source.lastPathComponent])
    }

    func testAllEightEXIFOrientationsAreAppliedAtFullResolution() throws {
        let colors: [[UInt8]] = [
            [255, 0, 0, 255], [0, 255, 0, 255], [0, 0, 255, 255],
            [255, 255, 0, 255], [255, 0, 255, 255], [0, 255, 255, 255]
        ]
        let image = try makeImage(width: 3, height: 2, rgba: colors.flatMap { $0 })
        let expectedIndices = [
            [0, 1, 2, 3, 4, 5], // up
            [2, 1, 0, 5, 4, 3], // horizontal mirror
            [5, 4, 3, 2, 1, 0], // rotate 180
            [3, 4, 5, 0, 1, 2], // vertical mirror
            [0, 3, 1, 4, 2, 5], // transpose
            [3, 0, 4, 1, 5, 2], // rotate 90 clockwise
            [5, 2, 4, 1, 3, 0], // transverse
            [2, 5, 1, 4, 0, 3]  // rotate 90 counterclockwise
        ]
        for orientation in 1...8 {
            let source = folder.appendingPathComponent("orientation-\(orientation).tiff")
            try save(image, type: .tiff, at: source, properties: [kCGImagePropertyOrientation: orientation])
            let output = try ImageConverter().convert(source: source, to: .png)
            let converted = try readImage(output)
            XCTAssertEqual(converted.width, orientation >= 5 ? 2 : 3)
            XCTAssertEqual(converted.height, orientation >= 5 ? 3 : 2)
            XCTAssertEqual(try rgbaBytes(of: converted), expectedIndices[orientation - 1].flatMap { colors[$0] }, "Orientation \(orientation)")
        }
    }

    func testJPEGOrientationBecomesUprightPNG() throws {
        let source = folder.appendingPathComponent("portrait.jpg")
        try save(solidImage(width: 32, height: 16), type: .jpeg, at: source, properties: [kCGImagePropertyOrientation: 6])
        let output = try ImageConverter().convert(source: source, to: .png)
        let converted = try readImage(output)
        XCTAssertEqual(converted.width, 16)
        XCTAssertEqual(converted.height, 32)
    }

    func testHEICOrientationWhenSystemEncoderIsAvailable() throws {
        let types = CGImageDestinationCopyTypeIdentifiers() as? [String] ?? []
        guard types.contains(UTType.heic.identifier) else {
            throw XCTSkip("This Mac has no HEIC encoder for generating the fixture.")
        }
        let source = folder.appendingPathComponent("portrait.heic")
        try save(solidImage(width: 64, height: 32), type: .heic, at: source, properties: [kCGImagePropertyOrientation: 6])
        let output = try ImageConverter().convert(source: source, to: .png)
        let converted = try readImage(output)
        XCTAssertEqual(converted.width, 32)
        XCTAssertEqual(converted.height, 64)
    }

    func testPDFContainsOnePageWithImageAspectRatio() throws {
        let source = folder.appendingPathComponent("wide.png")
        try save(solidImage(width: 60, height: 20), type: .png, at: source)
        let output = try ImageConverter().convert(source: source, to: .pdf)
        let document = try XCTUnwrap(CGPDFDocument(output as CFURL))
        XCTAssertEqual(document.numberOfPages, 1)
        let page = try XCTUnwrap(document.page(at: 1))
        let bounds = page.getBoxRect(.mediaBox)
        XCTAssertEqual(bounds.width / bounds.height, 3, accuracy: 0.0001)
        XCTAssertEqual(bounds.width, 60, accuracy: 0.0001)
    }

    func testSourceGPSAndAuthorMetadataAreNotCopied() throws {
        let source = folder.appendingPathComponent("private.tiff")
        try save(solidImage(), type: .tiff, at: source, properties: [
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFArtist: "Private Test Person"],
            kCGImagePropertyGPSDictionary: [
                kCGImagePropertyGPSLatitude: 37.7,
                kCGImagePropertyGPSLatitudeRef: "N",
                kCGImagePropertyGPSLongitude: 122.4,
                kCGImagePropertyGPSLongitudeRef: "W"
            ]
        ])
        for format in [OutputFormat.png, .jpeg] {
            let output = try ImageConverter().convert(source: source, to: format)
            let imageSource = try XCTUnwrap(CGImageSourceCreateWithURL(output as CFURL, nil))
            let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any])
            XCTAssertNil(properties[kCGImagePropertyGPSDictionary])
            let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
            XCTAssertNil(tiff?[kCGImagePropertyTIFFArtist])
        }
    }

    // MARK: - Fixture helpers (no bundled personal images)

    private func solidImage(width: Int = 4, height: Int = 4) throws -> CGImage {
        try makeImage(width: width, height: height, rgba: Array(repeating: [UInt8](arrayLiteral: 255, 0, 0, 255), count: width * height).flatMap { $0 })
    }

    private func makeImage(width: Int, height: Int, rgba: [UInt8]) throws -> CGImage {
        XCTAssertEqual(rgba.count, width * height * 4)
        let provider = try XCTUnwrap(CGDataProvider(data: Data(rgba) as CFData))
        let colorSpace = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        return try XCTUnwrap(CGImage(
            width: width, height: height,
            bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        ))
    }

    private func save(_ image: CGImage, type: UTType, at url: URL, properties: [CFString: Any] = [:]) throws {
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }

    private func readImage(_ url: URL) throws -> CGImage {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        return try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
    }

    private func rgbaBytes(of image: CGImage) throws -> [UInt8] {
        let colorSpace = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try XCTUnwrap(CGContext(
            data: nil, width: image.width, height: image.height,
            bitsPerComponent: 8, bytesPerRow: image.width * 4, space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        ))
        context.interpolationQuality = .none
        context.setBlendMode(.copy)
        context.draw(image, in: CGRect(x: 0, y: 0, width: CGFloat(image.width), height: CGFloat(image.height)))
        let bytes = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
        return Array(UnsafeBufferPointer(start: bytes, count: image.width * image.height * 4))
    }
}

private final class ConcurrentResults: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Result<URL, Error>] = []

    func append(_ result: Result<URL, Error>) {
        lock.lock()
        defer { lock.unlock() }
        storage.append(result)
    }

    var values: [Result<URL, Error>] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}
#endif
