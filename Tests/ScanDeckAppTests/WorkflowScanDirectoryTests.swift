import Foundation
import ScanDeckCore
import Testing
@testable import ScanDeckApp

/// Covers where a pass is allowed to write.
///
/// The Image Capture transport refuses a non-empty output directory, because
/// starting empty is how it knows every file it finds belongs to the pass it
/// just ran. Masters, meanwhile, stay on disk for the life of the batch. Those
/// two facts only coexist if each pass gets a directory of its own — otherwise
/// Continue Scanning, Retry, and Replace all fail the moment a batch holds its
/// first card, which is a defect no reducer test can see.
@MainActor
@Suite("Workflow scan directories")
struct WorkflowScanDirectoryTests {
    @Test("Each pass in a batch scans into an empty directory of its own")
    func passesDoNotShareADirectory() async throws {
        let sessions = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: sessions) }

        let scanner = RecordingScanPassProvider()
        let actions = ScanDeckWorkflowActions(
            scanner: scanner,
            sessionsDirectory: sessions
        )
        let batchID = BatchID(rawValue: UUID())

        for _ in 0..<3 {
            for await _ in actions.scan(
                ScanPassRequest(
                    batchID: batchID,
                    passID: ScanPassID(rawValue: UUID()),
                    kind: .append,
                    profile: .cards600FullBorder,
                    margins: try ScanMargins(all: 3)
                )
            ) {}
        }

        #expect(Set(scanner.directories).count == 3)

        // Each pass met a directory holding only its own master. Sharing one
        // would have handed pass two a folder the transport rejects outright.
        for directory in scanner.directories {
            let contents = try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil
            )
            #expect(contents.count == 1)
        }

        // Masters from earlier passes are still there: nothing is cleared to
        // make room, because a captured page outlives the pass that caught it.
        #expect(scanner.masterURLs.count == 3)
        for url in scanner.masterURLs {
            #expect(FileManager.default.fileExists(atPath: url.path))
        }

        // All three sit under the one batch, so the session folder stays the
        // unit that recovery and cleanup can reason about.
        let batchDirectories = Set(
            scanner.directories.map { $0.deletingLastPathComponent().path }
        )
        #expect(batchDirectories.count == 1)

        // And that folder is exactly the one `BatchSessionStore` owns. Discard
        // deletes the batch directory, so if masters ever landed outside it the
        // operator would discard a batch and keep the images — a scanned
        // collection quietly surviving the delete that was meant to remove it.
        let expected = BatchSessionStore(directory: sessions)
            .directory(for: batchID)
            .standardizedFileURL
            .path
        #expect(batchDirectories == [expected])
    }
}

/// Writes a stand-in master so each pass leaves the directory as a real one
/// would — the whole point of the test is what the *next* pass then meets.
@MainActor
private final class RecordingScanPassProvider: ScanPassProviding {
    private(set) var directories: [URL] = []
    private(set) var masterURLs: [URL] = []

    func scan(
        _ request: ScanPassRequest,
        into directory: URL
    ) -> AsyncStream<ScanPassProgress> {
        directories.append(directory)

        let url = directory.appending(
            path: "master-\(UUID().uuidString).jpg",
            directoryHint: .notDirectory
        )
        try? Data([0xFF, 0xD8, 0xFF, 0xD9]).write(to: url)
        masterURLs.append(url)

        return AsyncStream { continuation in
            continuation.yield(.page(url))
            continuation.yield(.finished(.succeeded))
            continuation.finish()
        }
    }
}
