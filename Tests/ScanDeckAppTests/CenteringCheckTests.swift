import CryptoKit
import Foundation
import Testing
@testable import ScanDeckApp

/// Mirrors `ScanDeckWorkflowActions.centeringToolURL()`'s development lookup.
///
/// The centering tool is private and `.gitignore` deliberately keeps it out of
/// the repository, so a clone cannot run the handoff test at all. Skipping is
/// the only honest outcome: a suite that fails on a fresh checkout teaches
/// every contributor that red is normal, which is how a real regression gets
/// waved through. The parser tests around it need no tool and still run.
private var privateCenteringToolIsPresent: Bool {
    let repositoryRoot = URL(filePath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    var isDirectory: ObjCBool = false
    let present = FileManager.default.fileExists(
        atPath: repositoryRoot
            .appending(path: "centering", directoryHint: .isDirectory)
            .appending(path: "centering_check.py", directoryHint: .notDirectory)
            .path,
        isDirectory: &isDirectory
    )
    return present && !isDirectory.boolValue
}

@Suite("Centering tool handoff")
struct CenteringCheckTests {
    @Test("Fragmented JSON progress remains ordered and typed")
    func fragmentedProgressParses() throws {
        var parser = CenteringToolOutputParser()
        let first = Data(
            """
            {"event":"progress","completedImages":2,"imageCount":8,
            """.utf8
        )
        let second = Data(
            (
                """
                "uploadedImages":2,"cachedImages":0,"failedImages":0}
                """
                + "\n"
            ).utf8
        )

        #expect(try parser.append(first).isEmpty)
        #expect(
            try parser.append(second) == [
                .progress(
                    CenteringCheckProgress(
                        completedImages: 2,
                        imageCount: 8,
                        uploadedImages: 2,
                        cachedImages: 0,
                        failedImages: 0
                    )
                )
            ]
        )
        #expect(try parser.finish().isEmpty)
    }

    @Test("The completion event carries output and cache counts")
    func completionParses() throws {
        var parser = CenteringToolOutputParser()
        let line = #"{"event":"complete","imageCount":8,"cardCount":4,"#
            + #""uploadedImages":0,"cachedImages":8,"#
            + #""outputFolder":"/tmp/batch/centering"}"#
        let data = Data((line + "\n").utf8)

        let events = try parser.append(data)

        #expect(events.count == 1)
        guard case let .completed(receipt) = events.first else {
            Issue.record("The completion event was not parsed.")
            return
        }
        #expect(receipt.imageCount == 8)
        #expect(receipt.uploadedImages == 0)
        #expect(receipt.cachedImages == 8)
        #expect(receipt.outputFolderURL.path == "/tmp/batch/centering")
    }

    @Test("A tool error keeps its operator-facing explanation")
    func errorParses() throws {
        var parser = CenteringToolOutputParser()
        let events = try parser.append(
            Data(
                (
                    """
                    {"event":"error","message":"HTTP 429 after retries."}
                    """
                    + "\n"
                ).utf8
            )
        )

        #expect(
            events == [
                .failed(message: "HTTP 429 after retries.")
            ]
        )
    }

    @Test("Malformed progress is refused instead of freezing silently")
    func malformedProgressFails() {
        var parser = CenteringToolOutputParser()

        #expect(throws: CenteringCheckFailure.self) {
            try parser.append(Data("not-json\n".utf8))
        }
    }

    @MainActor
    @Test(
        "The production handoff runs the private tool and reads cached results",
        .enabled(if: privateCenteringToolIsPresent)
    )
    func productionHandoffRunsWithoutUploadingCachedImages() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: folder,
            withIntermediateDirectories: true
        )
        defer {
            try? FileManager.default.removeItem(at: folder)
        }

        let front = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x01])
        let back = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x02])
        let frontURL = folder.appending(path: "scan_000001_F.jpg")
        let backURL = folder.appending(path: "scan_000001_B.jpg")
        try front.write(to: frontURL)
        try back.write(to: backURL)
        try cache(
            source: front,
            overlayMarker: 0x11,
            under: folder
        )
        try cache(
            source: back,
            overlayMarker: 0x12,
            under: folder
        )

        let actions = ScanDeckWorkflowActions(
            scanner: CenteringNoopScanner(),
            sessionsDirectory: folder.appending(
                path: "Sessions",
                directoryHint: .isDirectory
            )
        )
        let receipt = try await actions.checkCentering(
            CenteringCheckRequest(
                publishedFolderURL: folder,
                imageCount: 2
            ),
            progress: { _ in }
        )

        #expect(receipt.imageCount == 2)
        #expect(receipt.uploadedImages == 0)
        #expect(receipt.cachedImages == 2)
        let overlayURL = receipt.outputFolderURL
            .appending(path: "psa-10", directoryHint: .isDirectory)
            .appending(path: "scan_000001_F.jpg")
        #expect(
            FileManager.default.fileExists(atPath: overlayURL.path)
        )
        #expect(
            FileManager.default.fileExists(
                atPath: receipt.outputFolderURL
                    .appending(path: "centering_report.csv")
                    .path
            )
        )
    }

    private func cache(
        source: Data,
        overlayMarker: UInt8,
        under folder: URL
    ) throws {
        let contentHash = SHA256.hash(data: source)
            .map { String(format: "%02x", $0) }
            .joined()
        let directory = folder
            .appending(path: "centering", directoryHint: .isDirectory)
            .appending(path: ".cache", directoryHint: .isDirectory)
            .appending(path: String(contentHash.prefix(2)), directoryHint: .isDirectory)
            .appending(path: contentHash, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let record: [String: Any] = [
            "schemaVersion": 1,
            "contentHash": contentHash,
            // A placeholder on purpose. The cache record only has to round-trip
            // whatever string the tool wrote; the real request shape is the
            // tool's business and is deliberately not published here.
            "endpoint": "https://example.invalid/centering",
            "response": [
                "centeringValues": [
                    "LR": 0.5,
                    "TB": 0.5,
                ],
                "detectionFailed": false,
            ],
        ]
        try JSONSerialization.data(
            withJSONObject: record,
            options: [.prettyPrinted, .sortedKeys]
        ).write(to: directory.appending(path: "result.json"))
        try Data([0xFF, 0xD8, 0xFF, 0xE0, overlayMarker])
            .write(to: directory.appending(path: "overlay.jpg"))
    }
}

@MainActor
private final class CenteringNoopScanner: ScanPassProviding {
    func scan(
        _ request: ScanPassRequest,
        into directory: URL
    ) -> AsyncStream<ScanPassProgress> {
        AsyncStream { continuation in
            continuation.finish()
        }
    }
}
