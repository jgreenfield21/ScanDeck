import CoreGraphics
import Foundation
import ImageIO
import ScanDeckCore
import Testing
import UniformTypeIdentifiers
@testable import ScanDeckImagePipeline

@Suite("Real-background card cropping")
struct CardImageCropperTests {
    @Test("Orientation changes only when body pose has a decisive winner")
    func orientationRequiresClearBodyPoseEvidence() {
        #expect(CardOrientationDetector.decisivePoseRotation(scores: [
            .zero: 1,
            .clockwise90: 5,
            .clockwise180: 0,
            .clockwise270: 0.5,
        ]) == .clockwise90)
        #expect(CardOrientationDetector.decisivePoseRotation(scores: [
            .zero: 2,
            .clockwise90: 1.8,
            .clockwise180: 0,
            .clockwise270: 0,
        ]) == nil)
    }

    @Test("Orientation changes only when OCR has a decisive winner")
    func orientationRequiresClearTextEvidence() {
        #expect(CardOrientationDetector.decisiveRotation(scores: [
            .zero: 2,
            .clockwise90: 9,
            .clockwise180: 1,
            .clockwise270: 2,
        ]) == .clockwise90)
        #expect(CardOrientationDetector.decisiveRotation(scores: [
            .zero: 6,
            .clockwise90: 5.5,
            .clockwise180: 5,
            .clockwise270: 4,
        ]) == nil)
    }

    @Test("A manual crop approves the available border")
    func manualCropClearsAutomaticMarginWarnings() throws {
        let source = try makeWhiteBackgroundFixture(
            width: 400,
            height: 300,
            card: PixelRect(x: 40, y: 10, width: 320, height: 240),
            artwork: PixelRect(x: 55, y: 25, width: 290, height: 210)
        )
        let manualCrop = ManualCropRect(x: 0.1, y: 1.0 / 30.0, width: 0.8, height: 0.8)

        let analysis = try CardImageCropper().analyze(
            sourceURL: source,
            margins: .cardDefault,
            dpi: 600,
            manualCrop: manualCrop
        )

        #expect(analysis.mediaBounds == PixelRect(x: 40, y: 10, width: 320, height: 240))
        #expect(analysis.insufficientEdges.isEmpty)
        #expect(analysis.isPublishable)
        #expect(analysis.requestedCropBounds == analysis.availableCropBounds)
        #expect(analysis.requestedCropBounds.x == 0)
        #expect(analysis.requestedCropBounds.y == 0)
    }

    @Test("Vision expands an inner card rectangle to a sleeve-safe footprint")
    func visionFallbackRetainsTheSleeve() throws {
        let recovered = VisionMediaDetector.mediaBounds(
            from: [
                .init(
                    bounds: PixelRect(x: 380, y: 215, width: 2_015, height: 1_415),
                    confidence: 1
                ),
            ],
            imageWidth: 2_792,
            imageHeight: 3_808,
            dpi: 600
        )

        #expect(recovered == PixelRect(x: 263, y: 113, width: 2_250, height: 1_620))
    }

    @Test("Vision recovery absorbs only small margin-boundary uncertainty")
    func visionFallbackShiftsSmallBoundaryOverreach() {
        let candidate = VisionMediaDetector.Candidate(
            bounds: PixelRect(x: 380, y: 160, width: 2_015, height: 1_415),
            confidence: 1
        )
        let insets = PixelInsets(top: 71, right: 71, bottom: 71, left: 71)

        let recovered = VisionMediaDetector.mediaBounds(
            from: [candidate],
            imageWidth: 2_792,
            imageHeight: 1_762,
            dpi: 600,
            requiredInsets: insets
        )

        // Centered growth starts at y = 58, thirteen pixels into the requested
        // top margin. The fixed-size uncertainty box moves inward to y = 71.
        #expect(recovered == PixelRect(x: 263, y: 71, width: 2_250, height: 1_620))
    }

    @Test("Vision recovery preserves warnings for substantial missing margin")
    func visionFallbackDoesNotHideLargeBoundaryOverreach() {
        let recovered = VisionMediaDetector.mediaBounds(
            from: [
                .init(
                    bounds: PixelRect(x: 380, y: 120, width: 2_015, height: 1_415),
                    confidence: 1
                ),
            ],
            imageWidth: 2_792,
            imageHeight: 1_762,
            dpi: 600,
            requiredInsets: PixelInsets(top: 71, right: 71, bottom: 71, left: 71)
        )

        // Correcting y = 18 to y = 71 would require 53 px, beyond the 1 mm
        // Vision uncertainty allowance, so the normal margin warning remains.
        #expect(recovered == PixelRect(x: 263, y: 18, width: 2_250, height: 1_620))
    }

    @Test("Vision uses a confident duplex partner as its recovery footprint")
    func visionFallbackUsesPairedFootprint() {
        let recovered = VisionMediaDetector.mediaBounds(
            from: [
                .init(
                    bounds: PixelRect(x: 380, y: 215, width: 2_015, height: 1_415),
                    confidence: 1
                ),
            ],
            imageWidth: 2_792,
            imageHeight: 3_808,
            dpi: 600,
            pairedMediaSize: MediaPixelSize(width: 2_230, height: 1_595)
        )

        #expect(recovered == PixelRect(x: 273, y: 125, width: 2_230, height: 1_595))
    }

    @Test("Duplex footprint repairs an oversized ordinary detection without moving it")
    func pairedFootprintPreservesTheLocalCentre() {
        let local = PixelRect(x: 180, y: 40, width: 2_450, height: 1_760)

        let paired = CardImageCropper.boundsUsingPairedFootprint(
            local,
            pairedMediaSize: MediaPixelSize(width: 2_230, height: 1_595),
            imageWidth: 2_792,
            imageHeight: 3_808,
            dpi: 600
        )

        #expect(paired == PixelRect(x: 290, y: 123, width: 2_230, height: 1_595))
    }

    @Test("Duplex footprint cannot move a genuinely edge-bound card inward")
    func pairedFootprintDoesNotInventLocalBackground() {
        let local = PixelRect(x: -20, y: 100, width: 2_300, height: 1_620)

        let paired = CardImageCropper.boundsUsingPairedFootprint(
            local,
            pairedMediaSize: MediaPixelSize(width: 2_230, height: 1_595),
            imageWidth: 2_792,
            imageHeight: 3_808,
            dpi: 600
        )

        // The centre is retained. Nothing clamps the outline away from x = 0.
        #expect(paired == PixelRect(x: 15, y: 113, width: 2_230, height: 1_595))
    }

    @Test("Vision refuses two spatially separate cards")
    func visionFallbackDoesNotDiscardASecondCard() {
        let recovered = VisionMediaDetector.mediaBounds(
            from: [
                .init(
                    bounds: PixelRect(x: 357, y: 120, width: 2_064, height: 1_557),
                    confidence: 1
                ),
                .init(
                    bounds: PixelRect(x: 354, y: 1_730, width: 2_043, height: 1_435),
                    confidence: 1
                ),
            ],
            imageWidth: 2_792,
            imageHeight: 3_808,
            dpi: 600
        )

        #expect(recovered == nil)
    }

    @Test("Threshold consensus changes only the disagreeing edge")
    func thresholdConsensusIsPerEdge() {
        let primary = PixelRect(x: 100, y: 200, width: 300, height: 500)
        // Only the bottom has the large inward movement that identifies a
        // permissive-threshold tail. The other small movements model ordinary
        // edge fade and should keep their permissive positions.
        let stronger = PixelRect(x: 103, y: 204, width: 294, height: 426)

        let result = CardImageCropper.consensusBounds(
            primary: primary,
            stronger: stronger,
            window: 16
        )

        #expect(result.bounds == PixelRect(x: 100, y: 200, width: 300, height: 430))
        #expect(result.strongerEdges == [.bottom])
        #expect(result.maximumMovement == 70)
    }

    @Test("Threshold consensus can repair independent contaminated edges")
    func thresholdConsensusRepairsMultipleEdges() {
        let primary = PixelRect(x: 40, y: 50, width: 600, height: 800)
        let stronger = PixelRect(x: 80, y: 52, width: 558, height: 748)

        let result = CardImageCropper.consensusBounds(
            primary: primary,
            stronger: stronger,
            window: 16
        )

        #expect(result.bounds == PixelRect(x: 80, y: 50, width: 560, height: 750))
        #expect(result.strongerEdges == [.left, .bottom])
    }

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

    @Test("White scan beds use the enclosing card edge, not internal artwork")
    func whiteBackgroundEnclosesInternalArtwork() throws {
        let card = PixelRect(x: 120, y: 140, width: 280, height: 400)
        let artwork = PixelRect(x: 155, y: 205, width: 210, height: 270)
        let fixture = try makeWhiteBackgroundFixture(
            width: 520,
            height: 700,
            card: card,
            artwork: artwork
        )

        let analysis = try CardImageCropper().analyze(
            sourceURL: fixture,
            margins: try ScanMargins(all: 1),
            dpi: 600
        )

        #expect(abs(analysis.mediaBounds.x - card.x) <= 2)
        #expect(abs(analysis.mediaBounds.y - card.y) <= 2)
        #expect(abs(analysis.mediaBounds.width - card.width) <= 4)
        #expect(abs(analysis.mediaBounds.height - card.height) <= 4)
    }

    @Test("Isolated white-bed artifacts do not stretch the card envelope")
    func whiteBackgroundRejectsIsolatedArtifact() throws {
        let card = PixelRect(x: 120, y: 140, width: 280, height: 400)
        let fixture = try makeWhiteBackgroundFixture(
            width: 520,
            height: 700,
            card: card,
            artwork: PixelRect(x: 155, y: 205, width: 210, height: 270),
            artifact: PixelRect(x: 30, y: 30, width: 30, height: 30)
        )

        let analysis = try CardImageCropper().analyze(sourceURL: fixture)

        #expect(abs(analysis.mediaBounds.x - card.x) <= 2)
        #expect(abs(analysis.mediaBounds.y - card.y) <= 2)
        #expect(abs(analysis.mediaBounds.width - card.width) <= 4)
        #expect(abs(analysis.mediaBounds.height - card.height) <= 4)
    }

    @Test("Distant sleeve glare does not stretch a white-bed crop to the frame")
    func pennySleeveGlareStaysOutsideLocalizedSearch() throws {
        let sleeve = PixelRect(x: 296, y: 1_104, width: 2_200, height: 1_600)
        let fixture = try makeWhiteBackgroundFixture(
            width: 2_792,
            height: 3_808,
            card: sleeve,
            artwork: PixelRect(x: 520, y: 1_310, width: 1_750, height: 1_170),
            artifact: PixelRect(x: 40, y: 0, width: 32, height: 3_808)
        )

        let analysis = try CardImageCropper().analyze(
            sourceURL: fixture,
            margins: try ScanMargins(all: 3),
            dpi: 600
        )

        #expect(abs(analysis.mediaBounds.x - sleeve.x) <= 4)
        #expect(abs(analysis.mediaBounds.y - sleeve.y) <= 4)
        #expect(abs(analysis.mediaBounds.width - sleeve.width) <= 8)
        #expect(abs(analysis.mediaBounds.height - sleeve.height) <= 8)
        #expect(analysis.insufficientEdges.isEmpty)
    }

    @Test("A large remote reflection is not a second sleeve candidate")
    func remoteReflectionDoesNotMakeSleeveAmbiguous() throws {
        let sleeve = PixelRect(x: 296, y: 1_104, width: 2_200, height: 1_600)
        let fixture = try makeWhiteBackgroundFixture(
            width: 2_792,
            height: 3_808,
            card: sleeve,
            artwork: PixelRect(x: 1_120, y: 1_680, width: 500, height: 440),
            artifact: PixelRect(x: 30, y: 0, width: 80, height: 3_808)
        )

        let analysis = try CardImageCropper().analyze(
            sourceURL: fixture,
            margins: try ScanMargins(all: 3),
            dpi: 600
        )

        #expect(abs(analysis.mediaBounds.x - sleeve.x) <= 4)
        #expect(abs(analysis.mediaBounds.y - sleeve.y) <= 4)
        #expect(abs(analysis.mediaBounds.width - sleeve.width) <= 8)
        #expect(abs(analysis.mediaBounds.height - sleeve.height) <= 8)
        #expect(analysis.insufficientEdges.isEmpty)
    }

    @Test("White scan beds reject a second plausible media region")
    func whiteBackgroundRejectsAmbiguousMedia() throws {
        let fixture = try makeWhiteBackgroundFixture(
            width: 700,
            height: 700,
            card: PixelRect(x: 80, y: 180, width: 240, height: 340),
            artwork: PixelRect(x: 110, y: 230, width: 180, height: 240),
            artifact: PixelRect(x: 400, y: 220, width: 220, height: 260)
        )

        #expect(throws: CardImageCropperError.ambiguousMediaBounds) {
            try CardImageCropper().analyze(sourceURL: fixture)
        }
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

    private func makeWhiteBackgroundFixture(
        width: Int,
        height: Int,
        card: PixelRect,
        artwork: PixelRect,
        artifact: PixelRect? = nil
    ) throws -> URL {
        var pixels = [UInt8](repeating: 255, count: width * height * 4)

        func fill(_ rect: PixelRect, red: UInt8, green: UInt8, blue: UInt8) {
            for y in rect.y..<rect.maxY {
                for x in rect.x..<rect.maxX {
                    let offset = (y * width + x) * 4
                    pixels[offset] = red
                    pixels[offset + 1] = green
                    pixels[offset + 2] = blue
                    pixels[offset + 3] = 255
                }
            }
        }

        // Disconnected shadow/edge evidence around a border that is otherwise
        // indistinguishable from the white scan bed.
        let edge = 8
        fill(
            PixelRect(x: card.x, y: card.y, width: card.width, height: edge),
            red: 190,
            green: 190,
            blue: 190
        )
        fill(
            PixelRect(
                x: card.x,
                y: card.maxY - edge,
                width: card.width,
                height: edge
            ),
            red: 190,
            green: 190,
            blue: 190
        )
        fill(
            PixelRect(x: card.x, y: card.y, width: edge, height: card.height),
            red: 190,
            green: 190,
            blue: 190
        )
        fill(
            PixelRect(
                x: card.maxX - edge,
                y: card.y,
                width: edge,
                height: card.height
            ),
            red: 190,
            green: 190,
            blue: 190
        )
        fill(artwork, red: 230, green: 120, blue: 40)
        if let artifact {
            fill(artifact, red: 180, green: 180, blue: 180)
        }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let provider = try #require(CGDataProvider(data: Data(pixels) as CFData))
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
        let url = directory.appendingPathComponent("white-background-fixture.png")
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
