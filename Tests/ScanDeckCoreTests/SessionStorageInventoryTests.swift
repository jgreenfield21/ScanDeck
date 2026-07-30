import Foundation
import ScanDeckCore
import Testing

/// Covers what Settings reports about retained working files, and the one class
/// of them it will remove.
///
/// The counts matter because they are the only place the operator can see that
/// ScanDeck is holding pages, and the removal matters because it is a deletion
/// of captured images — so it has to touch exactly the directories that can
/// never be restored and nothing else.
@Suite("Session storage inventory")
struct SessionStorageInventoryTests {
    @Test("An empty store reports nothing retained")
    func emptyStoreIsEmpty() {
        let store = BatchSessionStore(directory: temporaryDirectory())
        #expect(store.inventory().isEmpty)
    }

    @Test("Resumable batches, their cards, and their bytes are counted")
    func countsResumableWork() throws {
        let root = temporaryDirectory()
        let store = BatchSessionStore(directory: root)
        defer { try? FileManager.default.removeItem(at: root) }

        let record = try saveBatch(in: store, cardCount: 2, masterBytes: 1_000)

        let inventory = store.inventory()
        #expect(inventory.resumableBatchCount == 1)
        #expect(inventory.resumableCardCount == 2)
        #expect(inventory.directoriesWithoutRecord.isEmpty)
        #expect(inventory.publishedRecordCount == 0)
        // The record itself plus the masters beside it.
        #expect(inventory.totalByteCount > 1_000)
        #expect(record.session.cards.count == 2)
    }

    @Test("A directory of masters with no record is reported separately")
    func countsDirectoriesWithoutRecord() throws {
        let root = temporaryDirectory()
        let store = BatchSessionStore(directory: root)
        defer { try? FileManager.default.removeItem(at: root) }

        _ = try saveBatch(in: store, cardCount: 1, masterBytes: 100)
        let orphan = try makeDirectoryWithoutRecord(in: root)

        let inventory = store.inventory()
        // `load()` passes over this silently, because at launch the only
        // question is what can be offered back. Here the question is what is
        // being kept, and the answer has to include what nothing can restore.
        // Resolved before comparing: the enumerator returns /private/var where
        // the temporary directory was handed out as /var. Same directory,
        // spelled the way the filesystem spells it.
        #expect(
            inventory.directoriesWithoutRecord.map {
                $0.resolvingSymlinksInPath()
            } == [orphan.resolvingSymlinksInPath()]
        )
        #expect(inventory.resumableBatchCount == 1)
    }

    @Test("Removal takes the unrestorable directories and nothing else")
    func removalIsNarrow() throws {
        let root = temporaryDirectory()
        let store = BatchSessionStore(directory: root)
        defer { try? FileManager.default.removeItem(at: root) }

        let record = try saveBatch(in: store, cardCount: 1, masterBytes: 100)
        let orphan = try makeDirectoryWithoutRecord(in: root)

        let removed = try store.removeDirectoriesWithoutRecord()

        #expect(removed == 1)
        #expect(!FileManager.default.fileExists(atPath: orphan.path))
        // The operator's unfinished batch is their work, and it has its own
        // Discard behind a confirmation. Sweeping it up here would delete a
        // recoverable batch under the heading of tidying up.
        #expect(
            FileManager.default.fileExists(
                atPath: store.directory(for: record.session.id).path
            )
        )
        #expect(store.load().resumable.count == 1)
    }

    @Test("An unreadable record is counted, never removed")
    func unreadableRecordsAreLeftAlone() throws {
        let root = temporaryDirectory()
        let store = BatchSessionStore(directory: root)
        defer { try? FileManager.default.removeItem(at: root) }

        let directory = root.appending(
            path: UUID().uuidString,
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        try Data("not json".utf8).write(
            to: directory.appending(
                path: BatchSessionStore.recordFileName,
                directoryHint: .notDirectory
            )
        )

        #expect(store.inventory().unreadableDirectoryCount == 1)
        #expect(try store.removeDirectoriesWithoutRecord() == 0)
        // A record nothing could parse is the case where the images matter
        // most and the app understands least.
        #expect(FileManager.default.fileExists(atPath: directory.path))
    }

    // MARK: - Harness

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    }

    @discardableResult
    private func saveBatch(
        in store: BatchSessionStore,
        cardCount: Int,
        masterBytes: Int
    ) throws -> PersistedBatchSession {
        var session = BatchSession(
            id: BatchID(rawValue: UUID()),
            jobID: JobID(rawValue: UUID()),
            batchName: try BatchName("aug01-sale"),
            firstSheetNumber: 1,
            deliveryOrder: .frontFirst,
            requestedMargins: try ScanMargins(all: 3),
            captureRotation: .zero
        )

        let passID = ScanPassID(rawValue: UUID())
        _ = try BatchSessionReducer.reduce(
            .beginAppend(passID: passID),
            into: &session
        )

        let batchDirectory = store.directory(for: session.id)
        try FileManager.default.createDirectory(
            at: batchDirectory,
            withIntermediateDirectories: true
        )

        var masterURLs: [MasterID: URL] = [:]
        for index in 0..<(cardCount * 2) {
            let masterID = MasterID(rawValue: UUID())
            let url = batchDirectory.appending(
                path: "master-\(index).jpg",
                directoryHint: .notDirectory
            )
            try Data(repeating: 0xAA, count: masterBytes).write(to: url)
            masterURLs[masterID] = url
            _ = try BatchSessionReducer.reduce(
                .pageReceived(
                    passID: passID,
                    masterID: masterID,
                    captureSequence: session.nextCaptureSequence,
                    newCardID: index.isMultiple(of: 2)
                        ? CardID(rawValue: UUID())
                        : nil
                ),
                into: &session
            )
        }
        _ = try BatchSessionReducer.reduce(
            .scanEnded(passID: passID, outcome: .completed),
            into: &session
        )

        let record = PersistedBatchSession(
            session: session,
            masterURLs: masterURLs,
            startedAt: .now,
            savedAt: .now,
            destinationBookmark: nil
        )
        try store.save(record)
        return record
    }

    private func makeDirectoryWithoutRecord(in root: URL) throws -> URL {
        // Exactly what a crash between creating a pass directory and the first
        // autosave leaves behind: real captured images, and nothing that says
        // which side of which card they are.
        let directory = root.appending(
            path: UUID().uuidString,
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        try Data([0xFF, 0xD8, 0xFF, 0xD9]).write(
            to: directory.appending(
                path: "master-0.jpg",
                directoryHint: .notDirectory
            )
        )
        return directory.standardizedFileURL
    }
}
