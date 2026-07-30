import Foundation
import ScanDeckCore
import Testing
@testable import ScanDeckImagePipeline

/// Rasterises a rectangle at a known angle so the estimator can be checked
/// against ground truth.
///
/// Every corpus number is worth exactly as much as this is: an instrument
/// nobody validated is not evidence, and the sign convention in
/// `MediaTiltEstimator.measure` is the kind of thing that is easy to get
/// backwards and impossible to notice on real captures, where every card is
/// nearly square anyway. Now that the crop acts on the sign, getting it
/// backwards would double a card's tilt instead of removing it.
struct RotatedRectangleFixture {
    let width: Int
    let height: Int
    let pixels: [UInt8]
    let bounds: PixelRect

    init(
        frameWidth: Int,
        frameHeight: Int,
        mediaWidth: Double,
        mediaHeight: Double,
        angleDegrees: Double,
        media: UInt8 = 200
    ) {
        width = frameWidth
        height = frameHeight
        var raster = [UInt8](repeating: 0, count: frameWidth * frameHeight * 4)
        let radians = angleDegrees * .pi / 180
        let cosine = cos(radians)
        let sine = sin(radians)
        let centreX = Double(frameWidth) / 2
        let centreY = Double(frameHeight) / 2
        let halfWidth = mediaWidth / 2
        let halfHeight = mediaHeight / 2

        var minimumX = frameWidth
        var minimumY = frameHeight
        var maximumX = -1
        var maximumY = -1
        for y in 0..<frameHeight {
            let offsetY = Double(y) + 0.5 - centreY
            for x in 0..<frameWidth {
                // Inverse-rotate the pixel centre into the rectangle's own
                // frame and test it against the four half-planes.
                let offsetX = Double(x) + 0.5 - centreX
                let localX = offsetX * cosine + offsetY * sine
                let localY = -offsetX * sine + offsetY * cosine
                guard abs(localX) <= halfWidth, abs(localY) <= halfHeight
                else { continue }
                let offset = (y * frameWidth + x) * 4
                raster[offset] = media
                raster[offset + 1] = media
                raster[offset + 2] = media
                raster[offset + 3] = 255
                minimumX = min(minimumX, x)
                minimumY = min(minimumY, y)
                maximumX = max(maximumX, x)
                maximumY = max(maximumY, y)
            }
        }
        pixels = raster
        bounds = PixelRect(
            x: minimumX,
            y: minimumY,
            width: maximumX - minimumX + 1,
            height: maximumY - minimumY + 1
        )
    }
}

@Suite("Media tilt estimator")
struct MediaTiltEstimatorTests {
    private static let angles: [Double] = [
        0, 0.05, -0.05, 0.1, -0.1, 0.25, -0.25, 0.5, -0.5, 1, -1, 2, -2, 3, -3,
    ]

    /// Capture geometry, not convenient geometry. A 600 dpi fi-8170 master is
    /// 3232 × 4248 with a toploader occupying about 1819 × 2415 of it, and the
    /// instrument's resolution is a function of how long the fitted edge is —
    /// so a smaller fixture would report a floor the real corpus never sees.
    static let frame = (width: 3232, height: 4248)
    static let media = (width: 1819.0, height: 2415.0)

    /// Measured against these fixtures at capture geometry, both signs:
    ///
    /// | drawn | recovered | error | edge spread |
    /// |---|---|---|---|
    /// | 0.00° | 0.0000° | 0.0000° | 0.0000° |
    /// | 0.05° | 0.0689° | 0.0189° | 0.0193° |
    /// | 0.10° | 0.0911° | 0.0089° | 0.0254° |
    /// | 0.25° | 0.2520° | 0.0020° | 0.0056° |
    /// | 0.50° | 0.5002° | 0.0002° | 0.0017° |
    /// | 1.00° | 0.9998° | 0.0002° | 0.0003° |
    /// | 3.00° | 2.9999° | 0.0001° | 0.0005° |
    ///
    /// So the floor is about **0.02°**, reached only below a tenth of a degree,
    /// where the fitted edge crosses barely two pixel rows across its whole
    /// length. That is an order below `MediaTiltEstimator.floorDegrees`, so the
    /// instrument is never the thing that limits what gets corrected.
    @Test("Recovers a known angle, with the right sign", arguments: angles)
    func recoversKnownAngle(_ angle: Double) throws {
        let fixture = RotatedRectangleFixture(
            frameWidth: Self.frame.width,
            frameHeight: Self.frame.height,
            mediaWidth: Self.media.width,
            mediaHeight: Self.media.height,
            angleDegrees: angle
        )
        let reading = MediaTiltEstimator.measure(
            pixels: fixture.pixels,
            width: fixture.width,
            height: fixture.height,
            bounds: fixture.bounds,
            background: (red: 0, green: 0, blue: 0),
            threshold: 24
        )

        #expect(reading.edges.count == 4)
        let consensus = try #require(reading.consensusDegrees)
        let spread = try #require(reading.spreadDegrees)
        #expect(
            abs(consensus - angle) < 0.03,
            "recovered \(consensus)° for a rectangle drawn at \(angle)°"
        )
        // All four edges must agree, or the reading has no error bar.
        #expect(spread < 0.03, "edges spread \(spread)° at \(angle)°")
        #expect(reading.worstScatter <= 1.0)
    }

    @Test("A streak along one edge does not move the angle")
    func survivesAStreak() throws {
        // TICKET-019's adversary, reproduced: a thin bright run entering from
        // the frame edge and lying against the media. It once stretched a
        // bounding box by 679 px, so an angle taken from a bounding box —
        // or fitted by least squares alone — would follow it too.
        let fixture = RotatedRectangleFixture(
            frameWidth: 1400,
            frameHeight: 1900,
            mediaWidth: 900,
            mediaHeight: 1200,
            angleDegrees: 1
        )
        var pixels = fixture.pixels
        let streakRows = (fixture.bounds.y + 500)..<(fixture.bounds.y + 560)
        for y in streakRows {
            for x in (fixture.bounds.x - 40)..<(fixture.bounds.x + 10) {
                let offset = (y * fixture.width + x) * 4
                pixels[offset] = 180
                pixels[offset + 1] = 180
                pixels[offset + 2] = 180
                pixels[offset + 3] = 255
            }
        }

        let reading = MediaTiltEstimator.measure(
            pixels: pixels,
            width: fixture.width,
            height: fixture.height,
            bounds: fixture.bounds,
            background: (red: 0, green: 0, blue: 0),
            threshold: 24
        )
        let left = try #require(reading.left)
        #expect(abs(left.angleDegrees - 1) < 0.03)
        #expect(abs(try #require(reading.consensusDegrees) - 1) < 0.03)
        // The streak has to be visible as rejection, not silently absorbed:
        // sixty corrupted rows went in, and the fit must say it threw them out.
        #expect(left.rejected >= 50, "rejected only \(left.rejected) of 60")
    }

    @Test("Least squares alone would have followed that streak")
    func showsWhyTheRobustStageIsThere() {
        // The guard on the guard. If plain least squares survived the streak
        // too, the two-stage fit would be unjustified complexity, and this
        // test is what would say so.
        let clean = (0..<700).map { (along: $0, across: 1000 + $0 / 57) }
        var corrupted = clean
        for index in 500..<560 {
            corrupted[index] = (along: index, across: 980)
        }
        func leastSquaresSlope(_ samples: [(along: Int, across: Int)]) -> Double {
            let count = Double(samples.count)
            let meanAlong = samples.reduce(0.0) { $0 + Double($1.along) } / count
            let meanAcross = samples.reduce(0.0) { $0 + Double($1.across) }
                / count
            var covariance = 0.0
            var variance = 0.0
            for sample in samples {
                let offset = Double(sample.along) - meanAlong
                covariance += offset * (Double(sample.across) - meanAcross)
                variance += offset * offset
            }
            return covariance / variance
        }

        let naive = atan(leastSquaresSlope(corrupted)) * 180 / .pi
        let truth = atan(leastSquaresSlope(clean)) * 180 / .pi
        let robust = MediaTiltEstimator.fit(corrupted, angleSign: 1)
        #expect(
            abs(naive - truth) > 0.1,
            "the fixture is not adversarial: least squares moved \(naive - truth)°"
        )
        #expect(abs((robust?.angleDegrees ?? .nan) - truth) < 0.03)
    }

    @Test("Undoes the rotation a bounding box implies")
    func recoversUnrotatedExtent() throws {
        let recovered = try #require(
            MediaTiltEstimator.unrotatedExtent(
                boundingWidth: 1819,
                boundingHeight: 2415,
                angleDegrees: 0.45
            )
        )
        // D-06's arithmetic, run backwards: if the 1819 × 2415 read really was
        // a 0.45°-tilted holder, the holder underneath it is ~1800 × 2400.
        #expect(abs(recovered.width - 1800) < 6)
        #expect(abs(recovered.height - 2400) < 6)

        let square = try #require(
            MediaTiltEstimator.unrotatedExtent(
                boundingWidth: 1819,
                boundingHeight: 2415,
                angleDegrees: 0
            )
        )
        #expect(square.width == 1819)
        #expect(square.height == 2415)
    }

    // MARK: - The gates that decide whether anything is resampled

    @Test("A reading below the floor is left alone")
    func doesNotCorrectBelowTheFloor() throws {
        let fixture = RotatedRectangleFixture(
            frameWidth: Self.frame.width,
            frameHeight: Self.frame.height,
            mediaWidth: Self.media.width,
            mediaHeight: Self.media.height,
            angleDegrees: 0.1
        )
        let reading = MediaTiltEstimator.measure(
            pixels: fixture.pixels,
            width: fixture.width,
            height: fixture.height,
            bounds: fixture.bounds,
            background: (red: 0, green: 0, blue: 0),
            threshold: 24
        )
        #expect(reading.isTrustworthy)
        #expect(MediaTiltEstimator.correctableAngle(from: reading) == nil)
    }

    @Test("A reading past the ceiling is discarded, not clamped")
    func doesNotCorrectPastTheCeiling() throws {
        // Clamping would rotate a misfed sheet by an angle nobody measured.
        // Discarding publishes it exactly as it publishes today.
        let fixture = RotatedRectangleFixture(
            frameWidth: Self.frame.width,
            frameHeight: Self.frame.height,
            mediaWidth: Self.media.width,
            mediaHeight: Self.media.height,
            angleDegrees: 5
        )
        let reading = MediaTiltEstimator.measure(
            pixels: fixture.pixels,
            width: fixture.width,
            height: fixture.height,
            bounds: fixture.bounds,
            background: (red: 0, green: 0, blue: 0),
            threshold: 24
        )
        #expect(abs(try #require(reading.consensusDegrees) - 5) < 0.05)
        #expect(MediaTiltEstimator.correctableAngle(from: reading) == nil)
    }

    @Test("An angle inside the window is corrected, with its sign kept")
    func correctsInsideTheWindow() throws {
        for angle in [0.54, -0.54, 1.0, -1.0] {
            let fixture = RotatedRectangleFixture(
                frameWidth: Self.frame.width,
                frameHeight: Self.frame.height,
                mediaWidth: Self.media.width,
                mediaHeight: Self.media.height,
                angleDegrees: angle
            )
            let reading = MediaTiltEstimator.measure(
                pixels: fixture.pixels,
                width: fixture.width,
                height: fixture.height,
                bounds: fixture.bounds,
                background: (red: 0, green: 0, blue: 0),
                threshold: 24
            )
            let correctable = try #require(
                MediaTiltEstimator.correctableAngle(from: reading)
            )
            #expect(abs(correctable - angle) < 0.03)
        }
    }

    @Test("A reading whose edges disagree is refused")
    func refusesAnUntrustworthyReading() {
        func fit(_ angle: Double) -> MediaTiltEstimator.EdgeFit {
            MediaTiltEstimator.EdgeFit(
                slope: tan(angle * .pi / 180),
                intercept: 0,
                angleDegrees: angle,
                samples: 900,
                rejected: 0,
                residualScatter: 0.4
            )
        }
        // The shape `sheet_000135_F` actually produced: three edges near
        // square and a fourth at 3.4°.
        let disagreeing = MediaTiltEstimator.Reading(
            left: fit(-0.200),
            right: fit(-0.097),
            top: fit(0.107),
            bottom: fit(3.442)
        )
        #expect(!disagreeing.isTrustworthy)
        #expect(MediaTiltEstimator.correctableAngle(from: disagreeing) == nil)

        // And `ticket024card6_F`: edges that agree on a line none of them
        // lies on. Spread alone would have let this through.
        let scattered = MediaTiltEstimator.Reading(
            left: MediaTiltEstimator.EdgeFit(
                slope: 0, intercept: 0, angleDegrees: 0.86, samples: 900,
                rejected: 400, residualScatter: 2.22
            ),
            right: fit(0.90),
            top: fit(0.95),
            bottom: fit(1.00)
        )
        #expect(scattered.spreadDegrees ?? 0 < 0.5)
        #expect(!scattered.isTrustworthy)
    }

    @Test("Fewer than three fitted edges is not a reading")
    func refusesTooFewEdges() {
        let fit = MediaTiltEstimator.EdgeFit(
            slope: 0, intercept: 0, angleDegrees: 0.5, samples: 900,
            rejected: 0, residualScatter: 0.3
        )
        let twoEdges = MediaTiltEstimator.Reading(
            left: fit, right: fit, top: nil, bottom: nil
        )
        #expect(twoEdges.consensusDegrees == nil)
        #expect(!twoEdges.isTrustworthy)
    }
}
