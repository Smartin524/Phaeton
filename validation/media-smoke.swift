import AVFoundation
import AppKit

func makeVideo(at url: URL) async throws {
    let w = try AVAssetWriter(outputURL: url, fileType: .mp4)
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 320, AVVideoHeightKey: 240])
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB, kCVPixelBufferWidthKey as String: 320, kCVPixelBufferHeightKey as String: 240])
    w.add(input); w.startWriting(); w.startSession(atSourceTime: .zero)
    for i in 0..<30 {
        while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 5_000_000) }
        var pb: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &pb)
        CVPixelBufferLockBaseAddress(pb!, [])
        memset(CVPixelBufferGetBaseAddress(pb!), Int32(i * 8), CVPixelBufferGetDataSize(pb!))
        CVPixelBufferUnlockBaseAddress(pb!, [])
        adaptor.append(pb!, withPresentationTime: CMTime(value: Int64(i), timescale: 15))
    }
    input.markAsFinished(); await w.finishWriting()
}

func check(_ cond: Bool, _ msg: String) { print(cond ? "PASS" : "FAIL", msg); if !cond { exit(1) } }

@main struct T {
    static func main() async throws {
        let dir = URL(fileURLWithPath: CommandLine.arguments[1])
        let svc = ConversionService()
        // audio source made by `say`: <dir>/speech.aiff, video: build from silent video + speech
        let silent = dir.appendingPathComponent("silent.mp4")
        try? FileManager.default.removeItem(at: silent)
        try await makeVideo(at: silent)
        let comp = AVMutableComposition()
        let v = AVURLAsset(url: silent), a = AVURLAsset(url: dir.appendingPathComponent("speech.aiff"))
        let vt = try await v.loadTracks(withMediaType: .video)[0], at = try await a.loadTracks(withMediaType: .audio)[0]
        let range = CMTimeRange(start: .zero, duration: try await v.load(.duration))
        try comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)!.insertTimeRange(range, of: vt, at: .zero)
        try comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)!.insertTimeRange(range, of: at, at: .zero)
        let movie = dir.appendingPathComponent("clip.mov")
        try? FileManager.default.removeItem(at: movie)
        let ex = AVAssetExportSession(asset: comp, presetName: AVAssetExportPresetHighestQuality)!
        ex.outputURL = movie; ex.outputFileType = .mov
        await ex.export()
        check(ex.status == .completed, "built test clip.mov")

        for (src, fmt) in [("clip.mov", OutputFormat.m4a), ("clip.mov", .wav), ("clip.mov", .mp4), ("speech.aiff", .m4a), ("speech.aiff", .wav)] {
            let out = try await svc.convert(source: dir.appendingPathComponent(src), to: fmt) { _ in }
            let asset = AVURLAsset(url: out)
            let dur = try await asset.load(.duration).seconds
            let hasAudio = try await !asset.loadTracks(withMediaType: .audio).isEmpty
            let hasVideo = try await !asset.loadTracks(withMediaType: .video).isEmpty
            print("OUT", out.lastPathComponent, String(format: "%.2fs", dur), "audio", hasAudio, "video", hasVideo)
            check(dur > 0.5 && (fmt == .mp4 ? hasVideo : (hasAudio && !hasVideo)), "\(src) -> \(fmt)")
        }
        let aiff = try await svc.convert(source: dir.appendingPathComponent("clip.mov"), to: .wav)
        check(aiff.lastPathComponent != "clip.wav", "repeat name increments: \(aiff.lastPathComponent)")
        _ = NSApplication.shared
        for (src, fmt) in [("notes.txt", OutputFormat.rtf), ("notes.txt", .docx), ("notes.txt", .pdf), ("notes.rtf", .txt), ("notes.docx", .txt)] {
            let s = dir.appendingPathComponent(src)
            if src == "notes.rtf" || src == "notes.docx" { if !FileManager.default.fileExists(atPath: s.path) { continue } }
            let out = try await svc.convert(source: s, to: fmt)
            print("OUT", out.lastPathComponent, (try? out.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? -1)
            if fmt == .pdf { check(CGPDFDocument(out as CFURL)!.numberOfPages >= 1, "txt->pdf") }
            if fmt == .txt { check(try String(contentsOf: out).contains("你好"), "text content kept") }
        }
        let rtf = dir.appendingPathComponent("notes.rtf")
        let docx = dir.appendingPathComponent("notes.docx")
        check(FileManager.default.fileExists(atPath: rtf.path), "rtf exists")
        check(try String(contentsOf: try await svc.convert(source: rtf, to: .txt)).contains("你好"), "rtf->txt")
        check(try String(contentsOf: try await svc.convert(source: docx, to: .txt)).contains("你好"), "docx->txt")
        let pdf = try await svc.convert(source: dir.appendingPathComponent("notes.txt"), to: .pdf)
        let t = try await svc.convert(source: pdf, to: .txt)
        check(try String(contentsOf: t).contains("你好"), "pdf->txt")
        print("ALL DONE")
    }
}
