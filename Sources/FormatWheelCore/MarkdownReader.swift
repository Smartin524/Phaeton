#if os(macOS)
import AppKit
import Foundation

/// Markdown to rich text, for MD → PDF / DOCX / RTF: headings, bold, italic, strikethrough, inline
/// code, links, lists (nested, numbered), block quotes, code blocks and tables become real
/// formatting instead of the raw # and ** characters. Parsing is Foundation's own Markdown.
enum MarkdownReader {
    private static let bodySize: CGFloat = 12
    private static let headingSizes: [CGFloat] = [22, 18, 15, 13.5, 12.5, 12]

    /// Real, named fonts for documents: Helvetica, with Chinese and Japanese from Hiragino Sans GB.
    /// Not the system UI font: it is private, so in a DOCX its name means nothing to Word (it falls
    /// back to Times). And for Chinese not PingFang, Songti or the automatic fallback: tested, PDFs
    /// set in those give back look-alike radicals ("⼀⾏" for "一行") when the text is copied or
    /// searched, at least with one of the two text engines; Hiragino Sans GB copies out right in both.
    static func documentFont(_ size: CGFloat, bold: Bool = false) -> NSFont {
        let base = NSFont(name: bold ? "Helvetica-Bold" : "Helvetica", size: size)
            ?? (bold ? .boldSystemFont(ofSize: size) : .systemFont(ofSize: size))
        return withChineseFallback(base, bold: bold)
    }

    /// The font with Hiragino Sans GB first in line for characters it does not have itself.
    static func withChineseFallback(_ font: NSFont, bold: Bool? = nil) -> NSFont {
        let heavy = bold ?? font.fontDescriptor.symbolicTraits.contains(.bold)
        guard let chinese = NSFont(name: heavy ? "HiraginoSansGB-W6" : "HiraginoSansGB-W3", size: font.pointSize) else { return font }
        let cascade = [chinese.fontDescriptor] + ((font.fontDescriptor.object(forKey: .cascadeList) as? [NSFontDescriptor]) ?? [])
        return NSFont(descriptor: font.fontDescriptor.addingAttributes([.cascadeList: cascade]), size: font.pointSize) ?? font
    }

    static func codeFont(_ size: CGFloat) -> NSFont {
        NSFont(name: "Menlo-Regular", size: size) ?? .monospacedSystemFont(ofSize: size, weight: .regular)
    }

    static func attributedString(from markdown: String) -> NSAttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .full,
                                                              failurePolicy: .returnPartiallyParsedIfPossible)
        guard let parsed = try? AttributedString(markdown: markdown, options: options) else {
            return NSAttributedString(string: markdown, attributes: [.font: documentFont(bodySize)])
        }

        // Runs that share one block (paragraph, heading, list item, cell…) have the same intent.
        var blocks: [(intent: PresentationIntent?, runs: [AttributedString.Runs.Run])] = []
        for run in parsed.runs {
            if let last = blocks.last, last.intent == run.presentationIntent {
                blocks[blocks.count - 1].runs.append(run)
            } else {
                blocks.append((run.presentationIntent, [run]))
            }
        }

        let out = NSMutableAttributedString()
        var tables: [Int: NSTextTable] = [:]
        var lastListItem: Int?
        for block in blocks {
            let kinds = block.intent?.components.map(\.kind) ?? []
            let start = out.length
            let style = NSMutableParagraphStyle()
            style.paragraphSpacing = 6
            var baseFont = documentFont(bodySize)
            var color: NSColor?
            var prefix = ""
            var headerCell = false

            let listDepth = kinds.filter { if case .orderedList = $0 { return true }; if case .unorderedList = $0 { return true }; return false }.count
            for kind in kinds {
                switch kind {
                case .header(let level):
                    baseFont = documentFont(headingSizes[min(max(level, 1), 6) - 1], bold: true)
                    style.paragraphSpacingBefore = 8
                case .codeBlock:
                    baseFont = codeFont(11)
                    style.headIndent = 16; style.firstLineHeadIndent = 16
                    style.paragraphSpacing = 1   // its lines stay together
                case .blockQuote:
                    style.headIndent += 16; style.firstLineHeadIndent += 16
                    color = .darkGray
                case .tableHeaderRow:
                    headerCell = true
                default: break
                }
            }

            // List items: the marker goes on the item's first paragraph only, indented by depth.
            if listDepth > 0 {
                let indent = CGFloat(listDepth) * 18
                style.headIndent = indent
                style.firstLineHeadIndent = indent - 14
                style.tabStops = [NSTextTab(textAlignment: .left, location: indent)]
                let item = block.intent?.components.first { if case .listItem = $0.kind { return true }; return false }
                if let item, item.identity != lastListItem {
                    lastListItem = item.identity
                    let ordered = kinds.first { if case .orderedList = $0 { return true }; if case .unorderedList = $0 { return true }; return false }
                    if case .listItem(let ordinal) = item.kind, case .orderedList = ordered { prefix = "\(ordinal).\t" }
                    else { prefix = (listDepth > 1 ? "◦" : "•") + "\t" }
                } else {
                    style.firstLineHeadIndent = indent
                }
            }

            // Table cells: one NSTextTable per Markdown table, one block per cell.
            if let table = block.intent?.components.first(where: { if case .table = $0.kind { return true }; return false }),
               case .table(let columns) = table.kind {
                let textTable = tables[table.identity] ?? {
                    let created = NSTextTable()
                    created.numberOfColumns = columns.count
                    created.collapsesBorders = true
                    tables[table.identity] = created
                    return created
                }()
                var row = 0, column = 0
                for kind in kinds {
                    if case .tableRow(let index) = kind { row = index }
                    if case .tableCell(let index) = kind { column = index }
                }
                let cell = NSTextTableBlock(table: textTable, startingRow: row, rowSpan: 1, startingColumn: column, columnSpan: 1)
                cell.setWidth(0.5, type: .absoluteValueType, for: .border)
                cell.setBorderColor(.gray)
                cell.setWidth(4, type: .absoluteValueType, for: .padding)
                style.textBlocks = [cell]
                style.paragraphSpacing = 0
                if headerCell { baseFont = documentFont(bodySize, bold: true) }
            }

            if !prefix.isEmpty { out.append(NSAttributedString(string: prefix, attributes: [.font: baseFont])) }
            for run in block.runs {
                var text = String(parsed[run.range].characters)
                if run == block.runs.last, kinds.contains(where: { if case .codeBlock = $0 { return true }; return false }),
                   text.hasSuffix("\n") { text.removeLast() }
                var attributes: [NSAttributedString.Key: Any] = [.font: font(baseFont, run.inlinePresentationIntent)]
                if let color { attributes[.foregroundColor] = color }
                if let link = run.link {
                    // Explicit look: when printed, a link otherwise loses the blue a text view gives it.
                    attributes[.link] = link
                    attributes[.foregroundColor] = NSColor.linkColor
                    attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
                }
                if run.inlinePresentationIntent?.contains(.strikethrough) == true {
                    attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
                }
                out.append(NSAttributedString(string: text, attributes: attributes))
            }
            out.append(NSAttributedString(string: "\n", attributes: [.font: baseFont]))
            let range = NSRange(location: start, length: out.length - start)
            out.addAttribute(.paragraphStyle, value: style, range: range)
            if kinds.contains(where: { if case .codeBlock = $0 { return true }; return false }) {
                // A code block keeps its lines together but stands apart from what is around it.
                let lines = out.string as NSString
                let first = lines.paragraphRange(for: NSRange(location: range.location, length: 0))
                let last = lines.paragraphRange(for: NSRange(location: NSMaxRange(range) - 1, length: 0))
                let opening = style.mutableCopy() as! NSMutableParagraphStyle
                opening.paragraphSpacingBefore = 8
                out.addAttribute(.paragraphStyle, value: opening, range: first)
                let closing = (first == last ? opening : style).mutableCopy() as! NSMutableParagraphStyle
                closing.paragraphSpacing = 8
                out.addAttribute(.paragraphStyle, value: closing, range: last)
            }
        }
        return out
    }

    private static func font(_ base: NSFont, _ inline: InlinePresentationIntent?) -> NSFont {
        guard let inline else { return base }
        if inline.contains(.code) { return codeFont(base.pointSize - 1) }
        var font = base
        if inline.contains(.stronglyEmphasized) { font = documentFont(base.pointSize, bold: true) }
        if inline.contains(.emphasized) {
            // Latin text gets a real italic; Chinese has none and stays upright. (A font descriptor, not
            // NSFontManager: this runs off the main thread.)
            let italic = font.fontDescriptor.withSymbolicTraits(font.fontDescriptor.symbolicTraits.union(.italic))
            font = NSFont(descriptor: italic, size: font.pointSize) ?? font
        }
        return font
    }
}
#endif
