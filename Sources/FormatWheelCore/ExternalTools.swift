#if os(macOS)
import Foundation

/// Optional converters that macOS frameworks cannot do (PDF → DOCX, WebP). They live in a
/// private virtualenv created by scripts/install-extras.sh; when it is absent the wheel
/// simply does not offer those formats.
enum ExternalTools {
    static let folder = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Phaeton", isDirectory: true)
    static var python: URL { folder.appendingPathComponent("venv/bin/python") }
    static var helper: URL { folder.appendingPathComponent("phaeton_helper.py") }

    static var isInstalled: Bool {
        FileManager.default.isExecutableFile(atPath: python.path)
            && FileManager.default.isReadableFile(atPath: helper.path)
    }

    /// scripts/install-extras.sh writes this marker once the MP3 encoder is installed.
    static var hasMP3: Bool {
        isInstalled && FileManager.default.fileExists(atPath: folder.appendingPathComponent("has-mp3").path)
    }

    static func convert(mode: String, input: URL, nextTo source: URL, format: OutputFormat) async throws -> URL {
        guard isInstalled, mode != "mp3" || hasMP3 else { throw ConversionError.extrasNotInstalled }
        let temporary = OutputPublisher.temporaryURL(nextTo: source, fileExtension: format.fileExtension)
        do {
            try await run([helper.path, mode, input.path, temporary.path])
            guard (try? temporary.checkResourceIsReachable()) == true else {
                throw ConversionError.exportFailed("没有生成输出文件")
            }
            return try OutputPublisher.publish(temporary, nextTo: source, fileExtension: format.fileExtension)
        } catch {
            OutputPublisher.discard(temporary)
            throw error
        }
    }

    private static func run(_ arguments: [String]) async throws {
        let process = Process()
        process.executableURL = python
        process.arguments = arguments
        // stderr goes to a file, not a Pipe: pdf2docx logs every page, and a pipe nobody
        // drains until exit fills up (64 KB) and blocks the helper forever.
        let log = FileManager.default.temporaryDirectory.appendingPathComponent("phaeton-\(UUID().uuidString).log")
        guard FileManager.default.createFile(atPath: log.path, contents: nil),
              let errors = try? FileHandle(forWritingTo: log) else {
            throw ConversionError.exportFailed("无法创建日志文件")
        }
        defer {
            try? errors.close()
            try? FileManager.default.removeItem(at: log)
        }
        process.standardError = errors
        process.standardOutput = FileHandle.nullDevice
        try Task.checkCancellation()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                process.terminationHandler = { finished in
                    if finished.terminationReason == .uncaughtSignal {
                        continuation.resume(throwing: ConversionError.cancelled)
                    } else if finished.terminationStatus == 0 {
                        continuation.resume()
                    } else {
                        let text = String(decoding: (try? Data(contentsOf: log)) ?? Data(), as: UTF8.self)
                        let last = text.split(separator: "\n").last.map(String.init) ?? "退出码 \(finished.terminationStatus)"
                        continuation.resume(throwing: ConversionError.exportFailed(last))
                    }
                }
                do { try process.run() } catch { continuation.resume(throwing: error) }
            }
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
    }
}
#endif
