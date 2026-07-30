import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import ScanDeckImagePipeline

@Suite("Review-grid thumbnail decoding")
struct ThumbnailDecoderTests {
    @Test("Bounds a full-resolution master to the review preview size")
    func boundsMasterToPreviewSize() throws {
        // Approximately one side of a 600 dpi card scan.
        let fixture = try makeFixture(width: 2_048, height: 2_867)
        defer { removeFixture(fixture) }

        let thumbnail = try ThumbnailDecoder.decode(contentsOf: fixture)

        #expect(max(thumbnail.width, thumbnail.height) == 512)
        #expect(thumbnail.width < 2_048)
        #expect(thumbnail.height < 2_867)

        // The long edge drives the bound, so the aspect ratio is preserved.
        let sourceRatio = 2_048.0 / 2_867.0
        let thumbnailRatio = Double(thumbnail.width) / Double(thumbnail.height)
        #expect(abs(sourceRatio - thumbnailRatio) < 0.01)
    }

    @Test("Honors a custom maximum pixel size")
    func honorsCustomMaximumSize() throws {
        let fixture = try makeFixture(width: 1_200, height: 800)
        defer { removeFixture(fixture) }

        let thumbnail = try ThumbnailDecoder.decode(
            contentsOf: fixture,
            maximumPixelSize: 128
        )

        #expect(max(thumbnail.width, thumbnail.height) == 128)
    }

    @Test("Decodes an image smaller than the bound without upscaling")
    func doesNotUpscaleSmallImages() throws {
        let fixture = try makeFixture(width: 64, height: 90)
        defer { removeFixture(fixture) }

        let thumbnail = try ThumbnailDecoder.decode(contentsOf: fixture)

        #expect(thumbnail.width == 64)
        #expect(thumbnail.height == 90)
    }

    @Test("Reports an unreadable file rather than returning an empty preview")
    func reportsUnreadableFile() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).jpg")

        #expect(throws: ThumbnailDecoderError.unreadableImage) {
            try ThumbnailDecoder.decode(contentsOf: missing)
        }
    }

    @Test("Reports a file that is not a decodable image")
    func reportsUndecodableFile() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let notAnImage = directory.appendingPathComponent("notes.jpg")
        try Data("this is not an image".utf8).write(to: notAnImage)

        #expect(throws: (any Error).self) {
            try ThumbnailDecoder.decode(contentsOf: notAnImage)
        }
    }

    // MARK: - Fixtures

    private func makeFixture(width: Int, height: Int) throws -> URL {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for index in stride(from: 0, to: pixels.count, by: 4) {
            let pixel = index / 4
            pixels[index] = UInt8((pixel % width) % 256)
            pixels[index + 1] = UInt8((pixel / width) % 256)
            pixels[index + 2] = 180
            pixels[index + 3] = 255
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
                        | CGBitmapInfo.byteOrder32Big.rawValue
                ),
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
            )
        )

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let url = directory.appendingPathComponent("master.png")
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
        return url
    }

    private func removeFixture(_ url: URL) {
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }
}
