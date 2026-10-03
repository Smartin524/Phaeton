#if os(macOS)
import AppKit
import Foundation
import PDFKit
import UniformTypeIdentifiers
import Vision

/// Document conversion with system frameworks only. PDF → TXT / MD reads the text layer and
/// falls back to Vision OCR for scans. TXT / MD / RTF / DOC / DOCX / ODT convert among
/// TXT, MD, RTF, DOCX and PDF; layout fidelity is that of NSAttributedString. Markdown is read
/// as Markdown (headings, lists, tables become formatting) and written with structure kept, for
/// pasting into an AI chat.
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
                let text: String
                switch format {
                case .txt: text = try await Self.pdfText(source)
                case .md: text = try Self.pdfMarkdown(source)
                default: throw ConversionError.unsupportedFormat
                }
                try Data(text.utf8).write(to: temporary, options: .withoutOverwriting)
            } else if format == .md {
                try Data(Self.markdown(of: source).utf8).write(to: temporary, options: .withoutOverwriting)
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
                    // AppKit printing (tables, pictures and searchable CJK text all come out right).
                    // It must run on the main thread, but a 170-page text takes well under half a second.
                    let copy = text.copy() as! NSAttributedString
                    let title = source.deletingPathExtension().lastPathComponent
                    try await MainActor.run { try Self.renderPDF(copy, title: title, to: temporary) }
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
        do {
            let width = String(document.pageCount).count
            for index in 0..<document.pageCount {
                try Task.checkCancellation()
                let number = String(format: "%0\(width)d", index + 1)
                try write(page: index, to: folder.appendingPathComponent("\(number).\(format.fileExtension)"))
            }
        } catch {
            // The folder is new and holds only our pages; a half-filled one is useless.
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
        return folder
    }

    private static let markdownExtensions: Set<String> = ["md", "markdown"]

    /// Any document as Markdown. DOCX is read from its XML (AppKit's reader loses tables, links and
    /// list structure); plain text and Markdown are kept as they are.
    private static func markdown(of url: URL) throws -> String {
        let ext = url.pathExtension.lowercased()
        if markdownExtensions.contains(ext) || ext == "txt" || ext == "text" { return try readPlainText(url) }
        if ext == "docx", let converted = try? DocxMarkdown.convert(url),
           !converted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return converted
        }
        let markdown = AttributedMarkdown.convert(try readAttributedText(url))
        guard !markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ConversionError.noTextFound }
        return markdown
    }

    /// PDF as Markdown; scanned pages are read with OCR (the same limit as PDF → TXT).
    private static func pdfMarkdown(_ url: URL) throws -> String {
        guard let document = PDFDocument(url: url), document.pageCount > 0 else {
            throw ConversionError.unreadableDocument
        }
        let scanned = (0..<document.pageCount).filter {
            (document.page(at: $0)?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }.count
        guard scanned <= maximumOCRPages else { throw ConversionError.tooManyPages(maximumOCRPages) }
        let text = try PDFMarkdown.convert(document, ocr: recognizeLines)
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { throw ConversionError.noTextFound }
        return text
    }

    /// Plain text in whatever encoding it was saved (UTF-8, UTF-16 or GB 18030).
    private static func readPlainText(_ url: URL) throws -> String {
        var encoding = String.Encoding.utf8
        if let text = try? String(contentsOf: url, usedEncoding: &encoding) { return text }
        let gb18030 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
        for candidate in [String.Encoding.utf8, .utf16, gb18030] {
            if let text = try? String(contentsOf: url, encoding: candidate) { return text }
        }
        throw ConversionError.unreadableDocument
    }

    private static func readAttributedText(_ url: URL) throws -> NSAttributedString {
        let ext = url.pathExtension.lowercased()
        if markdownExtensions.contains(ext) { return MarkdownReader.attributedString(from: try readPlainText(url)) }
        if ext == "txt" || ext == "text" { return plain(try readPlainText(url)) }
        guard let text = try? NSAttributedString(url: url, options: [:], documentAttributes: nil),
              text.length > 0 else { throw ConversionError.unreadableDocument }
        return text
    }

    private static func plain(_ text: String) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [.font: MarkdownReader.documentFont(12)])
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
            pages.append(try recognizeText(page))
        }
        let text = pages.joined(separator: "\n\n")
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { throw ConversionError.noTextFound }
        return text
    }

    /// Vision OCR of one scanned page, rendered at up to 3000 px.
    private static func recognizeText(_ page: PDFPage) throws -> String {
        try recognizeLines(page).map(\.text).joined(separator: "\n")
    }

    /// The page's lines in reading order, each with its height in points (a stand-in for font size).
    private static func recognizeLines(_ page: PDFPage) throws -> [(text: String, height: Double)] {
        try autoreleasepool {
            let bounds = page.bounds(for: .mediaBox)
            let scale = min(3.0, 3000 / max(bounds.width, bounds.height))
            let image = page.thumbnail(of: NSSize(width: bounds.width * scale, height: bounds.height * scale), for: .mediaBox)
            guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return [] }
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.automaticallyDetectsLanguage = true
            try VNImageRequestHandler(cgImage: cgImage).perform([request])
            return (request.results ?? []).compactMap { observation in
                observation.topCandidates(1).first.map { ($0.string, Double(observation.boundingBox.height * bounds.height)) }
            }
        }
    }

    /// Every font gets Hiragino Sans GB as its fallback for Chinese (see MarkdownReader.documentFont):
    /// documents set in Times, Calibri or Helvetica then print Chinese that copies out correctly.
    @MainActor
    private static func chineseFallback(_ text: NSAttributedString) -> NSAttributedString {
        let copy = NSMutableAttributedString(attributedString: text)
        copy.enumerateAttribute(.font, in: NSRange(location: 0, length: copy.length)) { value, range, _ in
            if let font = value as? NSFont { copy.addAttribute(.font, value: MarkdownReader.withChineseFallback(font), range: range) }
        }
        return copy
    }

    /// A4 with 54 pt margins. The job title becomes the PDF's title, so viewers show the file name
    /// instead of "Untitled".
    @MainActor
    private static func renderPDF(_ text: NSAttributedString, title: String, to url: URL) throws {
        let paper = NSSize(width: 595, height: 842)
        let margin: CGFloat = 54
        let info = NSPrintInfo(dictionary: [
            .jobDisposition: NSPrintInfo.JobDisposition.save,
            .jobSavingURL: url,
        ])
        info.paperSize = paper
        info.topMargin = margin; info.bottomMargin = margin
        info.leftMargin = margin; info.rightMargin = margin
        // Two text engines, each with a flaw: TextKit 2 (the default) prints text that copies and
        // searches correctly but stacks table cells one under another; TextKit 1 draws real tables
        // but its PDF text comes back as look-alike radicals ("⼀" for "一"). Tables decide.
        var hasTables = false
        text.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: text.length)) { value, _, stop in
            if let style = value as? NSParagraphStyle, style.textBlocks.contains(where: { $0 is NSTextTableBlock }) {
                hasTables = true
                stop.pointee = true
            }
        }
        let view = NSTextView(usingTextLayoutManager: !hasTables)
        view.frame = NSRect(x: 0, y: 0, width: paper.width - margin * 2, height: 100)
        view.isVerticallyResizable = true
        view.textContainer?.widthTracksTextView = true
        view.textStorage?.setAttributedString(chineseFallback(text))
        // The view must be as tall as the text, or the end is cut off. Measure with a separate
        // layout: laying out the view's own text before printing makes the PDF lose which character
        // each glyph is, so copied or searched Chinese comes back as look-alike radicals ("⼀" for "一").
        let measure = NSTextStorage(attributedString: view.textStorage ?? text)
        let layout = NSLayoutManager()
        measure.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: view.frame.width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = view.textContainer?.lineFragmentPadding ?? container.lineFragmentPadding
        layout.addTextContainer(container)
        layout.ensureLayout(for: container)
        // A little spare room: the two engines do not measure exactly alike.
        view.frame.size.height = max(100, layout.usedRect(for: container).height + 40)
        let operation = NSPrintOperation(view: view, printInfo: info)
        operation.jobTitle = title
        operation.showsPrintPanel = false
        operation.showsProgressPanel = false
        guard operation.run() else { throw ConversionError.exportFailed("无法生成 PDF") }
    }
}
#endif
