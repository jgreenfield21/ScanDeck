import CoreGraphics
import Foundation
import ImageIO
import ScanDeckImagePipeline
import Testing
import UniformTypeIdentifiers
@testable import ScanDeckApp

/// Review must show the file that will be published, not the scan frame.
@MainActor
@Suite("Review preview cropping")
struct ThumbnailCropTests {
    @Test("A preview is trimmed to the published crop")
    func previewIsTrimmedToTheCrop() async throws {
        let url = try writeImage(width: 1_600, height: 2_000)
        defer { try? FileManager.default.removeItem(at: url) }

        let store = ThumbnailStore(maximumPixelSize: 400)
        let full = try #require(await store.thumbnail(for: url))

        // A crop covering the middle quarter of the master.
        let crop = PublishedCrop(
            bounds: PixelRect(x: 400, y: 500, width: 800, height: 1_000),
            sourceWidth: 1_600,
            sourceHeight: 2_000
        )
        let trimmed = try #require(await store.thumbnail(for: url, croppedTo: crop))

        #expect(trimmed.width < full.width)
        #expect(trimmed.height < full.height)
        // Half the master on each axis, within a pixel of rounding.
        #expect(abs(Double(trimmed.width) - Double(full.width) / 2) <= 1)
        #expect(abs(Double(trimmed.height) - Double(full.height) / 2) <= 1)
    }

    @Test("The uncropped and cropped previews are cached separately")
    func cropIsPartOfTheCacheIdentity() async throws {
        let url = try writeImage(width: 1_200, height: 1_600)
        defer { try? FileManager.default.removeItem(at: url) }

        let store = ThumbnailStore(maximumPixelSize: 400)
        let full = try #require(await store.thumbnail(for: url))
        let crop = PublishedCrop(
            bounds: PixelRect(x: 100, y: 100, width: 600, height: 800),
            sourceWidth: 1_200,
            sourceHeight: 1_600
        )
        let trimmed = try #require(await store.thumbnail(for: url, croppedTo: crop))

        // Serving the cached uncropped preview for a cropped request is exactly
        // the bug this guards: review would keep showing the whole scan frame
        // after analysis had already found the card.
        #expect(trimmed.width != full.width || trimmed.height != full.height)
        #expect(try #require(await store.thumbnail(for: url)).width == full.width)
    }

    private func writeImage(width: Int, height: Int) throws -> URL {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for index in stride(from: 3, to: pixels.count, by: 4) {
            pixels[index] = 255
        }
        let provider = try #require(CGDataProvider(data: Data(pixels) as CFData))
        let image = try #require(
            CGImage(
                width: width,
                height: height,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(
                    rawValue: CGImageAlphaInfo.premultipliedLast.rawValue
                ),
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
            )
        )

        let url = FileManager.default.temporaryDirectory
            .appending(path: "\(UUID().uuidString).jpg", directoryHint: .notDirectory)
        let destination = try #require(
            CGImageDestinationCreateWithURL(
                url as CFURL,
                UTType.jpeg.identifier as CFString,
                1,
                nil
            )
        )
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return url
    }
}
