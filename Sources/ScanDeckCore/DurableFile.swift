import Darwin
import Foundation

public enum DurableFileError: Error, Equatable, LocalizedError, Sendable {
    case cannotOpen(path: String, reason: String)
    case cannotFlush(path: String, reason: String)
    case cannotRename(from: String, to: String, reason: String)
    case cannotWrite(path: String, reason: String)

    public var errorDescription: String? {
        switch self {
        case let .cannotOpen(path, reason):
            "Could not open \(path): \(reason)"
        case let .cannotFlush(path, reason):
            "Could not flush \(path) to disk: \(reason)"
        case let .cannotRename(from, to, reason):
            "Could not move \(from) to \(to): \(reason)"
        case let .cannotWrite(path, reason):
            "Could not write \(path): \(reason)"
        }
    }
}

/// Filesystem primitives with the durability `SPEC.md` section 5 requires.
///
/// Counter, job state, release journal, session state, and batch publication all
/// use fsync-then-rename. Two details are easy to get wrong and both matter here:
///
/// - On macOS plain `fsync` only pushes data into the drive's write cache.
///   `F_FULLFSYNC` is the primitive that actually reaches the platter or flash,
///   which is the difference between surviving a power cut and only surviving a
///   process crash.
/// - Flushing a file is not enough. The directory entry created by a rename is
///   itself buffered, so the containing directory must be flushed too or the
///   rename can be lost even though the file's contents are durable.
public enum DurableFile {
    /// Flushes a file or directory all the way to the device.
    public static func flush(_ url: URL) throws {
        let descriptor = open(url.path, O_RDONLY)
        guard descriptor >= 0 else {
            throw DurableFileError.cannotOpen(
                path: url.path,
                reason: String(cString: strerror(errno))
            )
        }
        defer { close(descriptor) }

        // F_FULLFSYNC is unsupported on some filesystems; fall back rather than
        // failing an operation that is otherwise sound.
        if fcntl(descriptor, F_FULLFSYNC) == -1, fsync(descriptor) != 0 {
            throw DurableFileError.cannotFlush(
                path: url.path,
                reason: String(cString: strerror(errno))
            )
        }
    }

    /// Renames within a volume and flushes both containing directories, so the
    /// move itself survives power loss.
    public static func rename(_ source: URL, to destination: URL) throws {
        guard Darwin.rename(source.path, destination.path) == 0 else {
            throw DurableFileError.cannotRename(
                from: source.path,
                to: destination.path,
                reason: String(cString: strerror(errno))
            )
        }
        try flush(destination.deletingLastPathComponent())
        let sourceParent = source.deletingLastPathComponent()
        if sourceParent != destination.deletingLastPathComponent() {
            try? flush(sourceParent)
        }
    }

    /// Writes to a sibling temporary file, flushes it, then renames into place.
    public static func write(_ data: Data, to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        } catch {
            throw DurableFileError.cannotWrite(
                path: directory.path,
                reason: error.localizedDescription
            )
        }

        let temporary = directory.appending(
            path: ".\(UUID().uuidString).tmp",
            directoryHint: .notDirectory
        )
        do {
            try data.write(to: temporary)
            try flush(temporary)
            try rename(temporary, to: url)
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
    }
}
