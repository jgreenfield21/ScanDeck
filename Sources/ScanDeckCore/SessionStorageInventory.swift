import Foundation

/// What ScanDeck is holding on to between runs, and which of it is reclaimable.
///
/// Session working files are captured pages, so this exists to *show* them
/// rather than to tidy them up on a schedule. ScanDeck never deletes a page on
/// a timer: invariant #1 says no failure may discard an acknowledged page, and
/// a retention policy that quietly did so on the app's own initiative would be
/// the same loss wearing a nicer name. Every removal below is a press.
public struct SessionStorageInventory: Equatable, Sendable {
    /// Batches the operator would be offered at the next launch.
    public let resumableBatchCount: Int
    public let resumableCardCount: Int

    /// Records that already asked to publish. They are neither offered nor
    /// deleted, because their numbers may have been committed to a folder that
    /// already exists — that is the release journal's business (TICKET-006b),
    /// and removing one here could destroy the only evidence of it.
    public let publishedRecordCount: Int

    /// Records nothing could parse. Their images are still on disk and must
    /// never be deleted on the strength of a record no one could read.
    public let unreadableDirectoryCount: Int

    /// Directories holding masters with no record beside them: a crash between
    /// creating a pass directory and the first autosave. There is no batch to
    /// restore from these, so ScanDeck can never turn them back into cards —
    /// but they are still captured images, which is why removing them is an
    /// explicit decision and not a cleanup.
    public let directoriesWithoutRecord: [URL]

    public let totalByteCount: Int64

    public init(
        resumableBatchCount: Int,
        resumableCardCount: Int,
        publishedRecordCount: Int,
        unreadableDirectoryCount: Int,
        directoriesWithoutRecord: [URL],
        totalByteCount: Int64
    ) {
        self.resumableBatchCount = resumableBatchCount
        self.resumableCardCount = resumableCardCount
        self.publishedRecordCount = publishedRecordCount
        self.unreadableDirectoryCount = unreadableDirectoryCount
        self.directoriesWithoutRecord = directoriesWithoutRecord
        self.totalByteCount = totalByteCount
    }

    public static let empty = SessionStorageInventory(
        resumableBatchCount: 0,
        resumableCardCount: 0,
        publishedRecordCount: 0,
        unreadableDirectoryCount: 0,
        directoriesWithoutRecord: [],
        totalByteCount: 0
    )

    public var isEmpty: Bool {
        self == .empty
    }
}

extension BatchSessionStore {
    /// Walks the sessions directory and counts what is there.
    ///
    /// Deliberately separate from `load()`. `load()` runs at every launch and
    /// answers one question — what can be offered back — so it skips a
    /// directory with no record without a word. This answers a different
    /// question the operator asks once in a while, in Settings, and the
    /// difference between those two is the whole reason a record-less directory
    /// is invisible at launch and visible here.
    public func inventory() -> SessionStorageInventory {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: storageDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        var resumableBatchCount = 0
        var resumableCardCount = 0
        var publishedRecordCount = 0
        var unreadableDirectoryCount = 0
        var directoriesWithoutRecord: [URL] = []
        var totalByteCount: Int64 = 0

        for batchDirectory in contents {
            guard (try? batchDirectory.resourceValues(forKeys: [.isDirectoryKey]))?
                .isDirectory == true
            else {
                continue
            }
            totalByteCount += Self.byteCount(of: batchDirectory)

            let recordURL = batchDirectory.appending(
                path: Self.recordFileName,
                directoryHint: .notDirectory
            )
            guard FileManager.default.fileExists(atPath: recordURL.path) else {
                directoriesWithoutRecord.append(batchDirectory)
                continue
            }
            guard let data = try? Data(contentsOf: recordURL),
                  let record = try? JSONDecoder().decode(
                      PersistedBatchSession.self,
                      from: data
                  )
            else {
                unreadableDirectoryCount += 1
                continue
            }

            if record.isResumable {
                resumableBatchCount += 1
                resumableCardCount += record.session.cards
                    .filter { $0.activeSides != nil }
                    .count
            } else {
                publishedRecordCount += 1
            }
        }

        return SessionStorageInventory(
            resumableBatchCount: resumableBatchCount,
            resumableCardCount: resumableCardCount,
            publishedRecordCount: publishedRecordCount,
            unreadableDirectoryCount: unreadableDirectoryCount,
            directoriesWithoutRecord: directoriesWithoutRecord.sorted {
                $0.path < $1.path
            },
            totalByteCount: totalByteCount
        )
    }

    /// Removes only the directories that hold masters with no record.
    ///
    /// Nothing else is touched. A resumable batch is the operator's work and
    /// has its own Discard behind a confirmation; a record that already asked
    /// to publish belongs to the release journal; an unreadable record is the
    /// one case where the images matter most and the app understands least.
    /// The images in *these* directories are real captured pages that ScanDeck
    /// can never restore into a batch, so the caller must have said so before
    /// calling this.
    @discardableResult
    public func removeDirectoriesWithoutRecord() throws -> Int {
        var removed = 0
        for directory in inventory().directoriesWithoutRecord {
            do {
                try FileManager.default.removeItem(at: directory)
                removed += 1
            } catch {
                throw BatchSessionStoreError.cannotDiscard(
                    error.localizedDescription
                )
            }
        }
        return removed
    }

    private static func byteCount(of directory: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: []
        ) else {
            return 0
        }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(
                forKeys: [.fileSizeKey, .isRegularFileKey]
            )
            guard values?.isRegularFile == true, let size = values?.fileSize
            else {
                continue
            }
            total += Int64(size)
        }
        return total
    }
}
