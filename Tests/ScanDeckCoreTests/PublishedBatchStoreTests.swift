import Foundation
import Testing
@testable import ScanDeckCore

/// The batch history, which is the only lasting record that a batch existed.
///
/// Once publication and the counter commit are both durable the session record
/// is cleared, so before this store the app could not name a single batch it had
/// produced. Everything here is about that record being trustworthy and never
/// being able to break the app: a history is a convenience, and it holds nothing
/// that could not be re-derived by opening the destination folder.
@Suite("Published batch history")
struct PublishedBatchStoreTests {
    @Test("Records round trip and come back newest first")
    func recordsRoundTripNewestFirst() throws {
        let store = makeStore()
        try store.append(makeRecord(name: "samplebox1", daysAgo: 2))
        try store.append(makeRecord(name: "samplebox3", daysAgo: 0))
        try store.append(makeRecord(name: "samplebox2", daysAgo: 1))

        #expect(
            store.records().map(\.batchName.value)
                == ["samplebox3", "samplebox2", "samplebox1"]
        )
    }

    /// The same idempotency the counter commit has.
    ///
    /// `resumeCompletion` regenerates a candidate after relaunch and reports the
    /// same success again, so a store keyed on anything but the batch identifier
    /// would show one batch twice.
    @Test("Re-recording the same batch replaces its row rather than adding one")
    func rerecordingReplaces() throws {
        let store = makeStore()
        let batchID = BatchID(rawValue: UUID())
        try store.append(
            makeRecord(name: "samplebox2", daysAgo: 0, id: batchID, cardCount: 3)
        )
        try store.append(
            makeRecord(
                name: "samplebox2",
                daysAgo: 0,
                id: batchID,
                cardCount: 215
            )
        )

        #expect(store.records().count == 1)
        #expect(store.records().first?.cardCount == 215)
    }

    @Test("Forgetting a batch removes only its row")
    func forgetRemovesOneRow() throws {
        let store = makeStore()
        let doomed = BatchID(rawValue: UUID())
        try store.append(makeRecord(name: "keep", daysAgo: 1))
        try store.append(makeRecord(name: "drop", daysAgo: 0, id: doomed))

        try store.forget(doomed)

        #expect(store.records().map(\.batchName.value) == ["keep"])
    }

    /// A history that cannot be read must not be able to stop the app opening.
    /// There is nothing in it that is not also visible in the destination folder.
    @Test("An unreadable history reads as empty rather than throwing")
    func corruptHistoryReadsAsEmpty() throws {
        let directory = makeDirectory()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        try Data("not json at all".utf8).write(
            to: directory.appending(
                path: "batches.json",
                directoryHint: .notDirectory
            )
        )

        #expect(PublishedBatchStore(directory: directory).records().isEmpty)
    }

    @Test("A missing history reads as empty")
    func missingHistoryReadsAsEmpty() {
        #expect(makeStore().records().isEmpty)
    }

    @Test("The history is capped so it cannot grow without bound")
    func historyIsCapped() throws {
        let store = makeStore()
        // One past the cap, oldest last, so the drop is observable.
        for index in 0...PublishedBatchStore.maximumRecordCount {
            try store.append(makeRecord(name: "batch-\(index)", daysAgo: index))
        }

        let records = store.records()
        #expect(records.count == PublishedBatchStore.maximumRecordCount)
        // Newest kept, oldest dropped.
        #expect(records.first?.batchName.value == "batch-0")
        #expect(
            records.last?.batchName.value
                == "batch-\(PublishedBatchStore.maximumRecordCount - 1)"
        )
    }

    /// The two facts that exist nowhere else once the session record is gone.
    @Test("The overruled and warned sheet numbers survive the round trip")
    func warningRecordSurvives() throws {
        let store = makeStore()
        try store.append(
            PublishedBatchRecord(
                id: BatchID(rawValue: UUID()),
                jobID: JobID(rawValue: UUID()),
                batchName: try BatchName("samplebox2"),
                cardCount: 215,
                firstSheetNumber: 195,
                lastSheetNumber: 409,
                destinationDisplayName: "Pokemon Scans",
                publishedAt: Date(timeIntervalSince1970: 1_000),
                destinationBookmark: nil,
                releasedWithSizeWarnings: [200, 314],
                releasedWithAcceptedMismatches: [314]
            )
        )

        let record = try #require(store.records().first)
        #expect(record.releasedWithSizeWarnings == [200, 314])
        #expect(record.releasedWithAcceptedMismatches == [314])
        #expect(record.firstSheetNumber == 195)
        #expect(record.lastSheetNumber == 409)
    }

    /// A row for a batch whose folder has moved is still worth showing — the
    /// numbers it burned are still the truth about the counter. Only the actions
    /// that need the files are refused.
    @Test("A record with no bookmark resolves to no folder rather than failing")
    func recordWithoutBookmarkResolvesToNil() throws {
        let store = makeStore()
        try store.append(makeRecord(name: "samplebox2", daysAgo: 0))
        let record = try #require(store.records().first)
        #expect(record.resolveDestinationURL() == nil)
    }

    @Test("A bookmark round trips to the folder it was taken from")
    func bookmarkResolvesToItsFolder() throws {
        let folder = makeDirectory()
        try FileManager.default.createDirectory(
            at: folder,
            withIntermediateDirectories: true
        )
        let store = makeStore()
        try store.append(
            PublishedBatchRecord(
                id: BatchID(rawValue: UUID()),
                jobID: JobID(rawValue: UUID()),
                batchName: try BatchName("samplebox2"),
                cardCount: 1,
                firstSheetNumber: 1,
                lastSheetNumber: 1,
                destinationDisplayName: folder.lastPathComponent,
                publishedAt: Date(timeIntervalSince1970: 1_000),
                destinationBookmark: try folder.bookmarkData(
                    options: [],
                    includingResourceValuesForKeys: nil,
                    relativeTo: nil
                )
            )
        )

        let resolved = try #require(store.records().first?.resolveDestinationURL())
        #expect(
            resolved.resolvingSymlinksInPath().path
                == folder.resolvingSymlinksInPath().path
        )
    }

    // MARK: - Harness

    /// A temp directory per store: `PublishedBatchStore.applicationSupport` is
    /// the operator's real history and no test may touch it.
    private func makeDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    }

    private func makeStore() -> PublishedBatchStore {
        PublishedBatchStore(directory: makeDirectory())
    }

    private func makeRecord(
        name: String,
        daysAgo: Int,
        id: BatchID = BatchID(rawValue: UUID()),
        cardCount: Int = 215
    ) -> PublishedBatchRecord {
        PublishedBatchRecord(
            id: id,
            jobID: JobID(rawValue: UUID()),
            batchName: try! BatchName(name),
            cardCount: cardCount,
            firstSheetNumber: 195,
            lastSheetNumber: 409,
            destinationDisplayName: "Pokemon Scans",
            publishedAt: Date(
                timeIntervalSince1970: 1_000_000 - Double(daysAgo) * 86_400
            ),
            destinationBookmark: nil
        )
    }
}
