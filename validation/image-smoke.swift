import AppKit
import Foundation
import ImageIO

@main struct T {
    static func main() async throws {
        let dir = URL(fileURLWithPath: CommandLine.arguments[1])
        let src = dir.appendingPathComponent("sample-photo.jpg")
        var failed = false
        for f in FileKind.image.outputs(for: [src]) {
            if f == .webp && !ExternalTools.isInstalled { print("SKIP webp (optional components not installed)"); continue }
            do {
                let out = try await ConversionService().convert(source: src, to: f)
                var info = "pdf"
                if f != .pdf, let s = CGImageSourceCreateWithURL(out as CFURL, nil), let im = CGImageSourceCreateImageAtIndex(s, 0, nil) {
                    info = "\(im.width)x\(im.height)"
                    if im.width != 1200 || im.height != 900 { failed = true }
                } else if f != .pdf { failed = true; info = "UNREADABLE" }
                print("OK  ", f, out.lastPathComponent, info, (try? out.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? -1)
            } catch { print("FAIL", f, error.localizedDescription); failed = true }
        }
        if ExternalTools.isInstalled {
            let pdfOut = try await ConversionService().convert(source: dir.appendingPathComponent("notes.pdf"), to: .docx)
            print("OK   pdf->docx", pdfOut.lastPathComponent)
            let heic = dir.appendingPathComponent("sample-photo.heic")
            let webp = try await ConversionService().convert(source: heic, to: .webp)
            print("OK   heic->webp", webp.lastPathComponent)
        } else {
            print("SKIP pdf->docx and heic->webp (optional components not installed)")
        }
        let longText = (1...400).map { "第 \($0) 行：Phaeton PDF to image test line." }.joined(separator: "\n")
        try longText.write(to: dir.appendingPathComponent("long.txt"), atomically: true, encoding: .utf8)
        _ = NSApplication.shared
        let longPDF = try await ConversionService().convert(source: dir.appendingPathComponent("long.txt"), to: .pdf)
        let pages = CGPDFDocument(longPDF as CFURL)!.numberOfPages
        print("pages", pages)
        let folder = try await ConversionService().convert(source: longPDF, to: .png)
        let files = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
        print("OK   multipage ->", folder.lastPathComponent, files.count, files.first ?? "")
        if files.count != pages || pages < 2 { failed = true }
        let one = try await ConversionService().convert(source: dir.appendingPathComponent("notes.pdf"), to: .jpeg)
        print("OK   single ->", one.lastPathComponent)
        print(failed ? "SOME FAILED" : "ALL DONE")
    }
}
