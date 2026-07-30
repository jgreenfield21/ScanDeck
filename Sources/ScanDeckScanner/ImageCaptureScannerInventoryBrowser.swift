import Foundation
@preconcurrency import ImageCaptureCore

/// Reports which scanners are attached, continuously and without touching them.
///
/// It runs an `ICDeviceBrowser` of its own rather than borrowing the probe's.
/// The probe's browser exists for the length of one pass and is stopped when the
/// pass ends, which is exactly when the operator most needs to be told the
/// scanner came back; a status source that only exists while scanning could
/// never say "reconnect it". Two browsers in one process see the same devices as
/// two different object graphs, which is why this publishes
/// ``ScannerDeviceIdentity`` values and never an `ICScannerDevice`.
///
/// It is strictly an observer: it opens no session, sets no device delegate, and
/// requests nothing. ICA scanners are single-client, so anything else here would
/// take the device away from the pass it is meant to describe.
@MainActor
public final class ImageCaptureScannerInventoryBrowser: NSObject,
    @MainActor ICDeviceBrowserDelegate
{
    /// How long the first sweep may take before its result is reported anyway.
    ///
    /// `deviceBrowserDidEnumerateLocalDevices` is the real signal and normally
    /// arrives in well under a second. This bounds the case where it never
    /// arrives at all: without it the app would sit in "Looking for a scanner…"
    /// forever, and because that state disables Scan, a missing callback would
    /// silently brick scanning rather than degrade the status line.
    private static let firstEnumerationDeadline: TimeInterval = 3

    private typealias Continuation = AsyncStream<ScannerInventory>.Continuation

    private let browser = ICDeviceBrowser()
    private var subscribers: [UUID: Continuation] = [:]
    private var devices: [ICScannerDevice] = []
    private var hasCompletedFirstEnumeration = false
    private var firstEnumerationTimer: Timer?
    private var isBrowsing = false

    public override init() {
        super.init()
    }

    /// The inventory as it stands, then every change to it.
    ///
    /// The current value arrives immediately, so a subscriber never has to
    /// render an empty status while waiting for the first change. Browsing
    /// starts on the first subscription rather than at construction, so making
    /// one of these costs nothing until something is actually listening.
    public func inventoryUpdates() -> AsyncStream<ScannerInventory> {
        startBrowsingIfNeeded()

        let id = UUID()
        let pair = AsyncStream<ScannerInventory>.makeStream(
            // Status is a current value, not a log: a slow consumer wants the
            // latest state, never a queue of superseded ones.
            bufferingPolicy: .bufferingNewest(1)
        )
        subscribers[id] = pair.continuation
        pair.continuation.yield(inventory)
        pair.continuation.onTermination = { @Sendable [weak self] _ in
            Task { @MainActor [weak self] in
                self?.subscribers.removeValue(forKey: id)
            }
        }
        return pair.stream
    }

    /// Stops browsing and finishes every subscription. The app never needs this;
    /// it exists so a test can tear the browser down deterministically.
    public func stop() {
        guard isBrowsing else {
            return
        }
        isBrowsing = false
        firstEnumerationTimer?.invalidate()
        firstEnumerationTimer = nil
        browser.stop()
        browser.delegate = nil
        for continuation in subscribers.values {
            continuation.finish()
        }
        subscribers.removeAll()
    }

    public var inventory: ScannerInventory {
        ScannerInventory(
            scanners: devices.map(Self.identity(of:)),
            hasCompletedFirstEnumeration: hasCompletedFirstEnumeration
        )
    }

    // MARK: - ICDeviceBrowserDelegate

    public func deviceBrowser(
        _ browser: ICDeviceBrowser,
        didAdd device: ICDevice,
        moreComing: Bool
    ) {
        guard let scanner = device as? ICScannerDevice,
              !devices.contains(where: { $0 === scanner })
        else {
            return
        }
        devices.append(scanner)
        publish()
    }

    public func deviceBrowser(
        _ browser: ICDeviceBrowser,
        didRemove device: ICDevice,
        moreGoing: Bool
    ) {
        guard let scanner = device as? ICScannerDevice else {
            return
        }
        let countBefore = devices.count
        devices.removeAll { $0 === scanner }
        guard devices.count != countBefore else {
            return
        }
        publish()
    }

    public func deviceBrowser(
        _ browser: ICDeviceBrowser,
        deviceDidChangeName device: ICDevice
    ) {
        guard devices.contains(where: { $0 === device }) else {
            return
        }
        // The name is what the status line and the scanner chooser show, so a
        // rename has to reach them or the operator picks a device by a label
        // that is no longer on it.
        publish()
    }

    public func deviceBrowserDidEnumerateLocalDevices(
        _ browser: ICDeviceBrowser
    ) {
        completeFirstEnumeration()
    }

    // MARK: - Browsing

    private func startBrowsingIfNeeded() {
        guard !isBrowsing else {
            return
        }
        isBrowsing = true
        browser.delegate = self

        let rawMask = ICDeviceTypeMask.scanner.rawValue
            | ICDeviceLocationTypeMask.local.rawValue
        browser.browsedDeviceTypeMask = ICDeviceTypeMask(rawValue: rawMask)!

        firstEnumerationTimer = Timer.scheduledTimer(
            timeInterval: Self.firstEnumerationDeadline,
            target: self,
            selector: #selector(didReachFirstEnumerationDeadline),
            userInfo: nil,
            repeats: false
        )
        browser.start()
    }

    @objc
    private func didReachFirstEnumerationDeadline() {
        firstEnumerationTimer = nil
        completeFirstEnumeration()
    }

    private func completeFirstEnumeration() {
        firstEnumerationTimer?.invalidate()
        firstEnumerationTimer = nil
        guard !hasCompletedFirstEnumeration else {
            return
        }
        hasCompletedFirstEnumeration = true
        publish()
    }

    private func publish() {
        let inventory = self.inventory
        for continuation in subscribers.values {
            continuation.yield(inventory)
        }
    }

    private static func identity(
        of scanner: ICScannerDevice
    ) -> ScannerDeviceIdentity {
        ScannerDeviceIdentity(
            name: scanner.name ?? "Unnamed scanner",
            usbVendorID: Int(scanner.usbVendorID),
            usbProductID: Int(scanner.usbProductID)
        )
    }
}
