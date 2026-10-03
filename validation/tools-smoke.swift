import AppKit
import AVFoundation
import Foundation
import ImageIO

@main struct T {
    static func main() async throws {
        let dir = URL(fileURLWithPath: CommandLine.arguments[1])
        _ = NSApplication.shared
        let svc = ConversionService()
        var failed = false
        func check(_ ok: Bool, _ msg: String) { print(ok ? "PASS" : "FAIL", msg); if !ok { failed = true } }
        func size(_ url: URL) -> (Int, Int) {
            guard let s = CGImageSourceCreateWithURL(url as CFURL, nil), let p = CGImageSourceCopyPropertiesAtIndex(s, 0, nil) as? [CFString: Any] else { return (0, 0) }
            return ((p[kCGImagePropertyPixelWidth] as? Int) ?? 0, (p[kCGImagePropertyPixelHeight] as? Int) ?? 0)
        }
        func bytes(_ url: URL) -> Int { (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0 }

        // SVG
        let svg = dir.appendingPathComponent("logo.svg")
        let png = try await svc.convert(source: svg, to: .png)
        print("svg->png", png.lastPathComponent, size(png))
        check(size(png).0 == 2048 && size(png).1 == 1365, "svg (240x160) rasterised at 2048 wide, aspect kept")
        let pdf = try await svc.convert(source: svg, to: .pdf)
        check(bytes(pdf) > 0, "svg->pdf")

        // image tools
        let photo = dir.appendingPathComponent("small.jpg")   // already heavily compressed
        let sample = dir.appendingPathComponent("sample.jpg")  // 1200 x 900
        do {
            _ = try await svc.apply(.compressImage, to: photo)
            check(false, "already-small jpeg should be refused")
        } catch { check(error.localizedDescription.contains("已经很小"), "already-small file refused: \(error.localizedDescription)") }
        let big = dir.appendingPathComponent("big.jpg")
        let small = try await svc.apply(.compressImage, to: big)
        print("compress", small.lastPathComponent, bytes(big), "->", bytes(small), size(small))
        check(bytes(small) < bytes(big) && size(small).0 == 2560, "big photo compressed and capped at 2560")
        let half = try await svc.apply(.halveImage, to: sample)
        check(size(half) == (600, 450), "halve 1200x900 -> \(size(half))")
        let square = try await svc.apply(.cropImage(width: 1, height: 1), to: sample)
        check(size(square) == (900, 900), "crop 1:1 -> \(size(square))")
        let wide = try await svc.apply(.cropImage(width: 16, height: 9), to: sample)
        check(size(wide) == (1200, 675), "crop 16:9 -> \(size(wide))")
        let tall = try await svc.apply(.cropImage(width: 9, height: 16), to: sample)
        check(size(tall).0 == 506 && size(tall).1 == 900, "crop 9:16 -> \(size(tall))")

        // video compress
        let clip = dir.appendingPathComponent("clip.mov")
        let v = try await svc.apply(.compressVideo(height: 480), to: clip)
        let asset = AVURLAsset(url: v)
        let track = try await asset.loadTracks(withMediaType: .video).first
        let dims = try await track?.load(.naturalSize)
        print("video", v.lastPathComponent, dims as Any)
        check(v.lastPathComponent.contains("480p") && track != nil, "video compress produced mp4")

        // mp3 (optional components)
        if ExternalTools.hasMP3 {
            let mp3 = try await svc.convert(source: dir.appendingPathComponent("speech.aiff"), to: .mp3)
            let mp3Duration = try await AVURLAsset(url: mp3).load(.duration).seconds
            print("mp3", mp3.lastPathComponent, bytes(mp3), String(format: "%.2fs", mp3Duration))
            check(mp3Duration > 2 && bytes(mp3) > 5000, "aiff -> mp3 decodes with right duration")
            let fromVideo = try await svc.convert(source: clip, to: .mp3)
            check(try await AVURLAsset(url: fromVideo).load(.duration).seconds > 1.5, "video -> mp3")
        } else {
            print("SKIP mp3 (optional components not installed)")
        }
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasPrefix(".phaeton-") }
        check(leftovers.isEmpty, "no temp leftovers \(leftovers)")
        print(failed ? "SOME FAILED" : "ALL DONE")
    }
}
