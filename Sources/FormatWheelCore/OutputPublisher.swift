#if os(macOS)
import Darwin
import Foundation

/// Moves a finished temporary file next to the source without ever replacing a file.
/// The temporary file is hidden, uniquely named and created by us, so removing it on
/// failure is safe. Public names are claimed with an atomic exclusive rename.
enum OutputPublisher {
    static func temporaryURL(nextTo source: URL, fileExtension: String) -> URL {
        source.deletingLastPathComponent()
            .appendingPathComponent(".phaeton-\(UUID().uuidString).\(fileExtension)", isDirectory: false)
    }

    static func publish(_ temporary: URL, nextTo source: URL, fileExtension: String, suffix: String = "") throws -> URL {
        let folder = source.deletingLastPathComponent()
        let stem = source.deletingPathExtension().lastPathComponent + suffix
        for number in 1...10_000 {
            let counter = number == 1 ? "" : " \(number)"
            let candidate = folder.appendingPathComponent("\(stem)\(counter).\(fileExtension)", isDirectory: false)
            let result = temporary.withUnsafeFileSystemRepresentation { from -> Int32 in
                candidate.withUnsafeFileSystemRepresentation { to -> Int32 in
                    guard let from, let to else { return -1 }
                    return renamex_np(from, to, UInt32(RENAME_EXCL))
                }
            }
            if result == 0 { return candidate }
            let code = errno
            if code == EEXIST { continue }
            discard(temporary)
            throw ConversionError.outputCreationFailed(code)
        }
        discard(temporary)
        throw ConversionError.tooManyOutputNames
    }

    /// Creates a new empty folder named after the source, never reusing an existing name.
    static func makeFolder(nextTo source: URL) throws -> URL {
        let parent = source.deletingLastPathComponent()
        let stem = source.deletingPathExtension().lastPathComponent
        for number in 1...10_000 {
            let candidate = parent.appendingPathComponent(number == 1 ? stem : "\(stem) \(number)", isDirectory: true)
            let result = candidate.withUnsafeFileSystemRepresentation { path -> Int32 in
                guard let path else { return -1 }
                return mkdir(path, 0o755)
            }
            if result == 0 { return candidate }
            let code = errno
            if code == EEXIST { continue }
            throw ConversionError.outputCreationFailed(code)
        }
        throw ConversionError.tooManyOutputNames
    }

    static func discard(_ temporary: URL) {
        try? FileManager.default.removeItem(at: temporary)
    }
}
#endif
