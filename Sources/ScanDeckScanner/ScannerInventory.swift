import Foundation

/// The USB identities ScanDeck will open a session on.
///
/// A scanner outside this set is refused before a session is opened rather than
/// driven and published: the pipeline depends on duplex, 600 dpi, the configured
/// scan area, and the PFU cropping features, and a device missing any of them
/// would produce output that looks plausible and is wrong. Both the probe that
/// selects a device for a pass and the browser that reports what is attached
/// read this one set, so the status the operator sees and the device the pass
/// will actually take can never disagree.
public enum SupportedScanner {
    public struct USBIdentity: Hashable, Sendable {
        public let vendorID: Int
        public let productID: Int

        public init(vendorID: Int, productID: Int) {
            self.vendorID = vendorID
            self.productID = productID
        }
    }

    public static let usbIdentities: Set<USBIdentity> = [
        USBIdentity(vendorID: 0x04c5, productID: 0x15ff),
        USBIdentity(vendorID: 0x05ca, productID: 0x03d8),
        USBIdentity(vendorID: 0x04c5, productID: 0x151f),
    ]

    public static func isSupported(vendorID: Int, productID: Int) -> Bool {
        usbIdentities.contains(
            USBIdentity(vendorID: vendorID, productID: productID)
        )
    }
}

/// One scanner the device browser can currently see, as a value.
///
/// Deliberately not an `ICScannerDevice`. Two `ICDeviceBrowser` instances hand
/// out *different objects* for one physical scanner, so object identity means
/// nothing across them — and Image Capture types must not leave this module in
/// the first place. Name plus USB identity is already what the probe matches on
/// when a device re-enumerates mid-pass, so it is what a caller can hold.
public struct ScannerDeviceIdentity: Hashable, Sendable {
    public let name: String
    public let usbVendorID: Int
    public let usbProductID: Int

    public init(name: String, usbVendorID: Int, usbProductID: Int) {
        self.name = name
        self.usbVendorID = usbVendorID
        self.usbProductID = usbProductID
    }

    /// Whether a pass would actually be allowed to take this device.
    public var isSupported: Bool {
        SupportedScanner.isSupported(
            vendorID: usbVendorID,
            productID: usbProductID
        )
    }
}

/// What the device browser can see right now.
public struct ScannerInventory: Equatable, Sendable {
    /// Every local scanner, in the order the browser reported it, including
    /// devices ScanDeck cannot drive — a scanner that is attached and
    /// unsupported is a different thing to explain than no scanner at all.
    public let scanners: [ScannerDeviceIdentity]

    /// False only until the browser's first sweep finishes.
    ///
    /// Announcing "no scanner found" during that first fraction of a second
    /// would send the operator to check a cable for a device that is about to
    /// appear, so the first sweep gets its own state rather than borrowing the
    /// empty one.
    public let hasCompletedFirstEnumeration: Bool

    public init(
        scanners: [ScannerDeviceIdentity],
        hasCompletedFirstEnumeration: Bool
    ) {
        self.scanners = scanners
        self.hasCompletedFirstEnumeration = hasCompletedFirstEnumeration
    }

    /// Nothing seen yet, and no conclusion drawn from that.
    public static let searching = ScannerInventory(
        scanners: [],
        hasCompletedFirstEnumeration: false
    )

    public var supportedScanners: [ScannerDeviceIdentity] {
        scanners.filter(\.isSupported)
    }

    public var unsupportedScanners: [ScannerDeviceIdentity] {
        scanners.filter { !$0.isSupported }
    }
}
