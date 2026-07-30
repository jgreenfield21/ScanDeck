import Foundation
import Testing
@testable import ScanDeckCore

@Suite("Persistent job counter")
struct JobCounterStoreTests {
    @Test("An unknown job starts at the first sheet number")
    func unknownJobStartsAtOne() {
        let context = makeStore()
        defer { context.cleanUp() }

        #expect(
            context.store.nextSheetNumber(for: context.jobID)
                == JobCounterStore.firstSheetNumber
        )
    }

    @Test("A committed counter survives a new store over the same directory")
    func committedCounterPersists() throws {
        let context = makeStore()
        defer { context.cleanUp() }

        try context.store.commit(nextSheetNumber: 116, for: context.jobID)

        // A fresh store stands in for the next launch.
        let reopened = JobCounterStore(directory: context.directory)
        #expect(reopened.nextSheetNumber(for: context.jobID) == 116)
    }

    @Test("Counters are independent per job")
    func countersAreScopedPerJob() throws {
        let context = makeStore()
        defer { context.cleanUp() }
        let other = JobID(rawValue: UUID())

        try context.store.commit(nextSheetNumber: 500, for: context.jobID)

        #expect(context.store.nextSheetNumber(for: context.jobID) == 500)
        #expect(
            context.store.nextSheetNumber(for: other)
                == JobCounterStore.firstSheetNumber
        )
    }

    @Test("Commit refuses to move the counter backwards")
    func commitIsMonotonic() throws {
        let context = makeStore()
        defer { context.cleanUp() }

        try context.store.commit(nextSheetNumber: 200, for: context.jobID)

        // A replayed or late commit must never hand back published numbers.
        #expect(throws: JobCounterError.notMonotonic(stored: 200, requested: 150)) {
            try context.store.commit(
                nextSheetNumber: 150,
                for: context.jobID
            )
        }
        #expect(context.store.nextSheetNumber(for: context.jobID) == 200)
    }

    @Test("Re-committing the same number is accepted")
    func commitIsIdempotent() throws {
        let context = makeStore()
        defer { context.cleanUp() }

        try context.store.commit(nextSheetNumber: 200, for: context.jobID)
        try context.store.commit(nextSheetNumber: 200, for: context.jobID)

        #expect(context.store.nextSheetNumber(for: context.jobID) == 200)
    }

    @Test("Seeding may move the counter in either direction")
    func seedingOverridesInBothDirections() throws {
        let context = makeStore()
        defer { context.cleanUp() }

        try context.store.commit(nextSheetNumber: 900, for: context.jobID)
        try context.store.seed(10, for: context.jobID)

        #expect(context.store.nextSheetNumber(for: context.jobID) == 10)
    }

    @Test("Seeding below the first sheet number is refused")
    func seedingBelowFloorIsRefused() {
        let context = makeStore()
        defer { context.cleanUp() }

        #expect(throws: (any Error).self) {
            try context.store.seed(0, for: context.jobID)
        }
    }

    @Test("A corrupted record falls back rather than crashing the app")
    func corruptedRecordFallsBack() throws {
        let context = makeStore()
        defer { context.cleanUp() }

        try context.store.commit(nextSheetNumber: 300, for: context.jobID)
        let file = context.directory.appending(
            path: "\(context.jobID.rawValue.uuidString).json",
            directoryHint: .notDirectory
        )
        try Data("not json".utf8).write(to: file)

        #expect(
            context.store.nextSheetNumber(for: context.jobID)
                == JobCounterStore.firstSheetNumber
        )
    }

    @Test("Writing leaves no temporary files behind")
    func writesCleanUpTemporaries() throws {
        let context = makeStore()
        defer { context.cleanUp() }

        try context.store.commit(nextSheetNumber: 42, for: context.jobID)

        let contents = try FileManager.default.contentsOfDirectory(
            atPath: context.directory.path
        )
        #expect(contents.count == 1)
        #expect(contents.allSatisfy { !$0.hasSuffix(".tmp") })
    }

    // MARK: - Harness

    private struct Context {
        let store: JobCounterStore
        let directory: URL
        let jobID: JobID

        func cleanUp() {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    private func makeStore() -> Context {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        return Context(
            store: JobCounterStore(directory: directory),
            directory: directory,
            jobID: JobID(rawValue: UUID())
        )
    }
}
