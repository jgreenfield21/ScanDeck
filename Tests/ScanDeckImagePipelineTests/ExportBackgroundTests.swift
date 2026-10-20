import CoreGraphics
import ScanDeckCore
import Testing
@testable import ScanDeckImagePipeline

@Suite("Export background")
struct ExportBackgroundTests {
    @Test("A chosen color replaces only the published outside margin", arguments: [
        (ExportBackground.white, UInt8(255)),
        (ExportBackground.black, UInt8(0)),
    ])
    func replacesMargin(background: ExportBackground, expected: UInt8) throws {
        let source = try #require(solidImage(red: 40, green: 120, blue: 200))
        let analysis = CropAnalysis(
            sourceWidth: 10,
            sourceHeight: 10,
            dpi: 600,
            mediaBounds: PixelRect(x: 2, y: 2, width: 6, height: 6),
            requestedCropBounds: PixelRect(x: 0, y: 0, width: 10, height: 10),
            availableCropBounds: PixelRect(x: 0, y: 0, width: 10, height: 10),
            requestedInsets: PixelInsets(top: 2, right: 2, bottom: 2, left: 2),
            insufficientEdges: [],
            threshold: 12,
            confidence: 1,
            deskew: nil,
            outputWidth: 10,
            outputHeight: 10
        )

        let output = try CardImageCropper().applyingExportBackground(
            background,
            to: source,
            analysis: analysis,
            cropBounds: analysis.requestedCropBounds
        )

        let corner = try pixel(output, x: 0, y: 0)
        #expect(corner.red == expected)
        #expect(corner.green == expected)
        #expect(corner.blue == expected)
        #expect(try pixel(output, x: 5, y: 5) == RGB(red: 40, green: 120, blue: 200))
    }

    @Test("Original preserves scanner pixels")
    func preservesOriginal() throws {
        let source = try #require(solidImage(red: 40, green: 120, blue: 200))
        let analysis = CropAnalysis(
            sourceWidth: 10,
            sourceHeight: 10,
            dpi: 600,
            mediaBounds: PixelRect(x: 2, y: 2, width: 6, height: 6),
            requestedCropBounds: PixelRect(x: 0, y: 0, width: 10, height: 10),
            availableCropBounds: PixelRect(x: 0, y: 0, width: 10, height: 10),
            requestedInsets: PixelInsets(top: 2, right: 2, bottom: 2, left: 2),
            insufficientEdges: [],
            threshold: 12,
            confidence: 1,
            deskew: nil,
            outputWidth: 10,
            outputHeight: 10
        )

        let output = try CardImageCropper().applyingExportBackground(
            .original,
            to: source,
            analysis: analysis,
            cropBounds: analysis.requestedCropBounds
        )
        #expect(try pixel(output, x: 0, y: 0) == RGB(red: 40, green: 120, blue: 200))
    }

    private struct RGB: Equatable {
        let red: UInt8
        let green: UInt8
        let blue: UInt8
    }

    private func solidImage(red: UInt8, green: UInt8, blue: UInt8) -> CGImage? {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: 10,
            height: 10,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
                | CGBitmapInfo.byteOrder32Big.rawValue
        ) else { return nil }
        context.setFillColor(CGColor(
            red: CGFloat(red) / 255,
            green: CGFloat(green) / 255,
            blue: CGFloat(blue) / 255,
            alpha: 1
        ))
        context.fill(CGRect(x: 0, y: 0, width: 10, height: 10))
        return context.makeImage()
    }

    private func pixel(_ image: CGImage, x: Int, y: Int) throws -> RGB {
        var bytes = [UInt8](repeating: 0, count: 4)
        let context = try #require(CGContext(
            data: &bytes,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
                | CGBitmapInfo.byteOrder32Big.rawValue
        ))
        context.draw(
            image,
            in: CGRect(x: -x, y: y - image.height + 1, width: image.width, height: image.height)
        )
        return RGB(red: bytes[0], green: bytes[1], blue: bytes[2])
    }
}
