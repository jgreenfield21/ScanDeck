import Foundation
@preconcurrency import ImageCaptureCore
import ImageIO
import ScanDeckCore
import UniformTypeIdentifiers

@MainActor
public final class ImageCaptureScannerProbe: NSObject,
    @MainActor ICDeviceBrowserDelegate,
    @MainActor ICScannerDeviceDelegate
{
    public typealias EventHandler = @MainActor (String) -> Void
    public typealias NoticeHandler = @MainActor (ScannerPassNotice) -> Void
    public typealias PageHandler = @MainActor (URL, Int) -> Void
    public typealias Completion = @MainActor (ScannerProbeResult) -> Void

    /// The one capture resolution ScanDeck scans at.
    ///
    /// The feeder is configured to this value and every delivered page is
    /// validated against it. A caller that assumes a different resolution
    /// would size its margins in the wrong unit and stamp the published JPEG
    /// with a resolution the pixels do not support, so callers must refuse a
    /// profile that disagrees rather than scan and mislabel the result.
    public nonisolated static let scanResolutionDPI = 600

    private let configuration: ScannerProbeConfiguration
    private let eventHandler: EventHandler
    private let noticeHandler: NoticeHandler
    private let pageHandler: PageHandler
    private let completion: Completion

    private enum Phase: Equatable {
        case idle
        case discovering
        case openingSession
        case waitingForAvailability
        case waitingForReady
        case waitingForFeeder
        case selectingFeeder
        case configuring
        case reconnecting
        case scanning
        case cancellingScan
        case stoppingBeforeSession
        case closing
        case finished
    }

    /// How long a removed selected scanner may take to re-join the bus before
    /// the pass is called dead, and how many bounces one pass will tolerate.
    ///
    /// The fi-8170 re-enumerates over USB when it wakes from sleep — and
    /// opening a session is exactly what wakes it — so before any paper has
    /// moved, a removal is routinely a bounce rather than a disconnect.
    /// Re-enumeration measures a second or two; eight leaves slack without
    /// stalling a genuinely unplugged scanner past operator patience.
    private static let reconnectWindow: TimeInterval = 8
    private static let maximumReconnectAttempts = 2

    private let browser = ICDeviceBrowser()
    private var timeoutTimer: Timer?
    private var enumerationSettleTimer: Timer?
    private var functionalUnitSettleTimer: Timer?
    private var cancellationFallbackTimer: Timer?
    private var disconnectGraceTimer: Timer?
    private var closeFallbackTimer: Timer?
    private var reconnectTimer: Timer?
    private var reconnectAttempts = 0
    private var lostScannerName: String?
    private var discoveredScanners: [ICScannerDevice] = []
    private var selectedScanner: ICScannerDevice?
    private var phase = Phase.idle
    private var sessionIsOpen = false
    private var deviceIsReady = false
    private var functionalUnitSettleAttempts = 0
    private var scannedPageURLs: [URL] = []
    private var hasAnnouncedScannerInUse = false

    /// The driver's own last error, kept whole rather than flattened.
    ///
    /// It used to be stored as its `localizedDescription` alone, which threw
    /// away the only thing that tells an empty feeder apart from a jam. Both
    /// arrive here as an `NSError` and both end the pass with zero pages; only
    /// the error says which happened.
    private var mostRecentScannerError: NSError?
    private var terminalResult: ScannerProbeResult?

    public init(
        configuration: ScannerProbeConfiguration,
        eventHandler: @escaping EventHandler = { _ in },
        noticeHandler: @escaping NoticeHandler = { _ in },
        pageHandler: @escaping PageHandler = { _, _ in },
        completion: @escaping Completion
    ) {
        self.configuration = configuration
        self.eventHandler = eventHandler
        self.noticeHandler = noticeHandler
        self.pageHandler = pageHandler
        self.completion = completion
        super.init()
    }

    public func start() {
        guard phase == .idle else {
            return
        }

        phase = .discovering
        browser.delegate = self

        let rawMask = ICDeviceTypeMask.scanner.rawValue
            | ICDeviceLocationTypeMask.local.rawValue
        browser.browsedDeviceTypeMask = ICDeviceTypeMask(rawValue: rawMask)!

        timeoutTimer = Timer.scheduledTimer(
            timeInterval: configuration.timeout,
            target: self,
            selector: #selector(didReachTimeout),
            userInfo: nil,
            repeats: false
        )

        emit("Looking for local Image Capture scanners…")
        browser.start()
    }

    public func cancel() {
        requestShutdown(.failed(message: "Probe cancelled."))
    }

    public func deviceBrowser(
        _ browser: ICDeviceBrowser,
        didAdd device: ICDevice,
        moreComing: Bool
    ) {
        guard let scanner = device as? ICScannerDevice else {
            return
        }

        if phase == .reconnecting {
            guard isSupportedScanner(scanner),
                  deviceMatchesSelection(scanner),
                  scanner.name == nil
                      || lostScannerName == nil
                      || scanner.name == lostScannerName
            else {
                return
            }

            reconnectTimer?.invalidate()
            reconnectTimer = nil
            if !discoveredScanners.contains(where: { $0 === scanner }) {
                discoveredScanners.append(scanner)
            }
            emit("Scanner re-enumerated; reopening the session…")
            rearmTimeout()
            selectedScanner = scanner
            scanner.delegate = self
            phase = .openingSession
            scanner.requestOpenSession()
            return
        }

        guard phase == .discovering else {
            return
        }

        if !discoveredScanners.contains(where: { $0 === scanner }) {
            discoveredScanners.append(scanner)
        }
        emit(scannerDescription(scanner))

        enumerationSettleTimer?.invalidate()
        enumerationSettleTimer = nil

        if !moreComing {
            enumerationSettleTimer = Timer.scheduledTimer(
                timeInterval: 0.25,
                target: self,
                selector: #selector(completeEnumerationAfterGracePeriod),
                userInfo: nil,
                repeats: false
            )
        }
    }

    public func deviceBrowser(
        _ browser: ICDeviceBrowser,
        didRemove device: ICDevice,
        moreGoing: Bool
    ) {
        guard let scanner = device as? ICScannerDevice else {
            return
        }

        emit("Scanner removed: \(scanner.name ?? "Unnamed scanner")")
        discoveredScanners.removeAll { $0 === scanner }

        if scanner === selectedScanner {
            handleSelectedScannerRemoval()
        } else if phase == .discovering, !moreGoing {
            scheduleEnumerationCompletion(after: 0.25)
        }
    }

    /// One removal policy for both callbacks — `ICDeviceBrowserDelegate` and
    /// `ICDeviceDelegate` report a removal independently and in no guaranteed
    /// order, and they must not race each other into different outcomes.
    ///
    /// Before paper moves, a removal is treated as a probable bounce: the
    /// selected scanner gets `reconnectWindow` to re-enumerate, and the pass
    /// restarts from session open — nothing has been captured, so the retry
    /// risks nothing. This is what turned "the selected scanner was
    /// disconnected" on the first real Continue Scanning press into a pass
    /// that simply proceeds. Mid-pass, the grace period exists to *collect*
    /// pages the driver is still writing, never to resume scanning: the
    /// feeder's state after a mid-feed drop is unknowable. During teardown
    /// the removal is ignored — the close-fallback timers already bound every
    /// wait, and failing here would overwrite the pass's real result.
    private func handleSelectedScannerRemoval() {
        switch phase {
        case .idle, .discovering, .reconnecting, .cancellingScan,
             .stoppingBeforeSession, .closing, .finished:
            return

        case .scanning:
            guard disconnectGraceTimer == nil else {
                return
            }
            // The device left the bus mid-pass, but the driver is very likely
            // still writing images it has already captured. Ending the pass on
            // this instant throws those away — pages that physically went
            // through the feeder. The grace period costs a moment on a failure
            // path and is the difference between losing a card and keeping it.
            emit("Scanner disconnected mid-pass; collecting any pages it already wrote…")
            disconnectGraceTimer = Timer.scheduledTimer(
                timeInterval: 2,
                target: self,
                selector: #selector(finishAfterDisconnectGracePeriod),
                userInfo: nil,
                repeats: false
            )

        case .openingSession, .waitingForAvailability, .waitingForReady,
             .waitingForFeeder, .selectingFeeder, .configuring:
            guard reconnectAttempts < Self.maximumReconnectAttempts else {
                finish(.failed(message: "The selected scanner was disconnected."))
                return
            }

            reconnectAttempts += 1
            lostScannerName = selectedScanner?.name
            selectedScanner?.delegate = nil
            selectedScanner = nil
            sessionIsOpen = false
            deviceIsReady = false
            functionalUnitSettleTimer?.invalidate()
            functionalUnitSettleTimer = nil
            phase = .reconnecting
            emit("The scanner left the bus before scanning; waiting for it to re-enumerate…")
            reconnectTimer?.invalidate()
            reconnectTimer = Timer.scheduledTimer(
                timeInterval: Self.reconnectWindow,
                target: self,
                selector: #selector(didReachReconnectWindowEnd),
                userInfo: nil,
                repeats: false
            )
        }
    }

    @objc
    private func didReachReconnectWindowEnd() {
        reconnectTimer = nil
        guard phase == .reconnecting else {
            return
        }
        finish(.failed(message: "The selected scanner was disconnected."))
    }

    @objc
    private func finishAfterDisconnectGracePeriod() {
        disconnectGraceTimer = nil
        finish(.failed(message: "The selected scanner was disconnected."))
    }

    public func deviceBrowserDidEnumerateLocalDevices(_ browser: ICDeviceBrowser) {
        guard phase == .discovering else {
            return
        }

        emit("Local scanner enumeration finished.")
        scheduleEnumerationCompletion(after: 0.75)
    }

    public func device(
        _ device: ICDevice,
        didOpenSessionWithError error: (any Error)?
    ) {
        guard let scanner = device as? ICScannerDevice,
              scanner === selectedScanner
        else {
            return
        }

        if phase == .stoppingBeforeSession {
            cancellationFallbackTimer?.invalidate()
            cancellationFallbackTimer = nil

            if error == nil {
                sessionIsOpen = true
                let stoppedResult = terminalResult
                    ?? .failed(
                        message: "The probe stopped while opening the scanner."
                    )
                beginClosing(
                    with: stoppedResult
                )
            } else {
                finish(
                    terminalResult
                        ?? .failed(message: "The scanner session did not open.")
                )
            }
            return
        }

        guard phase == .openingSession else {
            return
        }

        if let error {
            sessionIsOpen = false

            if isScannerBusyError(error) {
                phase = .waitingForAvailability
                emit(
                    "The scanner is in use by another application; "
                        + "waiting for it to become available…"
                )
                // The pass is stalled, not over, and nothing downstream can
                // tell that from silence. A typed notice is the only way the
                // app learns it should say so and then say when it clears.
                hasAnnouncedScannerInUse = true
                noticeHandler(
                    .scannerInUseElsewhere(
                        name: scanner.name ?? "The scanner"
                    )
                )
            } else {
                finish(
                    .failed(
                        message: "Could not open the scanner: "
                            + error.localizedDescription
                    )
                )
            }
            return
        }

        sessionIsOpen = true
        // The session is open, so whatever was holding it is not any more.
        // Withdrawn here rather than only from `scannerDeviceDidBecomeAvailable`
        // because that callback is not the only way out of the busy state: a
        // scanner that bounces off the bus while parked on -9925 leaves through
        // the reconnect path instead, and a notice that is only ever raised
        // leaves the operator reading "in use elsewhere" over a pass that is
        // scanning perfectly well.
        withdrawScannerInUseNoticeIfNeeded()
        emit("Session opened.")
        emit("Available functional units: \(scanner.availableFunctionalUnitTypes)")

        if !deviceIsReady {
            phase = .waitingForReady
            emit("Waiting for the scanner to become ready…")
        }
        requestDocumentFeederIfReady(on: scanner)
    }

    public func device(
        _ device: ICDevice,
        didCloseSessionWithError error: (any Error)?
    ) {
        guard let scanner = device as? ICScannerDevice,
              scanner === selectedScanner,
              phase == .closing
        else {
            return
        }

        closeFallbackTimer?.invalidate()
        closeFallbackTimer = nil
        sessionIsOpen = false

        if let error {
            emit("Session close reported: \(error.localizedDescription)")
            terminalResult = nil
            finish(
                .failed(
                    message: "Could not close the scanner session: "
                        + error.localizedDescription
                )
            )
        } else {
            emit("Session closed.")
            let result = terminalResult
                ?? .failed(message: "The scanner session closed unexpectedly.")
            terminalResult = nil
            finish(result)
        }
    }

    public func didRemove(_ device: ICDevice) {
        guard device === selectedScanner else {
            return
        }
        handleSelectedScannerRemoval()
    }

    public func deviceDidBecomeReady(_ device: ICDevice) {
        guard let scanner = device as? ICScannerDevice,
              scanner === selectedScanner,
              phase == .openingSession
                || phase == .waitingForReady
                || phase == .waitingForFeeder
        else {
            return
        }

        deviceIsReady = true
        emit("Scanner is ready.")
        emit("Available functional units: \(scanner.availableFunctionalUnitTypes)")
        requestDocumentFeederIfReady(on: scanner)
    }

    public func scannerDeviceDidBecomeAvailable(_ scanner: ICScannerDevice) {
        guard scanner === selectedScanner,
              phase == .waitingForAvailability,
              !scanner.hasOpenSession
        else {
            return
        }

        emit("Scanner became available; retrying the session.")
        withdrawScannerInUseNoticeIfNeeded()
        phase = .openingSession
        scanner.requestOpenSession()
    }

    /// Takes back the "in use elsewhere" notice, once, if one was raised.
    ///
    /// Raising a state without a guaranteed way to withdraw it is how a banner
    /// outlives the condition it describes. Every exit from the busy wait comes
    /// through here, including the pass ending for an unrelated reason, so the
    /// app can never be left claiming another application holds a scanner it
    /// has finished with.
    private func withdrawScannerInUseNoticeIfNeeded() {
        guard hasAnnouncedScannerInUse else {
            return
        }
        hasAnnouncedScannerInUse = false
        noticeHandler(.scannerAvailableAgain)
    }

    public func scannerDevice(
        _ scanner: ICScannerDevice,
        didSelect _: ICScannerFunctionalUnit,
        error: (any Error)?
    ) {
        guard scanner === selectedScanner, phase == .selectingFeeder else {
            return
        }

        if let error {
            beginClosing(
                with: .failed(
                    message: "Could not select the document feeder: "
                        + error.localizedDescription
                )
            )
            return
        }

        // The PFU ICA driver sends an initial callback whose functional-unit
        // pointer is NULL despite the framework's nonnull Swift annotation.
        // Never dereference that argument; use the scanner's published state.
        if let feeder = scanner.value(forKey: "selectedFunctionalUnit")
            as? ICScannerFunctionalUnitDocumentFeeder
        {
            emit("Selected functional unit: \(feeder.type).")
            handleSelectedFeeder(feeder, scanner: scanner)
            return
        }

        emit("Image Capture has not published the selected feeder yet; waiting…")
        functionalUnitSettleAttempts = 0
        functionalUnitSettleTimer?.invalidate()
        functionalUnitSettleTimer = Timer.scheduledTimer(
            timeInterval: 0.25,
            target: self,
            selector: #selector(pollSelectedFunctionalUnit),
            userInfo: nil,
            repeats: true
        )
    }

    private func handleSelectedFeeder(
        _ feeder: ICScannerFunctionalUnitDocumentFeeder,
        scanner: ICScannerDevice
    ) {
        guard scanner === selectedScanner, phase == .selectingFeeder else {
            return
        }

        phase = .configuring
        functionalUnitSettleTimer?.invalidate()
        functionalUnitSettleTimer = nil

        do {
            try configure(scanner: scanner, feeder: feeder)
        } catch {
            beginClosing(
                with: .failed(
                    message: "Scanner configuration failed: "
                        + error.localizedDescription
                )
            )
            return
        }

        switch configuration.operation {
        case .list:
            beginClosing(
                with: .listed(scannerCount: discoveredScanners.count)
            )
        case .inspect:
            beginClosing(
                with: .inspected(
                    deviceName: scanner.name ?? "Unnamed scanner"
                )
            )
        case .scan:
            do {
                try prepareOutputDirectory(for: scanner)
            } catch {
                beginClosing(
                    with: .failed(
                        message: "Could not prepare scan output: "
                            + error.localizedDescription
                    )
                )
                return
            }

            scannedPageURLs.removeAll(keepingCapacity: true)
            mostRecentScannerError = nil
            emit(
                "Starting one explicit \(Self.scanResolutionDPI) dpi duplex "
                    + "scan (the driver's paper-present flag is advisory)…"
            )
            phase = .scanning
            scanner.requestScan()
        }
    }

    public func scannerDevice(
        _ scanner: ICScannerDevice,
        didScanTo url: URL
    ) {
        guard scanner === selectedScanner, phase == .scanning else {
            return
        }

        do {
            let canonicalURL = try validateScannedPageFile(at: url)
            guard !scannedPageURLs.contains(canonicalURL) else {
                throw ProbeError.duplicatePageURL
            }

            scannedPageURLs.append(canonicalURL)
            let pageIndex = scannedPageURLs.index(before: scannedPageURLs.endIndex)
            emit(
                "Received page \(pageIndex + 1): "
                    + "\(canonicalURL.path)"
            )
            rearmTimeout()
            pageHandler(canonicalURL, pageIndex)
        } catch {
            requestShutdown(
                .failed(
                    message: "Scan output validation failed: "
                        + error.localizedDescription
                )
            )
        }
    }

    public func scannerDevice(
        _ scanner: ICScannerDevice,
        didCompleteScanWithError error: (any Error)?
    ) {
        guard scanner === selectedScanner else {
            return
        }

        if phase == .cancellingScan {
            cancellationFallbackTimer?.invalidate()
            cancellationFallbackTimer = nil
            beginClosing(
                with: terminalResult
                    ?? .failed(message: "The scan was cancelled.")
            )
            return
        }

        guard phase == .scanning else {
            return
        }

        if let error {
            let scannerDetail = mostRecentScannerErrorDescription.flatMap {
                $0 == error.localizedDescription ? nil : " Scanner reported: \($0)"
            } ?? ""
            beginClosing(
                with: .failed(
                    message: "Scan failed after \(scannedPageURLs.count) page(s): "
                        + error.localizedDescription
                        + scannerDetail,
                    reason: Self.failureReason(for: error as NSError)
                )
            )
            return
        }

        guard pageCountIsValid else {
            let scannerDetail = mostRecentScannerErrorDescription.map {
                " Scanner reported: \($0)"
            } ?? ""
            beginClosing(
                with: .failed(
                    message: pageCountFailureDescription
                        + scannerDetail,
                    // The path an empty chute actually takes. The driver
                    // reports the condition through `didEncounterError` and
                    // then completes the scan without an error of its own, so
                    // there is no page and no failure — only the error it
                    // mentioned in passing.
                    reason: Self.failureReason(for: mostRecentScannerError)
                )
            )
            return
        }

        beginClosing(
            with: .scanned(
                deviceName: scanner.name ?? "Unnamed scanner",
                pageURLs: scannedPageURLs
            )
        )
    }

    public func device(
        _ device: ICDevice,
        didEncounterError error: (any Error)?
    ) {
        guard device === selectedScanner,
              phase == .scanning || phase == .cancellingScan,
              let error
        else {
            return
        }
        mostRecentScannerError = error as NSError
        emit("Scanner reported an error: \(error.localizedDescription)")
    }

    public func device(
        _ device: ICDevice,
        didReceiveStatusInformation status: [ICDeviceStatus: Any]
    ) {
        guard device === selectedScanner, phase != .finished else {
            return
        }

        if let localized = status[.localizedStatusNotificationKey] as? String {
            emit("Scanner status: \(localized)")
        }
    }

    private func configure(
        scanner: ICScannerDevice,
        feeder: ICScannerFunctionalUnitDocumentFeeder
    ) throws {
        guard feeder.supportsDuplexScanning else {
            throw ProbeError.unsupported("duplex scanning")
        }
        guard feeder.supportedResolutions.contains(Self.scanResolutionDPI) else {
            throw ProbeError.unsupported("\(Self.scanResolutionDPI) dpi")
        }
        guard feeder.supportedBitDepths.contains(
            Int(ICScannerBitDepth.depth8Bits.rawValue)
        ) else {
            throw ProbeError.unsupported("8-bit RGB channels")
        }
        guard feeder.supportedDocumentTypes.contains(
            Int(ICScannerDocumentType.typeA6.rawValue)
        ) else {
            throw ProbeError.unsupported("A6 scan area")
        }

        describeScanGeometry("Before configuration", feeder: feeder)

        feeder.duplexScanningEnabled = true
        feeder.resolution = Self.scanResolutionDPI
        feeder.pixelDataType = .RGB
        feeder.bitDepth = .depth8Bits
        feeder.documentType = .typeA6

        guard feeder.duplexScanningEnabled else {
            throw ProbeError.settingRejected("duplex scanning")
        }
        guard feeder.resolution == Self.scanResolutionDPI else {
            throw ProbeError.settingRejected(
                "\(Self.scanResolutionDPI) dpi "
                    + "(driver retained \(feeder.resolution))"
            )
        }
        guard feeder.pixelDataType == .RGB else {
            throw ProbeError.settingRejected("RGB pixel data")
        }
        guard feeder.bitDepth == .depth8Bits else {
            throw ProbeError.settingRejected("8-bit channels")
        }
        guard feeder.documentType == .typeA6 else {
            throw ProbeError.settingRejected("A6 scan area")
        }

        scanner.transferMode = .fileBased
        scanner.documentUTI = UTType.jpeg.identifier
        scanner.documentName = "scandeck-m0"

        guard scanner.transferMode == .fileBased else {
            throw ProbeError.settingRejected("file-based transfer")
        }
        guard scanner.documentUTI == UTType.jpeg.identifier else {
            throw ProbeError.settingRejected("JPEG output")
        }

        describeScanGeometry("After A6", feeder: feeder)

        if let scanWindow = configuration.scanWindow {
            probeCustomScanWindow(scanWindow, on: feeder)
        }

        emit("Feeder: duplex, RGB 8-bit, \(Self.scanResolutionDPI) dpi, A6.")
        emit(
            "Driver paper-present signal (advisory): "
                + "\(feeder.documentLoaded ? "yes" : "no")."
        )
        emit("Reverse feeder page order: \(feeder.reverseFeederPageOrder ? "yes" : "no").")

        try configurePFUVendorFeatures(on: feeder)
    }

    /// Dumps everything the driver will say about the shape of a scan.
    ///
    /// The published master is 3232 × 4248 px where A6 at 600 dpi is
    /// 2480 × 3496, so something between the requested document type and the
    /// delivered frame is adding area — Overscan, presumably, but "presumably"
    /// is not a number anyone can size a smaller scan window against
    /// (TICKET-025). These are the driver's own values, read rather than
    /// assumed, and they cost four lines of a stream the app already drops.
    private func describeScanGeometry(
        _ label: String,
        feeder: ICScannerFunctionalUnitDocumentFeeder
    ) {
        let units = feeder.supportedMeasurementUnits
            .map { Self.describeMeasurementUnit($0) }
            .joined(separator: ", ")
        emit(
            "\(label) — measurement unit: "
                + "\(Self.describeMeasurementUnit(Int(feeder.measurementUnit.rawValue)))"
                + " (supported: \(units))"
        )
        emit(
            "\(label) — document type \(feeder.documentType.rawValue), "
                + "document size \(Self.describe(feeder.documentSize)), "
                + "physical size \(Self.describe(feeder.physicalSize))"
        )
        emit("\(label) — scan area \(Self.describe(feeder.scanArea))")
        emit(
            "\(label) — supported document types: "
                + feeder.supportedDocumentTypes.map(String.init)
                .joined(separator: ", ")
        )
    }

    /// Asks the driver for a scan window smaller than any standard document
    /// type, and reports what it kept.
    ///
    /// Every master is 3232 × 4248 px because the window is A6, while the
    /// largest holder measured is 1958 × 2532 px of media — the operator pays
    /// that difference in scan time, crop time, and disk on every card
    /// (TICKET-025). Whether the PFU driver will compose a custom `scanArea`
    /// with Overscan is the unknown the whole ticket turns on, and this is the
    /// question put to the device rather than to the documentation.
    private func probeCustomScanWindow(
        _ window: ScanWindowRequest,
        on feeder: ICScannerFunctionalUnitDocumentFeeder
    ) {
        let unitBefore = feeder.measurementUnit
        if feeder.supportedMeasurementUnits.contains(
            Int(ICScannerMeasurementUnit.pixels.rawValue)
        ) {
            feeder.measurementUnit = .pixels
            emit(
                "Requested pixel measurement; driver kept "
                    + Self.describeMeasurementUnit(
                        Int(feeder.measurementUnit.rawValue)
                    )
            )
        }

        let usingPixels = feeder.measurementUnit == .pixels
        let requested = usingPixels
            ? CGRect(
                x: 0,
                y: 0,
                width: Double(window.widthPixels),
                height: Double(window.heightPixels)
            )
            : CGRect(
                x: 0,
                y: 0,
                width: Double(window.widthPixels) / Double(Self.scanResolutionDPI),
                height: Double(window.heightPixels) / Double(Self.scanResolutionDPI)
            )

        emit("Requesting scan area \(Self.describe(requested))")
        feeder.scanArea = requested
        emit("Driver kept scan area \(Self.describe(feeder.scanArea))")

        let kept = feeder.scanArea
        if kept.size.width == 0, kept.size.height == 0 {
            emit(
                "VERDICT: the driver did not retain a custom scan area. It "
                    + "reports no physical size and no scan area, so the "
                    + "document type is the only window control it exposes."
            )
        } else if abs(kept.size.width - requested.size.width) < 0.01,
                  abs(kept.size.height - requested.size.height) < 0.01
        {
            emit(
                "VERDICT: the driver retained the requested scan area exactly. "
                    + "A real pass is still required to see what it delivers."
            )
        } else {
            emit(
                "VERDICT: the driver substituted its own scan area. A real "
                    + "pass is required to see what it delivers."
            )
        }

        feeder.measurementUnit = unitBefore
        describeScanGeometry("After scan-window probe", feeder: feeder)
    }

    private static func describeMeasurementUnit(_ rawValue: Int) -> String {
        switch ICScannerMeasurementUnit(rawValue: UInt(rawValue)) {
        case .inches:
            "inches"
        case .centimeters:
            "centimeters"
        case .picas:
            "picas"
        case .points:
            "points"
        case .twips:
            "twips"
        case .pixels:
            "pixels"
        default:
            "unit \(rawValue)"
        }
    }

    private static func describe(_ size: CGSize) -> String {
        String(format: "%.3f × %.3f", size.width, size.height)
    }

    private static func describe(_ rect: CGRect) -> String {
        String(
            format: "origin (%.3f, %.3f) size %.3f × %.3f",
            rect.origin.x,
            rect.origin.y,
            rect.size.width,
            rect.size.height
        )
    }

    private func requestDocumentFeederIfReady(on scanner: ICScannerDevice) {
        guard scanner === selectedScanner,
              sessionIsOpen,
              deviceIsReady,
              phase == .openingSession
                || phase == .waitingForReady
                || phase == .waitingForFeeder
        else {
            return
        }

        let feederRawValue = NSNumber(
            value: ICScannerFunctionalUnitType.documentFeeder.rawValue
        )
        guard scanner.availableFunctionalUnitTypes.contains(feederRawValue) else {
            if phase != .waitingForFeeder {
                emit("Waiting for the scanner to publish its document feeder…")
                phase = .waitingForFeeder
                functionalUnitSettleAttempts = 0
                functionalUnitSettleTimer?.invalidate()
                functionalUnitSettleTimer = Timer.scheduledTimer(
                    timeInterval: 0.25,
                    target: self,
                    selector: #selector(pollForDocumentFeeder),
                    userInfo: nil,
                    repeats: true
                )
            }
            return
        }

        functionalUnitSettleTimer?.invalidate()
        functionalUnitSettleTimer = nil
        functionalUnitSettleAttempts = 0
        phase = .selectingFeeder
        scanner.requestSelect(.documentFeeder)
    }

    /// Dumps every vendor feature, whatever class it is.
    ///
    /// `configurePFUVendorFeatures` compacts to `ICScannerFeatureEnumeration`
    /// because the four settings ScanDeck writes are all enumerations, and for
    /// a long time the dump inherited that filter — so range, boolean, and
    /// template features were invisible, and nobody could tell the difference
    /// between "the driver does not offer it" and "we never looked". A
    /// manual-feed timeout would be a range. This is also what TICKET-016's
    /// scanner matrix wants pasted into an issue.
    private func describeAllVendorFeatures(
        on feeder: ICScannerFunctionalUnitDocumentFeeder
    ) {
        let features = feeder.vendorFeatures ?? []
        emit("All vendor features (\(features.count)):")
        for feature in features {
            let name = feature.internalName ?? "unnamed"
            let label = feature.humanReadableName ?? ""
            switch feature {
            case let range as ICScannerFeatureRange:
                emit(
                    "  [range] \(name) “\(label)” "
                        + "current=\(range.currentValue) "
                        + "default=\(range.defaultValue) "
                        + "min=\(range.minValue) max=\(range.maxValue) "
                        + "step=\(range.stepSize)"
                )
            case let boolean as ICScannerFeatureBoolean:
                emit("  [boolean] \(name) “\(label)” current=\(boolean.value)")
            case let template as ICScannerFeatureTemplate:
                emit(
                    "  [template] \(name) “\(label)” "
                        + "targets=\(template.targets.count)"
                )
            case let enumeration as ICScannerFeatureEnumeration:
                // The values, not just the name. The dump used to print the
                // name alone, which left the same "the driver does not offer
                // it" versus "we never looked" ambiguity one level down: the
                // whole question of whether this driver can deskew is a
                // question about which values `cropping` offers, and nothing
                // in ScanDeck could answer it without feeding a card.
                let current = (enumeration.currentValue as? NSNumber)?.intValue
                let labels = enumeration.menuItemLabels
                let options = enumeration.values.enumerated().map {
                    index, value -> String in
                    let optionLabel = labels.indices.contains(index)
                        ? labels[index]
                        : "?"
                    let marker = value.intValue == current ? "*" : " "
                    return "\(marker)\(value.intValue)=“\(optionLabel)”"
                }
                let currentText = current.map(String.init) ?? "unknown"
                emit(
                    "  [enumeration] \(name) “\(label)” "
                        + "current=\(currentText) "
                        + "options: \(options.joined(separator: ", "))"
                )
            default:
                emit(
                    "  [\(String(describing: type(of: feature)))] \(name) "
                        + "“\(label)”"
                )
            }
        }
    }

    private func configurePFUVendorFeatures(
        on feeder: ICScannerFunctionalUnitDocumentFeeder
    ) throws {
        describeAllVendorFeatures(on: feeder)

        let enumerationFeatures = (feeder.vendorFeatures ?? []).compactMap {
            $0 as? ICScannerFeatureEnumeration
        }

        let snapshots = enumerationFeatures.compactMap(snapshot)

        emit("Vendor enumeration features:")
        for feature in snapshots {
            let options = feature.options
                .map { "\($0.rawValue)=\($0.localizedLabel)" }
                .joined(separator: ", ")
            emit("  \(feature.internalName): [\(options)] current=\(feature.currentRawValue.map(String.init) ?? "?")")
        }

        let selections = PFUCardScannerProfile.selections(
            croppingMode: configuration.croppingMode
        )
        for selection in selections {
            let option = try PFUCardScannerProfile.resolve(selection, in: snapshots)

            let matchingFeatures = enumerationFeatures.filter {
                guard let internalName = $0.internalName else {
                    return false
                }
                return PFUCardScannerProfile.canonicalInternalName(internalName)
                    == PFUCardScannerProfile.canonicalInternalName(
                        selection.internalName
                    )
            }

            guard !matchingFeatures.isEmpty else {
                throw ProbeError.vendorFeatureWriteFailed(selection.internalName)
            }

            for feature in matchingFeatures {
                guard let value = feature.values.first(where: {
                    $0.intValue == option.rawValue
                }) else {
                    throw ProbeError.vendorFeatureWriteFailed(selection.internalName)
                }

                feature.currentValue = value

                guard let verified = feature.currentValue as? NSNumber,
                      verified.intValue == option.rawValue
                else {
                    throw ProbeError.vendorFeatureVerificationFailed(
                        selection.internalName
                    )
                }
            }

            emit(
                "Verified \(selection.internalName)=\(option.rawValue) "
                    + "(\(option.localizedLabel); \(selection.purpose))."
            )
        }
    }

    private func snapshot(
        _ feature: ICScannerFeatureEnumeration
    ) -> VendorEnumerationFeatureSnapshot? {
        guard let internalName = feature.internalName else {
            return nil
        }

        let labels = feature.menuItemLabels
        let options = feature.values.enumerated().map { index, value in
            VendorEnumerationOption(
                rawValue: value.intValue,
                localizedLabel: labels.indices.contains(index)
                    ? labels[index]
                    : "Value \(value.intValue)"
            )
        }

        return VendorEnumerationFeatureSnapshot(
            internalName: internalName,
            localizedName: feature.humanReadableName,
            options: options,
            currentRawValue: (feature.currentValue as? NSNumber)?.intValue
        )
    }

    private func prepareOutputDirectory(for scanner: ICScannerDevice) throws {
        guard let outputDirectory = configuration.outputDirectory else {
            throw ProbeError.missingOutputDirectory
        }

        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(
            atPath: outputDirectory.path,
            isDirectory: &isDirectory
        )

        if exists {
            guard isDirectory.boolValue else {
                throw ProbeError.outputIsNotDirectory(outputDirectory)
            }

            let contents = try FileManager.default.contentsOfDirectory(
                at: outputDirectory,
                includingPropertiesForKeys: nil
            )
            guard contents.isEmpty else {
                throw ProbeError.outputDirectoryNotEmpty(outputDirectory)
            }
        } else {
            try FileManager.default.createDirectory(
                at: outputDirectory,
                withIntermediateDirectories: true
            )
        }

        scanner.downloadsDirectory = outputDirectory
        emit("Scan output: \(outputDirectory.path)")
    }

    private func validateScannedPageFile(at url: URL) throws -> URL {
        guard let configuredOutputDirectory = configuration.outputDirectory else {
            throw ProbeError.missingOutputDirectory
        }

        let outputDirectory = configuredOutputDirectory
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let canonicalURL = url.standardizedFileURL.resolvingSymlinksInPath()

        guard canonicalURL.isFileURL,
              isDescendant(canonicalURL, of: outputDirectory)
        else {
            throw ProbeError.pageOutsideOutputDirectory(canonicalURL)
        }

        let values = try canonicalURL.resourceValues(
            forKeys: [.isRegularFileKey, .fileSizeKey]
        )
        guard values.isRegularFile == true,
              let byteCount = values.fileSize,
              byteCount > 0
        else {
            throw ProbeError.invalidPageFile(canonicalURL)
        }

        guard FileManager.default.isReadableFile(atPath: canonicalURL.path),
              let imageSource = CGImageSourceCreateWithURL(
                  canonicalURL as CFURL,
                  nil
              ),
              let sourceTypeIdentifier = CGImageSourceGetType(imageSource),
              let sourceType = UTType(sourceTypeIdentifier as String),
              sourceType.conforms(to: .jpeg),
              let image = CGImageSourceCreateImageAtIndex(
                  imageSource,
                  0,
                  nil
              )
        else {
            throw ProbeError.invalidJPEG(canonicalURL)
        }

        guard image.colorSpace?.model == .rgb,
              image.bitsPerComponent == 8
        else {
            throw ProbeError.invalidColorFormat(
                canonicalURL,
                colorModel: image.colorSpace.map {
                    String(describing: $0.model)
                } ?? "unknown",
                bitsPerComponent: image.bitsPerComponent
            )
        }

        guard let properties = CGImageSourceCopyPropertiesAtIndex(
            imageSource,
            0,
            nil
        ) as? [CFString: Any],
            let dpiWidth = number(
                in: properties,
                for: kCGImagePropertyDPIWidth
            ),
            let dpiHeight = number(
                in: properties,
                for: kCGImagePropertyDPIHeight
            ),
            isApproximatelyScanResolution(dpiWidth),
            isApproximatelyScanResolution(dpiHeight)
        else {
            throw ProbeError.invalidDPI(canonicalURL)
        }

        emit(
            "Validated page file: \(canonicalURL.lastPathComponent) "
                + "(\(byteCount) bytes, \(image.width)×\(image.height), "
                + "RGB 8-bit, \(formatDPI(dpiWidth))×"
                + "\(formatDPI(dpiHeight)) dpi)."
        )
        return canonicalURL
    }

    private var pageCountIsValid: Bool {
        switch configuration.pageCountRequirement {
        case .exactlyTwo:
            scannedPageURLs.count == 2
        case .oneOrMore:
            !scannedPageURLs.isEmpty
        }
    }

    private var pageCountFailureDescription: String {
        switch configuration.pageCountRequirement {
        case .exactlyTwo:
            "Expected one duplex card (2 pages), but received "
                + "\(scannedPageURLs.count)."
        case .oneOrMore:
            "Expected at least one scanned page, but received none."
        }
    }

    private func isDescendant(_ candidate: URL, of directory: URL) -> Bool {
        let directoryComponents = directory.pathComponents
        let candidateComponents = candidate.pathComponents

        guard candidateComponents.count > directoryComponents.count else {
            return false
        }

        return zip(directoryComponents, candidateComponents).allSatisfy {
            $0.0 == $0.1
        }
    }

    private func number(
        in properties: [CFString: Any],
        for key: CFString
    ) -> Double? {
        (properties[key] as? NSNumber)?.doubleValue
    }

    private func isApproximatelyScanResolution(_ value: Double) -> Bool {
        value.isFinite
            && abs(value - Double(Self.scanResolutionDPI)) <= 10
    }

    private func formatDPI(_ value: Double) -> String {
        String(format: "%.1f", value)
    }

    private func scannerDescription(_ scanner: ICScannerDevice) -> String {
        let vendorID = scanner.usbVendorID >= 0
            ? String(
                format: "0x%04x",
                UInt16(truncatingIfNeeded: scanner.usbVendorID)
            )
            : "n/a"
        let productID = scanner.usbProductID >= 0
            ? String(
                format: "0x%04x",
                UInt16(truncatingIfNeeded: scanner.usbProductID)
            )
            : "n/a"

        return [
            "Found scanner: \(scanner.name ?? "Unnamed scanner")",
            "transport=\(scanner.transportType ?? "Unknown")",
            "location=\(scanner.locationDescription ?? "Unknown")",
            "usb=\(vendorID):\(productID)",
            "sessionOpen=\(scanner.hasOpenSession)"
        ].joined(separator: " · ")
    }

    private func deviceMatchesSelection(_ scanner: ICScannerDevice) -> Bool {
        guard let requested = configuration.deviceNameContains,
              !requested.isEmpty
        else {
            return true
        }

        return (scanner.name ?? "").localizedCaseInsensitiveContains(requested)
    }

    private func isSupportedScanner(_ scanner: ICScannerDevice) -> Bool {
        SupportedScanner.isSupported(
            vendorID: Int(scanner.usbVendorID),
            productID: Int(scanner.usbProductID)
        )
    }

    private func resolveAndOpenScanner() {
        guard phase == .discovering else {
            return
        }

        let candidates = discoveredScanners.filter {
            isSupportedScanner($0) && deviceMatchesSelection($0)
        }

        guard candidates.count == 1, let scanner = candidates.first else {
            let requested = configuration.deviceNameContains.map {
                " matching “\($0)”"
            } ?? ""

            if candidates.isEmpty {
                finish(
                    .failed(
                        message: "No supported fi-8170 USB scanner\(requested) "
                            + "was found."
                    )
                )
            } else {
                let names = candidates.map {
                    $0.name ?? "Unnamed scanner"
                }.joined(separator: ", ")
                finish(
                    .failed(
                        message: "More than one supported fi-8170 scanner"
                            + "\(requested) was found (\(names)); "
                            + "use --device to choose one uniquely."
                    )
                )
            }
            return
        }

        selectedScanner = scanner
        scanner.delegate = self
        phase = .openingSession
        emit(
            "Opening an exclusive session on "
                + "\(scanner.name ?? "Unnamed scanner")…"
        )
        scanner.requestOpenSession()
    }

    private func scheduleEnumerationCompletion(after interval: TimeInterval) {
        enumerationSettleTimer?.invalidate()
        enumerationSettleTimer = Timer.scheduledTimer(
            timeInterval: interval,
            target: self,
            selector: #selector(completeEnumerationAfterGracePeriod),
            userInfo: nil,
            repeats: false
        )
    }

    private func requestShutdown(_ result: ScannerProbeResult) {
        guard phase != .finished,
              phase != .closing,
              phase != .cancellingScan,
              phase != .stoppingBeforeSession
        else {
            return
        }

        terminalResult = result
        timeoutTimer?.invalidate()
        timeoutTimer = nil
        enumerationSettleTimer?.invalidate()
        enumerationSettleTimer = nil
        functionalUnitSettleTimer?.invalidate()
        functionalUnitSettleTimer = nil
        reconnectTimer?.invalidate()
        reconnectTimer = nil

        switch phase {
        case .scanning:
            guard let selectedScanner else {
                finish(result)
                return
            }

            phase = .cancellingScan
            emit("Cancelling the active scan before closing the session…")
            cancellationFallbackTimer = Timer.scheduledTimer(
                timeInterval: 5,
                target: self,
                selector: #selector(didReachCancellationFallback),
                userInfo: nil,
                repeats: false
            )
            selectedScanner.cancelScan()

        case .openingSession:
            phase = .stoppingBeforeSession
            emit("Waiting for the in-flight session request to finish…")
            cancellationFallbackTimer = Timer.scheduledTimer(
                timeInterval: 5,
                target: self,
                selector: #selector(didReachCancellationFallback),
                userInfo: nil,
                repeats: false
            )

        case .waitingForReady,
             .waitingForFeeder,
             .selectingFeeder,
             .configuring:
            beginClosing(with: result)

        case .idle,
             .discovering,
             .waitingForAvailability,
             .reconnecting:
            finish(result)

        case .cancellingScan,
             .stoppingBeforeSession,
             .closing,
             .finished:
            break
        }
    }

    private func beginClosing(with result: ScannerProbeResult) {
        guard phase != .finished, phase != .closing else {
            return
        }

        terminalResult = terminalResult ?? result
        timeoutTimer?.invalidate()
        timeoutTimer = nil
        enumerationSettleTimer?.invalidate()
        enumerationSettleTimer = nil
        functionalUnitSettleTimer?.invalidate()
        functionalUnitSettleTimer = nil
        cancellationFallbackTimer?.invalidate()
        cancellationFallbackTimer = nil
        reconnectTimer?.invalidate()
        reconnectTimer = nil

        guard let selectedScanner,
              sessionIsOpen || selectedScanner.hasOpenSession
        else {
            let terminalResult = self.terminalResult ?? result
            self.terminalResult = nil
            finish(terminalResult)
            return
        }

        sessionIsOpen = true
        phase = .closing
        closeFallbackTimer = Timer.scheduledTimer(
            timeInterval: 5,
            target: self,
            selector: #selector(didReachCloseFallback),
            userInfo: nil,
            repeats: false
        )
        selectedScanner.requestCloseSession()
    }

    private func finish(_ result: ScannerProbeResult) {
        guard phase != .finished else {
            return
        }

        // Before the pass is declared over, take whatever the driver actually
        // left on disk. Everything after this point stops listening.
        let result = claimUndeliveredPages(alongside: result)

        // A pass that ends while still parked on the busy wait has to take its
        // notice with it; the consumer stops listening a line later.
        withdrawScannerInUseNoticeIfNeeded()

        phase = .finished
        timeoutTimer?.invalidate()
        timeoutTimer = nil
        enumerationSettleTimer?.invalidate()
        enumerationSettleTimer = nil
        functionalUnitSettleTimer?.invalidate()
        functionalUnitSettleTimer = nil
        cancellationFallbackTimer?.invalidate()
        cancellationFallbackTimer = nil
        disconnectGraceTimer?.invalidate()
        disconnectGraceTimer = nil
        closeFallbackTimer?.invalidate()
        closeFallbackTimer = nil
        reconnectTimer?.invalidate()
        reconnectTimer = nil
        browser.stop()
        completion(result)
    }

    /// Sweeps the output directory for pages the delegate callback never
    /// delivered, and hands them over before the pass closes.
    ///
    /// Observed on a real fi-8170: when the scanner drops off the bus mid-pass,
    /// `didRemove` ends the pass immediately while the driver goes on writing
    /// the images it had already captured. Those files land in the output
    /// directory *after* `phase` stops being `.scanning`, so `didScanTo`
    /// discards them and two real, fully-scanned card sides vanish — on disk,
    /// paid for by a physical feed, and invisible to the app. That is invariant
    /// #1 broken by a race no caller can see.
    ///
    /// The fix is to stop treating the callback as the record of what was
    /// captured. The directory is: the probe owns it, required it to be empty,
    /// and validates everything in it to the same standard as a delivered page.
    private func claimUndeliveredPages(
        alongside result: ScannerProbeResult
    ) -> ScannerProbeResult {
        guard configuration.operation == .scan,
              let outputDirectory = configuration.outputDirectory,
              let contents = try? FileManager.default.contentsOfDirectory(
                  at: outputDirectory,
                  includingPropertiesForKeys: nil,
                  options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
              )
        else {
            return result
        }

        let delivered = Set(scannedPageURLs)
        // Ordered by name so a late sweep reconstructs the driver's own
        // sequence rather than whatever order the directory happens to list.
        let candidates = contents
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .filter { !delivered.contains($0.standardizedFileURL.resolvingSymlinksInPath()) }

        var claimed: [URL] = []
        for candidate in candidates {
            guard let canonicalURL = try? validateScannedPageFile(at: candidate),
                  !scannedPageURLs.contains(canonicalURL)
            else {
                // Not a page this pass produced, or not a complete one. A file
                // the probe cannot vouch for is left alone rather than handed
                // to the batch as if it were a scanned side.
                continue
            }
            scannedPageURLs.append(canonicalURL)
            claimed.append(canonicalURL)
            emit(
                "Recovered page \(scannedPageURLs.count) the driver wrote after "
                    + "the pass ended: \(canonicalURL.lastPathComponent)"
            )
            pageHandler(canonicalURL, scannedPageURLs.count - 1)
        }

        guard !claimed.isEmpty else {
            return result
        }

        // A success that was only a success because pages were missing has to
        // be restated with them included.
        switch result {
        case let .scanned(deviceName, _):
            return .scanned(deviceName: deviceName, pageURLs: scannedPageURLs)
        case .failed, .listed, .inspected:
            return result
        }
    }

    private func emit(_ message: String) {
        eventHandler(message)
    }

    /// Restarts the deadline after the scanner makes observable progress.
    ///
    /// The deadline catches a scanner that has stopped responding; it is not a
    /// budget for how long an operator's stack takes to feed. A production
    /// append pass runs until the feeder empties and legitimately outlasts any
    /// fixed total, so each delivered page buys another full interval. A device
    /// that goes quiet still fails within one interval of falling silent.
    ///
    /// Only a delivered page rearms it. Status chatter does not: a driver that
    /// narrates while delivering nothing is exactly the stall being watched for.
    private func rearmTimeout() {
        guard phase != .finished else {
            return
        }

        timeoutTimer?.invalidate()
        timeoutTimer = Timer.scheduledTimer(
            timeInterval: configuration.timeout,
            target: self,
            selector: #selector(didReachTimeout),
            userInfo: nil,
            repeats: false
        )
    }

    @objc
    private func didReachTimeout() {
        requestShutdown(.failed(message: timeoutFailureDescription))
    }

    /// Says what the deadline was actually waiting on.
    ///
    /// A pass parked on `-9925/-9926` is not an unresponsive scanner — it is a
    /// perfectly healthy one another application refuses to let go of, and
    /// reporting it as a stall sends the operator to check the cable on a
    /// device whose light is on. The condition is known here; wording it
    /// generically would throw that away at the last moment.
    private var timeoutFailureDescription: String {
        let seconds = Int(configuration.timeout)
        guard phase == .waitingForAvailability else {
            return "The scanner stopped responding for \(seconds) seconds."
        }
        return "Another application held the scanner for \(seconds) seconds, "
            + "so nothing was scanned. Quit the app using it — Image Capture, "
            + "Preview, or another scanning tool — and try again."
    }

    @objc
    private func completeEnumerationAfterGracePeriod() {
        enumerationSettleTimer = nil

        guard phase == .discovering else {
            return
        }

        switch configuration.operation {
        case .list:
            finish(.listed(scannerCount: discoveredScanners.count))
        case .inspect, .scan:
            resolveAndOpenScanner()
        }
    }

    @objc
    private func pollForDocumentFeeder() {
        guard let scanner = selectedScanner,
              phase == .waitingForFeeder
        else {
            return
        }

        functionalUnitSettleAttempts += 1

        let feederRawValue = NSNumber(
            value: ICScannerFunctionalUnitType.documentFeeder.rawValue
        )
        if scanner.availableFunctionalUnitTypes.contains(feederRawValue) {
            requestDocumentFeederIfReady(on: scanner)
            return
        }

        guard functionalUnitSettleAttempts >= 12 else {
            return
        }

        functionalUnitSettleTimer?.invalidate()
        functionalUnitSettleTimer = nil
        beginClosing(
            with: .failed(
                message: "The scanner did not publish a document feeder."
            )
        )
    }

    @objc
    private func pollSelectedFunctionalUnit() {
        guard let scanner = selectedScanner, phase == .selectingFeeder else {
            return
        }

        functionalUnitSettleAttempts += 1

        if let object = scanner.value(forKey: "selectedFunctionalUnit") as? NSObject {
            emit(
                "Selected functional-unit runtime class: "
                    + NSStringFromClass(type(of: object))
            )

            if let feeder = object as? ICScannerFunctionalUnitDocumentFeeder {
                handleSelectedFeeder(feeder, scanner: scanner)
                return
            }
        }

        guard functionalUnitSettleAttempts >= 12 else {
            return
        }

        functionalUnitSettleTimer?.invalidate()
        functionalUnitSettleTimer = nil
        beginClosing(
            with: .failed(
                message: "Image Capture did not publish a document-feeder object."
            )
        )
    }

    @objc
    private func didReachCancellationFallback() {
        cancellationFallbackTimer = nil

        guard let result = terminalResult else {
            return
        }

        switch phase {
        case .cancellingScan:
            emit(
                "The scanner did not confirm cancellation in time; "
                    + "closing the session."
            )
            beginClosing(with: result)

        case .stoppingBeforeSession:
            if let selectedScanner, selectedScanner.hasOpenSession {
                sessionIsOpen = true
                beginClosing(with: result)
            } else {
                terminalResult = nil
                finish(result)
            }

        default:
            break
        }
    }

    @objc
    private func didReachCloseFallback() {
        closeFallbackTimer = nil

        guard phase == .closing else {
            return
        }

        terminalResult = nil
        finish(
            .failed(
                message: "Timed out waiting for the scanner session to close."
            )
        )
    }

    private func isScannerBusyError(_ error: any Error) -> Bool {
        let code = (error as NSError).code
        return code == -9925 || code == -9926
    }

    /// The driver's wording for its last error, for the operator to read.
    private var mostRecentScannerErrorDescription: String? {
        mostRecentScannerError?.localizedDescription
    }

    /// Tells an empty ADF chute apart from every other way a pass can fail.
    ///
    /// Exactly one error decides, and which one depends on how the pass ended.
    /// A terminal error from `didCompleteScanWithError` is the pass's own
    /// verdict and outranks anything mentioned earlier: a driver that noted an
    /// empty chute and *then* jammed has jammed, and reporting that quietly as
    /// "the feeder is empty" would leave a card stuck in the transport with a
    /// blue information banner over it. Only when the scan completes without an
    /// error of its own — the path an empty chute actually takes — does the
    /// error it mentioned in passing get to speak.
    private static func failureReason(
        for error: NSError?
    ) -> ScannerPassFailureReason {
        guard let error, isFeederEmpty(error) else {
            return .scannerFault
        }
        return .feederEmpty
    }

    /// `0x03800320` — "No documents in the ADF paper chute", as the fi-8170
    /// driver reports it, against `0x03800131` for a jam.
    ///
    /// A code, not prose. That is the whole reason it is safe to key on where
    /// the message text would not be: the driver localises its sentence and
    /// this number stays put, and `ScanDeckApp` never sees either.
    ///
    /// Both forms are checked because only one has been observed. The operator's
    /// `carlsoboxone` run produced the code inside the localised description
    /// ("… (Error Code: 0x03800320)"); whether the driver also puts it in
    /// `NSError.code` has never been seen on hardware, so the numeric test is
    /// there for the case that it does, not on the strength of having watched
    /// it.
    ///
    /// The description is searched for the bare token and nothing around it.
    /// "Error Code:" is English and travels with the localisation; the ten
    /// characters of the code do not, and they are specific enough that a
    /// coincidental match is not a real risk.
    private static let feederEmptyErrorCode = 0x0380_0320
    private static let feederEmptyErrorToken = "0x03800320"

    private static func isFeederEmpty(_ error: NSError) -> Bool {
        if error.code == feederEmptyErrorCode {
            return true
        }
        return error.localizedDescription.range(
            of: feederEmptyErrorToken,
            options: .caseInsensitive
        ) != nil
    }

    private enum ProbeError: Error, LocalizedError {
        case unsupported(String)
        case settingRejected(String)
        case vendorFeatureWriteFailed(String)
        case vendorFeatureVerificationFailed(String)
        case missingOutputDirectory
        case outputIsNotDirectory(URL)
        case outputDirectoryNotEmpty(URL)
        case duplicatePageURL
        case pageOutsideOutputDirectory(URL)
        case invalidPageFile(URL)
        case invalidJPEG(URL)
        case invalidColorFormat(
            URL,
            colorModel: String,
            bitsPerComponent: Int
        )
        case invalidDPI(URL)

        var errorDescription: String? {
            switch self {
            case let .unsupported(capability):
                "The scanner does not report support for \(capability)."
            case let .settingRejected(setting):
                "The driver did not retain the requested \(setting) setting."
            case let .vendorFeatureWriteFailed(name):
                "Could not write required vendor feature \(name)."
            case let .vendorFeatureVerificationFailed(name):
                "The driver did not retain required vendor feature \(name)."
            case .missingOutputDirectory:
                "No output directory was provided."
            case let .outputIsNotDirectory(url):
                "\(url.path) is not a directory."
            case let .outputDirectoryNotEmpty(url):
                "\(url.path) is not empty; choose a new directory."
            case .duplicatePageURL:
                "The driver returned the same output URL more than once."
            case let .pageOutsideOutputDirectory(url):
                "\(url.path) is outside the requested output directory."
            case let .invalidPageFile(url):
                "\(url.path) is not a nonempty regular file."
            case let .invalidJPEG(url):
                "\(url.path) is not a readable JPEG image."
            case let .invalidColorFormat(
                url,
                colorModel,
                bitsPerComponent
            ):
                "\(url.path) is \(colorModel) with "
                    + "\(bitsPerComponent)-bit components; expected RGB 8-bit."
            case let .invalidDPI(url):
                "\(url.path) does not report approximately "
                    + "\(scanResolutionDPI)×\(scanResolutionDPI) dpi."
            }
        }
    }
}
