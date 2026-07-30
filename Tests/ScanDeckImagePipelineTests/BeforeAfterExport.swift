import CoreGraphics
import Foundation
import ImageIO
import ScanDeckCore
import Testing
import UniformTypeIdentifiers
@testable import ScanDeckImagePipeline

/// Writes the published image a master would have produced before deskew and
/// after it, plus a magnified comparison of the left border at each end of the
/// card, and prints the border's profile against the margin that was requested.
///
/// This exists because it earned its keep: the first deskew implementation
/// squared the card by de-rotating its bounding box, and every automated check
/// passed — the output was square, the border was uniform, nothing was padded.
/// It was this tool's border profile, run against real toploaders, that showed
/// the border sitting at 63–72 px against 71 requested, because de-rotating a
/// bounding box solves for sharp corners and a toploader's are rounded. Some
/// defects are only visible when you look at the picture.
///
/// Opt-in: `SCANDECK_BEFORE_AFTER=<output dir>`,
/// `SCANDECK_TILT_DIR=<dir of masters>`, and optionally `SCANDECK_SIDES` to
/// name which ones.
@Suite("Before/after export")
struct BeforeAfterExport {
    @Test(
        "Exports before/after pairs",
        .enabled(
            if: ProcessInfo.processInfo
                .environment["SCANDECK_BEFORE_AFTER"] != nil
        ),
        .timeLimit(.minutes(10))
    )
    func export() throws {
        let outputDirectory = URL(
            fileURLWithPath: try #require(
                ProcessInfo.processInfo.environment["SCANDECK_BEFORE_AFTER"]
            ),
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: outputDirectory,
            withIntermediateDirectories: true
        )
        let corpus = URL(
            fileURLWithPath: try #require(
                ProcessInfo.processInfo.environment["SCANDECK_TILT_DIR"]
            ),
            isDirectory: true
        )

        let names = (
            ProcessInfo.processInfo.environment["SCANDECK_SIDES"]
                ?? "sheet_000072_F,sheet_000109_F"
        )
        .split(separator: ",").map(String.init)

        let cropper = CardImageCropper()
        let margins = try ScanMargins(all: 3)
        for name in names {
            let source = try #require(
                ["jpeg", "jpg", "png"]
                    .map { corpus.appendingPathComponent("\(name).\($0)") }
                    .first { FileManager.default.fileExists(atPath: $0.path) }
            )
            let decoded = try cropper.decode(source)
            let analysis = try cropper.analyze(
                decoded: decoded,
                margins: margins,
                dpi: 600
            )
            let insets = analysis.requestedInsets

            // Before: the axis-aligned crop the pipeline made yesterday.
            let legacy = PixelRect(
                x: analysis.mediaBounds.x - insets.left,
                y: analysis.mediaBounds.y - insets.top,
                width: analysis.mediaBounds.width + insets.left + insets.right,
                height: analysis.mediaBounds.height + insets.top + insets.bottom
            )
            let before = try #require(
                decoded.image.cropping(
                    to: CGRect(
                        x: legacy.x, y: legacy.y,
                        width: legacy.width, height: legacy.height
                    )
                )
            )
            // After: whatever ships today.
            let deskew = try #require(analysis.deskew)
            let tilt = deskew.angleDegrees
            let after = try cropper.square(
                decoded.image,
                deskew: deskew,
                outputWidth: analysis.outputWidth,
                outputHeight: analysis.outputHeight,
                insets: insets
            )

            print(
                String(
                    format: "%@  tilt %+.3f°  before %d×%d  after %d×%d",
                    name, tilt,
                    before.width, before.height,
                    after.width, after.height
                )
            )
            for (image, label) in [(before, "before"), (after, "after")] {
                let near = try Self.leftBorder(of: image, atFraction: 0.1)
                let far = try Self.leftBorder(of: image, atFraction: 0.9)
                // Every row between the corners, so a systematic shortfall
                // cannot hide between two sample points.
                var widths: [Int] = []
                for step in 0...40 {
                    let fraction = 0.15 + 0.7 * Double(step) / 40
                    let width = try Self.leftBorder(of: image, atFraction: fraction)
                    if width >= 0 { widths.append(width) }
                }
                widths.sort()
                print(
                    String(
                        format:
                            "  %-6@ left border %d px top / %d px bottom "
                            + "(%d apart) — over the whole edge min %d, "
                            + "median %d, max %d, against %d requested",
                        label as NSString,
                        near, far, abs(near - far),
                        widths.first ?? -1,
                        widths[widths.count / 2],
                        widths.last ?? -1,
                        insets.left
                    )
                )
            }
            for (image, label) in [(before, "before"), (after, "after")] {
                try Self.write(
                    Self.scaled(image, toHeight: 900),
                    to: outputDirectory
                        .appendingPathComponent("\(name)-\(label).png")
                )
                // The left border at the top of the card against the same
                // border at the bottom. Tilted, those differ by the excursion;
                // squared, they agree. This is the whole change, magnified.
                try Self.write(
                    Self.leftBorderComparison(image),
                    to: outputDirectory
                        .appendingPathComponent("\(name)-\(label)-corners.png")
                )
            }
        }
    }

    /// How much black sits between the published left edge and the media, at a
    /// given fraction of the way down the card.
    static func leftBorder(
        of image: CGImage,
        atFraction fraction: Double
    ) throws -> Int {
        let cropper = CardImageCropper()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("probe.png")
        try write(image, to: url)
        let decoded = try cropper.decode(url)
        let estimate = cropper.estimateBackground(
            pixels: decoded.pixels,
            width: decoded.width,
            height: decoded.height
        )
        let threshold = UInt8(
            min(255, max(12, Int(estimate.residualThreshold) + 4))
        )
        let row = Int(Double(decoded.height) * fraction)
        var run = 0
        for x in 0..<decoded.width {
            let offset = (row * decoded.width + x) * 4
            let signal = max(
                Int(decoded.pixels[offset]) - Int(estimate.color.red),
                max(
                    Int(decoded.pixels[offset + 1]) - Int(estimate.color.green),
                    Int(decoded.pixels[offset + 2]) - Int(estimate.color.blue)
                )
            )
            if signal > Int(threshold) {
                run += 1
                if run >= 4 { return x - 3 }
            } else {
                run = 0
            }
        }
        return -1
    }

    /// Stacks a window from the top-left corner above one from the bottom-left,
    /// so the border's width at each end sits in one picture.
    static func leftBorderComparison(_ image: CGImage) -> CGImage {
        let window = 260
        let context = CGContext(
            data: nil,
            width: window,
            height: window * 2 + 8,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
                | CGBitmapInfo.byteOrder32Big.rawValue
        )!
        // A red seam so the two windows cannot be mistaken for one view.
        context.setFillColor(CGColor(red: 0.85, green: 0.1, blue: 0.1, alpha: 1))
        context.fill(CGRect(x: 0, y: window, width: window, height: 8))

        let top = image.cropping(
            to: CGRect(x: 0, y: 0, width: window, height: window)
        )!
        let bottom = image.cropping(
            to: CGRect(
                x: 0, y: image.height - window,
                width: window, height: window
            )
        )!
        // CoreGraphics is y-up, so the card's top window draws high.
        context.draw(
            top,
            in: CGRect(x: 0, y: window + 8, width: window, height: window)
        )
        context.draw(
            bottom,
            in: CGRect(x: 0, y: 0, width: window, height: window)
        )
        return context.makeImage()!
    }

    static func scaled(_ image: CGImage, toHeight height: Int) -> CGImage {
        let width = Int(
            (Double(image.width) / Double(image.height) * Double(height))
                .rounded()
        )
        let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
                | CGBitmapInfo.byteOrder32Big.rawValue
        )!
        context.interpolationQuality = .high
        context.draw(
            image,
            in: CGRect(x: 0, y: 0, width: width, height: height)
        )
        return context.makeImage()!
    }

    static func write(_ image: CGImage, to url: URL) throws {
        let destination = try #require(
            CGImageDestinationCreateWithURL(
                url as CFURL,
                UTType.png.identifier as CFString,
                1,
                nil
            )
        )
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
    }
}
