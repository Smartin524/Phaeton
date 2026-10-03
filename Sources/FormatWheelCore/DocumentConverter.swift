#if os(macOS)
import AppKit
import Foundation
import PDFKit
import UniformTypeIdentifiers
import Vision

/// Document conversion with system frameworks only. PDF → TXT reads the text layer and
/// falls back to Vision OCR for scans. TXT / RTF / DOC / DOCX / ODT convert among
/// TXT, RTF, DOCX and PDF; layout fidelity is that of NSAttributedString.
public struct DocumentConverter: Sendable {
    public init() {}

    private static let maximumOCRPages = 100
    private static let maximumPages = 300

    public func convert(source: URL, to format: OutputFormat) async throws -> URL {
        guard source.isFileURL else { throw ConversionError.notAFileURL }
        let temporary = OutputPublisher.temporaryURL(nextTo: source, fileExtension: format.fileExtension)
        do {
            if source.pathExtension.lowercased() == "pdf" {
                if format == .docx {
                    return try await ExternalTools.convert(mode: "pdf2docx", input: source, nextTo: source, format: .docx)
                }
                if format == .png || format == .jpeg {
                    return try Self.renderPages(of: source, as: format)
                }
                guard format == .txt else { throw ConversionError.unsupportedFormat }
                let text = try await Self.pdfText(source)
                try Data(text.utf8).write(to: temporary, options: .withoutOverwriting)
            } else {
                let text = try Self.readAttributedText(source)
                switch format {
                case .txt:
                    try Data(text.string.utf8).write(to: temporary, options: .withoutOverwriting)
                case .rtf, .docx:
                    let type: NSAttributedString.DocumentType = format == .rtf ? .rtf : .officeOpenXML
                    let data = try text.data(from: NSRange(location: 0, length: text.length),
                                             documentAttributes: [.documentType: type])
                    try data.write(to: temporary, options: .withoutOverwriting)
                case .pdf:
                    let copy = text.copy() as! NSAttributedString
                    try await MainActor.run { try Self.renderPDF(copy, to: temporary) }
                default:
                    throw ConversionError.unsupportedFormat
                }
            }
            try Task.checkCancellation()
            return try OutputPublisher.publish(temporary, nextTo: source, fileExtension: format.fileExtension)
        } catch {
            OutputPublisher.discard(temporary)
            throw error
        }
    }

    /// One page gives a single image next to the PDF; several pages go into a new folder
    /// named after the PDF, one numbered image per page. Pages render at 2× (max 4096 px).
    private static func renderPages(of source: URL, as format: OutputFormat) throws -> URL {
        guard let document = PDFDocument(url: source), document.pageCount > 0 else {
            throw ConversionError.unreadableDocument
        }
        guard document.pageCount <= maximumPages else { throw ConversionError.tooManyPages(maximumPages) }
        let type = format == .png ? UTType.png : UTType.jpeg
        func write(page index: Int, to url: URL) throws {
            try autoreleasepool {
                guard let page = document.page(at: index) else { throw ConversionError.unreadableDocument }
                let box = page.bounds(for: .cropBox)
                let scale = min(2.0, 4096 / max(box.width, box.height))
                let image = page.thumbnail(of: NSSize(width: box.width * scale, height: box.height * scale), for: .cropBox)
                guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
                      let destination = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil)
                else { throw ConversionError.cannotCreateEncoder }
                let options: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.92]
                CGImageDestinationAddImage(destination, cgImage, options as CFDictionary)
                guard CGImageDestinationFinalize(destination) else { throw ConversionError.encodingFailed }
            }
        }
        if document.pageCount == 1 {
            let temporary = OutputPublisher.temporaryURL(nextTo: source, fileExtension: format.fileExtension)
            do {
                try write(page: 0, to: temporary)
                try Task.checkCancellation()
                return try OutputPublisher.publish(temporary, nextTo: source, fileExtension: format.fileExtension)
            } catch {
                OutputPublisher.discard(temporary)
                throw error
            }
        }
        let folder = try OutputPublisher.makeFolder(nextTo: source)
        let width = String(document.pageCount).count
        for index in 0..<document.pageCount {
            do {
                try Task.checkCancellation()
            } catch {
                // The folder is new and holds only our pages; a half-filled one is useless.
                try? FileManager.default.removeItem(at: folder)
                throw error
            }
            let number = String(format: "%0\(width)d", index + 1)
            try write(page: index, to: folder.appendingPathComponent("\(number).\(format.fileExtension)"))
        }
        return folder
    }

    private static func readAttributedText(_ url: URL) throws -> NSAttributedString {
        let ext = url.pathExtension.lowercased()
        if ext == "txt" || ext == "text" || ext == "md" {
            var encoding = String.Encoding.utf8
            if let text = try? String(contentsOf: url, usedEncoding: &encoding) {
                return plain(text)
            }
            let gb18030 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
                CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
            for candidate in [String.Encoding.utf8, .utf16, gb18030] {
                if let text = try? String(contentsOf: url, encoding: candidate) { return plain(text) }
            }
            throw ConversionError.unreadableDocument
        }
        guard let text = try? NSAttributedString(url: url, options: [:], documentAttributes: nil),
              text.length > 0 else { throw ConversionError.unreadableDocument }
        return text
    }

    private static func plain(_ text: String) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 12)])
    }

    /// Text layer page by page; pages without one (scans, also inside a mixed PDF) go
    /// through Vision OCR. More than `maximumOCRPages` such pages is refused, not truncated.
    private static func pdfText(_ url: URL) async throws -> String {
        guard let document = PDFDocument(url: url), document.pageCount > 0 else {
            throw ConversionError.unreadableDocument
        }
        let layers = (0..<document.pageCount).map { document.page(at: $0)?.string ?? "" }
        let scanned = layers.filter { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.count
        guard scanned <= maximumOCRPages else { throw ConversionError.tooManyPages(maximumOCRPages) }
        var pages: [String] = []
        for (index, layer) in layers.enumerated() {
            try Task.checkCancellation()
            if !layer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                pages.append(layer)
                continue
            }
            guard let page = document.page(at: index) else { continue }
            try autoreleasepool {
                let bounds = page.bounds(for: .mediaBox)
                let scale = min(3.0, 3000 / max(bounds.width, bounds.height))
                let image = page.thumbnail(of: NSSize(width: bounds.width * scale, height: bounds.height * scale), for: .mediaBox)
                guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.automaticallyDetectsLanguage = true
                try VNImageRequestHandler(cgImage: cgImage).perform([request])
                let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
                pages.append(lines.joined(separator: "\n"))
            }
        }
        let text = pages.joined(separator: "\n\n")
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { throw ConversionError.noTextFound }
        return text
    }

    @MainActor
    private static func renderPDF(_ text: NSAttributedString, to url: URL) throws {
        let paper = NSSize(width: 595, height: 842)
        let margin: CGFloat = 54
        let info = NSPrintInfo(dictionary: [
            .jobDisposition: NSPrintInfo.JobDisposition.save,
            .jobSavingURL: url,
        ])
        info.paperSize = paper
        info.topMargin = margin; info.bottomMargin = margin
        info.leftMargin = margin; info.rightMargin = margin
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: paper.width - margin * 2, height: 100))
        view.isVerticallyResizable = true
        view.textContainer?.widthTracksTextView = true
        view.textStorage?.setAttributedString(text)
        if let container = view.textContainer, let layout = view.layoutManager {
            layout.ensureLayout(for: container)
            view.frame.size.height = max(100, layout.usedRect(for: container).height + 20)
        }
        let operation = NSPrintOperation(view: view, printInfo: info)
        operation.showsPrintPanel = false
        operation.showsProgressPanel = false
        guard operation.run() else { throw ConversionError.exportFailed("无法生成 PDF") }
    }
}
#endif
