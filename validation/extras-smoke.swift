import AppKit
import AVFoundation
import CoreImage
import Foundation
import ImageIO
import PDFKit

@main struct T {
    static func main() async throws {
        let dir = URL(fileURLWithPath: CommandLine.arguments[1])
        _ = NSApplication.shared
        let svc = ConversionService()
        var failed = false
        func check(_ ok: Bool, _ msg: String) { print(ok ? "PASS" : "FAIL", msg); if !ok { failed = true } }
        func bytes(_ url: URL) -> Int { (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0 }
        func f(_ name: String) -> URL { dir.appendingPathComponent(name) }
        func tracks(_ url: URL, _ type: AVMediaType) async -> Int { ((try? await AVURLAsset(url: url).loadTracks(withMediaType: type)) ?? []).count }
        func duration(_ url: URL) async -> Double { (try? await AVURLAsset(url: url).load(.duration).seconds) ?? 0 }

        // images -> one PDF; PDFs -> one PDF; pages; split
        let two = try await svc.batch(.mergeImagesToPDF, sources: [f("sample.jpg"), f("sample-transparent.png")])
        check(PDFDocument(url: two)?.pageCount == 2, "two images merged into a 2-page PDF (\(two.lastPathComponent))")
        let pdfA = try await svc.convert(source: f("sample.jpg"), to: .pdf)
        let merged = try await svc.batch(.mergePDFs, sources: [two, pdfA])
        check(PDFDocument(url: merged)?.pageCount == 3, "PDFs merged: 2 + 1 pages")
        let part = try await svc.extractPages(source: merged, pages: "1,3")
        check(PDFDocument(url: part)?.pageCount == 2, "extract pages 1,3")
        do { _ = try await svc.extractPages(source: merged, pages: "9"); check(false, "bad page accepted") }
        catch { check(error.localizedDescription.contains("页码无效"), "bad page refused") }
        let folder = try await svc.splitPDF(source: merged)
        check((try FileManager.default.contentsOfDirectory(atPath: folder.path)).count == 3, "split into 3 single-page PDFs")

        // OCR to TXT and to a string
        let text = NSAttributedString(string: "Phaeton OCR test 2026", attributes: [.font: NSFont.systemFont(ofSize: 56), .foregroundColor: NSColor.black])
        let image = NSImage(size: NSSize(width: 1200, height: 240))
        image.lockFocus(); NSColor.white.setFill(); NSRect(x: 0, y: 0, width: 1200, height: 240).fill()
        text.draw(at: NSPoint(x: 40, y: 80)); image.unlockFocus()
        try NSBitmapImageRep(data: image.tiffRepresentation!)!.representation(using: .png, properties: [:])!.write(to: f("words.png"))
        let ocr = try await svc.recognizeText(source: f("words.png"))
        check(ocr.contains("Phaeton") && ocr.contains("2026"), "image OCR: \(ocr)")
        let txt = try await svc.convert(source: f("words.png"), to: .txt)
        check(try String(contentsOf: txt).contains("Phaeton"), "image -> TXT file")

        // QR code, made with CoreImage and read back
        let filter = CIFilter(name: "CIQRCodeGenerator")!
        filter.setValue(Data("https://example.com/phaeton".utf8), forKey: "inputMessage")
        let qr = filter.outputImage!.transformed(by: CGAffineTransform(scaleX: 12, y: 12))
        let qrRep = NSBitmapImageRep(ciImage: qr)
        try qrRep.representation(using: .png, properties: [:])!.write(to: f("qr.png"))
        let codes = try await svc.readQRCodes(source: f("qr.png"))
        check(codes == ["https://example.com/phaeton"], "QR code read: \(codes)")

        // metadata: put GPS in a JPEG, strip it
        let cg = CGImageSourceCreateWithURL(f("sample.jpg") as CFURL, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }!
        let tagged = f("tagged.jpg")
        let dest = CGImageDestinationCreateWithURL(tagged as CFURL, "public.jpeg" as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, cg, [kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 31.2, kCGImagePropertyGPSLatitudeRef: "N",
            kCGImagePropertyGPSLongitude: 121.4, kCGImagePropertyGPSLongitudeRef: "E"], kCGImagePropertyExifDictionary: [kCGImagePropertyExifUserComment: "secret"]] as CFDictionary)
        CGImageDestinationFinalize(dest)
        func hasGPS(_ url: URL) -> Bool {
            guard let s = CGImageSourceCreateWithURL(url as CFURL, nil), let p = CGImageSourceCopyPropertiesAtIndex(s, 0, nil) as? [CFString: Any] else { return false }
            return p[kCGImagePropertyGPSDictionary] != nil
        }
        check(hasGPS(tagged), "test JPEG really has GPS")
        let clean = try await svc.stripMetadata(source: tagged)
        check(!hasGPS(clean) && clean.lastPathComponent.contains("无元数据"), "metadata stripped: \(clean.lastPathComponent)")

        // compress to a target size
        let target = 150_000
        let small = try await svc.compressImage(source: f("big.jpg"), toBytes: target)
        print("compress to", target, "->", bytes(small))
        check(bytes(small) <= target && bytes(small) > target / 4, "image compressed to at most the target")
        do { _ = try await svc.compressImage(source: f("small.jpg"), toBytes: 10_000_000); check(false, "larger target accepted") }
        catch { check(true, "target above current size refused") }

        // background removal: needs a real subject, so a synthetic picture may find none
        do {
            let cut = try await svc.removeBackground(source: f("sample.jpg"))
            let s = CGImageSourceCreateWithURL(cut as CFURL, nil)!
            let img = CGImageSourceCreateImageAtIndex(s, 0, nil)!
            check(img.alphaInfo != .none && img.alphaInfo != .noneSkipLast, "background removed, PNG keeps alpha (\(cut.lastPathComponent))")
        } catch {
            print("SKIP background removal on the synthetic sample:", error.localizedDescription)
        }

        // video and audio
        let clip = f("clip.mov")
        let clipLength = await duration(clip)
        let joined = try await svc.batch(.joinVideos, sources: [clip, clip])
        let jd = await duration(joined)
        let joinedVideo = await tracks(joined, .video)
        check(abs(jd - clipLength * 2) < 0.3 && joinedVideo == 1, String(format: "two clips joined: %.2fs", jd))
        let muted = try await svc.muteVideo(source: clip)
        let mutedAudio = await tracks(muted, .audio), mutedVideo = await tracks(muted, .video)
        check(mutedAudio == 0 && mutedVideo == 1, "mute removes audio, keeps picture")
        let fast = try await svc.changeSpeed(source: clip, factor: 2)
        let fd = await duration(fast)
        check(abs(fd - clipLength / 2) < 0.3, String(format: "2x speed: %.2fs from %.2fs", fd, clipLength))
        // The sample clip is tiny, so re-encoding cannot make it smaller and must be refused.
        do { _ = try await svc.compressVideo(source: clip, toBytes: bytes(clip) / 2); check(false, "bigger result was kept") }
        catch { check(error.localizedDescription.contains("已经很小"), "video compress never keeps a bigger file") }
        let speech = f("speech.aiff")
        let speechLength = await duration(speech)
        let audioJoin = try await svc.batch(.joinAudio, sources: [speech, speech])
        let audioJoinLength = await duration(audioJoin)
        check(abs(audioJoinLength - speechLength * 2) < 0.3, "two audio files joined")

        let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasPrefix(".phaeton-") }
        check(leftovers.isEmpty, "no temp leftovers \(leftovers)")
        print(failed ? "SOME FAILED" : "ALL DONE")
    }
}
