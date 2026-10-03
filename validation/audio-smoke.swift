import AVFoundation
import Foundation

func rms(_ url: URL, from: Double, to: Double) async -> Float {
    let asset = AVURLAsset(url: url)
    guard let track = try? await asset.loadTracks(withMediaType: .audio).first,
          let reader = try? AVAssetReader(asset: asset) else { return -1 }
    reader.timeRange = CMTimeRange(start: CMTime(seconds: from, preferredTimescale: 600), end: CMTime(seconds: to, preferredTimescale: 600))
    let output = AVAssetReaderTrackOutput(track: track, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 16,
        AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false, AVNumberOfChannelsKey: 1])
    reader.add(output); reader.startReading()
    var sum = 0.0, n = 0.0
    while let buffer = output.copyNextSampleBuffer(), let block = CMSampleBufferGetDataBuffer(buffer) {
        let length = CMBlockBufferGetDataLength(block)
        var data = Data(count: length)
        data.withUnsafeMutableBytes { raw in if let b = raw.baseAddress { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: b) } }
        data.withUnsafeBytes { raw in for s in raw.bindMemory(to: Int16.self) { let v = Double(s) / 32768; sum += v * v; n += 1 } }
    }
    return n > 0 ? Float((sum / n).squareRoot()) : 0
}

@main struct T {
    static func main() async throws {
        let dir = URL(fileURLWithPath: CommandLine.arguments[1])
        let src = dir.appendingPathComponent("speech.aiff")
        var failed = false
        func check(_ ok: Bool, _ msg: String) { print(ok ? "PASS" : "FAIL", msg); if !ok { failed = true } }

        let plain = try await MediaConverter().trimAudio(source: src, start: 0.5, end: 2.0) { _ in }
        let d1 = try await AVURLAsset(url: plain).load(.duration).seconds
        print("plain", plain.lastPathComponent, d1)
        check(plain.pathExtension == "aiff" && abs(d1 - 1.5) < 0.1, "no fades: copied as AIFF, 1.5 s")

        let faded = try await MediaConverter().trimAudio(source: src, start: 0.2, end: 2.4, fadeIn: 0.5, fadeOut: 0.5) { _ in }
        let d2 = try await AVURLAsset(url: faded).load(.duration).seconds
        print("faded", faded.lastPathComponent, d2)
        check(faded.pathExtension == "m4a" && abs(d2 - 2.2) < 0.15, "fades: M4A, 2.2 s")
        // Compare with the same range cut without fades, so the speech content itself cancels out.
        let reference = try await MediaConverter().trimAudio(source: src, start: 0.2, end: 2.4) { _ in }
        let headRef = await rms(reference, from: 0, to: 0.1), tailRef = await rms(reference, from: d2 - 0.1, to: d2)
        let head = await rms(faded, from: 0, to: 0.1), tail = await rms(faded, from: d2 - 0.1, to: d2)
        print("rms head faded/ref", head, headRef, "tail faded/ref", tail, tailRef)
        check(head < headRef * 0.4, "fade in lowers the start")
        check(tail < tailRef * 0.4, "fade out lowers the end")

        let peaks = await MediaConverter.waveform(source: src, buckets: 120)
        print("waveform", peaks.count, peaks.max() ?? 0)
        check(peaks.count == 120 && (peaks.max() ?? 0) > 0.99 && peaks.contains(where: { $0 < 0.2 }), "waveform has 120 normalised buckets with dynamics")

        do { _ = try await MediaConverter().trimAudio(source: src, start: 2, end: 1) { _ in }; check(false, "bad range accepted") }
        catch { check(true, "bad range refused") }
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasPrefix(".phaeton-") }
        check(leftovers.isEmpty, "no temp leftovers")
        print(failed ? "SOME FAILED" : "ALL DONE")
    }
}
