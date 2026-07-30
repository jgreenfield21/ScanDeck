import Foundation

public enum JobCounterError: Error, Equatable, LocalizedError, Sendable {
    case counterExhausted
    case notMonotonic(stored: UInt64, requested: UInt64)
    case unwritableStore(String)

    public var errorDescription: String? {
        switch self {
        case .counterExhausted:
            "This job has used every available sheet number."
        case let .notMonotonic(stored, requested):
            "The counter cannot move backwards from \(stored) to \(requested)."
        case let .unwritableStore(reason):
            "The sheet counter could not be saved: \(reason)"
        }
    }
}

/// The persistent per-job sheet counter.
///
/// Every competitor on the Mac derives numbering from "next unused filename in
/// the destination folder", which silently resets when files are moved or a new
/// folder is chosen. `SPEC.md` section 3 requires the opposite: a durable
/// counter owned by the job, monotonic across sessions, and seedable by the
/// operator.
///
/// Numbers are committed only after a batch publishes. A cancelled batch burns
/// nothing, and deleted cards leave intentional gaps because completion advances
/// the counter past the highest provisional number rather than counting cards.
public struct JobCounterStore {
    public static let firstSheetNumber: UInt64 = 1

    private let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    /// `~/Library/Application Support/ScanDeck/Jobs`, per `SPEC.md` section 3.
    ///
    /// The directory is created on first write, so constructing this never
    /// fails and never silently redirects the counter somewhere temporary.
    public static var applicationSupport: JobCounterStore {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? URL(filePath: NSHomeDirectory())
            .appending(path: "Library/Application Support", directoryHint: .isDirectory)

        return JobCounterStore(
            directory: base
                .appending(path: "ScanDeck", directoryHint: .isDirectory)
                .appending(path: "Jobs", directoryHint: .isDirectory)
        )
    }

    /// The number the next batch for this job should start from.
    ///
    /// An unknown job starts at ``firstSheetNumber`` rather than failing, so a
    /// freshly installed app can scan immediately.
    public func nextSheetNumber(for jobID: JobID) -> UInt64 {
        guard let record = try? read(jobID) else {
            return Self.firstSheetNumber
        }
        return record.nextSheetNumber
    }

    /// Advances the stored counter after a batch has published.
    ///
    /// Refuses to move backwards: a late or replayed commit must never hand out
    /// a number an earlier batch already published.
    public func commit(
        nextSheetNumber: UInt64,
        for jobID: JobID
    ) throws {
        let stored = self.nextSheetNumber(for: jobID)
        guard nextSheetNumber >= stored else {
            throw JobCounterError.notMonotonic(
                stored: stored,
                requested: nextSheetNumber
            )
        }
        try write(
            JobCounterRecord(jobID: jobID, nextSheetNumber: nextSheetNumber)
        )
    }

    /// An explicit operator override, which may move the counter in either
    /// direction. `SPEC.md` section 3 makes the counter seedable on purpose.
    public func seed(_ nextSheetNumber: UInt64, for jobID: JobID) throws {
        guard nextSheetNumber >= Self.firstSheetNumber else {
            throw JobCounterError.notMonotonic(
                stored: Self.firstSheetNumber,
                requested: nextSheetNumber
            )
        }
        try write(
            JobCounterRecord(jobID: jobID, nextSheetNumber: nextSheetNumber)
        )
    }

    // MARK: - Storage

    private struct JobCounterRecord: Codable, Equatable, Sendable {
        let jobID: JobID
        let nextSheetNumber: UInt64
    }

    private func url(for jobID: JobID) -> URL {
        directory.appending(
            path: "\(jobID.rawValue.uuidString).json",
            directoryHint: .notDirectory
        )
    }

    private func read(_ jobID: JobID) throws -> JobCounterRecord {
        let data = try Data(contentsOf: url(for: jobID))
        return try JSONDecoder().decode(JobCounterRecord.self, from: data)
    }

    private func write(_ record: JobCounterRecord) throws {
        do {
            try DurableFile.write(
                try JSONEncoder().encode(record),
                to: url(for: record.jobID)
            )
        } catch let error as DurableFileError {
            throw JobCounterError.unwritableStore(
                error.errorDescription ?? "\(error)"
            )
        } catch {
            throw JobCounterError.unwritableStore(error.localizedDescription)
        }
    }
}
