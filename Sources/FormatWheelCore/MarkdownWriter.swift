#if os(macOS)
import AppKit
import Foundation
import PDFKit

/// Rich text (RTF, ODT, DOC… as AppKit reads them) to Markdown: headings from the font size, lists,
/// tables, bold, italic, strikethrough, code and links.
enum AttributedMarkdown {
    static func convert(_ text: NSAttributedString) -> String {
        var md = MarkdownBuilder()
        let string = text.string as NSString
        let body = bodySize(of: text)
        // Item counts per nesting level, each tied to the list it counts: a new list starts again at 1.
        var counters: [(list: ObjectIdentifier, count: Int)] = []
        var table: (id: ObjectIdentifier, cells: [Int: [Int: [MarkdownSpan]]])?

        func flushTable() {
            guard let current = table else { return }
            let rows = current.cells.keys.sorted().map { row -> [String] in
                let columns = current.cells[row] ?? [:]
                let width = (columns.keys.max() ?? -1) + 1
                // Header cells are bold anyway; bold markers there are only noise.
                return (0..<width).map { column in
                    MarkdownBuilder.inline((columns[column] ?? []).map { var span = $0; if row == 0 { span.bold = false }; return span })
                }
            }
            md.table(rows)
            table = nil
        }

        var location = 0
        while location < string.length {
            let range = string.paragraphRange(for: NSRange(location: location, length: 0))
            location = NSMaxRange(range)
            let style = text.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle
            var spans = self.spans(of: text, in: range)

            if let cell = style?.textBlocks.compactMap({ $0 as? NSTextTableBlock }).last {
                let id = ObjectIdentifier(cell.table)
                if table?.id != id { flushTable(); table = (id, [:]) }
                var existing = table!.cells[cell.startingRow]?[cell.startingColumn] ?? []
                if !existing.isEmpty { existing.append(MarkdownSpan(text: "\n")) }
                table!.cells[cell.startingRow, default: [:]][cell.startingColumn] = existing + spans
                continue
            }
            flushTable()

            let plain = spans.map(\.text).joined()
            if let lists = style?.textLists, let innermost = lists.last {
                // Some readers also keep the marker as text ("\t•\t"); it is not part of the item.
                if let typed = MarkdownBuilder.textListMarker(plain) { spans = MarkdownBuilder.dropPrefix(typed.drop, from: spans) }
                let level = lists.count - 1
                let id = ObjectIdentifier(innermost)
                if counters.count > level + 1 { counters.removeLast(counters.count - level - 1) }
                if counters.count == level + 1, counters[level].list != id { counters.removeLast() }
                if counters.count < level + 1 { counters.append((id, 0)) }
                while counters.count < level + 1 { counters.append((id, 0)) }
                counters[level].count += 1
                md.listItem(level: level, marker: isOrdered(innermost) ? "\(counters[level].count)." : "-", spans)
                continue
            }
            counters = []
            if let typed = MarkdownBuilder.textListMarker(plain) {
                md.listItem(level: typed.level, marker: typed.marker, MarkdownBuilder.dropPrefix(typed.drop, from: spans))
                continue
            }
            let trimmed = plain.trimmingCharacters(in: .whitespacesAndNewlines)
            if let level = style.map({ $0.headerLevel }).flatMap({ $0 > 0 ? $0 : nil })
                ?? MarkdownBuilder.headingLevel(size: largestSize(of: text, in: range), body: body, length: trimmed.count) {
                md.heading(level, spans)
            } else {
                md.paragraph(spans)
            }
        }
        flushTable()
        return md.text
    }

    private static func isOrdered(_ list: NSTextList) -> Bool {
        let bullets: [NSTextList.MarkerFormat] = [.disc, .circle, .square, .hyphen, .box, .check, .diamond]
        return !bullets.contains(list.markerFormat)
    }

    /// The paragraph's runs, without its closing line break; pictures become "[图片]".
    static func spans(of text: NSAttributedString, in range: NSRange) -> [MarkdownSpan] {
        var spans: [MarkdownSpan] = []
        text.enumerateAttributes(in: range) { attributes, runRange, _ in
            var piece = (text.string as NSString).substring(with: runRange)
            piece = piece.replacingOccurrences(of: "\u{2028}", with: "\n").replacingOccurrences(of: "\u{2029}", with: "\n")
            if piece.hasSuffix("\n") || piece.hasSuffix("\r") { piece = String(piece.dropLast()) }
            if attributes[.attachment] != nil { piece = piece.replacingOccurrences(of: "\u{FFFC}", with: "[图片]") }
            guard !piece.isEmpty else { return }
            var span = MarkdownSpan(text: piece)
            if let font = attributes[.font] as? NSFont {
                let traits = font.fontDescriptor.symbolicTraits
                span.bold = traits.contains(.bold)
                span.italic = traits.contains(.italic)
                span.code = traits.contains(.monoSpace)
            }
            if let strike = attributes[.strikethroughStyle] as? Int, strike != 0 { span.strike = true }
            if let url = attributes[.link] as? URL { span.link = url.absoluteString }
            else if let link = attributes[.link] as? String { span.link = link }
            spans.append(span)
        }
        return spans
    }

    private static func bodySize(of text: NSAttributedString) -> Double {
        var samples: [(Double, Int)] = []
        text.enumerateAttribute(.font, in: NSRange(location: 0, length: text.length)) { value, range, _ in
            if let font = value as? NSFont { samples.append((Double(font.pointSize), range.length)) }
        }
        return MarkdownBuilder.mostCommon(samples) ?? 12
    }

    private static func largestSize(of text: NSAttributedString, in range: NSRange) -> Double {
        var largest = 0.0
        text.enumerateAttribute(.font, in: range) { value, run, _ in
            let visible = (text.string as NSString).substring(with: run).trimmingCharacters(in: .whitespacesAndNewlines)
            if let font = value as? NSFont, !visible.isEmpty { largest = max(largest, Double(font.pointSize)) }
        }
        return largest
    }
}

/// PDF to Markdown. A PDF only knows lines of text, so structure is inferred: larger lines are
/// headings, lines are joined into paragraphs (a short line ends one, and a paragraph may run on to
/// the next page), bullets become list items, and running headers, footers and page numbers are
/// dropped. Scanned pages go through `ocr`, whose line heights stand in for font sizes.
enum PDFMarkdown {
    private struct Line { let text: String; let size: Double }

    static func convert(_ document: PDFDocument,
                        ocr: (PDFPage) throws -> [(text: String, height: Double)]) throws -> String {
        var pages: [(lines: [Line], scanned: Bool)] = []
        for index in 0..<document.pageCount {
            try Task.checkCancellation()
            guard let page = document.page(at: index) else { continue }
            let layer = page.string ?? ""
            if layer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                pages.append((try ocr(page).map { Line(text: $0.text, size: $0.height) }, true))
            } else {
                pages.append((lines(of: page.attributedString ?? NSAttributedString(string: layer)), false))
            }
        }
        let repeated = runningLines(pages.map(\.lines))
        // Typed text and OCR line heights are different measures; each has its own body size.
        func body(scanned: Bool) -> Double {
            MarkdownBuilder.mostCommon(pages.filter { $0.scanned == scanned }.flatMap(\.lines).map { ($0.size, $0.text.count) }) ?? 12
        }
        let typedBody = body(scanned: false), scannedBody = body(scanned: true)

        var writer = Writer()
        for page in pages {
            let kept = page.lines.filter { !repeated.contains(pattern($0.text)) && !isPageNumber($0.text) }
            writer.add(kept, body: page.scanned ? scannedBody : typedBody,
                       full: Double(page.lines.map(\.text.count).max() ?? 0))
        }
        writer.flush()
        return writer.md.text
    }

    /// Lines that recur on most pages (digits ignored, so "Report · 3" and "Report · 4" match):
    /// running headers and footers, noise between paragraphs.
    private static func runningLines(_ pages: [[Line]]) -> Set<String> {
        guard pages.count >= 3 else { return [] }
        var counts: [String: Int] = [:]
        for page in pages {
            // Only the top and bottom of a page carry headers and footers.
            let edges = page.prefix(3) + page.suffix(3)
            for key in Set(edges.map { pattern($0.text) }) { counts[key, default: 0] += 1 }
        }
        return Set(counts.filter { Double($0.value) >= Double(pages.count) * 0.5 }.keys)
    }

    private static func pattern(_ text: String) -> String {
        String(text.map { $0.isNumber ? "#" : $0 })
    }

    private static func isPageNumber(_ text: String) -> Bool {
        let core = text.trimmingCharacters(in: CharacterSet(charactersIn: " -–—·|/第页Page"))
        return !core.isEmpty && core.count <= 4 && core.allSatisfy(\.isNumber)
    }

    private static func lines(of text: NSAttributedString) -> [Line] {
        var lines: [Line] = []
        let string = text.string as NSString
        var location = 0
        while location < string.length {
            let range = string.lineRange(for: NSRange(location: location, length: 0))
            location = NSMaxRange(range)
            let raw = string.substring(with: range).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !raw.isEmpty else { continue }
            var size = 0.0
            text.enumerateAttribute(.font, in: range) { value, _, _ in
                if let font = value as? NSFont { size = max(size, Double(font.pointSize)) }
            }
            lines.append(Line(text: raw, size: size))
        }
        return lines
    }

    /// Collects lines into the open paragraph or list item, across pages, and writes each block
    /// when it ends.
    private struct Writer {
        var md = MarkdownBuilder()
        private var open = ""
        private var item: (level: Int, marker: String)?

        mutating func add(_ lines: [Line], body: Double, full: Double) {
            for line in lines {
                let text = line.text
                // Only size marks a heading: bold alone also marks table headers and lead-ins.
                if let level = MarkdownBuilder.headingLevel(size: line.size, body: body, length: text.count) {
                    flush()
                    md.heading(level, [MarkdownSpan(text: text)])
                    continue
                }
                // "(2) …", "b) …", "M6.2 …": a numbered part starts a new paragraph.
                if PDFMarkdown.startsNumberedPart(text) { flush() }
                if let typed = MarkdownBuilder.textListMarker(text) ?? PDFMarkdown.bullet(text) {
                    flush()
                    item = (typed.level, typed.marker)
                    open = String(text.dropFirst(typed.drop))
                } else {
                    open = PDFMarkdown.join(open, text)
                }
                // A line much shorter than the page's longest ends its paragraph or item.
                if Double(text.count) < full * 0.7 { flush() }
            }
        }

        mutating func flush() {
            if !open.isEmpty {
                if let item { md.listItem(level: item.level, marker: item.marker, [MarkdownSpan(text: open)]) }
                else { md.paragraph([MarkdownSpan(text: open)]) }
            }
            open = ""
            item = nil
        }
    }

    fileprivate static func startsNumberedPart(_ text: String) -> Bool {
        let patterns = [#"^\(\d{1,2}\)\s"#, #"^\([a-zA-Z]\)\s"#, #"^[a-zA-Z]\)\s"#, #"^[A-Z]\d+(\.\d+)+\s"#]
        return patterns.contains { text.range(of: $0, options: .regularExpression) != nil }
    }

    /// "• item" or "1. item" typed with a space, as PDFs usually have them.
    fileprivate static func bullet(_ text: String) -> (level: Int, marker: String, drop: Int)? {
        if let first = text.first, "•●▪◦·-–".contains(first), text.dropFirst().first == " " {
            return (0, "-", 2)
        }
        let digits = text.prefix { $0.isASCII && $0.isNumber }
        if !digits.isEmpty, digits.count <= 2, text.dropFirst(digits.count).hasPrefix(". ") {
            return (0, digits + ".", digits.count + 2)
        }
        return nil
    }

    /// Joins two lines of one paragraph: no space between Chinese or Japanese text, a space between
    /// words, and a word broken with a hyphen is put back together.
    fileprivate static func join(_ left: String, _ right: String) -> String {
        guard let last = left.last, let first = right.first else { return left + right }
        if last == "-", first.isLowercase { return String(left.dropLast()) + right }
        if isCJK(last) || isCJK(first) { return left + right }
        return left + " " + right
    }

    private static func isCJK(_ character: Character) -> Bool {
        character.unicodeScalars.contains { scalar in
            (0x2E80...0x9FFF).contains(scalar.value) || (0xAC00...0xD7AF).contains(scalar.value)
                || (0xF900...0xFAFF).contains(scalar.value) || (0xFF00...0xFFEF).contains(scalar.value)
        }
    }
}
#endif
