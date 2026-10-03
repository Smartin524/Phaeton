import AppKit
import FormatWheelCore

/// Converts dropped files one at a time and keeps a short status for the menu-bar panel.
@MainActor
final class AppModel {
    private(set) var isConverting = false
    private(set) var progress: Double?
    private(set) var resultURL: URL?
    private(set) var message = "按住 Shift 拖动文件，拖到轮盘格式上松手。"
    /// Where the running job was started (the wheel's centre), so its progress ring appears there.
    /// nil for jobs started from a window or a menu: the ring then appears at the pointer.
    private(set) var origin: NSPoint?
    var queuedCount: Int { queue.count }
    var onChange: (() -> Void)?
    var onFinish: ((String, URL?, Bool) -> Void)?
    var onCancel: (() -> Void)?
    /// A job needs the optional components; the app offers to install them and may run it again.
    var onNeedExtras: (([URL], String, @escaping ToolWork) -> Void)?

    private struct Job {
        let sources: [URL]
        let label: String
        let origin: NSPoint?
        let work: ToolWork
    }

    private let service = ConversionService()
    private var task: Task<Void, Never>?
    /// Jobs asked for while another one runs; they start one after another instead of being dropped.
    private var queue: [Job] = []

    func convert(_ sources: [URL], to format: OutputFormat, at origin: NSPoint? = nil) {
        let service = self.service
        run(Job(sources: sources, label: "转换为 \(format.title)", origin: origin) { source, progress in
            try await service.convert(source: source, to: format, progress: progress)
        })
    }

    /// One output from all the files (merge PDFs, join clips…).
    func batch(_ sources: [URL], action: BatchAction, at origin: NSPoint? = nil) {
        guard let first = sources.first else { return }
        let service = self.service
        run(Job(sources: [first], label: action.title, origin: origin) { _, progress in
            try await service.batch(action, sources: sources, progress: progress)
        })
    }

    /// Runs any per-file job with the usual progress, status and notification handling.
    func perform(_ sources: [URL], label: String, work: @escaping ToolWork) {
        run(Job(sources: sources, label: label, origin: nil, work: work))
    }

    /// Starts the job now, or queues it behind the one that is running.
    private func run(_ job: Job) {
        guard !job.sources.isEmpty else { return }
        if isConverting {
            queue.append(job)
            message = "已加入队列：\(job.label)（排队中 \(queue.count) 个）"
            onChange?()
            return
        }
        start(job)
    }

    private func startNext() {
        guard !isConverting, !queue.isEmpty else { return }
        start(queue.removeFirst())
    }

    private func start(_ job: Job) {
        guard !isConverting else { return }
        let sources = job.sources, label = job.label, work = job.work
        isConverting = true
        progress = nil
        resultURL = nil
        origin = job.origin
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
                            // A late update must not repaint a percentage after the job has ended.
                            guard let self, self.isConverting else { return }
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
                self.startNext()
                return
            }
            self.finish(outputs: outputs, total: sources.count, failure: failure)
        }
    }

    /// Stops the running job and drops everything queued behind it: "cancel" means stop.
    func cancel() {
        queue.removeAll()
        task?.cancel()
    }

    private func finish(outputs: [URL], total: Int, failure: Error?) {
        isConverting = false
        progress = nil
        task = nil
        origin = nil
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
        startNext()
    }
}
