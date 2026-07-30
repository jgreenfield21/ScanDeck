import CoreGraphics
import Foundation
import ImageIO
import ScanDeckCore
import Testing
import UniformTypeIdentifiers
@testable import ScanDeckImagePipeline

@Suite("Real-background card cropping")
struct CardImageCropperTests {
    @Test("Detects a card and retains only captured requested margins")
    func detectsAndCrops() throws {
        let fixture = try makeFixture(
            width: 520,
            height: 700,
            media: PixelRect(x: 120, y: 140, width: 280, height: 400)
        )
        let margins = try ScanMargins(all: 1)
        let output = fixture.deletingLastPathComponent()
            .appendingPathComponent("crop.jpg")

        let result = try CardImageCropper().crop(
            sourceURL: fixture,
            destinationURL: output,
            margins: margins,
            dpi: 600
        )

        #expect(result.analysis.mediaBounds.x == 120)
        #expect(result.analysis.mediaBounds.y == 140)
        #expect(abs(result.analysis.mediaBounds.width - 280) <= 2)
        #expect(abs(result.analysis.mediaBounds.height - 400) <= 2)
        #expect(result.analysis.insufficientEdges.isEmpty)
        #expect(result.analysis.requestedInsets.top == 24)
        #expect(FileManager.default.fileExists(atPath: output.path))

        let source = try #require(
            CGImageSourceCreateWithURL(output as CFURL, nil)
        )
        let properties = try #require(
            CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any]
        )
        #expect(
            (properties[kCGImagePropertyDPIWidth] as? NSNumber)?.intValue
                == 600
        )
    }

    @Test("Flags an unavailable top margin and refuses publication")
    func insufficientTop() throws {
        let fixture = try makeFixture(
            width: 520,
            height: 700,
            media: PixelRect(x: 120, y: 5, width: 280, height: 400)
        )
        let cropper = CardImageCropper()
        let analysis = try cropper.analyze(sourceURL: fixture)

        #expect(analysis.insufficientEdges == [.top])
        #expect(!analysis.isPublishable)
        #expect(analysis.availableCropBounds.y == 0)
        #expect(
            throws: CardImageCropperError.insufficientRealBackground([.top])
        ) {
            try cropper.crop(
                sourceURL: fixture,
                destinationURL: fixture.deletingLastPathComponent()
                    .appendingPathComponent("rejected.jpg")
            )
        }
    }

    @Test("Rejects an all-black frame")
    func rejectsBlankFrame() throws {
        let fixture = try makeFixture(
            width: 320,
            height: 480,
            media: nil
        )

        #expect(throws: CardImageCropperError.noMediaDetected) {
            try CardImageCropper().analyze(sourceURL: fixture)
        }
    }

    @Test("A faint artefact does not stretch the detected card")
    func faintArtefactDoesNotWinOverTheCard() throws {
        // Taken from a real fi-8170 pass: a card in a toploader detected as
        // 1822 × 3972 px at the permissive threshold and 1821 × 2417 px at the
        // conservative one, because something faint on the black background
        // registered as media down almost the whole frame. Believing the
        // permissive read swallowed the margins and reported the scan
        // unpublishable — a good scan the operator could not release.
        let card = PixelRect(x: 700, y: 376, width: 800, height: 1_000)
        let url = try makeFixture(
            width: 2_400,
            height: 3_000,
            media: card,
            faintStreak: PixelRect(x: 700, y: 8, width: 800, height: 2_960)
        )

        let analysis = try CardImageCropper().analyze(
            sourceURL: url,
            margins: try ScanMargins(all: 3),
            dpi: 600
        )

        #expect(analysis.mediaBounds == card)
        #expect(analysis.insufficientEdges.isEmpty)
        // Reported as a low-confidence read rather than a clean one, so a
        // review surface can single it out later.
        #expect(analysis.confidence < 0.5)
    }

    @Test("A bright streak connected to the holder does not stretch it")
    func brightStreakDoesNotStretchTheHolder() throws {
        // The defect that shipped a back 679 px taller than its own front:
        // ~10 px rear-side streaks ran from the frame's top edge into the
        // toploader's top glint, cleared even the conservative threshold, and
        // stretched the dominant component's bounding box. Profile-derived
        // bounds must hold the media box at the holder instead.
        let holder = PixelRect(x: 600, y: 400, width: 1_200, height: 1_600)
        let card = PixelRect(x: 750, y: 728, width: 900, height: 1_260)
        let url = try makeFixture(
            width: 2_400,
            height: 3_000,
            media: card,
            glintFrame: holder,
            brightStreak: PixelRect(x: 1_100, y: 0, width: 10, height: 420)
        )

        let analysis = try CardImageCropper().analyze(
            sourceURL: url,
            margins: try ScanMargins(all: 3),
            dpi: 600
        )

        #expect(abs(analysis.mediaBounds.x - holder.x) <= 4)
        #expect(abs(analysis.mediaBounds.y - holder.y) <= 4)
        #expect(abs(analysis.mediaBounds.width - holder.width) <= 8)
        #expect(abs(analysis.mediaBounds.height - holder.height) <= 8)
        #expect(analysis.insufficientEdges.isEmpty)
        #expect(analysis.confidence >= 0.7)
    }

    @Test("Profile floors keep a holder's faint interior inside the bounds")
    func holderInteriorSurvivesProfileFloors() throws {
        // The dual risk of occupancy floors: high enough to reject a streak,
        // they must still pass the hollow interior of a holder, which only
        // its side glints hold up — measured at 13–45 mask blocks per row on
        // a real pass against the streak's 1–5.
        let holder = PixelRect(x: 600, y: 400, width: 1_200, height: 1_600)
        let card = PixelRect(x: 750, y: 728, width: 900, height: 1_260)
        let url = try makeFixture(
            width: 2_400,
            height: 3_000,
            media: card,
            glintFrame: holder
        )

        let analysis = try CardImageCropper().analyze(
            sourceURL: url,
            margins: try ScanMargins(all: 3),
            dpi: 600
        )

        #expect(abs(analysis.mediaBounds.x - holder.x) <= 4)
        #expect(abs(analysis.mediaBounds.y - holder.y) <= 4)
        #expect(abs(analysis.mediaBounds.width - holder.width) <= 8)
        #expect(abs(analysis.mediaBounds.height - holder.height) <= 8)
        #expect(analysis.insufficientEdges.isEmpty)
    }

    @Test("A sub-floor tail past the media does not extend the bounds")
    func subFloorTailDoesNotExtendTheBounds() throws {
        // The detector used to walk the bound out over any sub-floor
        // occupancy that died out within a budget, on the theory that a
        // toploader's open-end lip glints below the support floor while a
        // streak runs on to the frame edge. Run across the operator's 186
        // real pairs that pass **caused 23 of the 26 pairs whose two sides
        // disagreed** and rescued none — the losing side's "lip" was
        // typically one occupied block per row for 14–32 rows and then
        // nothing, 28–64 px of black claimed as media by one camera and by
        // neither the other camera nor the eye.
        //
        // There is no occupancy level that separates the two: the widest
        // false tail measured 2–6 blocks per row for 21 rows, which is the
        // shape a real lip was described by. A single image does not carry
        // the evidence, so the bound stops at what the support floor holds up
        // and the reducer's pair cross-check arbitrates the rest.
        let holder = PixelRect(x: 600, y: 400, width: 1_200, height: 1_600)
        let card = PixelRect(x: 750, y: 728, width: 900, height: 1_260)
        let tail = PixelRect(x: 1_140, y: 2_000, width: 10, height: 60)
        let url = try makeFixture(
            width: 2_400,
            height: 3_000,
            media: card,
            glintFrame: holder,
            faintLip: tail
        )

        let analysis = try CardImageCropper().analyze(
            sourceURL: url,
            margins: try ScanMargins(all: 3),
            dpi: 600
        )

        #expect(abs(analysis.mediaBounds.y - holder.y) <= 4)
        #expect(abs(analysis.mediaBounds.maxY - holder.maxY) <= 8)
        #expect(analysis.insufficientEdges.isEmpty)
    }

    @Test(
        "Every real pair agrees once profiles bound the media",
        .enabled(
            if: ProcessInfo.processInfo
                .environment["SCANDECK_REAL_ASSET_DIR"] != nil
        )
    )
    func realPassPairsAgree() throws {
        // Opt-in validation against real fi-8170 captures, paired by _F/_B in
        // the filename. The corpus holds the defect tombstones: the published
        // pair whose back shipped 679 px taller than its front, and the
        // masters whose faint open-end lip cost one side 70 px. The images
        // stay the operator's and are never committed.
        let directory = URL(
            fileURLWithPath: try #require(
                ProcessInfo.processInfo
                    .environment["SCANDECK_REAL_ASSET_DIR"]
            ),
            isDirectory: true
        )
        let contents = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        let fronts = contents
            .filter { $0.lastPathComponent.contains("_F") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        try #require(!fronts.isEmpty)

        let cropper = CardImageCropper()
        let margins = try ScanMargins(all: 2)
        for front in fronts {
            let back = directory.appendingPathComponent(
                front.lastPathComponent
                    .replacingOccurrences(of: "_F", with: "_B")
            )
            guard FileManager.default.fileExists(atPath: back.path) else {
                continue
            }

            let frontAnalysis = try cropper.analyze(
                sourceURL: front,
                margins: margins,
                dpi: 600
            )
            let backAnalysis = try cropper.analyze(
                sourceURL: back,
                margins: margins,
                dpi: 600
            )

            let widthDifference = abs(
                frontAnalysis.mediaBounds.width - backAnalysis.mediaBounds.width
            )
            let heightDifference = abs(
                frontAnalysis.mediaBounds.height - backAnalysis.mediaBounds.height
            )
            #expect(
                widthDifference
                    <= MediaPixelSize.pairAgreementTolerancePixels,
                "\(front.lastPathComponent) width"
            )
            #expect(
                heightDifference
                    <= MediaPixelSize.pairAgreementTolerancePixels,
                "\(front.lastPathComponent) height"
            )
        }
    }

    private func makeFixture(
        width: Int,
        height: Int,
        media: PixelRect?,
        faintStreak: PixelRect? = nil,
        glintFrame: PixelRect? = nil,
        brightStreak: PixelRect? = nil,
        faintLip: PixelRect? = nil
    ) throws -> URL {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for index in stride(from: 3, to: pixels.count, by: 4) {
            pixels[index] = 255
        }
        // Barely above the permissive threshold and well below the conservative
        // one, which is exactly where a scanner artefact lives.
        if let faintStreak {
            for y in faintStreak.y..<faintStreak.maxY {
                for x in faintStreak.x..<faintStreak.maxX {
                    let offset = (y * width + x) * 4
                    pixels[offset] = 18
                    pixels[offset + 1] = 18
                    pixels[offset + 2] = 18
                    pixels[offset + 3] = 255
                }
            }
        }
        // A toploader over the black background: the plastic edges glint while
        // the interior stays black, so the frame is a hollow outline.
        if let glintFrame {
            let thickness = 12
            for y in glintFrame.y..<glintFrame.maxY {
                for x in glintFrame.x..<glintFrame.maxX
                where y < glintFrame.y + thickness
                    || y >= glintFrame.maxY - thickness
                    || x < glintFrame.x + thickness
                    || x >= glintFrame.maxX - thickness
                {
                    let offset = (y * width + x) * 4
                    pixels[offset] = 60
                    pixels[offset + 1] = 60
                    pixels[offset + 2] = 60
                    pixels[offset + 3] = 255
                }
            }
        }
        // Bright enough to clear the conservative threshold too — the streak
        // class the two-threshold consensus cannot catch.
        if let brightStreak {
            for y in brightStreak.y..<brightStreak.maxY {
                for x in brightStreak.x..<brightStreak.maxX {
                    let offset = (y * width + x) * 4
                    pixels[offset] = 45
                    pixels[offset + 1] = 45
                    pixels[offset + 2] = 45
                    pixels[offset + 3] = 255
                }
            }
        }
        // A holder's open-end lip: narrow enough to sit under the support
        // floor, dying out within the fringe budget. The last third fades to
        // a value only the permissive threshold can see — the measured shape
        // of a real lip, and what makes the consensus window necessary.
        if let faintLip {
            let fadeStart = faintLip.y + faintLip.height * 2 / 3
            for y in faintLip.y..<faintLip.maxY {
                let value: UInt8 = y < fadeStart ? 30 : 16
                for x in faintLip.x..<faintLip.maxX {
                    let offset = (y * width + x) * 4
                    pixels[offset] = value
                    pixels[offset + 1] = value
                    pixels[offset + 2] = value
                    pixels[offset + 3] = 255
                }
            }
        }
        if let media {
            for y in media.y..<media.maxY {
                for x in media.x..<media.maxX {
                    let offset = (y * width + x) * 4
                    pixels[offset] = 40
                    pixels[offset + 1] = 120
                    pixels[offset + 2] = 220
                    pixels[offset + 3] = 255
                }
            }
        }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let provider = try #require(
            CGDataProvider(data: Data(pixels) as CFData)
        )
        let image = try #require(
            CGImage(
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
        )

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let url = directory.appendingPathComponent("fixture.png")
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
}
