import Foundation
import ScanDeckCore

/// One feeder pass requested by the batch workflow.
///
/// A pass may return any positive number of pages. Duplex pairing and the
/// exact-two-page requirement for Retry/Replace belong to the batch reducer,
/// not this transport request.
public struct ScannerPassRequest: Equatable, Sendable {
    public let outputDirectory: URL
    public let deviceNameContains: String?
    public let timeout: TimeInterval
    public let croppingMode: PFUCroppingMode

    public init(
        outputDirectory: URL,
        deviceNameContains: String? = nil,
        timeout: TimeInterval = 180,
        croppingMode: PFUCroppingMode = .overscan
    ) {
        self.outputDirectory = outputDirectory
        self.deviceNameContains = deviceNameContains
        self.timeout = timeout
        self.croppingMode = croppingMode
    }
}

/// A validated raw page in scanner delivery order.
public struct ScannerPassPage: Equatable, Sendable {
    public let url: URL

    /// Zero-based position within this feeder pass.
    public let index: Int

    public init(url: URL, index: Int) {
        self.url = url
        self.index = index
    }
}

/// The terminal result for one feeder pass.
///
/// Failure retains every raw page URL that was validated and emitted before
/// the scanner reported the failure. Callers can therefore reduce a partial
/// append pass without losing acknowledged pages.
public enum ScannerPassOutcome: Equatable, Sendable {
    case succeeded(deviceName: String, pageURLs: [URL])
    case failed(
        message: String,
        reason: ScannerPassFailureReason,
        pageURLs: [URL]
    )

    /// The failure a transport-level refusal means: nothing about the feeder
    /// is known, because the pass never reached it.
    public static func failed(
        message: String,
        pageURLs: [URL]
    ) -> ScannerPassOutcome {
        .failed(message: message, reason: .scannerFault, pageURLs: pageURLs)
    }

    public var pageURLs: [URL] {
        switch self {
        case let .succeeded(_, pageURLs), let .failed(_, _, pageURLs):
            pageURLs
        }
    }
}

/// A transport condition the operator has to act on, as distinct from the
/// diagnostic log the status stream carries.
///
/// Typed rather than another status string on purpose: the app decides what to
/// show from the case, never by matching on the driver's wording. The wording
/// belongs to the driver and changes with it; the condition does not.
public enum ScannerPassNotice: Equatable, Sendable {
    /// `-9925`/`-9926` — another application holds this single-client scanner.
    ///
    /// The pass is not over. The probe waits and reopens the session the moment
    /// Image Capture reports the device released, so what the operator needs is
    /// the reason it has stalled and the fact that it will resume itself.
    case scannerInUseElsewhere(name: String)

    /// The scanner was released and the pass is going ahead.
    case scannerAvailableAgain
}

/// Ordered events from one feeder pass.
public enum ScannerPassEvent: Equatable, Sendable {
    case status(String)
    case notice(ScannerPassNotice)
    case page(ScannerPassPage)
    case finished(ScannerPassOutcome)
}

/// Reusable scanner transport. Image Capture objects remain main-actor-bound;
/// only the Sendable event values should cross into a workflow actor.
@MainActor
public protocol ScannerPassClient: AnyObject {
    var isScanning: Bool { get }

    func scan(_ request: ScannerPassRequest) -> AsyncStream<ScannerPassEvent>
    func cancel()
}

/// Production feeder-pass API backed by the proven Image Capture probe.
///
/// The client supports sequential passes. A concurrent request receives an
/// immediate failed `finished` event and does not disturb the active pass.
@MainActor
public final class ImageCaptureScannerPassClient: ScannerPassClient {
    private typealias Continuation =
        AsyncStream<ScannerPassEvent>.Continuation

    private var activeProbe: ImageCaptureScannerProbe?
    private var activePassID: UUID?
    private var activeContinuation: Continuation?
    private var activePageURLs: [URL] = []

    public init() {}

    public var isScanning: Bool {
        activeProbe != nil
    }

    public func scan(
        _ request: ScannerPassRequest
    ) -> AsyncStream<ScannerPassEvent> {
        guard activeProbe == nil else {
            return Self.finishedStream(
                .failed(
                    message: "A scanner pass is already in progress.",
                    pageURLs: []
                )
            )
        }
        guard request.outputDirectory.isFileURL else {
            return Self.finishedStream(
                .failed(
                    message: "The scan output directory must be a file URL.",
                    pageURLs: []
                )
            )
        }
        guard request.timeout.isFinite, request.timeout > 0 else {
            return Self.finishedStream(
                .failed(
                    message: "The scanner timeout must be positive.",
                    pageURLs: []
                )
            )
        }

        let pair = AsyncStream<ScannerPassEvent>.makeStream(
            bufferingPolicy: .unbounded
        )
        let passID = UUID()

        activePassID = passID
        activeContinuation = pair.continuation
        activePageURLs = []

        pair.continuation.onTermination = {
            @Sendable [weak self] termination in
            Task { @MainActor [weak self] in
                self?.handleConsumerTermination(
                    termination,
                    passID: passID
                )
            }
        }

        let configuration = ScannerProbeConfiguration(
            operation: .scan,
            deviceNameContains: request.deviceNameContains,
            outputDirectory: request.outputDirectory,
            timeout: request.timeout,
            pageCountRequirement: .oneOrMore,
            croppingMode: request.croppingMode
        )
        let probe = ImageCaptureScannerProbe(
            configuration: configuration,
            eventHandler: { [weak self] message in
                self?.receiveStatus(message, passID: passID)
            },
            noticeHandler: { [weak self] notice in
                self?.receiveNotice(notice, passID: passID)
            },
            pageHandler: { [weak self] url, index in
                self?.receivePage(url, index: index, passID: passID)
            },
            completion: { [weak self] result in
                self?.finish(result, passID: passID)
            }
        )

        activeProbe = probe
        probe.start()
        return pair.stream
    }

    public func cancel() {
        activeProbe?.cancel()
    }

    private func receiveStatus(_ message: String, passID: UUID) {
        guard activePassID == passID else {
            return
        }
        activeContinuation?.yield(.status(message))
    }

    private func receiveNotice(_ notice: ScannerPassNotice, passID: UUID) {
        guard activePassID == passID else {
            return
        }
        activeContinuation?.yield(.notice(notice))
    }

    private func receivePage(_ url: URL, index: Int, passID: UUID) {
        guard activePassID == passID else {
            return
        }

        // The probe guarantees a dense, ordered zero-based sequence.
        guard index == activePageURLs.count else {
            activeProbe?.cancel()
            return
        }

        activePageURLs.append(url)
        activeContinuation?.yield(
            .page(ScannerPassPage(url: url, index: index))
        )
    }

    private func finish(_ result: ScannerProbeResult, passID: UUID) {
        guard activePassID == passID else {
            return
        }

        let retainedPageURLs = activePageURLs
        let continuation = activeContinuation
        clearActivePass()

        let outcome: ScannerPassOutcome
        switch result {
        case let .scanned(deviceName, pageURLs):
            outcome = .succeeded(
                deviceName: deviceName,
                pageURLs: pageURLs
            )
        case let .failed(message, reason):
            outcome = .failed(
                message: message,
                reason: reason,
                pageURLs: retainedPageURLs
            )
        case .listed:
            outcome = .failed(
                message: "The scanner returned a device-list result "
                    + "during a scan pass.",
                pageURLs: retainedPageURLs
            )
        case .inspected:
            outcome = .failed(
                message: "The scanner returned an inspection result "
                    + "during a scan pass.",
                pageURLs: retainedPageURLs
            )
        }

        continuation?.yield(.finished(outcome))
        continuation?.finish()
    }

    private func handleConsumerTermination(
        _ termination: Continuation.Termination,
        passID: UUID
    ) {
        guard activePassID == passID else {
            return
        }

        switch termination {
        case .cancelled:
            activeProbe?.cancel()
        case .finished:
            break
        @unknown default:
            activeProbe?.cancel()
        }
    }

    private func clearActivePass() {
        activeProbe = nil
        activePassID = nil
        activeContinuation = nil
        activePageURLs = []
    }

    private static func finishedStream(
        _ outcome: ScannerPassOutcome
    ) -> AsyncStream<ScannerPassEvent> {
        let pair = AsyncStream<ScannerPassEvent>.makeStream(
            bufferingPolicy: .unbounded
        )
        pair.continuation.yield(.finished(outcome))
        pair.continuation.finish()
        return pair.stream
    }
}
