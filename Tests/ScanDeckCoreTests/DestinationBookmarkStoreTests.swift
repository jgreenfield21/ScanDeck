import Foundation
import Testing
@testable import ScanDeckCore

@Suite("Destination bookmark storage")
struct DestinationBookmarkStoreTests {
    @Test("Saves and resolves a destination folder")
    func savesAndResolvesDestination() throws {
        let storage = InMemoryDestinationBookmarkStorage()
        let store = DestinationBookmarkStore(storage: storage)
        let destination = try makeTemporaryDestination()
        defer {
            try? FileManager.default.removeItem(
                at: destination.deletingLastPathComponent()
            )
        }

        try store.save(destination)

        let resolved = try #require(store.resolveDestination())
        #expect(resolved.standardizedFileURL == destination.standardizedFileURL)
        #expect(storage.destinationBookmark != nil)
    }

    @Test("Returns nil when no bookmark is stored")
    func returnsNilWithoutStoredBookmark() {
        let store = DestinationBookmarkStore(
            storage: InMemoryDestinationBookmarkStorage()
        )

        #expect(store.resolveDestination() == nil)
    }

    @Test("Returns nil after the destination folder is deleted")
    func returnsNilAfterDestinationIsDeleted() throws {
        let storage = InMemoryDestinationBookmarkStorage()
        let store = DestinationBookmarkStore(storage: storage)
        let destination = try makeTemporaryDestination()
        let temporaryRoot = destination.deletingLastPathComponent()
        defer {
            try? FileManager.default.removeItem(at: temporaryRoot)
        }

        try store.save(destination)
        try FileManager.default.removeItem(at: destination)

        #expect(store.resolveDestination() == nil)
    }

    @Test("Displays the parent and destination folder names")
    func displaysParentAndLeaf() {
        let destination = URL(
            fileURLWithPath: "/Volumes/Google Drive/Card Scans",
            isDirectory: true
        )

        #expect(
            DestinationBookmarkStore.displayName(for: destination)
                == "Google Drive / Card Scans"
        )
    }

    @Test("Displays only the leaf when the parent is the filesystem root")
    func displaysLeafWithoutMeaningfulParent() {
        let destination = URL(
            fileURLWithPath: "/Card Scans",
            isDirectory: true
        )

        #expect(
            DestinationBookmarkStore.displayName(for: destination)
                == "Card Scans"
        )
    }

    private func makeTemporaryDestination() throws -> URL {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let destination = temporaryRoot
            .appendingPathComponent("Card Scans", isDirectory: true)
        try FileManager.default.createDirectory(
            at: destination,
            withIntermediateDirectories: true
        )
        return destination
    }
}
