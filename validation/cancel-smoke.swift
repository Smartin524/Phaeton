import Foundation

@main struct T {
    static func main() async throws {
        let dir = URL(fileURLWithPath: CommandLine.arguments[1])
        let src = dir.appendingPathComponent("long.aiff")
        for format in [OutputFormat.wav, .m4a] {
            let task = Task { try await ConversionService().convert(source: src, to: format) }
            try await Task.sleep(nanoseconds: 60_000_000)
            task.cancel()
            do { let out = try await task.value; print("finished before cancel:", out.lastPathComponent) }
            catch { print("cancelled ->", format, error.localizedDescription) }
        }
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasPrefix(".phaeton-") }
        print(leftovers.isEmpty ? "PASS no temp leftovers" : "FAIL leftovers: \(leftovers)")
        print(try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted())
    }
}
