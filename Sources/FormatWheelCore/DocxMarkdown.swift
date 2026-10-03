#if os(macOS)
import Foundation

/// DOCX to Markdown straight from the Word XML. AppKit's DOCX reader drops tables, links and list
/// structure, which are exactly what matters when the Markdown is for an AI to read; the XML has them:
/// heading styles (and outline levels), numbered and bulleted lists with their nesting, tables, links,
/// bold, italic, strikethrough and code fonts.
enum DocxMarkdown {
    static func convert(_ url: URL) throws -> String {
        guard let documentXML = try entry("word/document.xml", in: url),
              let document = try? XMLDocument(data: documentXML),
              let body = document.rootElement()?.child("body") else {
            throw ConversionError.unreadableDocument
        }
        var reader = Reader(
            styles: try entry("word/styles.xml", in: url).flatMap { try? XMLDocument(data: $0) }.map(Styles.init) ?? Styles(),
            numbering: try entry("word/numbering.xml", in: url).flatMap { try? XMLDocument(data: $0) }.map(Numbering.init) ?? Numbering(),
            links: try entry("word/_rels/document.xml.rels", in: url).flatMap { try? XMLDocument(data: $0) }.map(relationships) ?? [:])
        let blocks = reader.blocks(in: body)
        return Reader.write(blocks)
    }

    /// One file from inside the .docx (a zip), or nil when the archive does not have it.
    private static func entry(_ path: String, in archive: URL) throws -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-p", archive.path, path]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()   // read before waiting: no full-pipe stall
        process.waitUntilExit()
        return process.terminationStatus == 0 && !data.isEmpty ? data : nil
    }

    private static func relationships(_ xml: XMLDocument) -> [String: String] {
        var links: [String: String] = [:]
        for relation in xml.rootElement()?.children(named: "Relationship") ?? [] {
            if let id = relation.attr("Id"), let target = relation.attr("Target"),
               relation.attr("Type")?.hasSuffix("/hyperlink") == true {
                links[id] = target
            }
        }
        return links
    }

    // MARK: Styles and numbering

    struct Styles {
        struct Style { var name = ""; var basedOn: String?; var outline: Int?; var numId: String?; var ilvl: Int? }
        var byId: [String: Style] = [:]

        init() {}
        init(_ xml: XMLDocument) {
            for element in xml.rootElement()?.children(named: "style") ?? [] {
                guard let id = element.attr("styleId") else { continue }
                var style = Style()
                style.name = element.child("name")?.attr("val")?.lowercased() ?? ""
                style.basedOn = element.child("basedOn")?.attr("val")
                let properties = element.child("pPr")
                style.outline = properties?.child("outlineLvl")?.attr("val").flatMap(Int.init)
                style.numId = properties?.child("numPr")?.child("numId")?.attr("val")
                style.ilvl = properties?.child("numPr")?.child("ilvl")?.attr("val").flatMap(Int.init)
                byId[id] = style
            }
        }

        /// The style and the ones it is based on, nearest first.
        func chain(_ id: String?) -> [Style] {
            var result: [Style] = []
            var next = id
            while let current = next, let style = byId[current], result.count < 10 {
                result.append(style)
                next = style.basedOn
            }
            return result
        }

        func headingLevel(_ id: String?) -> Int? {
            for style in chain(id) {
                if style.name == "title" { return 1 }
                if style.name == "subtitle" { return 2 }
                if style.name.hasPrefix("heading "), let level = Int(style.name.dropFirst(8)) { return level }
                if let outline = style.outline, outline < 9 { return outline + 1 }
            }
            return nil
        }

        /// The list a paragraph style belongs to. Word's "List Bullet 2" / "List Number 3" styles
        /// nest by their own numbering rather than by level, so the number in the name gives the depth.
        func numbering(_ id: String?) -> (numId: String, ilvl: Int)? {
            for style in chain(id) {
                guard let numId = style.numId else { continue }
                var level = style.ilvl ?? 0
                if level == 0, style.name.hasPrefix("list "), let depth = Int(style.name.split(separator: " ").last ?? ""), depth > 1 {
                    level = depth - 1
                }
                return (numId, level)
            }
            return nil
        }
    }

    struct Numbering {
        /// numId → level → (bullet?, start)
        var formats: [String: [Int: (bullet: Bool, start: Int)]] = [:]

        init() {}
        init(_ xml: XMLDocument) {
            var abstract: [String: [Int: (Bool, Int)]] = [:]
            for element in xml.rootElement()?.children(named: "abstractNum") ?? [] {
                guard let id = element.attr("abstractNumId") else { continue }
                var levels: [Int: (Bool, Int)] = [:]
                for level in element.children(named: "lvl") {
                    guard let index = level.attr("ilvl").flatMap(Int.init) else { continue }
                    let format = level.child("numFmt")?.attr("val") ?? "decimal"
                    let start = level.child("start")?.attr("val").flatMap(Int.init) ?? 1
                    levels[index] = (format == "bullet" || format == "none", start)
                }
                abstract[id] = levels
            }
            for element in xml.rootElement()?.children(named: "num") ?? [] {
                if let id = element.attr("numId"), let base = element.child("abstractNumId")?.attr("val") {
                    formats[id] = abstract[base]
                }
            }
        }
    }

    // MARK: Reading the body

    enum Block {
        case paragraph(spans: [MarkdownSpan], heading: Int?, size: Double, list: (level: Int, marker: String)?)
        case table([[String]])
    }

    struct Reader {
        let styles: Styles
        let numbering: Numbering
        let links: [String: String]
        private var counters: [String: [Int: Int]] = [:]

        init(styles: Styles, numbering: Numbering, links: [String: String]) {
            self.styles = styles
            self.numbering = numbering
            self.links = links
        }

        mutating func blocks(in container: XMLElement) -> [Block] {
            var blocks: [Block] = []
            for element in container.elementChildren {
                switch element.localName {
                case "p": blocks.append(paragraph(element))
                case "tbl": blocks.append(.table(table(element)))
                case "sdt": if let content = element.child("sdtContent") { blocks += self.blocks(in: content) }
                default: break
                }
            }
            return blocks
        }

        private mutating func paragraph(_ p: XMLElement) -> Block {
            let properties = p.child("pPr")
            let styleId = properties?.child("pStyle")?.attr("val")
            var heading = styles.headingLevel(styleId)
            if heading == nil, let outline = properties?.child("outlineLvl")?.attr("val").flatMap(Int.init), outline < 9 {
                heading = outline + 1
            }
            var field = FieldState()
            let spans = runs(in: p, link: nil, field: &field)
            let size = spans.isEmpty ? 0 : runSizes(in: p).max() ?? 0

            var list: (Int, String)?
            let numPr = properties?.child("numPr")
            let direct = numPr.flatMap { pr in pr.child("numId")?.attr("val").map { ($0, pr.child("ilvl")?.attr("val").flatMap(Int.init) ?? 0) } }
            if heading == nil, let (numId, level) = direct ?? styles.numbering(styleId), numId != "0",
               let format = numbering.formats[numId]?[level] ?? numbering.formats[numId]?[0] {
                var levels = counters[numId] ?? [:]
                levels = levels.filter { $0.key <= level }
                levels[level] = (levels[level] ?? (format.start - 1)) + 1
                counters[numId] = levels
                list = (level, format.bullet ? "-" : "\(levels[level]!).")
            }
            return .paragraph(spans: spans, heading: heading, size: size, list: list)
        }

        /// Font sizes (points) of the visible runs: for headings typed as big bold text.
        private func runSizes(in p: XMLElement) -> [Double] {
            p.descendants(named: "r").compactMap { run in
                guard run.descendants(named: "t").contains(where: { !($0.stringValue ?? "").isEmpty }) else { return nil }
                return run.child("rPr")?.child("sz")?.attr("val").flatMap(Double.init).map { $0 / 2 }
            }
        }

        struct FieldState { var instruction = ""; var inResult = false; var link: String? }

        private func runs(in element: XMLElement, link: String?, field: inout FieldState) -> [MarkdownSpan] {
            var spans: [MarkdownSpan] = []
            for child in element.elementChildren {
                switch child.localName {
                case "r": spans += run(child, link: link ?? field.link, field: &field)
                case "hyperlink":
                    let target = child.attr("id").flatMap { links[$0] } ?? child.attr("anchor").map { "#" + $0 }
                    spans += runs(in: child, link: target, field: &field)
                case "ins", "smartTag", "customXml", "fldSimple", "bdo", "dir":
                    spans += runs(in: child, link: link, field: &field)
                case "sdt": if let content = child.child("sdtContent") { spans += runs(in: content, link: link, field: &field) }
                default: break   // deleted text, bookmarks, proofing marks…
                }
            }
            return spans
        }

        private func run(_ r: XMLElement, link: String?, field: inout FieldState) -> [MarkdownSpan] {
            let properties = r.child("rPr")
            if properties?.child("vanish").map(isOn) == true { return [] }
            var style = MarkdownSpan(text: "")
            style.bold = properties?.child("b").map(isOn) ?? false
            style.italic = properties?.child("i").map(isOn) ?? false
            style.strike = (properties?.child("strike").map(isOn) ?? false) || (properties?.child("dstrike").map(isOn) ?? false)
            let fontName = properties?.child("rFonts")?.attr("ascii")?.lowercased() ?? ""
            style.code = ["courier", "menlo", "consolas", "monaco", "mono"].contains { fontName.contains($0) }
            style.link = link

            var spans: [MarkdownSpan] = []
            for child in r.elementChildren {
                var text = ""
                switch child.localName {
                case "fldChar":
                    switch child.attr("fldCharType") {
                    case "begin": field = FieldState()
                    case "separate":
                        field.inResult = true
                        // HYPERLINK "https://…" fields: the visible result is the link text.
                        let words = field.instruction.split(separator: "\"")
                        if field.instruction.trimmingCharacters(in: .whitespaces).hasPrefix("HYPERLINK"), words.count >= 2 {
                            field.link = String(words[1])
                        }
                    case "end": field = FieldState()
                    default: break
                    }
                case "instrText": field.instruction += child.stringValue ?? ""
                case "t": text = child.stringValue ?? ""
                case "tab": text = "\t"   // kept: "\t1\tItem" is how some writers type a list
                case "br", "cr": text = child.attr("type") == "page" ? "" : "\n"
                case "noBreakHyphen": text = "-"
                case "drawing", "pict", "object": text = "[图片]"
                default: break
                }
                if !text.isEmpty {
                    var span = style
                    span.text = text
                    if span.link == nil { span.link = field.link }
                    spans.append(span)
                }
            }
            return spans
        }

        private func isOn(_ toggle: XMLElement) -> Bool {
            let value = toggle.attr("val")?.lowercased()
            return value == nil || !(value == "0" || value == "false" || value == "off" || value == "none")
        }

        private mutating func table(_ tbl: XMLElement) -> [[String]] {
            tbl.children(named: "tr").map { row in
                var cells: [String] = []
                for cell in row.children(named: "tc") {
                    let properties = cell.child("tcPr")
                    let continued = properties?.child("vMerge").map { $0.attr("val") != "restart" } ?? false
                    let text = continued ? "" : cellText(cell)
                    cells.append(text)
                    let span = properties?.child("gridSpan")?.attr("val").flatMap(Int.init) ?? 1
                    if span > 1 { cells += Array(repeating: "", count: span - 1) }
                }
                return cells
            }
        }

        /// A cell's paragraphs, one per line; a table inside a cell is flattened to its text.
        private mutating func cellText(_ cell: XMLElement) -> String {
            blocks(in: cell).map { block -> String in
                switch block {
                case .paragraph(let spans, _, _, let list):
                    let text = MarkdownBuilder.inline(spans)
                    return list.map { "\($0.marker) " + text } ?? text
                case .table(let rows): return rows.map { $0.joined(separator: " ") }.joined(separator: "\n")
                }
            }.filter { !$0.isEmpty }.joined(separator: "\n")
        }

        // MARK: Writing

        static func write(_ blocks: [Block]) -> String {
            // Documents that make headings with big bold text instead of styles: compare with the body size.
            let body = MarkdownBuilder.mostCommon(blocks.compactMap { block in
                if case .paragraph(let spans, nil, let size, nil) = block { return (size, spans.map(\.text.count).reduce(0, +)) }
                return nil
            }) ?? 0
            var md = MarkdownBuilder()
            for block in blocks {
                switch block {
                case .table(let rows): md.table(rows)
                case .paragraph(let spans, let heading, let size, let list):
                    let text = spans.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines)
                    if let heading {
                        md.heading(heading, spans)
                    } else if let list {
                        md.listItem(level: list.level, marker: list.marker, spans)
                    } else if let typed = MarkdownBuilder.textListMarker(spans.map(\.text).joined()) {
                        md.listItem(level: typed.level, marker: typed.marker, MarkdownBuilder.dropPrefix(typed.drop, from: spans))
                    } else if let level = MarkdownBuilder.headingLevel(size: size, body: body, length: text.count) {
                        md.heading(level, spans)
                    } else {
                        md.paragraph(spans)
                    }
                }
            }
            return md.text
        }
    }
}

// MARK: - Namespace-agnostic XML helpers (Word files use the w: prefix, but not always)

extension XMLElement {
    var elementChildren: [XMLElement] { children?.compactMap { $0 as? XMLElement } ?? [] }

    func child(_ localName: String) -> XMLElement? { elementChildren.first { $0.localName == localName } }

    func children(named localName: String) -> [XMLElement] { elementChildren.filter { $0.localName == localName } }

    func descendants(named localName: String) -> [XMLElement] {
        elementChildren.flatMap { ($0.localName == localName ? [$0] : []) + $0.descendants(named: localName) }
    }

    func attr(_ localName: String) -> String? {
        attributes?.first { $0.localName == localName }?.stringValue
    }
}
#endif
