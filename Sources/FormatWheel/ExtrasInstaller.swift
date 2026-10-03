import Foundation

/// Runs the bundled install-extras.sh: a private Python environment with the tools behind
/// WebP, MP3 and PDF → DOCX, in ~/Library/Application Support/Phaeton. Nothing system-wide.
enum ExtrasInstaller {
    /// Returns nil on success, otherwise a short reason.
    static func install() async -> String? {
        guard let script = Bundle.main.url(forResource: "install-extras", withExtension: "sh") else {
            return "安装脚本不在应用包里，请从源码目录运行 scripts/install-extras.sh。"
        }
        return await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = [script.path]
            let errors = Pipe()
            process.standardError = errors
            process.standardOutput = FileHandle.nullDevice
            process.terminationHandler = { finished in
                if finished.terminationStatus == 0 {
                    continuation.resume(returning: nil)
                } else {
                    let text = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                    let last = text.split(separator: "\n").last.map(String.init) ?? "退出码 \(finished.terminationStatus)"
                    continuation.resume(returning: last)
                }
            }
            do { try process.run() } catch { continuation.resume(returning: error.localizedDescription) }
        }
    }
}
