import AVFoundation
import Foundation
import ImageIO

@main struct T {
    static func main() async throws {
        let dir = URL(fileURLWithPath: CommandLine.arguments[1])
        let clip = dir.appendingPathComponent("clip.mov")
        var failed = false
        func check(_ ok: Bool, _ msg: String) { print(ok ? "PASS" : "FAIL", msg); if !ok { failed = true } }

        let cut = try await MediaConverter().trim(source: clip, start: 0.5, end: 1.5) { _ in }
        let asset = AVURLAsset(url: cut)
        let duration = try await asset.load(.duration).seconds
        let hasVideo = try await !asset.loadTracks(withMediaType: .video).isEmpty
        let hasAudio = try await !asset.loadTracks(withMediaType: .audio).isEmpty
        print("trim", cut.lastPathComponent, String(format: "%.2fs", duration), hasVideo, hasAudio)
        check(duration > 0.5 && duration < 1.6 && hasVideo && hasAudio && cut.lastPathComponent.contains("剪辑"), "fast trim keeps audio+video and about one second")

        let frame = try await MediaConverter.extractFrame(source: clip, at: 1.0)
        let source = CGImageSourceCreateWithURL(frame as CFURL, nil)!
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as! [CFString: Any]
        print("frame", frame.lastPathComponent, props[kCGImagePropertyPixelWidth]!, props[kCGImagePropertyPixelHeight]!)
        check((props[kCGImagePropertyPixelWidth] as? Int) == 320 && frame.pathExtension == "png", "frame is a 320-wide png")

        do { _ = try await MediaConverter().trim(source: clip, start: 1.5, end: 0.5) { _ in }; check(false, "bad range accepted") }
        catch { check(true, "bad range refused: \(error.localizedDescription)") }
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasPrefix(".phaeton-") }
        check(leftovers.isEmpty, "no temp leftovers")
        print(failed ? "SOME FAILED" : "ALL DONE")
    }
}
