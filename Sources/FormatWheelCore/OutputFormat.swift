import Foundation
import UniformTypeIdentifiers

public enum OutputFormat: String, CaseIterable, Identifiable, Sendable {
    case png, jpeg, webp, heic, pdf   // images, documents
    case m4a, wav, aiff, mp3, mp4, mov                // audio and video
    case txt, md, rtf, docx      // documents

    public var id: String { rawValue }
    public var title: String { rawValue.uppercased() }
    public var fileExtension: String { self == .jpeg ? "jpg" : rawValue }
}

/// The kind of file being dragged. It decides which formats the wheel offers.
public enum FileKind: String, Sendable {
    case image, audio, video, document

    private static let textExtensions: Set<String> = ["txt", "text", "md", "markdown", "rtf", "rtfd", "doc", "docx", "odt"]

    public init?(_ url: URL) {
        let ext = url.pathExtension.lowercased()
        let type = UTType(filenameExtension: ext)
        if ext == "pdf" || type?.conforms(to: .pdf) == true {
            self = .document
        } else if Self.textExtensions.contains(ext) {
            self = .document
        } else if let type, type.conforms(to: .movie) {
            self = .video
        } else if let type, type.conforms(to: .audio) {
            self = .audio
        } else if let type, type.conforms(to: .image) {
            self = .image
        } else {
            return nil
        }
    }

    /// Formats worth offering for these sources, leaving out a format every source
    /// already has.
    public func outputs(for urls: [URL]) -> [OutputFormat] {
        let all: [OutputFormat]
        switch self {
        case .image: all = [.png, .jpeg, .webp, .heic, .pdf, .txt]
        case .audio: all = [.m4a, .wav, .aiff, .mp3]
        case .video: all = [.m4a, .wav, .aiff, .mp3, .mp4, .mov]
        case .document:
            // Offer only what every selected file can become: PDFs and text documents
            // share TXT, MD and DOCX (PDF → DOCX needs the optional components, offered on first use).
            let pdfs = urls.filter { $0.pathExtension.lowercased() == "pdf" }.count
            if pdfs == urls.count {
                all = [.png, .jpeg, .txt, .md, .docx]
            } else if pdfs == 0 {
                all = [.txt, .md, .rtf, .docx, .pdf]
            } else {
                all = [.txt, .md, .docx]
            }
        }
        return all.filter { format in
            !urls.allSatisfy { Self.canonicalExtension($0) == format.fileExtension }
        }
    }

    private static func canonicalExtension(_ url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "jpeg", "jpe": return "jpg"
        case "aif": return "aiff"
        case "heif": return "heic"
        case "text": return "txt"
        case "markdown": return "md"
        case let other: return other
        }
    }
}
