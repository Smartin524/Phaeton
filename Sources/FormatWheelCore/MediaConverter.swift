#if os(macOS)
import AVFoundation
import CoreGraphics
import Foundation
import ImageIO

/// Audio and video conversion with AVFoundation only: video → audio, audio ↔ audio and
/// video → MP4. Formats macOS cannot read (MKV, WebM, OGG…) are rejected, not guessed.
public struct MediaConverter: Sendable {
    public init() {}

    public func convert(source: URL, to format: OutputFormat,
                        progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        guard source.isFileURL else { throw ConversionError.notAFileURL }
        let asset = AVURLAsset(url: source)
        guard (try? await asset.load(.isReadable)) == true else { throw ConversionError.unreadableMedia }
        let audioTracks = (try? await asset.loadTracks(withMediaType: .audio)) ?? []
        let videoTracks = (try? await asset.loadTracks(withMediaType: .video)) ?? []
        switch format {
        case .m4a, .wav, .aiff, .mp3: if audioTracks.isEmpty { throw ConversionError.noAudioTrack }
        case .mp4, .mov: if videoTracks.isEmpty { throw ConversionError.noVideoTrack }
        default: throw ConversionError.unsupportedFormat
        }

        if format == .mp3 {
            // MP3 has no system encoder: decode to a temporary WAV, then encode with LAME.
            let wav = OutputPublisher.temporaryURL(nextTo: source, fileExtension: "wav")
            defer { OutputPublisher.discard(wav) }
            try await writePCM(asset, track: audioTracks[0], tracks: audioTracks, bigEndian: false, type: .wav,
                               to: wav) { progress($0 * 0.5) }
            return try await ExternalTools.convert(mode: "mp3", input: wav, nextTo: source, format: .mp3)
        }
        let temporary = OutputPublisher.temporaryURL(nextTo: source, fileExtension: format.fileExtension)
        do {
            switch format {
            case .m4a:
                try await export(asset, preset: AVAssetExportPresetAppleM4A, type: .m4a, to: temporary, progress: progress)
            case .mp4, .mov:
                try await export(asset, preset: AVAssetExportPresetHighestQuality, type: format == .mp4 ? .mp4 : .mov,
                                 to: temporary, progress: progress)
            default:
                try await writePCM(asset, track: audioTracks[0], tracks: audioTracks,
                                   bigEndian: format == .aiff, type: format == .aiff ? .aiff : .wav,
                                   to: temporary, progress: progress)
            }
            return try OutputPublisher.publish(temporary, nextTo: source, fileExtension: format.fileExtension)
        } catch {
            OutputPublisher.discard(temporary)
            throw error
        }
    }

    /// Re-encodes a video to MP4 no larger than `height` lines, next to the source with a
    /// "720p"-style suffix. Presets only scale down, never up.
    public func compress(source: URL, height: Int,
                         progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        guard source.isFileURL else { throw ConversionError.notAFileURL }
        let asset = AVURLAsset(url: source)
        guard (try? await asset.load(.isReadable)) == true else { throw ConversionError.unreadableMedia }
        guard let videoTracks = try? await asset.loadTracks(withMediaType: .video), !videoTracks.isEmpty else {
            throw ConversionError.noVideoTrack
        }
        var preset: String
        switch height {
        case 1080...: preset = AVAssetExportPreset1920x1080
        case 720...: preset = AVAssetExportPreset1280x720
        case 480...: preset = AVAssetExportPreset640x480
        default: preset = AVAssetExportPresetMediumQuality   // 0: keep the resolution, smaller file
        }
        if !AVAssetExportSession.exportPresets(compatibleWith: asset).contains(preset) {
            preset = AVAssetExportPresetMediumQuality
        }
        let temporary = OutputPublisher.temporaryURL(nextTo: source, fileExtension: "mp4")
        do {
            try await export(asset, preset: preset, type: .mp4, to: temporary, progress: progress)
            return try OutputPublisher.publish(temporary, nextTo: source, fileExtension: "mp4", suffix: height > 0 ? " \(height)p" : " 压缩")
        } catch {
            OutputPublisher.discard(temporary)
            throw error
        }
    }

    /// Fast trim: copies the chosen segment without re-encoding. Quick and lossless, but the cut
    /// can only start on a key frame, so the first moments may differ slightly from the request.
    public func trim(source: URL, start: Double, end: Double,
                     progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        guard source.isFileURL else { throw ConversionError.notAFileURL }
        let asset = AVURLAsset(url: source)
        guard (try? await asset.load(.isReadable)) == true else { throw ConversionError.unreadableMedia }
        let total = (try? await asset.load(.duration).seconds) ?? 0
        guard end > start, start >= 0, total > 0 else { throw ConversionError.exportFailed("起止时间无效") }
        let range = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600),
                                end: CMTime(seconds: min(end, total), preferredTimescale: 600))
        guard let probe = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
            throw ConversionError.unsupportedFormat
        }
        let ext = source.pathExtension.lowercased()
        var type: AVFileType = (ext == "mp4" || ext == "m4v") ? .mp4 : .mov
        if !probe.supportedFileTypes.contains(type) { type = .mov }
        let outExt = type == .mp4 ? "mp4" : "mov"
        let temporary = OutputPublisher.temporaryURL(nextTo: source, fileExtension: outExt)
        do {
            try await export(asset, preset: AVAssetExportPresetPassthrough, type: type, to: temporary,
                             range: range, progress: progress)
            return try OutputPublisher.publish(temporary, nextTo: source, fileExtension: outExt, suffix: " 剪辑")
        } catch {
            OutputPublisher.discard(temporary)
            throw error
        }
    }

    /// Cuts a segment out of an audio file. Without fades the audio is copied untouched when the
    /// container allows it (quick, lossless); with fades it is re-encoded to M4A, because a volume
    /// ramp cannot be applied to compressed audio without decoding it.
    public func trimAudio(source: URL, start: Double, end: Double, fadeIn: Double = 0, fadeOut: Double = 0,
                          progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        guard source.isFileURL else { throw ConversionError.notAFileURL }
        let asset = AVURLAsset(url: source)
        guard (try? await asset.load(.isReadable)) == true else { throw ConversionError.unreadableMedia }
        let total = (try? await asset.load(.duration).seconds) ?? 0
        guard let track = try? await asset.loadTracks(withMediaType: .audio).first else { throw ConversionError.noAudioTrack }
        guard end > start, start >= 0, total > 0 else { throw ConversionError.exportFailed("起止时间无效") }
        let from = CMTime(seconds: start, preferredTimescale: 600)
        let to = CMTime(seconds: min(end, total), preferredTimescale: 600)
        let range = CMTimeRange(start: from, end: to)
        let length = (to - from).seconds

        let temporary: URL
        let ext: String
        var mix: AVAudioMix?
        var preset = AVAssetExportPresetPassthrough
        var type: AVFileType?
        if fadeIn > 0 || fadeOut > 0 {
            // Ramps are expressed on the source timeline, inside the exported range.
            let parameters = AVMutableAudioMixInputParameters(track: track)
            let fi = min(fadeIn, length / 2), fo = min(fadeOut, length / 2)
            if fi > 0 {
                parameters.setVolumeRamp(fromStartVolume: 0, toEndVolume: 1,
                                         timeRange: CMTimeRange(start: from, duration: CMTime(seconds: fi, preferredTimescale: 600)))
            }
            if fo > 0 {
                parameters.setVolumeRamp(fromStartVolume: 1, toEndVolume: 0,
                                         timeRange: CMTimeRange(start: to - CMTime(seconds: fo, preferredTimescale: 600),
                                                                duration: CMTime(seconds: fo, preferredTimescale: 600)))
            }
            let audioMix = AVMutableAudioMix()
            audioMix.inputParameters = [parameters]
            mix = audioMix
            preset = AVAssetExportPresetAppleM4A
            type = .m4a
            ext = "m4a"
        } else {
            // Copy as-is when the container supports it, otherwise fall back to M4A.
            let wanted: AVFileType?
            switch source.pathExtension.lowercased() {
            case "m4a": wanted = .m4a
            case "wav": wanted = .wav
            case "aif", "aiff": wanted = .aiff
            case "caf": wanted = .caf
            case "mp3": wanted = .mp3
            default: wanted = nil
            }
            if let wanted, let probe = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough),
               probe.supportedFileTypes.contains(wanted) {
                type = wanted
                ext = source.pathExtension.lowercased()
            } else {
                preset = AVAssetExportPresetAppleM4A
                type = .m4a
                ext = "m4a"
            }
        }
        temporary = OutputPublisher.temporaryURL(nextTo: source, fileExtension: ext)
        do {
            try await export(asset, preset: preset, type: type ?? .m4a, to: temporary, range: range, audioMix: mix,
                             progress: progress)
            return try OutputPublisher.publish(temporary, nextTo: source, fileExtension: ext, suffix: " 剪辑")
        } catch {
            OutputPublisher.discard(temporary)
            throw error
        }
    }

    /// Peak levels (0…1) of an audio or video file in `count` buckets, for drawing a waveform.
    public static func waveform(source: URL, buckets count: Int) async -> [Float] {
        let asset = AVURLAsset(url: source)
        guard let track = try? await asset.loadTracks(withMediaType: .audio).first,
              let duration = try? await asset.load(.duration).seconds, duration > 0,
              let reader = try? AVAssetReader(asset: asset) else { return [] }
        let rate = 8000.0
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false,
            AVNumberOfChannelsKey: 1, AVSampleRateKey: rate,
        ])
        guard reader.canAdd(output) else { return [] }
        reader.add(output)
        guard reader.startReading() else { return [] }
        let perBucket = max(1, Int(duration * rate) / count)
        var peaks = [Float](repeating: 0, count: count)
        var index = 0
        while let buffer = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            var data = Data(count: length)
            data.withUnsafeMutableBytes { raw in
                if let base = raw.baseAddress { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: base) }
            }
            data.withUnsafeBytes { raw in
                for sample in raw.bindMemory(to: Int16.self) {
                    let bucket = min(count - 1, index / perBucket)
                    peaks[bucket] = max(peaks[bucket], Float(abs(Int32(sample))) / 32768)
                    index += 1
                }
            }
        }
        let loudest = peaks.max() ?? 0
        return loudest > 0 ? peaks.map { $0 / loudest } : peaks
    }

    /// Saves the frame at `seconds` as a PNG next to the video.
    public static func extractFrame(source: URL, at seconds: Double) async throws -> URL {
        guard source.isFileURL else { throw ConversionError.notAFileURL }
        let asset = AVURLAsset(url: source)
        guard (try? await asset.load(.isReadable)) == true else { throw ConversionError.unreadableMedia }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let image: CGImage
        do {
            image = try await generator.image(at: CMTime(seconds: max(0, seconds), preferredTimescale: 600)).image
        } catch {
            throw ConversionError.exportFailed("无法读取这一帧")
        }
        let temporary = OutputPublisher.temporaryURL(nextTo: source, fileExtension: "png")
        do {
            guard let destination = CGImageDestinationCreateWithURL(temporary as CFURL, "public.png" as CFString, 1, nil) else {
                throw ConversionError.cannotCreateEncoder
            }
            CGImageDestinationAddImage(destination, image, nil)
            guard CGImageDestinationFinalize(destination) else { throw ConversionError.encodingFailed }
            return try OutputPublisher.publish(temporary, nextTo: source, fileExtension: "png",
                                               suffix: String(format: " 帧 %.1fs", seconds))
        } catch {
            OutputPublisher.discard(temporary)
            throw error
        }
    }

    /// Rough size of the compressed file, from the export session's own estimate.
    public func estimateCompressedBytes(source: URL, height: Int) async -> Int? {
        let asset = AVURLAsset(url: source)
        let preset: String
        switch height {
        case 1080...: preset = AVAssetExportPreset1920x1080
        case 720...: preset = AVAssetExportPreset1280x720
        case 480...: preset = AVAssetExportPreset640x480
        default: preset = AVAssetExportPresetMediumQuality
        }
        guard let session = AVAssetExportSession(asset: asset, presetName: preset) else { return nil }
        session.outputFileType = .mp4
        let bytes = session.estimatedOutputFileLength
        return bytes > 0 ? Int(bytes) : nil
    }

    func export(_ asset: AVAsset, preset: String, type: AVFileType, to url: URL,
                range: CMTimeRange? = nil, audioMix: AVAudioMix? = nil,
                videoComposition: AVVideoComposition? = nil, fileLengthLimit: Int64? = nil,
                keepsPitch: Bool = false,
                progress: @escaping @Sendable (Double) -> Void) async throws {
        guard let session = AVAssetExportSession(asset: asset, presetName: preset) else {
            throw ConversionError.unsupportedFormat
        }
        session.outputURL = url
        session.outputFileType = type
        if let range { session.timeRange = range }
        if let audioMix { session.audioMix = audioMix }
        if let videoComposition { session.videoComposition = videoComposition }
        if let fileLengthLimit { session.fileLengthLimit = fileLengthLimit }
        if keepsPitch { session.audioTimePitchAlgorithm = .spectral }
        let box = UncheckedBox(session)
        let poll = Task {
            while !Task.isCancelled {
                progress(Double(box.value.progress))
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
        }
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                box.value.exportAsynchronously { continuation.resume() }
            }
        } onCancel: {
            box.value.cancelExport()
        }
        poll.cancel()
        switch session.status {
        case .completed: progress(1)
        case .cancelled: throw ConversionError.cancelled
        default: throw ConversionError.exportFailed(session.error?.localizedDescription ?? "未知错误")
        }
    }

    private func writePCM(_ asset: AVAsset, track: AVAssetTrack, tracks: [AVAssetTrack], bigEndian: Bool,
                          type: AVFileType, to url: URL,
                          progress: @escaping @Sendable (Double) -> Void) async throws {
        var sampleRate = 44_100.0
        var channels = 2
        if let description = try? await track.load(.formatDescriptions).first,
           let basic = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee {
            sampleRate = basic.mSampleRate
            channels = max(1, min(Int(basic.mChannelsPerFrame), 2))
        }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: bigEndian,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let duration = max(0.001, (try? await asset.load(.duration).seconds) ?? 0.001)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: settings)
        guard reader.canAdd(output) else { throw ConversionError.unreadableMedia }
        reader.add(output)
        let writer = try AVAssetWriter(outputURL: url, fileType: type)
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
        guard writer.canAdd(input) else { throw ConversionError.unsupportedFormat }
        writer.add(input)
        guard reader.startReading() else { throw ConversionError.exportFailed(reader.error?.localizedDescription ?? "无法读取") }
        guard writer.startWriting() else { throw ConversionError.exportFailed(writer.error?.localizedDescription ?? "无法写入") }
        writer.startSession(atSourceTime: .zero)

        let pump = UncheckedBox((reader: reader, writer: writer, input: input, output: output))
        let queue = DispatchQueue(label: "Phaeton.pcm")
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                pump.value.input.requestMediaDataWhenReady(on: queue) {
                    let p = pump.value
                    while p.input.isReadyForMoreMediaData {
                        guard let buffer = p.output.copyNextSampleBuffer() else {
                            p.input.markAsFinished()
                            continuation.resume()
                            return
                        }
                        progress(min(1, CMSampleBufferGetPresentationTimeStamp(buffer).seconds / duration))
                        if !p.input.append(buffer) {
                            p.reader.cancelReading()
                            p.input.markAsFinished()
                            continuation.resume()
                            return
                        }
                    }
                }
            }
        } onCancel: {
            pump.value.reader.cancelReading()
        }
        if Task.isCancelled || reader.status == .cancelled {
            writer.cancelWriting()
            throw ConversionError.cancelled
        }
        if reader.status == .failed {
            writer.cancelWriting()
            throw ConversionError.exportFailed(reader.error?.localizedDescription ?? "读取失败")
        }
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw ConversionError.exportFailed(writer.error?.localizedDescription ?? "写入失败")
        }
        progress(1)
    }
}

/// AVFoundation objects are thread-safe for the calls made here but not marked Sendable.
private final class UncheckedBox<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}
#endif
