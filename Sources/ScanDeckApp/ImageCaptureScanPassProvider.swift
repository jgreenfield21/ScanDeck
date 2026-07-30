import Foundation
import ScanDeckCore
import ScanDeckScanner

/// Supplies pages for one pass from a real fi-series scanner.
///
/// `ScannerPassEvent` and `ScanPassProgress` were shaped alike deliberately, so
/// this is a translation rather than a second pairing implementation. The
/// transport reports validated pages in delivery order and says nothing about
/// which card they belong to; duplex pairing, the exact-two-page rule for Retry
/// and Replace, and every completion gate stay in `BatchSession`, which is
/// where they are tested.
@MainActor
final class ImageCaptureScanPassProvider: ScanPassProviding {
    private let client: any ScannerPassClient
    private let preferredScannerName: @MainActor () -> String?
    private let silenceTimeout: TimeInterval

    /// - Parameters:
    ///   - preferredScannerName: Restricts the pass to a device whose name
    ///     contains this text, read at the moment each pass starts so a change
    ///     in Settings takes effect on the next press rather than the next
    ///     launch. `nil` — the default, and what the app supplies unless the
    ///     operator pins one — takes the single attached supported scanner.
    ///     That stays the default deliberately: hard-filtering on a name nobody
    ///     chose would fail for every supported device that is not that one,
    ///     and a device that cannot do duplex, 600 dpi, and the PFU cropping
    ///     features fails loudly while being configured rather than scanning
    ///     something subtly wrong.
    ///   - silenceTimeout: How long the scanner may deliver nothing before the
    ///     pass is abandoned. Each delivered page restarts it, so this bounds a
    ///     stall and never the length of a feed.
    init(
        client: any ScannerPassClient = ImageCaptureScannerPassClient(),
        preferredScannerName: @escaping @MainActor () -> String? = { nil },
        silenceTimeout: TimeInterval = 180
    ) {
        self.client = client
        self.preferredScannerName = preferredScannerName
        self.silenceTimeout = silenceTimeout
    }

    func scan(
        _ request: ScanPassRequest,
        into directory: URL
    ) -> AsyncStream<ScanPassProgress> {
        let captureResolution = ImageCaptureScannerProbe.scanResolutionDPI
        guard request.profile.resolutionDPI == captureResolution else {
            // The profile's resolution sizes the margins and is stamped into
            // the published JPEG. Scanning at a resolution the profile does not
            // expect would measure a 3 mm border in the wrong unit and label
            // the result with a density its pixels do not have — wrong output
            // that still looks plausible. Refusing costs the operator a pass;
            // proceeding costs them a batch.
            return Self.refused(
                "This scanner captures at \(captureResolution) dpi, but the "
                    + "“\(request.profile.name)” profile asks for "
                    + "\(request.profile.resolutionDPI) dpi. Nothing was "
                    + "scanned."
            )
        }

        let events = client.scan(
            ScannerPassRequest(
                outputDirectory: directory,
                deviceNameContains: preferredScannerName(),
                timeout: silenceTimeout,
                croppingMode: .overscan
            )
        )

        return AsyncStream { continuation in
            continuation.yield(.status("Preparing the scanner…"))
            let task = Task {
                await Self.forward(events, to: continuation)
            }
            continuation.onTermination = { @Sendable [weak self] termination in
                task.cancel()
                guard case .cancelled = termination else {
                    return
                }
                // The consumer walked away mid-pass. Stopping the transport is
                // what puts the scanner back down; the pages it already
                // acknowledged stay on disk either way.
                Task { @MainActor [weak self] in
                    self?.client.cancel()
                }
            }
        }
    }

    // MARK: - Translation

    private static func forward(
        _ events: AsyncStream<ScannerPassEvent>,
        to continuation: AsyncStream<ScanPassProgress>.Continuation
    ) async {
        var deliveredPageURLs: [URL] = []

        for await event in events {
            switch event {
            case .status:
                // The transport's status stream is a diagnostic log written for
                // the CLI: device dumps, vendor feature tables, and the path
                // and pixel dimensions of each validated file. None of that is
                // shipped copy, and the status line shows only the most recent
                // message, so forwarding it verbatim would leave the operator
                // reading file paths while their cards feed. The driver's own
                // wording still reaches them verbatim in any failure message,
                // which is what SPEC section 7 actually requires. TICKET-009
                // decides which live driver notices — a cover left open, a
                // multifeed — deserve to reach the operator as well.
                break

            case let .notice(notice):
                // A typed condition, not log chatter: the transport says the
                // pass has stalled on something the operator can clear, and
                // says when it clears. Translated case for case so the app
                // never has to read the driver's wording to know what happened.
                continuation.yield(.notice(progressNotice(for: notice)))

            case let .page(page):
                deliveredPageURLs.append(page.url)
                continuation.yield(.page(page.url))
                continuation.yield(
                    .status(progressStatus(sideCount: deliveredPageURLs.count))
                )

            case let .finished(outcome):
                // Invariant #1 at the seam. The terminal outcome names every
                // page the transport validated, including on failure. Anything
                // it names that was never forwarded is an acknowledged page
                // about to be dropped, so it is delivered before the verdict
                // that would close the pass. The two lists agree today; this
                // is what makes their agreeing not something to rely on.
                for url in outcome.pageURLs
                where !deliveredPageURLs.contains(url) {
                    deliveredPageURLs.append(url)
                    continuation.yield(.page(url))
                }

                continuation.yield(.finished(completion(for: outcome)))
                continuation.finish()
                return
            }
        }

        // A transport that ends without a verdict would strand the batch in
        // `.scanning`, where the operator can neither retry, complete, nor
        // cancel. Silence is therefore reported as a failure: the reducer keeps
        // every captured page on a failed pass, so this loses nothing.
        if !Task.isCancelled {
            continuation.yield(
                .finished(
                    .failed(
                        message: "The scanner stopped reporting before the "
                            + "pass finished. Pages already captured are safe."
                    )
                )
            )
        }
        continuation.finish()
    }

    /// Reassurance during a long feed, which is the one job the status line has
    /// while the review grid fills in behind it.
    ///
    /// Sides rather than cards: this layer sees pages in delivery order and has
    /// no view of pairing, and claiming a card count it cannot know would be
    /// wrong the moment a pass ends on an orphan side.
    private static func progressStatus(sideCount: Int) -> String {
        "Feeding cards… \(sideCount) side\(sideCount == 1 ? "" : "s") captured."
    }

    private static func progressNotice(
        for notice: ScannerPassNotice
    ) -> ScanPassNotice {
        switch notice {
        case let .scannerInUseElsewhere(name):
            .scannerInUseElsewhere(name: name)
        case .scannerAvailableAgain:
            .scannerAvailableAgain
        }
    }

    private static func completion(
        for outcome: ScannerPassOutcome
    ) -> ScanPassCompletion {
        switch outcome {
        case .succeeded:
            .succeeded
        case let .failed(message, reason, _):
            .failed(message: message, reason: passFailureReason(for: reason))
        }
    }

    private static func passFailureReason(
        for reason: ScannerPassFailureReason
    ) -> ScanPassFailureReason {
        switch reason {
        case .feederEmpty:
            .feederEmpty
        case .scannerFault:
            .scannerFault
        }
    }

    private static func refused(
        _ message: String
    ) -> AsyncStream<ScanPassProgress> {
        AsyncStream { continuation in
            continuation.yield(.finished(.failed(message: message)))
            continuation.finish()
        }
    }
}
