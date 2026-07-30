import Foundation

/// A support report an operator can paste into an issue without reading it
/// first.
///
/// The rule is content-free: no page pixels, no file names, no folder paths, no
/// batch names. That is enforced by the shape of ``Input`` rather than by
/// remembering — there is nowhere to put a path, so no future edit can add one
/// by accident. What a hardware or storage bug actually needs is the device's
/// own identity and capabilities, the app and OS versions, and counts; none of
/// that says anything about the cards someone scanned.
///
/// The destination is reported as configured-or-not and resolvable-or-not,
/// which is the part that diagnoses a publication failure. Where it points is
/// the operator's business.
public enum DiagnosticsReport {
    public struct Scanner: Equatable, Sendable {
        public let name: String
        public let usbVendorID: Int
        public let usbProductID: Int
        public let isSupported: Bool

        public init(
            name: String,
            usbVendorID: Int,
            usbProductID: Int,
            isSupported: Bool
        ) {
            self.name = name
            self.usbVendorID = usbVendorID
            self.usbProductID = usbProductID
            self.isSupported = isSupported
        }
    }

    /// Working-file counts, flattened out of ``SessionStorageInventory``.
    ///
    /// The inventory carries `[URL]`, which would have made the guarantee above
    /// a claim rather than a property of the type — nothing prints those URLs
    /// today, and nothing stops the next edit from doing so. Counts cannot be
    /// misused that way.
    public struct Storage: Equatable, Sendable {
        public let unfinishedBatchCount: Int
        public let unfinishedCardCount: Int
        public let awaitingReleaseJournalCount: Int
        public let unreadableRecordCount: Int
        public let directoryWithoutRecordCount: Int
        public let totalByteCount: Int64

        public init(_ inventory: SessionStorageInventory) {
            unfinishedBatchCount = inventory.resumableBatchCount
            unfinishedCardCount = inventory.resumableCardCount
            awaitingReleaseJournalCount = inventory.publishedRecordCount
            unreadableRecordCount = inventory.unreadableDirectoryCount
            directoryWithoutRecordCount = inventory
                .directoriesWithoutRecord.count
            totalByteCount = inventory.totalByteCount
        }
    }

    public struct Counter: Equatable, Sendable {
        public let jobName: String
        public let nextSheetNumber: UInt64

        public init(jobName: String, nextSheetNumber: UInt64) {
            self.jobName = jobName
            self.nextSheetNumber = nextSheetNumber
        }
    }

    public struct Input: Sendable {
        public let applicationVersion: String
        public let applicationBuild: String
        public let operatingSystemVersion: String
        public let hardwareModel: String
        public let scanners: [Scanner]
        public let preferredScannerName: String?
        public let hasDestination: Bool
        public let destinationResolves: Bool
        public let counters: [Counter]
        public let sessionStorage: Storage
        public let activeBatchCardCount: Int?

        public init(
            applicationVersion: String,
            applicationBuild: String,
            operatingSystemVersion: String,
            hardwareModel: String,
            scanners: [Scanner],
            preferredScannerName: String?,
            hasDestination: Bool,
            destinationResolves: Bool,
            counters: [Counter],
            sessionStorage: Storage,
            activeBatchCardCount: Int?
        ) {
            self.applicationVersion = applicationVersion
            self.applicationBuild = applicationBuild
            self.operatingSystemVersion = operatingSystemVersion
            self.hardwareModel = hardwareModel
            self.scanners = scanners
            self.preferredScannerName = preferredScannerName
            self.hasDestination = hasDestination
            self.destinationResolves = destinationResolves
            self.counters = counters
            self.sessionStorage = sessionStorage
            self.activeBatchCardCount = activeBatchCardCount
        }
    }

    public static func text(for input: Input) -> String {
        var lines: [String] = []

        lines.append("ScanDeck diagnostics")
        lines.append(
            "This report is content-free: no images, file names, folder paths, "
                + "or batch names."
        )
        lines.append("")

        lines.append("## Application")
        lines.append(
            "Version: \(input.applicationVersion) (build \(input.applicationBuild))"
        )
        lines.append("macOS: \(input.operatingSystemVersion)")
        lines.append("Hardware: \(input.hardwareModel)")
        lines.append("")

        lines.append("## Scanners")
        if input.scanners.isEmpty {
            lines.append("None attached.")
        } else {
            for scanner in input.scanners {
                lines.append(
                    "\(scanner.name) — usb "
                        + formatUSBIdentity(
                            vendorID: scanner.usbVendorID,
                            productID: scanner.usbProductID
                        )
                        + " — \(scanner.isSupported ? "supported" : "not supported")"
                )
            }
        }
        lines.append(
            "Preferred scanner: "
                + (input.preferredScannerName ?? "any supported scanner")
        )
        lines.append("")

        lines.append("## Destination")
        lines.append("Configured: \(yesOrNo(input.hasDestination))")
        lines.append("Resolves now: \(yesOrNo(input.destinationResolves))")
        lines.append("")

        lines.append("## Counters")
        if input.counters.isEmpty {
            lines.append("None.")
        } else {
            for counter in input.counters {
                lines.append(
                    "\(counter.jobName): next sheet number "
                        + String(format: "%06llu", counter.nextSheetNumber)
                )
            }
        }
        lines.append("")

        lines.append("## Working files")
        let storage = input.sessionStorage
        lines.append(
            "Unfinished batches: \(storage.unfinishedBatchCount) "
                + "(\(storage.unfinishedCardCount) cards)"
        )
        lines.append(
            "Awaiting release journal: \(storage.awaitingReleaseJournalCount)"
        )
        lines.append("Unreadable records: \(storage.unreadableRecordCount)")
        lines.append(
            "Directories with no record: \(storage.directoryWithoutRecordCount)"
        )
        lines.append("Total size: \(formatBytes(storage.totalByteCount))")
        lines.append(
            "Active batch: "
                + (input.activeBatchCardCount.map { "\($0) cards" } ?? "none")
        )

        return lines.joined(separator: "\n") + "\n"
    }

    private static func formatUSBIdentity(
        vendorID: Int,
        productID: Int
    ) -> String {
        guard vendorID >= 0, productID >= 0 else {
            return "n/a"
        }
        return String(
            format: "0x%04x:0x%04x",
            UInt16(truncatingIfNeeded: vendorID),
            UInt16(truncatingIfNeeded: productID)
        )
    }

    private static func yesOrNo(_ value: Bool) -> String {
        value ? "yes" : "no"
    }

    private static func formatBytes(_ count: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: count)
    }
}
