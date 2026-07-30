import Foundation
import ScanDeckScanner
@testable import ScanDeckApp

/// A device browser whose reports are written down in advance.
///
/// Plugging and unplugging an fi-8170 is not something a suite can do. What is
/// worth testing is what the app does with the report — that Scan blocks, that a
/// mid-pass bounce does not repaint the UI, that a busy scanner explains itself
/// — so the report is the thing that gets scripted.
@MainActor
final class ScriptedScannerInventorySource: ScannerInventorySource {
    private(set) var inventory: ScannerInventory
    private var continuations: [UUID: AsyncStream<ScannerInventory>.Continuation] = [:]

    init(inventory: ScannerInventory = .oneSupportedScanner) {
        self.inventory = inventory
    }

    func inventoryUpdates() -> AsyncStream<ScannerInventory> {
        let id = UUID()
        let pair = AsyncStream<ScannerInventory>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        continuations[id] = pair.continuation
        pair.continuation.yield(inventory)
        pair.continuation.onTermination = { @Sendable [weak self] _ in
            Task { @MainActor [weak self] in
                self?.continuations.removeValue(forKey: id)
            }
        }
        return pair.stream
    }

    /// Reports a change, exactly as the browser would on a plug or unplug.
    func report(_ inventory: ScannerInventory) {
        self.inventory = inventory
        for continuation in continuations.values {
            continuation.yield(inventory)
        }
    }
}

extension ScannerDeviceIdentity {
    static let fi8170 = ScannerDeviceIdentity(
        name: "fi-8170",
        usbVendorID: 0x04c5,
        usbProductID: 0x15ff
    )

    /// A second supported unit, so the ambiguity case has two of them.
    static let secondFi8170 = ScannerDeviceIdentity(
        name: "fi-8170 (2)",
        usbVendorID: 0x04c5,
        usbProductID: 0x15ff
    )

    /// Attached, enumerated, and not something ScanDeck will drive.
    static let unsupportedScanner = ScannerDeviceIdentity(
        name: "Generic Flatbed 4200",
        usbVendorID: 0x03f0,
        usbProductID: 0x0001
    )
}

extension ScannerInventory {
    static let oneSupportedScanner = ScannerInventory(
        scanners: [.fi8170],
        hasCompletedFirstEnumeration: true
    )

    static let nothingAttached = ScannerInventory(
        scanners: [],
        hasCompletedFirstEnumeration: true
    )
}
