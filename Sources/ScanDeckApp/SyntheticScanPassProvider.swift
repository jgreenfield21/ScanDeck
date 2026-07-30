import CoreGraphics
import Foundation
import ImageIO
import ScanDeckCore
import ScanDeckScanner
import UniformTypeIdentifiers

/// Reports one stand-in scanner so `--synthetic` can actually scan.
///
/// The mode exists to drive the production workflow without an fi-8170. A
/// status source that truthfully found nothing would disable Scan and make the
/// mode useless, so this reports a device — under a name that says what it is,
/// because the name is what reaches the screen and nothing on screen should
/// claim hardware that is not attached. It borrows the supported USB identity
/// only so the same "is this drivable" rule applies to it as to a real device.
@MainActor
final class SyntheticScannerInventorySource: ScannerInventorySource {
    let inventory = ScannerInventory(
        scanners: [
            ScannerDeviceIdentity(
                name: "Synthetic page source",
                usbVendorID: 0x04c5,
                usbProductID: 0x15ff
            ),
        ],
        hasCompletedFirstEnumeration: true
    )

    func inventoryUpdates() -> AsyncStream<ScannerInventory> {
        AsyncStream { continuation in
            continuation.yield(inventory)
            // Nothing can unplug a scanner that is not there, so the stream is
            // over as soon as it starts.
            continuation.finish()
        }
    }
}

/// Stands in for the scanner until the Image Capture adapter lands (TICKET-004).
///
/// It writes real JPEG masters — a card-shaped block of colour on the scanner's
/// black background — so crop analysis, margin verdicts, and atomic publication
/// all run for real. Only the hardware is simulated. That keeps the demo honest
/// and lets contributors without an fi-8170 exercise the whole workflow.
@MainActor
final class SyntheticScanPassProvider: ScanPassProviding {
    /// The first append pass ends on an orphan front, so the incomplete-card
    /// gate is reachable without staging a paper jam.
    private var appendPass = 0

    private let pageInterval: Duration

    init(pageInterval: Duration = .milliseconds(260)) {
        self.pageInterval = pageInterval
    }

    func scan(
        _ request: ScanPassRequest,
        into directory: URL
    ) -> AsyncStream<ScanPassProgress> {
        let pageCount: Int
        switch request.kind {
        case .append:
            pageCount = appendPass == 0 ? 5 : 2
            appendPass += 1
        case .retry, .replace:
            pageCount = 2
        }

        let interval = pageInterval
        let dpi = request.profile.resolutionDPI
        let margins = request.margins

        return AsyncStream { continuation in
            let task = Task { @MainActor in
                continuation.yield(.status("Feeding cards…"))
                for index in 0..<pageCount {
                    try? await Task.sleep(for: interval)
                    guard !Task.isCancelled else {
                        continuation.finish()
                        return
                    }
                    do {
                        let url = try Self.writeSyntheticPage(
                            into: directory,
                            index: index,
                            dpi: dpi,
                            margins: margins
                        )
                        continuation.yield(.page(url))
                    } catch {
                        continuation.yield(
                            .finished(
                                .failed(message: error.localizedDescription)
                            )
                        )
                        continuation.finish()
                        return
                    }
                }
                continuation.yield(.finished(.succeeded))
                continuation.finish()
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    /// Renders a card on black with comfortably more background than the
    /// requested margin, so the crop has real border to keep.
    private static func writeSyntheticPage(
        into directory: URL,
        index: Int,
        dpi: Int,
        margins: ScanMargins
    ) throws -> URL {
        let insets = try margins.pixels(atDPI: dpi)
        let border = max(
            insets.top,
            insets.right,
            insets.bottom,
            insets.left
        ) + 40

        let mediaWidth = 760
        let mediaHeight = 1_060
        let width = mediaWidth + border * 2
        let height = mediaHeight + border * 2

        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for index in stride(from: 3, to: pixels.count, by: 4) {
            pixels[index] = 255
        }

        // A deterministic per-page hue keeps successive cards visually distinct
        // in review without pretending to be a real scan.
        let tint = UInt8(60 + (index * 47) % 160)
        for y in border..<(border + mediaHeight) {
            for x in border..<(border + mediaWidth) {
                let offset = (y * width + x) * 4
                pixels[offset] = tint
                pixels[offset + 1] = 120
                pixels[offset + 2] = 220
            }
        }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let image = CGImage(
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bitsPerPixel: 32,
                  bytesPerRow: width * 4,
                  space: colorSpace,
                  bitmapInfo: CGBitmapInfo(
                      rawValue: CGImageAlphaInfo.premultipliedLast.rawValue
                          | CGBitmapInfo.byteOrder32Big.rawValue
                  ),
                  provider: provider,
                  decode: nil,
                  shouldInterpolate: false,
                  intent: .defaultIntent
              )
        else {
            throw SyntheticScanError.cannotRenderPage
        }

        let url = directory.appending(
            path: "master-\(UUID().uuidString).jpg",
            directoryHint: .notDirectory
        )
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            throw SyntheticScanError.cannotWritePage
        }
        CGImageDestinationAddImage(
            destination,
            image,
            [
                kCGImageDestinationLossyCompressionQuality: 0.95,
                kCGImagePropertyDPIWidth: dpi,
                kCGImagePropertyDPIHeight: dpi,
            ] as CFDictionary
        )
        guard CGImageDestinationFinalize(destination) else {
            throw SyntheticScanError.cannotWritePage
        }
        return url
    }

    enum SyntheticScanError: Error, LocalizedError {
        case cannotRenderPage
        case cannotWritePage

        var errorDescription: String? {
            switch self {
            case .cannotRenderPage:
                "A simulated page could not be rendered."
            case .cannotWritePage:
                "A simulated page could not be written to the session folder."
            }
        }
    }
}
