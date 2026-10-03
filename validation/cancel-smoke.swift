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
        // The picture and PDF tools must honour cancellation too: cancelled at once, they write nothing.
        let svc = ConversionService()
        func listing() -> Set<String> { Set((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []) }
        let jobs: [(String, @Sendable () async throws -> URL)] = [
            ("strip metadata", { try await svc.stripMetadata(source: dir.appendingPathComponent("sample.jpg")) }),
            ("remove background", { try await svc.removeBackground(source: dir.appendingPathComponent("sample.jpg")) }),
            ("compress to size", { try await svc.compressImage(source: dir.appendingPathComponent("big.jpg"), toBytes: 100_000) }),
            ("save image edit", { try await svc.saveImageEdit(source: dir.appendingPathComponent("sample.jpg"), edit: ImageEdit(scale: 0.5)) }),
            ("split PDF", { try await svc.splitPDF(source: dir.appendingPathComponent("notes.pdf")) }),
        ]
        for (name, job) in jobs {
            let before = listing()
            let task = Task { try await job() }
            task.cancel()
            do { let out = try await task.value; print("FAIL \(name): finished although cancelled -> \(out.lastPathComponent)") }
            catch { print("PASS \(name): cancelled before writing") }
            let created = listing().subtracting(before)
            if !created.isEmpty { print("FAIL \(name): left \(created)") }
        }
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasPrefix(".phaeton-") }
        print(leftovers.isEmpty ? "PASS no temp leftovers" : "FAIL leftovers: \(leftovers)")
        print(try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted())
    }
}
