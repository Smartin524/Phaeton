#if os(macOS)
import CoreImage
import CoreGraphics
import Foundation
import Vision

/// Text recognition, QR reading and background removal, all with the system Vision framework.
enum VisionTools {
    static func recognizeText(in image: CGImage) throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.automaticallyDetectsLanguage = true
        try VNImageRequestHandler(cgImage: image).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }

    static func qrPayloads(in image: CGImage) throws -> [String] {
        let request = VNDetectBarcodesRequest()
        request.symbologies = [.qr]
        try VNImageRequestHandler(cgImage: image).perform([request])
        return (request.results ?? []).compactMap { $0.payloadStringValue }
    }

    /// The main subject on a transparent background (macOS 14+).
    static func removeBackground(from image: CGImage) throws -> CGImage {
        guard #available(macOS 14.0, *) else { throw ConversionError.needsNewerSystem("去背景") }
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: image)
        try handler.perform([request])
        guard let result = request.results?.first, !result.allInstances.isEmpty else { throw ConversionError.noSubject }
        let buffer = try result.generateMaskedImage(ofInstances: result.allInstances, from: handler,
                                                    croppedToInstancesExtent: false)
        let ciImage = CIImage(cvPixelBuffer: buffer)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let output = CIContext().createCGImage(ciImage, from: ciImage.extent, format: .RGBA8, colorSpace: space) else {
            throw ConversionError.cannotRenderImage
        }
        return output
    }
}
#endif
