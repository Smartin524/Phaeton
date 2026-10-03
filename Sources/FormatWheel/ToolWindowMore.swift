import AppKit
import FormatWheelCore
import PDFKit
import SwiftUI

/// "More" page of the image editor: one-shot tools that do not need the crop box.
struct ImageMoreTools: View {
    let urls: [URL]
    let perform: (String, @escaping ToolWork) -> Void
    let close: () -> Void
    @State private var targetSize = ""
    @State private var unit = SizeUnit.kilobytes
    @State private var status = ""
    private let service = ConversionService()

    var body: some View {
        Section(caption: "处理") {
            ListGroup {
                ActionRow(symbol: "person.crop.rectangle", title: "去背景") {
                    run("去背景") { try await service.removeBackground(source: $0) }
                }
                ActionRow(symbol: "location.slash", title: "移除位置等元数据", isLast: true) {
                    run("移除元数据") { try await service.stripMetadata(source: $0) }
                }
            }
        }
        Section(caption: "压缩到指定大小") {
            SizeRow(text: $targetSize, unit: $unit, action: compress)
        }
        if urls.count == 1 {
            Section(caption: "识别") {
                ListGroup {
                    ActionRow(symbol: "text.viewfinder", title: "复制图片中的文字", action: copyText)
                    ActionRow(symbol: "qrcode.viewfinder", title: "识别二维码", isLast: true, action: copyQR)
                }
                if !status.isEmpty {
                    Text(status).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(3)
                }
            }
        }
    }

    private func run(_ label: String, _ job: @escaping @Sendable (URL) async throws -> URL) {
        perform(label) { source, _ in try await job(source) }
        close()
    }

    private func compress() {
        guard let bytes = unit.bytes(from: targetSize) else { status = "请输入大小，例如 500 KB"; return }
        let service = self.service
        run("压缩") { try await service.compressImage(source: $0, toBytes: bytes) }
    }

    private func copyText() {
        status = "正在识别…"
        let url = urls[0], service = self.service
        Task {
            do {
                let text = try await service.recognizeText(source: url)
                copy(text)
                status = "已复制 \(text.count) 个字符"
            } catch { status = error.localizedDescription }
        }
    }

    private func copyQR() {
        status = "正在识别…"
        let url = urls[0], service = self.service
        Task {
            do {
                let codes = try await service.readQRCodes(source: url)
                guard !codes.isEmpty else { status = "没有找到二维码"; return }
                copy(codes.joined(separator: "\n"))
                status = "已复制：\(codes[0])" + (codes.count > 1 ? " 等 \(codes.count) 个" : "")
            } catch { status = error.localizedDescription }
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

enum SizeUnit: String, CaseIterable, Identifiable {
    case kilobytes = "KB", megabytes = "MB"
    var id: String { rawValue }

    func bytes(from text: String) -> Int? {
        guard let value = Double(text.trimmingCharacters(in: .whitespaces)), value > 0 else { return nil }
        return Int(value * (self == .kilobytes ? 1_000 : 1_000_000))
    }
}

/// One row: a number, KB / MB, and a small button that applies it.
struct SizeRow: View {
    @Binding var text: String
    @Binding var unit: SizeUnit
    let action: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            TextField("大小", text: $text)
                .textFieldStyle(.roundedBorder).font(.system(size: 12)).multilineTextAlignment(.center)
                .frame(maxWidth: .infinity).controlSize(.small)
            Menu {
                ForEach(SizeUnit.allCases) { choice in Button(choice.rawValue) { unit = choice } }
            } label: {
                Text(unit.rawValue).font(.system(size: 12, weight: .medium))
            }
            .menuStyle(.borderlessButton).fixedSize()
            Button("压缩", action: action).buttonStyle(PanelButtonStyle())
        }
    }
}

/// "More" page of the video editor: compress, limit the size, mute, change speed.
struct VideoMoreTools: View {
    let urls: [URL]
    let perform: (String, @escaping ToolWork) -> Void
    let close: () -> Void
    @State private var height = 720
    @State private var estimate = ""
    @State private var targetSize = ""
    @State private var unit = SizeUnit.megabytes
    @State private var status = ""
    private let service = ConversionService()
    private let heights: [(String, Int)] = [("1080p", 1080), ("720p", 720), ("480p", 480), ("原尺寸", 0)]

    var body: some View {
        Section(caption: "压缩") {
            ChipGrid(columns: 2) {
                ForEach(heights, id: \.1) { title, value in
                    Chip(title: title, selected: height == value) { height = value }
                }
            }
            ListGroup {
                ActionRow(symbol: "arrow.down.right.and.arrow.up.left", title: estimate.isEmpty ? "开始压缩" : "开始压缩（约 \(estimate)）", isLast: true) {
                    let h = height
                    run("压缩视频") { source, progress in try await MediaConverter().compress(source: source, height: h, progress: progress) }
                }
            }
        }
        .task(id: height) {
            estimate = ""
            let url = urls[0], h = height
            let bytes = await MediaConverter().estimateCompressedBytes(source: url, height: h)
            if let bytes, !Task.isCancelled { estimate = formatBytes(bytes) }
        }
        Section(caption: "压缩到指定大小") {
            SizeRow(text: $targetSize, unit: $unit) {
                guard let bytes = unit.bytes(from: targetSize) else { status = "请输入大小，例如 20 MB"; return }
                let service = self.service
                run("压缩视频") { source, progress in try await service.compressVideo(source: source, toBytes: bytes, progress: progress) }
            }
            if !status.isEmpty { Text(status).font(.system(size: 11)).foregroundStyle(.secondary) }
        }
        Section(caption: "声音") {
            ListGroup {
                ActionRow(symbol: "speaker.slash", title: "静音", isLast: true) {
                    let service = self.service
                    run("静音") { source, progress in try await service.muteVideo(source: source, progress: progress) }
                }
            }
        }
        Section(caption: "变速") {
            ChipGrid(columns: 4) {
                ForEach([0.5, 0.75, 1.5, 2], id: \.self) { factor in
                    Chip(title: "\(factor == 0.75 ? "0.75" : String(format: "%g", factor))×", selected: false) {
                        let service = self.service
                        run("变速") { source, progress in try await service.changeSpeed(source: source, factor: factor, progress: progress) }
                    }
                }
            }
        }
    }

    private func run(_ label: String, _ job: @escaping ToolWork) {
        perform(label, job)
        close()
    }
}

/// PDF editor: preview, pull out pages, split into single pages.
struct PDFToolView: View {
    let urls: [URL]
    let perform: (String, @escaping ToolWork) -> Void
    let close: () -> Void
    let fit: (CGSize) -> Void
    @State private var pageCount = 0
    @State private var pages = ""
    @State private var status = ""
    private let service = ConversionService()

    var body: some View {
        HStack(spacing: 0) {
            PDFPreview(url: urls[0]).padding(.top, 12).padding(.horizontal, 12).padding(.bottom, 12)
            SidePanel {
                if urls.count > 1 {
                    Text("PDF 工具一次只能处理一个文件；多个文件请用轮盘上的“合并 PDF”。")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                } else {
                    Section(caption: "共 \(pageCount) 页 · 提取页面") {
                        HStack(spacing: 6) {
                            TextField("例如 1-3,5", text: $pages).textFieldStyle(.roundedBorder)
                                .font(.system(size: 12)).controlSize(.small)
                            Button("提取", action: extract).buttonStyle(PanelButtonStyle())
                        }
                        if !status.isEmpty { Text(status).font(.system(size: 11)).foregroundStyle(.red) }
                    }
                    Section(caption: "拆分") {
                        ListGroup {
                            ActionRow(symbol: "square.split.2x1", title: "每页存为单独的 PDF", isLast: true, action: split)
                        }
                    }
                }
            } footer: {
                HStack {
                    Spacer()
                    Button("关闭", action: close).keyboardShortcut(.cancelAction).buttonStyle(PanelButtonStyle())
                }
            }
        }
        .ignoresSafeArea()
        .tint(Theme.accent)
        .task {
            guard let document = PDFDocument(url: urls[0]), let first = document.page(at: 0) else { return }
            pageCount = document.pageCount
            fit(first.bounds(for: .mediaBox).size)
        }
    }

    private func extract() {
        guard let document = PDFDocument(url: urls[0]),
              (try? PDFToolView.validate(pages, count: document.pageCount)) != nil else {
            status = "页码无效，请输入类似 1-3,5"
            return
        }
        let text = pages, service = self.service
        perform("提取页面") { source, _ in try await service.extractPages(source: source, pages: text) }
        close()
    }

    private func split() {
        let service = self.service
        perform("拆分 PDF") { source, _ in try await service.splitPDF(source: source) }
        close()
    }

    /// Cheap local check so a typo shows an error here instead of a failed job.
    private static func validate(_ text: String, count: Int) throws {
        let cleaned = text.replacingOccurrences(of: "，", with: ",").replacingOccurrences(of: " ", with: "")
        guard !cleaned.isEmpty else { throw ConversionError.invalidPages(text) }
        for part in cleaned.split(separator: ",") {
            let numbers = part.split(separator: "-", omittingEmptySubsequences: false).compactMap { Int($0) }
            guard (1...2).contains(numbers.count), numbers.allSatisfy({ (1...count).contains($0) }),
                  numbers == numbers.sorted() else { throw ConversionError.invalidPages(text) }
        }
    }
}

private struct PDFPreview: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.document = PDFDocument(url: url)
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.backgroundColor = .clear
        view.pageShadowsEnabled = true
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {}
}
