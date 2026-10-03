#if os(macOS)
import CoreGraphics
import Foundation

/// Pixel operations shared by the tool presets and the interactive image editor.
enum ImageOps {
    /// Crop with a rectangle in pixels (top-left origin).
    static func cropped(_ image: CGImage, toPixels rect: CGRect) throws -> CGImage {
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let clipped = rect.integral.intersection(bounds)
        guard clipped.width >= 1, clipped.height >= 1, let result = image.cropping(to: clipped) else {
            throw ConversionError.cannotRenderImage
        }
        return result
    }

    static func scaled(_ image: CGImage, by factor: Double) throws -> CGImage {
        let width = max(1, Int((Double(image.width) * factor).rounded()))
        let height = max(1, Int((Double(image.height) * factor).rounded()))
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw ConversionError.cannotRenderImage
        }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let result = context.makeImage() else { throw ConversionError.cannotRenderImage }
        return result
    }
}
#endif
