import Foundation

/// An operation on several dropped files at once, producing one output next to the first.
public enum BatchAction: Hashable, Sendable {
    case mergeImagesToPDF
    case mergePDFs
    case joinVideos
    case joinAudio

    public var title: String {
        switch self {
        case .mergeImagesToPDF, .mergePDFs: return "合并 PDF"
        case .joinVideos, .joinAudio: return "拼接"
        }
    }

    /// The batch action offered when these files are dropped together, if any.
    public static func available(kind: FileKind, urls: [URL]) -> BatchAction? {
        guard urls.count > 1 else { return nil }
        switch kind {
        case .image: return .mergeImagesToPDF
        case .video: return .joinVideos
        case .audio: return .joinAudio
        case .document:
            return urls.allSatisfy { $0.pathExtension.lowercased() == "pdf" } ? .mergePDFs : nil
        }
    }
}
