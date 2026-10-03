import AppKit
import FormatWheelCore

/// Converts dropped files one at a time and keeps a short status for the menu bar.
@MainActor
final class AppModel {
    private(set) var isConverting = false
    private(set) var progress: Double?
    private(set) var resultURL: URL?
    private(set) var message = "按住 Shift 拖动文件，拖到轮盘格式上松手。"
    var onChange: (() -> Void)?
    var onFinish: ((String, URL?, Bool) -> Void)?
    var onCancel: (() -> Void)?
    /// A job needs the optional components; the app offers to install them and may run it again.
    var onNeedExtras: (([URL], String, @escaping ToolWork) -> Void)?

    private let service = ConversionService()
    private var task: Task<Void, Never>?

    func convert(_ sources: [URL], to format: OutputFormat) {
        let service = self.service
        run(sources, label: "转换为 \(format.title)") { source, progress in
            try await service.convert(source: source, to: format, progress: progress)
        }
    }

    /// One output from all the files (merge PDFs, join clips…).
    func batch(_ sources: [URL], action: BatchAction) {
        guard let first = sources.first else { return }
        let service = self.service
        run([first], label: action.title) { _, progress in
            try await service.batch(action, sources: sources, progress: progress)
        }
    }

    /// Runs any per-file job with the usual progress, status and notification handling.
    func perform(_ sources: [URL], label: String,
                 work: @escaping @Sendable (URL, @escaping @Sendable (Double) -> Void) async throws -> URL) {
        run(sources, label: label, work: work)
    }

    private func run(_ sources: [URL], label: String,
                     work: @escaping @Sendable (URL, @escaping @Sendable (Double) -> Void) async throws -> URL) {
        guard !isConverting, !sources.isEmpty else { return }
        isConverting = true
        progress = nil
        resultURL = nil
        message = "正在\(label)…"
        onChange?()
        task = Task { [weak self] in
            var outputs: [URL] = []
            var failure: Error?
            var missing = false
            for (index, source) in sources.enumerated() {
                if Task.isCancelled { break }
                do {
                    let output = try await work(source) { value in
                        Task { @MainActor in
                            guard let self else { return }
                            self.progress = (Double(index) + value) / Double(sources.count)
                            self.message = "正在\(label)… \(Int(self.progress! * 100))%"
                            self.onChange?()
                        }
                    }
                    outputs.append(output)
                } catch {
                    if let known = error as? ConversionError, case .extrasNotInstalled = known {
                        missing = true
                        break
                    }
                    failure = error is CancellationError ? ConversionError.cancelled : error
                }
            }
            guard let self else { return }
            if missing {
                self.isConverting = false
                self.progress = nil
                self.task = nil
                self.message = "需要先安装可选组件。"
                self.onChange?()
                self.onCancel?()
                self.onNeedExtras?(sources, label, work)
                return
            }
            self.finish(outputs: outputs, total: sources.count, failure: failure)
        }
    }

    func cancel() { task?.cancel() }

    private func finish(outputs: [URL], total: Int, failure: Error?) {
        isConverting = false
        progress = nil
        task = nil
        resultURL = outputs.last
        if let failure {
            message = outputs.isEmpty ? failure.localizedDescription
                : "已转换 \(outputs.count)/\(total)；\(failure.localizedDescription)"
            if (failure as? ConversionError).map({ if case .cancelled = $0 { return false } else { return true } }) ?? true {
                NSSound.beep()
            }
        } else if let last = outputs.last {
            message = outputs.count == 1 ? "已保存：\(last.lastPathComponent)"
                : "已转换 \(outputs.count) 个文件，保存在原文件旁。"
        } else {
            message = "已取消转换。"
        }
        onChange?()
        let cancelled = (failure as? ConversionError).map { if case .cancelled = $0 { return true } else { return false } } ?? false
        if cancelled { onCancel?() } else { onFinish?(message, outputs.last, failure == nil) }
    }
}
