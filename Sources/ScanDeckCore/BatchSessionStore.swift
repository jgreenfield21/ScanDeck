import Foundation

public enum BatchSessionStoreError: Error, Equatable, LocalizedError, Sendable {
    case unwritableStore(String)
    case cannotDiscard(String)

    public var errorDescription: String? {
        switch self {
        case let .unwritableStore(reason):
            "This batch could not be saved for recovery: \(reason)"
        case let .cannotDiscard(reason):
            "The recovered batch could not be discarded: \(reason)"
        }
    }
}

/// Where one captured master lives on disk.
public struct PersistedMaster: Codable, Equatable, Sendable {
    public let masterID: MasterID
    public let url: URL

    public init(masterID: MasterID, url: URL) {
        self.masterID = masterID
        self.url = url
    }
}

/// A batch's durable record: the reducer state plus the little else needed to
/// put the operator back exactly where they were.
///
/// `BatchSession` deliberately knows nothing about the filesystem, which is what
/// makes it testable — so the reducer state alone cannot restore a batch. Master
/// locations and the destination have to travel with it, or a recovered batch is
/// a list of cards with no images and nowhere to publish them.
public struct PersistedBatchSession: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let session: BatchSession
    public let masters: [PersistedMaster]
    public let startedAt: Date
    public let savedAt: Date

    /// A bookmark, never a path. `SPEC.md` invariant 3: the destination is
    /// resolved at pick time, and between a crash and the next launch it may
    /// have been renamed, moved, or unmounted.
    public let destinationBookmark: Data?

    public init(
        session: BatchSession,
        masterURLs: [MasterID: URL],
        startedAt: Date,
        savedAt: Date,
        destinationBookmark: Data?
    ) {
        schemaVersion = Self.currentSchemaVersion
        self.session = session
        // Sorted so an unchanged batch encodes to identical bytes, which keeps
        // autosave from rewriting the file on every dispatch that changed
        // nothing about the masters.
        masters = masterURLs
            .map { PersistedMaster(masterID: $0.key, url: $0.value) }
            .sorted { $0.masterID.rawValue.uuidString < $1.masterID.rawValue.uuidString }
        self.startedAt = startedAt
        self.savedAt = savedAt
        self.destinationBookmark = destinationBookmark
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        guard schemaVersion <= Self.currentSchemaVersion else {
            throw BatchSessionStoreError.unwritableStore(
                "This batch was saved by a newer version of ScanDeck."
            )
        }
        session = try container.decode(BatchSession.self, forKey: .session)
        masters = try container.decode([PersistedMaster].self, forKey: .masters)
        startedAt = try container.decode(Date.self, forKey: .startedAt)
        savedAt = try container.decode(Date.self, forKey: .savedAt)
        destinationBookmark = try container.decodeIfPresent(
            Data.self,
            forKey: .destinationBookmark
        )
    }

    public var masterURLs: [MasterID: URL] {
        Dictionary(
            masters.map { ($0.masterID, $0.url) },
            uniquingKeysWith: { first, _ in first }
        )
    }

    /// Whether this record describes work the operator can still be handed back.
    ///
    /// A batch that reached `.releasing` or `.completed` has already asked for
    /// publication, so its record is evidence about a folder that may already
    /// exist on the destination. Resuming one here could republish a batch that
    /// already landed; those belong to the release journal (TICKET-006b), which
    /// is why they are neither offered nor deleted.
    public var isResumable: Bool {
        switch session.phase {
        case .ready, .scanning, .review:
            true
        case .releasing, .completed:
            false
        }
    }
}

/// What a scan of the sessions directory found.
public struct RecoverableSessions: Equatable, Sendable {
    /// Every readable record, most recently saved first.
    public let records: [PersistedBatchSession]

    /// Directories holding a record ScanDeck could not read — corrupt, or
    /// written by a newer version. Their masters are still on disk and must
    /// never be deleted on the strength of a record nothing could parse.
    public let unreadableDirectories: [URL]

    public init(
        records: [PersistedBatchSession],
        unreadableDirectories: [URL]
    ) {
        self.records = records
        self.unreadableDirectories = unreadableDirectories
    }

    public var resumable: [PersistedBatchSession] {
        records.filter(\.isResumable)
    }

    /// Records describing a batch that asked to be published and may never
    /// have had its counter committed — the release journal `SPEC.md` section
    /// 5 requires.
    ///
    /// There is no separate journal file, and that is deliberate rather than
    /// an omission. The window the journal has to bridge is exactly the window
    /// this record already spans: it is written durably before publication is
    /// requested and deleted only once the counter is durable too, so a second
    /// file would carry the same facts with the same lifetime and one more way
    /// to fall out of step. What the record adds over a purpose-built journal
    /// is the destination bookmark, which is how recovery answers the only
    /// question that matters — did the batch folder actually land.
    public var interruptedReleases: [PersistedBatchSession] {
        records.filter { !$0.isResumable }
    }
}

/// Durable storage for unfinished batches.
///
/// The record lives beside the masters it references, one directory per batch,
/// so a batch is a single thing to recover and a single thing to discard. That
/// is what makes Discard honest: there is no way to remove the record and leave
/// orphaned images, or the reverse.
///
/// Writes go through `DurableFile`, so a crash mid-save leaves either the
/// previous record or the new one — never a half-written file that would decode
/// into a batch that never existed.
public struct BatchSessionStore: Sendable {
    public static let recordFileName = "session.json"

    private let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    /// `~/Library/Application Support/ScanDeck/Sessions`.
    ///
    /// The single source of this path: masters are written into it by the
    /// workflow and the record is written beside them, and the two must not be
    /// able to disagree.
    public static var applicationSupportDirectory: URL {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? URL(filePath: NSHomeDirectory())
            .appending(path: "Library/Application Support", directoryHint: .isDirectory)

        return base
            .appending(path: "ScanDeck", directoryHint: .isDirectory)
            .appending(path: "Sessions", directoryHint: .isDirectory)
    }

    public static var applicationSupport: BatchSessionStore {
        BatchSessionStore(directory: applicationSupportDirectory)
    }

    /// The directory every batch's working files live under.
    public var storageDirectory: URL {
        directory
    }

    public func directory(for batchID: BatchID) -> URL {
        directory.appending(
            path: batchID.rawValue.uuidString,
            directoryHint: .isDirectory
        )
    }

    public func recordURL(for batchID: BatchID) -> URL {
        directory(for: batchID).appending(
            path: Self.recordFileName,
            directoryHint: .notDirectory
        )
    }

    public func save(_ record: PersistedBatchSession) throws {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try DurableFile.write(
                try encoder.encode(record),
                to: recordURL(for: record.session.id)
            )
        } catch let error as DurableFileError {
            throw BatchSessionStoreError.unwritableStore(
                error.errorDescription ?? "\(error)"
            )
        } catch {
            throw BatchSessionStoreError.unwritableStore(
                error.localizedDescription
            )
        }
    }

    /// Reads every batch directory, keeping what it can parse and naming what it
    /// cannot.
    ///
    /// One unreadable record must never hide the others: a corrupt file is the
    /// moment an operator most needs the batches that are still intact.
    public func load() -> RecoverableSessions {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        var records: [PersistedBatchSession] = []
        var unreadable: [URL] = []

        for batchDirectory in contents {
            guard (try? batchDirectory.resourceValues(forKeys: [.isDirectoryKey]))?
                .isDirectory == true
            else {
                continue
            }

            let url = batchDirectory.appending(
                path: Self.recordFileName,
                directoryHint: .notDirectory
            )
            guard FileManager.default.fileExists(atPath: url.path) else {
                // Masters with no record: a crash between creating the pass
                // directory and the first autosave. There is no batch to
                // restore, and deleting is not this method's call.
                continue
            }

            guard let data = try? Data(contentsOf: url),
                  let record = try? JSONDecoder().decode(
                      PersistedBatchSession.self,
                      from: data
                  )
            else {
                unreadable.append(batchDirectory)
                continue
            }
            records.append(record)
        }

        return RecoverableSessions(
            records: records.sorted { $0.savedAt > $1.savedAt },
            unreadableDirectories: unreadable.sorted { $0.path < $1.path }
        )
    }

    /// Removes a batch's record and every master it captured.
    ///
    /// The only call in ScanDeck that deletes acknowledged pages, which is why
    /// it exists behind an explicit operator decision and nothing else.
    public func discard(_ batchID: BatchID) throws {
        let target = directory(for: batchID)
        guard FileManager.default.fileExists(atPath: target.path) else {
            return
        }
        do {
            try FileManager.default.removeItem(at: target)
        } catch {
            throw BatchSessionStoreError.cannotDiscard(
                error.localizedDescription
            )
        }
    }
}
