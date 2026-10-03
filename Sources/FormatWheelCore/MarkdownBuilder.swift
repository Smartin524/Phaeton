import Foundation

/// A piece of inline text with its formatting: what every Markdown source (DOCX, rich text, PDF)
/// is reduced to before it is written out.
struct MarkdownSpan: Equatable {
    var text: String
    var bold = false
    var italic = false
    var strike = false
    var code = false
    var link: String?

    func sameStyle(as other: MarkdownSpan) -> Bool {
        bold == other.bold && italic == other.italic && strike == other.strike && code == other.code && link == other.link
    }
}

/// Writes Markdown block by block. Blocks are separated by a blank line and the items of one list by a
/// single line break, so the result reads well as plain text (the way an AI or a person sees it) and
/// also renders correctly.
struct MarkdownBuilder {
    private var lines: [String] = []
    private var inList = false
    /// Whether the last top-level item was numbered: a bulleted and a numbered list in a row are
    /// two lists, and read better with a blank line between them.
    private var lastTopOrdered: Bool?

    var text: String { lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n" }
    var isEmpty: Bool { lines.isEmpty }

    mutating func heading(_ level: Int, _ spans: [MarkdownSpan]) {
        // A heading is bold by nature; bold markers inside it are only noise.
        let text = Self.inline(spans.map { var span = $0; span.bold = false; return span })
            .replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        block(String(repeating: "#", count: min(max(level, 1), 6)) + " " + text)
    }

    mutating func paragraph(_ spans: [MarkdownSpan]) {
        let text = Self.inline(spans).trimmingCharacters(in: .whitespaces)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        block(text.components(separatedBy: "\n").map(Self.escapeLineStart).joined(separator: "\n"))
    }

    /// `marker` is "-" or "3." and so on; nested levels are indented four spaces each.
    mutating func listItem(level: Int, marker: String, _ spans: [MarkdownSpan]) {
        let text = Self.inline(spans).replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        let ordered = marker != "-"
        if !lines.isEmpty && (!inList || (level == 0 && lastTopOrdered != nil && lastTopOrdered != ordered)) {
            lines.append("")
        }
        if level == 0 { lastTopOrdered = ordered }
        lines.append(String(repeating: "    ", count: max(0, level)) + marker + " " + text)
        inList = true
    }

    /// The first row is the header. Line breaks inside a cell become <br>.
    mutating func table(_ rows: [[String]]) {
        let rows = rows.filter { !$0.allSatisfy { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } }
        guard let width = rows.map(\.count).max(), width > 0, let header = rows.first else { return }
        func row(_ cells: [String]) -> String {
            let padded = cells + Array(repeating: "", count: width - cells.count)
            return "| " + padded.map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
                    .replacingOccurrences(of: "|", with: "\\|")
                    .replacingOccurrences(of: "\n", with: "<br>")
            }.joined(separator: " | ") + " |"
        }
        let separator = "|" + String(repeating: " --- |", count: width)
        block(([row(header), separator] + rows.dropFirst().map(row)).joined(separator: "\n"))
    }

    mutating func rule() { block("---") }

    private mutating func block(_ text: String) {
        if !lines.isEmpty { lines.append("") }
        lines.append(text)
        inList = false
        lastTopOrdered = nil
    }

    // MARK: Inline text

    /// Joins spans into Markdown: neighbours with the same style are merged first, and markers hug
    /// the text (spaces stay outside them), as Markdown requires.
    static func inline(_ spans: [MarkdownSpan]) -> String {
        var merged: [MarkdownSpan] = []
        for span in spans where !span.text.isEmpty {
            if let last = merged.last, last.sameStyle(as: span) {
                merged[merged.count - 1].text += span.text
            } else {
                merged.append(span)
            }
        }
        var out = ""
        for span in merged {
            let text = span.text
            let core = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !core.isEmpty else { out += text; continue }
            let lead = String(text.prefix { $0.isWhitespace || $0.isNewline })
            let trail = String(text.reversed().prefix { $0.isWhitespace || $0.isNewline }.reversed())
            var body: String
            if span.code {
                body = core.contains("`") ? "`` \(core) ``" : "`\(core)`"
            } else {
                body = escape(core)
                if span.bold && span.italic { body = "***\(body)***" }
                else if span.bold { body = "**\(body)**" }
                else if span.italic { body = "*\(body)*" }
                if span.strike { body = "~~\(body)~~" }
            }
            if let link = span.link, !link.isEmpty {
                body = "[\(body)](\(link.replacingOccurrences(of: " ", with: "%20")))"
            }
            out += lead + body + trail
        }
        return out
    }

    /// Characters that would otherwise turn plain text into formatting.
    static func escape(_ text: String) -> String {
        var out = ""
        for character in text {
            if "\\*_`".contains(character) { out.append("\\") }
            out.append(character)
        }
        return out
    }

    /// A line that starts like a heading, quote or list item but is ordinary text.
    static func escapeLineStart(_ line: String) -> String {
        if line.hasPrefix("#") || line.hasPrefix(">") || line.hasPrefix("- ") || line.hasPrefix("+ ") {
            return "\\" + line
        }
        let digits = line.prefix { $0.isASCII && $0.isNumber }
        if !digits.isEmpty, line.dropFirst(digits.count).hasPrefix(". ") || line.dropFirst(digits.count).hasPrefix(") ") {
            return digits + "\\" + line.dropFirst(digits.count)
        }
        return line
    }

    // MARK: Lists typed as text

    /// Lists that a converter flattened into text, like "\t•\tItem" or "\t2\tItem": the nesting level,
    /// the Markdown marker and how many characters of marker to drop.
    static func textListMarker(_ text: String) -> (level: Int, marker: String, drop: Int)? {
        let bullets: [Character: Int] = ["•": 0, "●": 0, "·": 0, "◦": 1, "○": 1, "▪": 2, "■": 2, "‣": 1]
        let chars = Array(text)
        var index = 0
        while index < chars.count, chars[index] == "\t" || chars[index] == " " { index += 1 }
        guard index < chars.count else { return nil }
        if let level = bullets[chars[index]], index + 1 < chars.count, chars[index + 1] == "\t" || chars[index + 1] == " " {
            var end = index + 1
            while end < chars.count, chars[end] == "\t" || chars[end] == " " { end += 1 }
            return (level, "-", end)
        }
        var end = index
        while end < chars.count, chars[end].isASCII, chars[end].isNumber { end += 1 }
        guard end > index, end - index <= 3 else { return nil }
        let number = String(chars[index..<end])
        if end < chars.count, chars[end] == "." || chars[end] == ")" { end += 1 }
        // Only a tab after the number marks a list; "2024 年" is just text.
        guard end < chars.count, chars[end] == "\t" else { return nil }
        while end < chars.count, chars[end] == "\t" || chars[end] == " " { end += 1 }
        return (0, number + ".", end)
    }

    /// Drops the first `count` characters from a run of spans.
    static func dropPrefix(_ count: Int, from spans: [MarkdownSpan]) -> [MarkdownSpan] {
        var remaining = count
        var out: [MarkdownSpan] = []
        for var span in spans {
            if remaining > 0 {
                let length = span.text.count
                if length <= remaining { remaining -= length; continue }
                span.text = String(span.text.dropFirst(remaining))
                remaining = 0
            }
            out.append(span)
        }
        return out
    }

    /// Weighted most common value: the body text size of a document.
    static func mostCommon(_ samples: [(value: Double, weight: Int)]) -> Double? {
        var totals: [Double: Int] = [:]
        for sample in samples where sample.value > 0 { totals[(sample.value * 2).rounded() / 2, default: 0] += sample.weight }
        return totals.max { $0.value < $1.value }?.key
    }

    /// Heading level for text this much larger than the body, or nil for body text.
    static func headingLevel(size: Double, body: Double, length: Int) -> Int? {
        guard body > 0, length > 0, length <= 80 else { return nil }
        let ratio = size / body
        if ratio >= 1.75 { return 1 }
        if ratio >= 1.4 { return 2 }
        if ratio >= 1.15 { return 3 }
        return nil
    }
}
