import Foundation
import ScanDeckCore
import ScanDeckScanner
import Testing
@testable import ScanDeckApp

/// Covers the one seam between the batch workflow and real hardware.
///
/// `ScannerPassClient` is a protocol, so the translation can be driven by a
/// scripted transport and every rule below is checked without an fi-8170. What
/// cannot be checked here is whether the scanner behaves as scripted — that is
/// TICKET-008's job, and no test in this file should be read as evidence of it.
@MainActor
@Suite("Image Capture scan pass translation")
struct ImageCaptureScanPassProviderTests {
    @Test("Pages reach the workflow in delivery order")
    func translatesAPassInOrder() async throws {
        let client = ScriptedScannerPassClient()
        let first = pageURL("one")
        let second = pageURL("two")
        client.events = [
            .page(ScannerPassPage(url: first, index: 0)),
            .page(ScannerPassPage(url: second, index: 1)),
            .finished(
                .succeeded(deviceName: "fi-8170", pageURLs: [first, second])
            ),
        ]

        let progress = await collect(from: client)

        #expect(progress.pageURLs == [first, second])
        #expect(progress.completion == .succeeded)
    }

    @Test("The status line carries progress, not the driver's diagnostics")
    func statusLineIsOperatorFacing() async throws {
        let client = ScriptedScannerPassClient()
        let page = pageURL("one")
        client.events = [
            .status("Vendor enumeration features:"),
            .status("  cropping: [0=None (with black background), 4=Overscan]"),
            .page(ScannerPassPage(url: page, index: 0)),
            .status("Validated page file: master-1.jpg (905×1205, 600.0 dpi)."),
            .finished(.succeeded(deviceName: "fi-8170", pageURLs: [page])),
        ]

        let progress = await collect(from: client)

        // Copy is part of the product. The transport's log is written for the
        // CLI, and the status line shows only its most recent entry, so
        // forwarding it would leave the operator reading file paths mid-feed.
        #expect(
            progress.statuses == [
                "Preparing the scanner…",
                "Feeding cards… 1 side captured.",
            ]
        )
    }

    @Test("A stalled single-client scanner crosses the seam as a typed state")
    func busyNoticeSurvivesTranslation() async throws {
        let client = ScriptedScannerPassClient()
        let page = pageURL("one")
        client.events = [
            .notice(.scannerInUseElsewhere(name: "fi-8170")),
            .notice(.scannerAvailableAgain),
            .page(ScannerPassPage(url: page, index: 0)),
            .finished(.succeeded(deviceName: "fi-8170", pageURLs: [page])),
        ]

        let progress = await collect(from: client)

        // `-9925/-9926` is a state the operator can clear, not a failure, and
        // not a line in the diagnostic log that gets dropped with the rest of
        // it. Typed so the app never reads the driver's wording to know what
        // happened.
        #expect(
            progress.notices == [
                .scannerInUseElsewhere(name: "fi-8170"),
                .scannerAvailableAgain,
            ]
        )
        #expect(progress.completion == .succeeded)
        #expect(progress.pageURLs == [page])
    }

    @Test("A driver failure reaches the operator verbatim")
    func failureMessageSurvivesTranslation() async throws {
        let client = ScriptedScannerPassClient()
        client.events = [
            .finished(
                .failed(
                    message: "Scan failed after 3 page(s): Paper jam. "
                        + "Scanner reported: ADF cover open.",
                    pageURLs: []
                )
            ),
        ]

        let progress = await collect(from: client)

        // SPEC section 7: driver errors surface as the driver worded them.
        #expect(
            progress.completion
                == .failed(
                    message: "Scan failed after 3 page(s): Paper jam. "
                        + "Scanner reported: ADF cover open."
                )
        )
    }

    @Test("A page named only by the outcome is delivered before the verdict")
    func outcomeOnlyPageIsNotDropped() async throws {
        let client = ScriptedScannerPassClient()
        let delivered = pageURL("delivered")
        let onlyInOutcome = pageURL("only-in-outcome")
        client.events = [
            .page(ScannerPassPage(url: delivered, index: 0)),
            .finished(
                .succeeded(
                    deviceName: "fi-8170",
                    pageURLs: [delivered, onlyInOutcome]
                )
            ),
        ]

        let progress = await collect(from: client)

        // Invariant #1: no acknowledged page may be lost at the seam, and a
        // page announced only by the terminal outcome is still acknowledged.
        #expect(progress.pageURLs == [delivered, onlyInOutcome])
        #expect(progress.events.last == .finishedMarker)
    }

    @Test("Reconciling the outcome never delivers a page twice")
    func reconciliationDoesNotDuplicatePages() async throws {
        let client = ScriptedScannerPassClient()
        let first = pageURL("one")
        let second = pageURL("two")
        client.events = [
            .page(ScannerPassPage(url: first, index: 0)),
            .page(ScannerPassPage(url: second, index: 1)),
            .finished(
                .succeeded(deviceName: "fi-8170", pageURLs: [first, second])
            ),
        ]

        let progress = await collect(from: client)

        // A duplicate would become a phantom card side in the reducer.
        #expect(progress.pageURLs == [first, second])
    }

    @Test("A failed pass still hands over the pages it captured")
    func failedPassRetainsItsPages() async throws {
        let client = ScriptedScannerPassClient()
        let captured = pageURL("captured")
        client.events = [
            .finished(
                .failed(message: "Paper jammed in the ADF.", pageURLs: [captured])
            ),
        ]

        let progress = await collect(from: client)

        #expect(progress.pageURLs == [captured])
        #expect(
            progress.completion == .failed(
                message: "Paper jammed in the ADF.",
                reason: .scannerFault
            )
        )
    }

    @Test("An empty feeder crosses the seam as its own reason, not a fault")
    func feederEmptyIsTranslatedRatherThanFlattened() async throws {
        let client = ScriptedScannerPassClient()
        client.events = [
            .finished(
                .failed(
                    message: "Expected at least one scanned page, but received "
                        + "none. Scanner reported: No documents in the ADF "
                        + "paper chute. (Error Code: 0x03800320)",
                    reason: .feederEmpty,
                    pageURLs: []
                )
            ),
        ]

        let progress = await collect(from: client)

        // The condition survives the translation as a case. Without it the app
        // would have to read the driver's sentence to tell the normal end of an
        // automatic run from a jam — which is exactly what the typed enums on
        // both sides of this seam exist to prevent.
        guard case let .failed(message, reason) = progress.completion else {
            Issue.record("The pass ended without a verdict.")
            return
        }
        #expect(reason == .feederEmpty)
        // The driver's wording still travels intact; what changed is that
        // nobody downstream has to parse it.
        #expect(message.contains("0x03800320"))
    }

    @Test("A jam stays a fault across the seam")
    func jamKeepsItsFaultReason() async throws {
        let client = ScriptedScannerPassClient()
        client.events = [
            .finished(
                .failed(
                    message: "Paper jammed in the ADF. (Error Code: 0x03800131)",
                    reason: .scannerFault,
                    pageURLs: []
                )
            ),
        ]

        let progress = await collect(from: client)

        guard case let .failed(_, reason) = progress.completion else {
            Issue.record("The pass ended without a verdict.")
            return
        }
        #expect(reason == .scannerFault)
    }

    @Test("A transport that ends without a verdict fails instead of hanging")
    func silentTransportBecomesAFailure() async throws {
        let client = ScriptedScannerPassClient()
        client.events = [.page(ScannerPassPage(url: pageURL("one"), index: 0))]

        let progress = await collect(from: client)

        // Without this the batch would sit in `.scanning` forever, unable to
        // retry, complete, or cancel.
        guard case let .failed(message, _) = progress.completion else {
            Issue.record("The pass ended without a verdict.")
            return
        }
        #expect(message.contains("safe"))
        #expect(progress.pageURLs.count == 1)
    }

    @Test("The transport is asked for Overscan into the pass directory")
    func requestsOverscanIntoTheGivenDirectory() async throws {
        let client = ScriptedScannerPassClient()
        client.events = [
            .finished(.succeeded(deviceName: "fi-8170", pageURLs: [])),
        ]
        let directory = URL(
            fileURLWithPath: "/tmp/scandeck-tests/pass",
            isDirectory: true
        )

        _ = await collect(from: client, into: directory)

        let request = try #require(client.requests.first)
        // Overscan is what produces real background beyond the media edge;
        // without it there is no border to crop and invariant #2 is unmeetable.
        #expect(request.croppingMode == .overscan)
        #expect(request.outputDirectory == directory)
        #expect(request.timeout == 180)
    }

    @Test("A profile the scanner cannot honour is refused before scanning")
    func mismatchedResolutionIsRefused() async throws {
        let client = ScriptedScannerPassClient()
        let profile = ScanProfileViewData(
            id: UUID(),
            name: "Cards 300",
            detail: "",
            symbolName: "rectangle",
            resolutionDPI: 300,
            defaultMarginMillimeters: 3,
            captureRotation: .zero,
            deliveryOrder: .frontFirst
        )

        let progress = await collect(from: client, profile: profile)

        // Scanning at 600 while the profile says 300 would size the 3 mm border
        // in the wrong unit and stamp the JPEG with a density it does not have.
        #expect(client.requests.isEmpty)
        guard case let .failed(message, _) = progress.completion else {
            Issue.record("A mismatched profile was allowed to scan.")
            return
        }
        #expect(message.contains("600"))
        #expect(message.contains("300"))
        #expect(message.contains("Nothing was scanned"))
    }

    @Test("Walking away mid-pass stops the scanner")
    func consumerCancellationStopsTheTransport() async throws {
        let client = ScriptedScannerPassClient()
        client.events = [.status("Feeding cards…")]
        client.staysOpen = true
        let provider = ImageCaptureScanPassProvider(client: client)

        let task = Task { @MainActor in
            for await _ in provider.scan(request(), into: temporaryDirectory()) {}
        }
        try await waitUntil { !client.requests.isEmpty }
        task.cancel()

        try await waitUntil { client.cancelCount > 0 }
        #expect(client.cancelCount > 0)
    }

    // MARK: - Harness

    private struct RecordedProgress {
        enum Marker: Equatable {
            case status(String)
            case notice(ScanPassNotice)
            case page(URL)
            case finishedMarker
        }

        var events: [Marker] = []
        var completion: ScanPassCompletion?

        var statuses: [String] {
            events.compactMap {
                if case let .status(message) = $0 { message } else { nil }
            }
        }

        var notices: [ScanPassNotice] {
            events.compactMap {
                if case let .notice(notice) = $0 { notice } else { nil }
            }
        }

        var pageURLs: [URL] {
            events.compactMap {
                if case let .page(url) = $0 { url } else { nil }
            }
        }
    }

    private func collect(
        from client: ScriptedScannerPassClient,
        into directory: URL? = nil,
        profile: ScanProfileViewData = .cards600FullBorder
    ) async -> RecordedProgress {
        let provider = ImageCaptureScanPassProvider(client: client)
        var recorded = RecordedProgress()

        for await progress in provider.scan(
            request(profile: profile),
            into: directory ?? temporaryDirectory()
        ) {
            switch progress {
            case let .status(message):
                recorded.events.append(.status(message))
            case let .notice(notice):
                recorded.events.append(.notice(notice))
            case let .page(url):
                recorded.events.append(.page(url))
            case let .finished(completion):
                recorded.events.append(.finishedMarker)
                recorded.completion = completion
            }
        }
        return recorded
    }

    private func request(
        profile: ScanProfileViewData = .cards600FullBorder
    ) -> ScanPassRequest {
        ScanPassRequest(
            batchID: BatchID(rawValue: UUID()),
            passID: ScanPassID(rawValue: UUID()),
            kind: .append,
            profile: profile,
            margins: try! ScanMargins(all: 3)
        )
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    }

    private func pageURL(_ name: String) -> URL {
        URL(
            fileURLWithPath: "/tmp/scandeck-tests/\(name).jpg",
            isDirectory: false
        )
    }

    private func waitUntil(
        _ condition: @MainActor () -> Bool,
        within timeout: Duration = .seconds(30),
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition() {
                return
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record(
            "Condition was never satisfied.",
            sourceLocation: sourceLocation
        )
    }
}

/// A transport whose whole pass is written down in advance.
@MainActor
private final class ScriptedScannerPassClient: ScannerPassClient {
    var isScanning = false
    var events: [ScannerPassEvent] = []

    /// Leaves the stream open after the scripted events so a consumer walking
    /// away can be observed reaching the scanner.
    var staysOpen = false

    private(set) var requests: [ScannerPassRequest] = []
    private(set) var cancelCount = 0

    private var openContinuation: AsyncStream<ScannerPassEvent>.Continuation?

    func scan(
        _ request: ScannerPassRequest
    ) -> AsyncStream<ScannerPassEvent> {
        requests.append(request)

        let pair = AsyncStream<ScannerPassEvent>.makeStream(
            bufferingPolicy: .unbounded
        )
        for event in events {
            pair.continuation.yield(event)
        }

        if staysOpen {
            openContinuation = pair.continuation
        } else {
            pair.continuation.finish()
        }
        return pair.stream
    }

    func cancel() {
        cancelCount += 1
        openContinuation?.finish()
        openContinuation = nil
    }
}
