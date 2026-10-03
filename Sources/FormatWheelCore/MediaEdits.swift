#if os(macOS)
import AVFoundation
import CoreGraphics
import Foundation

/// Joining, muting, speeding up and size-limiting audio and video, with AVFoundation only.
extension MediaConverter {
    /// Puts the clips one after another. Videos are scaled to fit the first clip's frame; clips
    /// without audio simply leave a silent stretch.
    public func join(_ urls: [URL], video: Bool,
                     progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        guard urls.count >= 2 else { throw ConversionError.notEnoughFiles }
        let composition = AVMutableComposition()
        let videoTrack = video ? composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) : nil
        let audioTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
        var cursor = CMTime.zero
        var renderSize = CGSize.zero
        var instructions: [AVMutableVideoCompositionInstruction] = []
        for url in urls {
            let asset = AVURLAsset(url: url)
            guard (try? await asset.load(.isReadable)) == true else { throw ConversionError.unreadableMedia }
            let duration = try await asset.load(.duration)
            let range = CMTimeRange(start: .zero, duration: duration)
            if let videoTrack {
                guard let source = try await asset.loadTracks(withMediaType: .video).first else { throw ConversionError.noVideoTrack }
                try videoTrack.insertTimeRange(range, of: source, at: cursor)
                let natural = try await source.load(.naturalSize)
                let transform = try await source.load(.preferredTransform)
                let shown = natural.applying(transform)
                let size = CGSize(width: abs(shown.width), height: abs(shown.height))
                if renderSize == .zero { renderSize = size }
                let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: videoTrack)
                let scale = min(renderSize.width / size.width, renderSize.height / size.height)
                var fit = transform.concatenating(CGAffineTransform(scaleX: scale, y: scale))
                // Move so the picture is centred in the frame, whatever the rotation put at the origin.
                let box = CGRect(origin: .zero, size: natural).applying(fit)
                fit = fit.concatenating(CGAffineTransform(translationX: (renderSize.width - box.width) / 2 - box.minX,
                                                          y: (renderSize.height - box.height) / 2 - box.minY))
                layer.setTransform(fit, at: cursor)
                let instruction = AVMutableVideoCompositionInstruction()
                instruction.timeRange = CMTimeRange(start: cursor, duration: duration)
                instruction.layerInstructions = [layer]
                instructions.append(instruction)
            } else if (try await asset.loadTracks(withMediaType: .audio)).isEmpty {
                throw ConversionError.noAudioTrack
            }
            if let source = try await asset.loadTracks(withMediaType: .audio).first {
                try audioTrack?.insertTimeRange(range, of: source, at: cursor)
            }
            cursor = cursor + duration
        }
        let first = urls[0]
        var videoComposition: AVMutableVideoComposition?
        if video {
            videoComposition = AVMutableVideoComposition()
            videoComposition?.renderSize = renderSize
            videoComposition?.frameDuration = CMTime(value: 1, timescale: 30)
            videoComposition?.instructions = instructions
        }
        let ext = video ? "mp4" : "m4a"
        let temporary = OutputPublisher.temporaryURL(nextTo: first, fileExtension: ext)
        do {
            try await export(composition, preset: video ? AVAssetExportPresetHighestQuality : AVAssetExportPresetAppleM4A,
                             type: video ? .mp4 : .m4a, to: temporary, videoComposition: videoComposition, progress: progress)
            return try OutputPublisher.publish(temporary, nextTo: first, fileExtension: ext, suffix: " 拼接")
        } catch {
            OutputPublisher.discard(temporary)
            throw error
        }
    }

    /// The same video without its sound; the picture is copied, not re-encoded.
    public func mute(source: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let asset = AVURLAsset(url: source)
        guard (try? await asset.load(.isReadable)) == true else { throw ConversionError.unreadableMedia }
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw ConversionError.noVideoTrack }
        let composition = AVMutableComposition()
        let target = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
        let duration = try await asset.load(.duration)
        try target?.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: track, at: .zero)
        target?.preferredTransform = try await track.load(.preferredTransform)
        let ext = source.pathExtension.lowercased()
        let type: AVFileType = (ext == "mp4" || ext == "m4v") ? .mp4 : .mov
        let outExt = type == .mp4 ? "mp4" : "mov"
        let temporary = OutputPublisher.temporaryURL(nextTo: source, fileExtension: outExt)
        do {
            try await export(composition, preset: AVAssetExportPresetPassthrough, type: type, to: temporary, progress: progress)
            return try OutputPublisher.publish(temporary, nextTo: source, fileExtension: outExt, suffix: " 静音")
        } catch {
            OutputPublisher.discard(temporary)
            throw error
        }
    }

    /// Plays the clip `factor` times as fast (0.5 = half speed), pitch kept natural.
    public func changeSpeed(source: URL, factor: Double,
                            progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        guard factor > 0.1, factor < 20 else { throw ConversionError.exportFailed("速度无效") }
        let asset = AVURLAsset(url: source)
        guard (try? await asset.load(.isReadable)) == true else { throw ConversionError.unreadableMedia }
        let duration = try await asset.load(.duration)
        let composition = AVMutableComposition()
        let full = CMTimeRange(start: .zero, duration: duration)
        guard let video = try await asset.loadTracks(withMediaType: .video).first else { throw ConversionError.noVideoTrack }
        let videoTarget = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
        try videoTarget?.insertTimeRange(full, of: video, at: .zero)
        videoTarget?.preferredTransform = try await video.load(.preferredTransform)
        if let audio = try await asset.loadTracks(withMediaType: .audio).first {
            let audioTarget = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
            try audioTarget?.insertTimeRange(full, of: audio, at: .zero)
        }
        composition.scaleTimeRange(CMTimeRange(start: .zero, duration: duration),
                                   toDuration: CMTime(seconds: duration.seconds / factor, preferredTimescale: 600))
        let label = factor == factor.rounded() ? String(Int(factor)) : String(format: "%g", factor)
        let temporary = OutputPublisher.temporaryURL(nextTo: source, fileExtension: "mp4")
        do {
            try await export(composition, preset: AVAssetExportPresetHighestQuality, type: .mp4, to: temporary,
                             keepsPitch: true, progress: progress)
            return try OutputPublisher.publish(temporary, nextTo: source, fileExtension: "mp4", suffix: " \(label)x")
        } catch {
            OutputPublisher.discard(temporary)
            throw error
        }
    }

    /// Re-encodes so the file is about `bytes` or smaller. The system chooses the bit rate.
    public func compress(source: URL, toBytes bytes: Int,
                         progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let original = (try? source.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? Int.max
        guard bytes > 0, bytes < original else { throw ConversionError.alreadySmall }
        let asset = AVURLAsset(url: source)
        guard (try? await asset.load(.isReadable)) == true else { throw ConversionError.unreadableMedia }
        guard (try? await asset.loadTracks(withMediaType: .video).first) != nil else { throw ConversionError.noVideoTrack }
        let temporary = OutputPublisher.temporaryURL(nextTo: source, fileExtension: "mp4")
        do {
            try await export(asset, preset: AVAssetExportPresetHighestQuality, type: .mp4, to: temporary,
                             fileLengthLimit: Int64(bytes), progress: progress)
            // Re-encoding a file that is already small can make it bigger; never keep that.
            let result = (try? temporary.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? Int.max
            guard result < original else { throw ConversionError.alreadySmall }
            return try OutputPublisher.publish(temporary, nextTo: source, fileExtension: "mp4", suffix: " 压缩")
        } catch {
            OutputPublisher.discard(temporary)
            throw error
        }
    }
}
#endif
