#if os(macOS)
import AppKit
import Foundation
import PDFKit

/// Merging and splitting PDFs, and building one from several images.
enum PDFTools {
    static func mergeImages(_ urls: [URL]) throws -> URL {
        guard urls.count >= 2 else { throw ConversionError.notEnoughFiles }
        let converter = ImageConverter()
        let document = PDFDocument()
        for url in urls {
            try Task.checkCancellation()
            try autoreleasepool {
                let image = try converter.decodeStillImage(url)
                let picture = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
                guard let page = PDFPage(image: picture) else { throw ConversionError.cannotRenderImage }
                document.insert(page, at: document.pageCount)
            }
        }
        return try write(document, nextTo: urls[0], suffix: " 合并")
    }

    static func mergePDFs(_ urls: [URL]) throws -> URL {
        guard urls.count >= 2 else { throw ConversionError.notEnoughFiles }
        let document = PDFDocument()
        for url in urls {
            try Task.checkCancellation()
            guard let part = PDFDocument(url: url) else { throw ConversionError.unreadableDocument }
            for index in 0..<part.pageCount {
                guard let page = part.page(at: index)?.copy() as? PDFPage else { continue }
                document.insert(page, at: document.pageCount)
            }
        }
        return try write(document, nextTo: urls[0], suffix: " 合并")
    }

    /// Parses "1-3,5" (1-based, commas or Chinese commas) into 0-based page indices, in the order given.
    static func parsePages(_ text: String, pageCount: Int) throws -> [Int] {
        let cleaned = text.replacingOccurrences(of: "，", with: ",").replacingOccurrences(of: "－", with: "-")
            .replacingOccurrences(of: " ", with: "")
        guard !cleaned.isEmpty else { throw ConversionError.invalidPages(text) }
        var pages: [Int] = []
        for part in cleaned.split(separator: ",") {
            let bounds = part.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
            guard bounds.count <= 2, let first = Int(bounds[0]) else { throw ConversionError.invalidPages(text) }
            let last = bounds.count == 2 ? Int(bounds[1]) : first
            guard let last, first >= 1, last >= first, last <= pageCount else { throw ConversionError.invalidPages(text) }
            pages += Array((first - 1)...(last - 1))
        }
        return pages
    }

    static func extract(source: URL, pages text: String) throws -> URL {
        guard let document = PDFDocument(url: source), document.pageCount > 0 else { throw ConversionError.unreadableDocument }
        let indices = try parsePages(text, pageCount: document.pageCount)
        let result = PDFDocument()
        for index in indices {
            guard let page = document.page(at: index)?.copy() as? PDFPage else { continue }
            result.insert(page, at: result.pageCount)
        }
        return try write(result, nextTo: source, suffix: " 摘取")
    }

    /// One PDF per page, in a new folder named after the source.
    static func splitAll(source: URL) throws -> URL {
        guard let document = PDFDocument(url: source), document.pageCount > 0 else { throw ConversionError.unreadableDocument }
        guard document.pageCount <= 500 else { throw ConversionError.tooManyPages(500) }
        let folder = try OutputPublisher.makeFolder(nextTo: source)
        do {
            let width = String(document.pageCount).count
            for index in 0..<document.pageCount {
                try Task.checkCancellation()
                guard let page = document.page(at: index)?.copy() as? PDFPage else { continue }
                let single = PDFDocument()
                single.insert(page, at: 0)
                let name = String(format: "%0\(width)d", index + 1)
                guard single.write(to: folder.appendingPathComponent("\(name).pdf")) else { throw ConversionError.encodingFailed }
            }
        } catch {
            // The folder is ours (just created, only our files in it): a cancelled or failed split leaves nothing behind.
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
        return folder
    }

    private static func write(_ document: PDFDocument, nextTo source: URL, suffix: String) throws -> URL {
        let temporary = OutputPublisher.temporaryURL(nextTo: source, fileExtension: "pdf")
        guard document.write(to: temporary) else {
            OutputPublisher.discard(temporary)
            throw ConversionError.encodingFailed
        }
        return try OutputPublisher.publish(temporary, nextTo: source, fileExtension: "pdf", suffix: suffix)
    }
}
#endif
