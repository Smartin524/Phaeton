import AppKit
import Foundation
import PDFKit

/// Markdown in and out through the real converter: rich documents → MD keep structure, MD → PDF /
/// DOCX / TXT is read as Markdown, and PDF text (including the PDFs Phaeton itself writes) copies out
/// as real characters, not look-alike radicals.
@main struct T {
    static func main() async throws {
        let dir = URL(fileURLWithPath: CommandLine.arguments[1])
        _ = NSApplication.shared
        let svc = ConversionService()
        var failed = false
        func check(_ ok: Bool, _ msg: String) { print(ok ? "PASS" : "FAIL", msg); if !ok { failed = true } }
        func text(_ url: URL) throws -> String { try String(contentsOf: url, encoding: .utf8) }

        // Rich documents made with textutil: headings by size, bold, links, lists, a table.
        let html = """
        <html><head><meta charset="utf-8"></head><body><h1>项目周报</h1>
        <p>这是<b>加粗</b>和<a href="https://example.com">链接</a>，注意 a*b。</p><h2>进展</h2>
        <ul><li>完成转换</li><li>修复问题</li></ul><ol><li>第一步</li><li>第二步</li></ol>
        <table border="1"><tr><th>名称</th><th>数量</th></tr><tr><td>苹果</td><td>3</td></tr></table></body></html>
        """
        let htmlURL = dir.appendingPathComponent("weekly.html")
        try html.write(to: htmlURL, atomically: true, encoding: .utf8)
        for format in ["rtf", "docx"] {
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/textutil")
            p.arguments = ["-convert", format, htmlURL.path]; try p.run(); p.waitUntilExit()
        }
        let rtfMD = try text(try await svc.convert(source: dir.appendingPathComponent("weekly.rtf"), to: .md))
        check(rtfMD.contains("# 项目周报") && rtfMD.contains("## 进展"), "rtf → md: headings")
        check(rtfMD.contains("**加粗**") && rtfMD.contains("[链接](https://example.com"), "rtf → md: bold and link")
        check(rtfMD.contains("- 完成转换") && rtfMD.contains("1. 第一步"), "rtf → md: lists")
        check(rtfMD.contains("| 名称 | 数量 |") && rtfMD.contains("| 苹果 | 3 |"), "rtf → md: table")
        check(rtfMD.contains("a\\*b"), "rtf → md: a literal * is escaped")
        let docxMD = try text(try await svc.convert(source: dir.appendingPathComponent("weekly.docx"), to: .md))
        check(docxMD.contains("# 项目周报") && docxMD.contains("- 完成转换") && docxMD.contains("1. 第一步"), "docx → md: headings and lists")

        // Markdown in: read as formatting, not as raw # and **.
        let md = "# 产品说明\n\n这是一段**加粗**文字，行内容一。\n\n- 第一项\n- 第二项\n\n| 类型 | 说明 |\n| --- | --- |\n| 文档 | 一行 |\n"
        let mdURL = dir.appendingPathComponent("notes.md")
        try md.write(to: mdURL, atomically: true, encoding: .utf8)
        let plainMD = dir.appendingPathComponent("plain.md")
        try "# 说明\n\n这是一段行内文字，官网一行。\n".write(to: plainMD, atomically: true, encoding: .utf8)

        let txt = try text(try await svc.convert(source: mdURL, to: .txt))
        check(!txt.contains("**") && !txt.contains("# ") && txt.contains("加粗"), "md → txt: markup removed")
        let pdf = try await svc.convert(source: plainMD, to: .pdf)
        let pdfText = PDFDocument(url: pdf)?.page(at: 0)?.string ?? ""
        check(pdfText.contains("一段行内文字") && pdfText.contains("一行"), "md → pdf: Chinese copies out as real characters")
        check(!pdfText.contains("#"), "md → pdf: no raw markup")
        let tablePDF = try await svc.convert(source: mdURL, to: .pdf)
        check((PDFDocument(url: tablePDF)?.page(at: 0)?.string ?? "").contains("文档"), "md with a table → pdf")
        let docx = try await svc.convert(source: mdURL, to: .docx)
        let unzip = Process(); unzip.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        let pipe = Pipe(); unzip.standardOutput = pipe
        unzip.arguments = ["-p", docx.path, "word/document.xml"]; try unzip.run()
        let xml = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self); unzip.waitUntilExit()
        check(xml.contains("产品说明") && !xml.contains("**"), "md → docx: text without markup")
        check(!xml.contains("AppleSystemUIFont") && !xml.contains(".SF"), "md → docx: named fonts Word knows")

        // PDF out: headings come back from the type size.
        let back = try text(try await svc.convert(source: pdf, to: .md))
        check(back.contains("# 说明") && back.contains("一段行内文字"), "pdf → md: heading and text")
        print(failed ? "SOME FAILED" : "ALL DONE")
    }
}
