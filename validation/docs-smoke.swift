import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

@main struct T {
    static func main() async throws {
        let dir = URL(fileURLWithPath: CommandLine.arguments[1])
        _ = NSApplication.shared
        let svc = ConversionService()
        var failed = false
        func check(_ ok: Bool, _ msg: String) { print(ok ? "PASS" : "FAIL", msg); if !ok { failed = true } }

        // 1. Scanned PDF: an image-only PDF made from rendered text, then OCR.
        let text = NSAttributedString(string: "Phaeton scan test 2026\n你好，这是扫描件识别测试。\nInvoice total: 128.50",
                                      attributes: [.font: NSFont.systemFont(ofSize: 40), .foregroundColor: NSColor.black])
        let image = NSImage(size: NSSize(width: 1400, height: 400))
        image.lockFocus(); NSColor.white.setFill(); NSRect(x: 0, y: 0, width: 1400, height: 400).fill()
        text.draw(in: NSRect(x: 40, y: 40, width: 1300, height: 320)); image.unlockFocus()
        let png = dir.appendingPathComponent("scan.png")
        let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
        try rep.representation(using: .png, properties: [:])!.write(to: png)
        let scanPDF = try await svc.convert(source: png, to: .pdf)
        let out = try await svc.convert(source: scanPDF, to: .txt)
        let ocr = try String(contentsOf: out)
        print("OCR TEXT:", ocr.replacingOccurrences(of: "\n", with: " | "))
        check(ocr.contains("Phaeton"), "OCR english")
        check(ocr.contains("你好") || ocr.contains("扫描"), "OCR chinese")
        check(ocr.contains("128"), "OCR digits")

        // 2. Complex document: heading, table and list -> rtf -> pdf -> docx. (RTF, because textutil
        //    keeps the table structure there; its own DOCX writer flattens tables into paragraphs.)
        let html = "<html><body><h1>Quarterly Report</h1><p>Hello <b>bold</b> text.</p><table border=1><tr><th>Item</th><th>Qty</th></tr><tr><td>Apples</td><td>12</td></tr><tr><td>Pears</td><td>7</td></tr></table><ul><li>First point</li><li>Second point</li></ul></body></html>"
        let htmlURL = dir.appendingPathComponent("report.html")
        try html.write(to: htmlURL, atomically: true, encoding: .utf8)
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/textutil")
        p.arguments = ["-convert", "rtf", htmlURL.path]; try p.run(); p.waitUntilExit()
        let rtf = dir.appendingPathComponent("report.rtf")
        let pdf = try await svc.convert(source: rtf, to: .pdf)
        let back = try await svc.convert(source: pdf, to: .docx)
        let unzip = Process(); unzip.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        let pipe = Pipe(); unzip.standardOutput = pipe
        unzip.arguments = ["-p", back.path, "word/document.xml"]; try unzip.run()
        let xml = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self); unzip.waitUntilExit()
        check(xml.contains("Quarterly Report"), "docx keeps heading text")
        check(xml.contains("Apples") && xml.contains("Pears"), "docx keeps table text")
        check(xml.contains("<w:tbl>"), "docx contains a real table")
        check(xml.contains("First point"), "docx keeps list text")
        print(failed ? "SOME FAILED" : "ALL DONE")
    }
}
