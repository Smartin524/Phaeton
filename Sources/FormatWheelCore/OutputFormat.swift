import Foundation
import UniformTypeIdentifiers

public enum OutputFormat: String, CaseIterable, Identifiable, Sendable {
    case png, jpeg, webp, heic, pdf   // images, documents
    case m4a, wav, aiff, mp3, mp4, mov                // audio and video
    case txt, rtf, docx          // documents

    public var id: String { rawValue }
    public var title: String { rawValue.uppercased() }
    public var fileExtension: String { self == .jpeg ? "jpg" : rawValue }
}

/// The kind of file being dragged. It decides which formats the wheel offers.
public enum FileKind: String, Sendable {
    case image, audio, video, document

    private static let textExtensions: Set<String> = ["txt", "text", "md", "rtf", "rtfd", "doc", "docx", "odt"]

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
        case .image: all = [.png, .jpeg, .webp, .heic, .pdf]
        case .audio: all = [.m4a, .wav, .aiff, .mp3]
        case .video: all = [.m4a, .wav, .aiff, .mp3, .mp4, .mov]
        case .document:
            // Offer only what every selected file can become: PDFs and text documents
            // share TXT and DOCX (PDF → DOCX needs the optional components, offered on first use).
            let pdfs = urls.filter { $0.pathExtension.lowercased() == "pdf" }.count
            if pdfs == urls.count {
                all = [.png, .jpeg, .txt, .docx]
            } else if pdfs == 0 {
                all = [.txt, .rtf, .docx, .pdf]
            } else {
                all = [.txt, .docx]
            }
        }
        return all.filter { format in
            !urls.allSatisfy { Self.canonicalExtension($0) == format.fileExtension }
        }
    }

    /// Tools offered in the wheel's wrench panel for this kind of file.
    public var tools: [ToolAction] {
        switch self {
        case .image:
            return [.compressImage, .halveImage, .cropImage(width: 1, height: 1), .cropImage(width: 4, height: 3),
                    .cropImage(width: 16, height: 9), .cropImage(width: 3, height: 4), .cropImage(width: 9, height: 16)]
        case .video:
            return [.compressVideo(height: 1080), .compressVideo(height: 720), .compressVideo(height: 480)]
        case .audio, .document:
            return []
        }
    }

    private static func canonicalExtension(_ url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "jpeg", "jpe": return "jpg"
        case "aif": return "aiff"
        case "heif": return "heic"
        case "text": return "txt"
        case let other: return other
        }
    }
}

/// An operation that is not a change of format: compress, shrink or crop.
public enum ToolAction: Hashable, Sendable {
    case compressImage
    case halveImage
    case cropImage(width: Int, height: Int)
    case compressVideo(height: Int)

    public var title: String {
        switch self {
        case .compressImage: return "压缩（JPEG 75%）"
        case .halveImage: return "尺寸缩小一半"
        case .cropImage(let w, let h): return "居中裁切 \(w):\(h)"
        case .compressVideo(let height): return "压缩到 \(height)p"
        }
    }

    /// Appended to the file name, e.g. "photo 4x3.jpg".
    var suffix: String {
        switch self {
        case .compressImage: return " 压缩"
        case .halveImage: return " 50%"
        case .cropImage(let w, let h): return " \(w)x\(h)"
        case .compressVideo(let height): return " \(height)p"
        }
    }
}

/// An adapter boundary for conversion backends.
public protocol FileConversionEngine: Sendable {
    var supportedOutputFormats: [OutputFormat] { get }
    func convert(source: URL, to format: OutputFormat) throws -> URL
}

public extension FileConversionEngine {
    var supportedOutputFormats: [OutputFormat] { [.png, .jpeg, .heic, .pdf] }
}
