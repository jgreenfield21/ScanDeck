import Foundation
import Testing
@testable import ScanDeckCore

/// Covers the store that makes invariant #1 survive a crash.
///
/// The masters are already durable the moment the scanner writes them. What
/// this store protects is the state that gives them meaning — which side of
/// which card, at which number — and the two things the reducer deliberately
/// does not know: where those files are, and where the batch is going.
@Suite("Unfinished batch storage")
struct BatchSessionStoreTests {
    @Test("A saved batch comes back whole")
    func roundTripsEverythingNeededToResume() throws {
        let harness = try Harness()
        let session = try harness.session()
        let master = MasterID(rawValue: UUID())
        let masterURL = URL(fileURLWithPath: "/tmp/scandeck/master-1.jpg")
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)

        try harness.store.save(
            PersistedBatchSession(
                session: session,
                masterURLs: [master: masterURL],
                startedAt: startedAt,
                savedAt: Date(timeIntervalSince1970: 1_700_000_500),
                destinationBookmark: Data([0xAB, 0xCD])
            )
        )

        let record = try #require(harness.store.load().resumable.first)
        #expect(record.session == session)
        #expect(record.masterURLs == [master: masterURL])
        #expect(record.startedAt == startedAt)
        #expect(record.destinationBookmark == Data([0xAB, 0xCD]))
    }

    @Test("Saving twice replaces the record rather than accumulating")
    func savingIsIdempotentPerBatch() throws {
        let harness = try Harness()
        let session = try harness.session()

        for offset in 0..<3 {
            try harness.store.save(
                harness.record(
                    session,
                    savedAt: Date(timeIntervalSince1970: 1_000 + Double(offset))
                )
            )
        }

        #expect(harness.store.load().records.count == 1)
    }

    @Test("Batches come back newest first")
    func recordsAreOrderedByMostRecentlySaved() throws {
        let harness = try Harness()
        let older = try harness.session(name: "jul30-sale", batch: UUID())
        let newer = try harness.session(name: "aug01-sale", batch: UUID())

        try harness.store.save(
            harness.record(older, savedAt: Date(timeIntervalSince1970: 100))
        )
        try harness.store.save(
            harness.record(newer, savedAt: Date(timeIntervalSince1970: 900))
        )

        #expect(
            harness.store.load().records.map(\.session.batchName.value)
                == ["aug01-sale", "jul30-sale"]
        )
    }

    @Test("An unreadable record is named, not swallowed, and never hides others")
    func corruptRecordIsReportedAlongsideTheGoodOnes() throws {
        let harness = try Harness()
        let healthy = try harness.session(name: "aug01-sale", batch: UUID())
        try harness.store.save(harness.record(healthy))

        let corruptID = BatchID(rawValue: UUID())
        try harness.writeRawRecord("{ this is not json", for: corruptID)

        let found = harness.store.load()

        // A corrupt file is exactly when an operator most needs the batches
        // that are still intact.
        #expect(found.records.count == 1)
        #expect(found.records.first?.session.batchName.value == "aug01-sale")
        #expect(found.unreadableDirectories.count == 1)
        #expect(
            found.unreadableDirectories.first?.lastPathComponent
                == corruptID.rawValue.uuidString
        )
        // Unreadable must never mean deleted: the images are still there.
        #expect(
            FileManager.default.fileExists(
                atPath: harness.store.directory(for: corruptID).path
            )
        )
    }

    @Test("A record from a newer ScanDeck is left alone rather than guessed at")
    func futureSchemaIsUnreadable() throws {
        let harness = try Harness()
        let batchID = BatchID(rawValue: UUID())
        try harness.writeRawRecord(
            #"{"schemaVersion": 99, "masters": [], "startedAt": 0, "savedAt": 0}"#,
            for: batchID
        )

        let found = harness.store.load()

        #expect(found.records.isEmpty)
        #expect(found.unreadableDirectories.count == 1)
    }

    @Test("Masters with no record are skipped without complaint")
    func directoryWithoutRecordIsNotAnError() throws {
        let harness = try Harness()
        // A crash between creating the pass directory and the first autosave.
        // There is no batch to restore and nothing has gone wrong.
        let orphan = harness.root.appending(
            path: UUID().uuidString,
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: orphan,
            withIntermediateDirectories: true
        )

        let found = harness.store.load()

        #expect(found.records.isEmpty)
        #expect(found.unreadableDirectories.isEmpty)
    }

    @Test("Discard removes the record and every master with it")
    func discardTakesTheImagesToo() throws {
        let harness = try Harness()
        let session = try harness.session()
        try harness.store.save(harness.record(session))

        let masterDirectory = harness.store
            .directory(for: session.id)
            .appending(path: "pass-1", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: masterDirectory,
            withIntermediateDirectories: true
        )
        let master = masterDirectory.appending(
            path: "master-1.jpg",
            directoryHint: .notDirectory
        )
        try Data([0xFF, 0xD8]).write(to: master)

        try harness.store.discard(session.id)

        // Record and images go together, so Discard can never leave orphaned
        // pages behind or delete images while claiming the batch survives.
        #expect(!FileManager.default.fileExists(atPath: master.path))
        #expect(
            !FileManager.default.fileExists(
                atPath: harness.store.directory(for: session.id).path
            )
        )
        #expect(harness.store.load().records.isEmpty)
    }

    @Test("Discarding a batch that is already gone is not an error")
    func discardIsIdempotent() throws {
        let harness = try Harness()
        try harness.store.discard(BatchID(rawValue: UUID()))
    }

    @Test("A batch that already asked to publish is not offered for resume")
    func releasingBatchesBelongToTheReleaseJournal() throws {
        let harness = try Harness()
        var session = try harness.session()

        let passID = ScanPassID(rawValue: UUID())
        try BatchSessionReducer.reduce(
            .beginAppend(passID: passID),
            into: &session
        )
        try BatchSessionReducer.reduce(
            .pageReceived(
                passID: passID,
                masterID: MasterID(rawValue: UUID()),
                captureSequence: 0,
                newCardID: CardID(rawValue: UUID())
            ),
            into: &session
        )
        try BatchSessionReducer.reduce(
            .pageReceived(
                passID: passID,
                masterID: MasterID(rawValue: UUID()),
                captureSequence: 1,
                newCardID: nil
            ),
            into: &session
        )
        try BatchSessionReducer.reduce(
            .scanEnded(passID: passID, outcome: .completed),
            into: &session
        )
        for card in session.cards {
            guard let sides = card.activeSides else {
                continue
            }
            for side in [OutputSide.front, .back] {
                guard let scannedSide = sides[side] else {
                    continue
                }
                try BatchSessionReducer.reduce(
                    .marginAssessed(
                        masterID: scannedSide.masterID,
                        rotation: scannedSide.rotation,
                        result: .sufficient(mediaSize: nil)
                    ),
                    into: &session
                )
            }
        }
        try BatchSessionReducer.reduce(
            .requestCompletion(attemptID: ReleaseAttemptID(rawValue: UUID())),
            into: &session
        )
        try harness.store.save(harness.record(session))

        let found = harness.store.load()

        // Readable, so nothing is lost; not resumable, because resuming could
        // republish a folder that already landed. TICKET-006b owns these.
        #expect(found.records.count == 1)
        #expect(found.resumable.isEmpty)
    }

    // MARK: - Harness

    private struct Harness {
        let root: URL
        let store: BatchSessionStore

        init() throws {
            root = FileManager.default.temporaryDirectory
                .appending(path: UUID().uuidString, directoryHint: .isDirectory)
            try FileManager.default.createDirectory(
                at: root,
                withIntermediateDirectories: true
            )
            store = BatchSessionStore(directory: root)
        }

        func session(
            name: String = "aug01-sale",
            batch: UUID = UUID()
        ) throws -> BatchSession {
            BatchSession(
                id: BatchID(rawValue: batch),
                jobID: JobID(rawValue: UUID()),
                batchName: try BatchName(name),
                firstSheetNumber: 114,
                deliveryOrder: .frontFirst
            )
        }

        func record(
            _ session: BatchSession,
            savedAt: Date = Date(timeIntervalSince1970: 1_700_000_000)
        ) -> PersistedBatchSession {
            PersistedBatchSession(
                session: session,
                masterURLs: [:],
                startedAt: Date(timeIntervalSince1970: 1_699_000_000),
                savedAt: savedAt,
                destinationBookmark: nil
            )
        }

        func writeRawRecord(_ contents: String, for batchID: BatchID) throws {
            let directory = store.directory(for: batchID)
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            try Data(contents.utf8).write(
                to: store.recordURL(for: batchID)
            )
        }
    }
}
