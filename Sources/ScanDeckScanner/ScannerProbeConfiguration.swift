import Foundation
import ScanDeckCore

public enum ScannerProbeOperation: Equatable, Sendable {
    case list
    case inspect
    case scan
}

/// Page-count validation retained by the M0 probe.
///
/// Production batch scans use ``oneOrMore`` so the batch reducer, rather than
/// the transport, owns duplex pairing and targeted Retry/Replace policy.
public enum ScannerProbePageCountRequirement: Equatable, Sendable {
    case exactlyTwo
    case oneOrMore
}

/// A scan window asked for in master pixels at the probe's capture resolution.
///
/// Pixels rather than millimetres because that is the unit every number in this
/// investigation is already measured in — the delivered master, the detected
/// media, the 71 px margin — and converting through millimetres twice would put
/// rounding between the request and the measurement it is compared against.
public struct ScanWindowRequest: Equatable, Sendable {
    public let widthPixels: Int
    public let heightPixels: Int

    public init(widthPixels: Int, heightPixels: Int) {
        self.widthPixels = widthPixels
        self.heightPixels = heightPixels
    }
}

public struct ScannerProbeConfiguration: Sendable {
    public var operation: ScannerProbeOperation
    public var deviceNameContains: String?
    public var outputDirectory: URL?
    public var timeout: TimeInterval
    public var pageCountRequirement: ScannerProbePageCountRequirement
    public var croppingMode: PFUCroppingMode

    /// When set, the probe asks the driver for this window instead of leaving
    /// the document type to decide, and reports what came back. Investigation
    /// only (TICKET-025): nothing in the app sets it.
    public var scanWindow: ScanWindowRequest?

    public init(
        operation: ScannerProbeOperation = .list,
        deviceNameContains: String? = nil,
        outputDirectory: URL? = nil,
        timeout: TimeInterval = 30,
        pageCountRequirement: ScannerProbePageCountRequirement = .exactlyTwo,
        croppingMode: PFUCroppingMode = .fullFrameBlack,
        scanWindow: ScanWindowRequest? = nil
    ) {
        self.operation = operation
        self.deviceNameContains = deviceNameContains
        self.outputDirectory = outputDirectory
        self.timeout = timeout
        self.pageCountRequirement = pageCountRequirement
        self.croppingMode = croppingMode
        self.scanWindow = scanWindow
    }
}

/// Why a pass ended without the pages it was asked for.
///
/// Typed for the same reason `ScannerPassNotice` is: the driver owns its
/// wording and changes it with the localisation, the condition does not, and
/// `ScanDeckApp` must never read a driver string to learn what happened.
///
/// The distinction earns its keep because an empty chute is not a fault. It is
/// the *normal* end of an automatic run (TICKET-029): the operator stopped
/// feeding and the next pass found nothing to take. Reporting that in red as
/// "Scan could not finish" is the wrong copy for the commonest way a batch
/// ends, and it sits beside a genuine jam wearing the same face.
public enum ScannerPassFailureReason: Equatable, Sendable {
    /// The ADF paper chute was empty. Nothing was scanned and nothing is wrong.
    case feederEmpty

    /// Everything else, including a jam, a disconnect, and a refused setting.
    /// The driver's own wording is what describes it.
    case scannerFault
}

public enum ScannerProbeResult: Sendable {
    case listed(scannerCount: Int)
    case inspected(deviceName: String)
    case scanned(deviceName: String, pageURLs: [URL])
    case failed(message: String, reason: ScannerPassFailureReason)

    /// The failure every site means unless it has learned otherwise.
    ///
    /// A shorthand rather than a default, because a default on the case would
    /// let a new failure path acquire a reason nobody chose. Only the two
    /// places that hold the driver's error say anything else.
    public static func failed(message: String) -> ScannerProbeResult {
        .failed(message: message, reason: .scannerFault)
    }

    public var exitCode: Int32 {
        switch self {
        case .listed, .inspected, .scanned:
            0
        case .failed:
            1
        }
    }
}
