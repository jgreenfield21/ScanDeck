import CoreGraphics
import Foundation
import ImageIO
import ScanDeckCore
import Testing
import UniformTypeIdentifiers
@testable import ScanDeckImagePipeline

@Suite("Atomic batch publication")
struct BatchPublisherTests {
    @Test("Publishes one file per side using the carduploader names")
    func publishesNamedPair() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }

        let receipt = try await BatchPublisher().publish(
            harness.request(sheetNumbers: [114, 115])
        )

        #expect(
            receipt.fileNames.sorted() == [
                "scan_000114_B.jpg",
                "scan_000114_F.jpg",
                "scan_000115_B.jpg",
                "scan_000115_F.jpg",
            ]
        )
        #expect(
            receipt.publishedFolderURL.lastPathComponent == "aug01-sale"
        )

        let published = try FileManager.default.contentsOfDirectory(
            atPath: receipt.publishedFolderURL.path
        )
        #expect(published.sorted() == receipt.fileNames.sorted())
    }

    @Test("Published images carry the requested DPI metadata")
    func publishedImagesCarryDPI() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }

        let receipt = try await BatchPublisher().publish(
            harness.request(sheetNumbers: [114])
        )
        let file = receipt.publishedFolderURL.appending(
            path: "scan_000114_F.jpg",
            directoryHint: .notDirectory
        )

        let source = try #require(CGImageSourceCreateWithURL(file as CFURL, nil))
        let properties = try #require(
            CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        )
        #expect(
            (properties[kCGImagePropertyDPIWidth] as? NSNumber)?.intValue == 600
        )
    }

    @Test("Reports one step per file, in order, then the rename")
    func reportsProgressPerFile() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }

        // `publish` is synchronous and the callback fires on its own thread, so
        // a lock rather than an actor: the collection has to be safe to append
        // to from there and safe to read here.
        let recorder = ProgressRecorder()
        let receipt = try await BatchPublisher().publish(
            harness.request(sheetNumbers: [114, 115]),
            progress: { recorder.record($0) }
        )

        // Two cards is four files. The zeroth report is what puts a real total
        // on screen before the first quarter-second of cropping has elapsed.
        #expect(
            recorder.steps == [
                .writing(filesWritten: 0, fileCount: 4),
                .writing(filesWritten: 1, fileCount: 4),
                .writing(filesWritten: 2, fileCount: 4),
                .writing(filesWritten: 3, fileCount: 4),
                .writing(filesWritten: 4, fileCount: 4),
                .placingFolder,
            ]
        )
        #expect(receipt.fileNames.count == 4)
    }

    @Test("A count is never reported for a file that failed to land")
    func progressNeverOutrunsTheDisk() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }

        var request = harness.request(sheetNumbers: [114])
        request = PublicationRequest(
            batchName: request.batchName,
            destinationRoot: request.destinationRoot,
            cards: request.cards + [
                PublicationCard(
                    sheetNumber: 115,
                    front: PublicationSide(
                        masterURL: harness.destinationRoot
                            .appending(path: "missing.jpg"),
                        rotation: .zero
                    ),
                    back: PublicationSide(
                        masterURL: harness.destinationRoot
                            .appending(path: "missing.jpg"),
                        rotation: .zero
                    )
                ),
            ],
            margins: request.margins,
            template: request.template,
            dpi: request.dpi,
            quality: request.quality
        )

        let recorder = ProgressRecorder()
        await #expect(throws: (any Error).self) {
            try await BatchPublisher().publish(
                request,
                progress: { recorder.record($0) }
            )
        }

        // Two of the four files cannot be read, so at most two can ever land
        // and no report may claim more. This used to pin the last report at
        // exactly 2, which only held while staging was serial: four-way
        // staging (TICKET-035) starts all four at once and the failure is
        // usually observed first, so the terminal number is whatever had
        // finished by then. The property the assertion was defending is
        // unchanged and is what is asserted now — a count is only ever
        // reported for a file that is on disk and flushed.
        let counts = recorder.steps.compactMap { step -> Int? in
            guard case let .writing(filesWritten, fileCount) = step else {
                return nil
            }
            #expect(fileCount == 4)
            return filesWritten
        }
        #expect(counts == Array(0...(counts.count - 1)))
        #expect((counts.last ?? 0) <= 2)
        #expect(!recorder.steps.contains(.placingFolder))
    }

    @Test("Leaves no staging directory behind on success")
    func removesStagingOnSuccess() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }

        _ = try await BatchPublisher().publish(harness.request(sheetNumbers: [114]))

        let entries = try FileManager.default.contentsOfDirectory(
            atPath: harness.destinationRoot.path
        )
        #expect(entries == ["aug01-sale"])
    }

    @Test("Refuses to touch an existing batch folder")
    func refusesExistingBatchFolder() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }

        let existing = harness.destinationRoot.appending(
            path: "aug01-sale",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: existing,
            withIntermediateDirectories: true
        )
        let keepsake = existing.appending(path: "keep.txt", directoryHint: .notDirectory)
        try Data("original".utf8).write(to: keepsake)

        await #expect(throws: BatchPublisherError.batchFolderAlreadyExists(existing)) {
            try await BatchPublisher().publish(harness.request(sheetNumbers: [114]))
        }

        // The existing folder must be exactly as it was.
        #expect(
            try String(contentsOf: keepsake, encoding: .utf8) == "original"
        )
    }

    @Test("A missing master aborts the batch and leaves the destination clean")
    func missingMasterLeavesDestinationUntouched() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }

        var request = harness.request(sheetNumbers: [114, 115])
        request = PublicationRequest(
            batchName: request.batchName,
            destinationRoot: request.destinationRoot,
            cards: request.cards + [
                PublicationCard(
                    sheetNumber: 116,
                    front: PublicationSide(
                        masterURL: harness.destinationRoot
                            .appending(path: "missing.jpg"),
                        rotation: .zero
                    ),
                    back: PublicationSide(
                        masterURL: harness.destinationRoot
                            .appending(path: "missing.jpg"),
                        rotation: .zero
                    )
                ),
            ],
            margins: request.margins
        )

        await #expect(throws: (any Error).self) {
            try await BatchPublisher().publish(request)
        }

        // No partial folder, no staging leftovers — publication is all or
        // nothing (SPEC section 5).
        let entries = try FileManager.default.contentsOfDirectory(
            atPath: harness.destinationRoot.path
        )
        #expect(entries.isEmpty)
    }

    @Test("A failure with many sides in flight still leaves nothing behind")
    func parallelFailureDrainsBeforeCleaningUp() async throws {
        // TICKET-035's first condition. Four-way staging means that when one
        // side throws, three others are mid-crop — and the cleanup removes the
        // directory they are writing into. Structured concurrency drains the
        // group before `catch` runs, and this is what would fail if that ever
        // stopped being true: a half-deleted staging directory left in the
        // operator's destination.
        //
        // Run several times because the interleaving is the thing under test
        // and one pass proves very little about it.
        for attempt in 0..<8 {
            let harness = try Harness()
            defer { harness.cleanUp() }

            // Twenty cards is forty files, so the failing one is reached with
            // the window full and plenty still queued behind it.
            var request = harness.request(
                sheetNumbers: Array(200..<220).map(UInt64.init)
            )
            var cards = request.cards
            cards.insert(
                PublicationCard(
                    sheetNumber: 999,
                    front: PublicationSide(
                        masterURL: harness.destinationRoot
                            .appending(path: "missing.jpg"),
                        rotation: .zero
                    ),
                    back: PublicationSide(
                        masterURL: harness.masterURL,
                        rotation: .zero
                    )
                ),
                // Partway in rather than first or last, so the failure lands
                // with work both in flight and still to come.
                at: 6
            )
            request = PublicationRequest(
                batchName: request.batchName,
                destinationRoot: request.destinationRoot,
                cards: cards,
                margins: request.margins
            )

            await #expect(throws: (any Error).self) {
                try await BatchPublisher().publish(request)
            }

            let entries = try FileManager.default.contentsOfDirectory(
                atPath: harness.destinationRoot.path
            )
            #expect(
                entries.isEmpty,
                "attempt \(attempt) left \(entries) in the destination"
            )
        }
    }

    @Test("The batch folder does not exist until the rename")
    func nothingAppearsBeforeTheRename() async throws {
        // TICKET-035's second condition, observed from inside the run rather
        // than argued: while files are being staged the destination must hold
        // a staging directory and nothing else. Parallelism lives entirely
        // inside that phase; the atomic rename is still the only thing that
        // makes a batch folder appear.
        let harness = try Harness()
        defer { harness.cleanUp() }

        let finalFolder = harness.destinationRoot
            .appending(path: "aug01-sale", directoryHint: .isDirectory)
        let observations = ProgressRecorder()
        let sawBatchFolderEarly = FolderWatch()

        _ = try await BatchPublisher().publish(
            harness.request(sheetNumbers: Array(300..<310).map(UInt64.init)),
            progress: { step in
                observations.record(step)
                if case .writing = step,
                   FileManager.default.fileExists(atPath: finalFolder.path)
                {
                    sawBatchFolderEarly.trip()
                }
            }
        )

        #expect(!sawBatchFolderEarly.tripped)
        #expect(observations.steps.contains(.placingFolder))
        #expect(
            FileManager.default.fileExists(atPath: finalFolder.path)
        )
    }

    @Test("A template that collides is caught before anything is written")
    func detectsFilenameCollision() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }

        // Two cards forced to the same number collide once rendered.
        let request = harness.request(sheetNumbers: [114, 114])

        await #expect(
            throws: BatchPublisherError.filenameCollision("scan_000114_F.jpg")
        ) {
            try await BatchPublisher().publish(request)
        }

        let entries = try FileManager.default.contentsOfDirectory(
            atPath: harness.destinationRoot.path
        )
        #expect(entries.isEmpty)
    }

    @Test("An empty batch is refused")
    func refusesEmptyBatch() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }

        await #expect(throws: BatchPublisherError.noCards) {
            try await BatchPublisher().publish(harness.request(sheetNumbers: []))
        }
    }

    @Test("A rotated side is written with its axes swapped")
    func rotationIsBakedIn() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }

        var request = harness.request(sheetNumbers: [114])
        request = PublicationRequest(
            batchName: request.batchName,
            destinationRoot: request.destinationRoot,
            cards: [
                PublicationCard(
                    sheetNumber: 114,
                    front: PublicationSide(
                        masterURL: harness.masterURL,
                        rotation: .clockwise90
                    ),
                    back: PublicationSide(
                        masterURL: harness.masterURL,
                        rotation: .zero
                    )
                ),
            ],
            margins: request.margins
        )

        let receipt = try await BatchPublisher().publish(request)
        let rotated = try harness.pixelSize(
            of: receipt.publishedFolderURL
                .appending(path: "scan_000114_F.jpg")
        )
        let upright = try harness.pixelSize(
            of: receipt.publishedFolderURL
                .appending(path: "scan_000114_B.jpg")
        )

        #expect(rotated.width == upright.height)
        #expect(rotated.height == upright.width)
    }

    @Test(
        "Publishes a real-sized batch within its measured budget",
        .enabled(
            if: ProcessInfo.processInfo
                .environment["SCANDECK_PUBLISH_BENCHMARK"] != nil
        ),
        .timeLimit(.minutes(30))
    )
    func publishBenchmark() async throws {
        // Opt-in, because it writes a gigabyte and takes a minute. Set
        // SCANDECK_PUBLISH_BENCHMARK to a card count — 400 is a real batch
        // (D-10), 186 is the `carlsoboxone` batch every earlier number in the
        // tracker was taken at. Run it in release; in debug the cropper is
        // two orders of magnitude slower and the figure means nothing.
        let cardCount = Int(
            ProcessInfo.processInfo
                .environment["SCANDECK_PUBLISH_BENCHMARK"] ?? "400"
        ) ?? 400
        let harness = try Harness(
            masterWidth: 3_232,
            masterHeight: 4_248,
            media: PixelRect(x: 706, y: 408, width: 1_820, height: 2_424)
        )
        defer { harness.cleanUp() }

        // The serial baseline is a property of the cropper, not the
        // publisher, so it is measured directly rather than by turning the
        // publisher's concurrency down.
        let sample = 8
        let serialStart = ContinuousClock.now
        for index in 0..<sample {
            let destination = harness.root
                .appending(path: "serial-\(index).jpg")
            try CardImageCropper().crop(
                sourceURL: harness.masterURL,
                destinationURL: destination,
                margins: try ScanMargins(all: 3),
                dpi: 600
            )
            try DurableFile.flush(destination)
        }
        let serialPerFile = serialStart.duration(to: .now) / sample

        let start = ContinuousClock.now
        let receipt = try await BatchPublisher().publish(
            harness.request(
                sheetNumbers: (0..<cardCount).map(UInt64.init),
                margins: try ScanMargins(all: 3)
            )
        )
        let elapsed = start.duration(to: .now)

        let fileCount = cardCount * 2
        #expect(receipt.fileNames.count == fileCount)
        let perFile = elapsed / fileCount
        print(
            """
            publish benchmark: \(cardCount) cards / \(fileCount) files
              serial per file  \(serialPerFile)
              serial projected \(serialPerFile * fileCount)
              parallel total   \(elapsed)
              parallel per file \(perFile)
              speed-up         \(
                  Double(serialPerFile.components.attoseconds)
                      / Double(max(perFile.components.attoseconds, 1))
              )x
            """
        )
        // The measured knee is 4-way at 0.071 s per file against 0.222 s
        // serial. Budgeted loosely at twice that, because this runs on
        // whatever else the machine is doing.
        #expect(perFile < .milliseconds(150))
    }

    // MARK: - Harness

    private struct Harness {
        let root: URL
        let destinationRoot: URL
        let masterURL: URL

        /// Defaults to a small master so the behavioural tests stay fast; the
        /// benchmark asks for the real 3232 × 4248 the fi-8170 delivers.
        init(
            masterWidth: Int = 520,
            masterHeight: Int = 700,
            media: PixelRect = PixelRect(x: 120, y: 140, width: 280, height: 400)
        ) throws {
            root = FileManager.default.temporaryDirectory
                .appending(path: UUID().uuidString, directoryHint: .isDirectory)
            destinationRoot = root.appending(
                path: "Destination",
                directoryHint: .isDirectory
            )
            try FileManager.default.createDirectory(
                at: destinationRoot,
                withIntermediateDirectories: true
            )
            masterURL = try Self.writeMaster(
                into: root,
                width: masterWidth,
                height: masterHeight,
                media: media
            )
        }

        func request(
            sheetNumbers: [UInt64],
            margins: ScanMargins
        ) -> PublicationRequest {
            PublicationRequest(
                batchName: try! BatchName("aug01-sale"),
                destinationRoot: destinationRoot,
                cards: sheetNumbers.map { number in
                    PublicationCard(
                        sheetNumber: number,
                        front: PublicationSide(
                            masterURL: masterURL,
                            rotation: .zero
                        ),
                        back: PublicationSide(
                            masterURL: masterURL,
                            rotation: .zero
                        )
                    )
                },
                margins: margins
            )
        }

        func request(sheetNumbers: [UInt64]) -> PublicationRequest {
            PublicationRequest(
                batchName: try! BatchName("aug01-sale"),
                destinationRoot: destinationRoot,
                cards: sheetNumbers.map { number in
                    PublicationCard(
                        sheetNumber: number,
                        front: PublicationSide(
                            masterURL: masterURL,
                            rotation: .zero
                        ),
                        back: PublicationSide(
                            masterURL: masterURL,
                            rotation: .zero
                        )
                    )
                },
                margins: try! ScanMargins(all: 1)
            )
        }

        func pixelSize(of url: URL) throws -> (width: Int, height: Int) {
            let source = try #require(
                CGImageSourceCreateWithURL(url as CFURL, nil)
            )
            let properties = try #require(
                CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                    as? [CFString: Any]
            )
            return (
                properties[kCGImagePropertyPixelWidth] as? Int ?? 0,
                properties[kCGImagePropertyPixelHeight] as? Int ?? 0
            )
        }

        func cleanUp() {
            try? FileManager.default.removeItem(at: root)
        }

        private static func writeMaster(
            into directory: URL,
            width: Int,
            height: Int,
            media: PixelRect
        ) throws -> URL {
            var pixels = [UInt8](repeating: 0, count: width * height * 4)
            for index in stride(from: 3, to: pixels.count, by: 4) {
                pixels[index] = 255
            }
            for y in media.y..<media.maxY {
                for x in media.x..<media.maxX {
                    let offset = (y * width + x) * 4
                    pixels[offset] = 40
                    pixels[offset + 1] = 120
                    pixels[offset + 2] = 220
                }
            }

            let provider = try #require(
                CGDataProvider(data: Data(pixels) as CFData)
            )
            let image = try #require(
                CGImage(
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bitsPerPixel: 32,
                    bytesPerRow: width * 4,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGBitmapInfo(
                        rawValue: CGImageAlphaInfo.premultipliedLast.rawValue
                            | CGBitmapInfo.byteOrder32Big.rawValue
                    ),
                    provider: provider,
                    decode: nil,
                    shouldInterpolate: false,
                    intent: .defaultIntent
                )
            )

            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            let url = directory.appending(
                path: "master.png",
                directoryHint: .notDirectory
            )
            let destination = try #require(
                CGImageDestinationCreateWithURL(
                    url as CFURL,
                    UTType.png.identifier as CFString,
                    1,
                    nil
                )
            )
            CGImageDestinationAddImage(destination, image, nil)
            #expect(CGImageDestinationFinalize(destination))
            return url
        }
    }
}

/// Collects progress from whichever thread publication runs on.
///
/// `publish` is synchronous and the callback is `@Sendable`, so the recorder
/// has to be safe to append to there and safe to read back here.
private final class ProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [PublicationProgress] = []

    func record(_ step: PublicationProgress) {
        lock.withLock { recorded.append(step) }
    }

    var steps: [PublicationProgress] {
        lock.withLock { recorded }
    }
}

/// A one-way flag, set from inside the progress callback.
private final class FolderWatch: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    func trip() {
        lock.withLock { value = true }
    }

    var tripped: Bool {
        lock.withLock { value }
    }
}
