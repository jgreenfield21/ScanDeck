import Foundation

/// Measures how far the media sits from square inside a captured frame.
///
/// Tilt was measured here for the first time on 2026-07-30, across 24 sides
/// from three batches: **0.19°–1.00°, median 0.54°, zero-mean and random in
/// sign.** Every card comes off the ADF rotated, and because the crop is
/// axis-aligned around the bounding box of a tilted card, a requested 3.0 mm
/// border publishes as 3.0 mm at one corner and up to 4.8 mm at the far end of
/// the same edge. That non-uniformity is what deskew exists to remove.
///
/// D-06 had declined deskew on "under ~0.5°", but the figure behind that phrase
/// was a toploader detected at 1819 × 2415 px against a *nominal* 1800 × 2400 —
/// an axis-aligned bounding box compared to an assumed media size. A bounding
/// box grows for two independent reasons, rotation and the holder simply being
/// bigger than nominal, and that comparison cannot tell them apart.
///
/// It is tempting to call that an upper bound and move on. It is not one, and
/// the direction it fails in is the dangerous one: where the holder is
/// *narrower* than nominal the same arithmetic **understates** the angle. That
/// happens on five of the twenty sides measured — every side whose de-rotated
/// width lands under 1800 px — and on `sheet_000109_F` the rule infers 0.43°
/// from an 18 px excess against a measured 0.607°.
///
/// So the angle is taken from the media's own edges instead of from its
/// bounding box. Four edges are fitted independently, which is what makes a
/// reading checkable where no ground truth exists: a rigid rectangle rotates
/// all four by the same angle, so their spread is the error bar, and
/// `isTrustworthy` is what the crop consults before it resamples anything.
struct MediaTiltEstimator {
    struct EdgeThresholds: Sendable, Equatable {
        let left: UInt8
        let right: UInt8
        let top: UInt8
        let bottom: UInt8

        static func uniform(_ threshold: UInt8) -> Self {
            Self(
                left: threshold,
                right: threshold,
                top: threshold,
                bottom: threshold
            )
        }
    }

    /// One edge's fitted line.
    struct EdgeFit: Sendable, Equatable {
        /// `dx/dy` for the left and right edges, `dy/dx` for top and bottom.
        let slope: Double
        /// Where the fitted line crosses zero, so the edge can be evaluated at
        /// any row or column rather than only described by its angle.
        let intercept: Double
        /// The rotation the slope implies, signed so that a rigid rotation
        /// gives all four edges the same value.
        let angleDegrees: Double
        /// Edge crossings found along the fitted span.
        let samples: Int
        /// Crossings the robust stage threw out. On a clean toploader edge
        /// this is a handful; a large count means an artefact lay along the
        /// edge, and the angle is only as good as what survived it.
        let rejected: Int
        /// Median absolute deviation of the surviving samples about the
        /// fitted line, in pixels. A straight edge scatters well under a
        /// pixel; anything larger means the "edge" being fitted is not one.
        let residualScatter: Double
    }

    struct Reading: Sendable, Equatable {
        let left: EdgeFit?
        let right: EdgeFit?
        let top: EdgeFit?
        let bottom: EdgeFit?

        var edges: [EdgeFit] { [left, right, top, bottom].compactMap { $0 } }

        /// The angle the four edges agree on, or `nil` if fewer than three
        /// edges produced a fit. Three is the floor because two opposite
        /// edges agreeing proves only that one artefact did not move, while
        /// three spans both axes.
        var consensusDegrees: Double? {
            let angles = edges.map(\.angleDegrees)
            guard angles.count >= 3 else { return nil }
            return MediaTiltEstimator.median(angles)
        }

        /// The spread across the fitted edges. This is the reading's own error
        /// bar and it must be quoted with the angle, never separately.
        var spreadDegrees: Double? {
            let angles = edges.map(\.angleDegrees)
            guard let low = angles.min(), let high = angles.max() else {
                return nil
            }
            return high - low
        }

        var worstScatter: Double { edges.map(\.residualScatter).max() ?? 0 }
        var totalRejected: Int { edges.map(\.rejected).reduce(0, +) }

        /// The media's true rectangle, taken from where the four fitted edges
        /// actually lie.
        ///
        /// The obvious alternative — de-rotate the axis-aligned bounding box —
        /// was tried first and is wrong on real media, because it solves for a
        /// rectangle with **sharp corners**. A toploader's corners are rounded,
        /// so its bounding box is smaller than a sharp rectangle at the same
        /// angle would be, and solving the sharp equations therefore
        /// underestimates the card. Measured across five real sides, that put
        /// the published border at 63–72 px against 71 requested, where the
        /// pre-deskew crop never came in under 71. Fitted edges have no corner
        /// assumption in them at all: the distance between the left and right
        /// lines *is* the width.
        ///
        /// All four edges are required, not three. Three is enough to agree on
        /// an angle, which is what `consensusDegrees` needs; it is not enough
        /// to bound a rectangle, and guessing the fourth side from a bounding
        /// box would reintroduce exactly the error this replaced.
        func squaredRectangle(within bounds: PixelRect) -> SquaredRectangle? {
            guard let left, let right, let top, let bottom,
                  let angle = consensusDegrees
            else { return nil }
            let midX = Double(bounds.x) + Double(bounds.width) / 2
            let midY = Double(bounds.y) + Double(bounds.height) / 2
            let leftX = left.slope * midY + left.intercept
            let rightX = right.slope * midY + right.intercept
            let topY = top.slope * midX + top.intercept
            let bottomY = bottom.slope * midX + bottom.intercept

            // The crossings are the outermost media pixels, so the span is
            // inclusive of both. Projecting onto the card's own axes is a
            // cosine because the two lines of a pair are parallel to within
            // the edge spread.
            let cosine = cos(angle * .pi / 180)
            let width = (rightX - leftX + 1) * cosine
            let height = (bottomY - topY + 1) * cosine
            guard width > 0, height > 0 else { return nil }
            return SquaredRectangle(
                // The card's centre is where its two midlines cross, which is
                // also more robust than the bounding box's centre: a bounding
                // box is fixed by four extreme points, and one artefact moves
                // it.
                centreX: (leftX + rightX) / 2,
                centreY: (topY + bottomY) / 2,
                width: width,
                height: height
            )
        }

        /// Whether this reading may be acted on.
        ///
        /// Both thresholds come from the 2026-07-30 corpus run, where they
        /// separate 20 sides from 4 with nothing in between on the axis that
        /// decides each: the four sides that fail are `sheet_000072_B`,
        /// `sheet_000135_F`, `sheet_000135_B` and `ticket024card6_F`, and
        /// three of those four sit on the two pairs the corpus README already
        /// documents as blocked detections. The instrument's own confidence
        /// agreeing with what is independently known to be wrong is the reason
        /// it is trusted to gate a resample.
        ///
        /// Scatter is checked as well as spread because they fail
        /// independently: `ticket024card6_F` spreads only 0.36° while
        /// scattering 2.22 px, which is four edges agreeing on a line none of
        /// them actually lies on.
        var isTrustworthy: Bool {
            guard let spread = spreadDegrees, consensusDegrees != nil else {
                return false
            }
            return spread < MediaTiltEstimator.maximumEdgeSpreadDegrees
                && worstScatter < MediaTiltEstimator.maximumResidualScatter
        }
    }

    /// The media's true rectangle, in source pixels.
    struct SquaredRectangle: Sendable, Equatable {
        let centreX: Double
        let centreY: Double
        let width: Double
        let height: Double
    }

    static let maximumEdgeSpreadDegrees = 0.5
    static let maximumResidualScatter = 1.0

    /// Below this the image is left alone, byte-identical to what it would
    /// have been before deskew existed.
    ///
    /// This is not a taste threshold. The measured per-side error bar is 0.19°
    /// median, so an angle smaller than this is not distinguishable from
    /// square by this instrument, and correcting it would be fitting noise
    /// into every published pixel. It is also 8 px of border drift across a
    /// 2415 px card — 0.36 mm — which is the scale at which the uniformity
    /// argument for doing this at all stops applying.
    static let floorDegrees = 0.2

    /// Above this the media is not tilted, it is misfed, and the reading is
    /// discarded rather than acted on — which means the card publishes exactly
    /// as it does today rather than entering a new blocking state that the
    /// reducer has no vocabulary for.
    ///
    /// 3° is 2.7× the worst tilt ever measured (1.12°, on a side whose own
    /// error bar rejects it; the worst trusted reading is 1.00°). It is also
    /// what the frame can afford: a 3° rotation of a 1819 × 2415 holder needs
    /// ~61 px per edge on top of the 71 px margin, against a measured
    /// worst-case clearance of 296 px.
    static let ceilingDegrees = 3.0

    /// The angle to correct, or `nil` to leave the image untouched. This is
    /// the single place the floor, the ceiling and the error bar are applied,
    /// so no caller can consult one and forget another.
    static func correctableAngle(from reading: Reading) -> Double? {
        guard reading.isTrustworthy, let angle = reading.consensusDegrees else {
            return nil
        }
        let magnitude = abs(angle)
        guard magnitude >= floorDegrees, magnitude <= ceilingDegrees else {
            return nil
        }
        return angle
    }

    /// Consecutive foreground pixels required before a scan believes it has
    /// crossed the edge. One bright pixel in the background is dust or sensor
    /// noise; four in a row at 600 dpi is 0.17 mm of something.
    static let requiredRun = 4

    /// How far past the detected bound to scan, as a fraction of the
    /// perpendicular span. A quarter of the span is about 14° of excursion —
    /// far past the angle at which media has stopped being tilted and started
    /// being misfed, so the scan cannot be the thing that limits the reading.
    static func searchBand(forSpan span: Int) -> Int { max(24, span / 4) }

    /// The fraction trimmed from each end of the span before fitting.
    ///
    /// Near a corner the outermost pixel of a row belongs to the adjacent edge
    /// rather than the one being fitted, and the corner itself is rounded on
    /// every toploader. Twenty per cent of a 2415 px card is 483 px, which
    /// clears the ~126 px corner transition a 3° tilt makes with a wide margin.
    static let cornerTrimFraction = 0.2

    static func measure(
        pixels: [UInt8],
        width: Int,
        height: Int,
        bounds: PixelRect,
        background: (red: UInt8, green: UInt8, blue: UInt8),
        threshold: UInt8
    ) -> Reading {
        measure(
            pixels: pixels,
            width: width,
            height: height,
            bounds: bounds,
            background: background,
            thresholds: .uniform(threshold)
        )
    }

    static func measure(
        pixels: [UInt8],
        width: Int,
        height: Int,
        bounds: PixelRect,
        background: (red: UInt8, green: UInt8, blue: UInt8),
        thresholds: EdgeThresholds
    ) -> Reading {
        func foreground(_ x: Int, _ y: Int, threshold: UInt8) -> Bool {
            guard x >= 0, x < width, y >= 0, y < height else { return false }
            let offset = (y * width + x) * 4
            let signal = max(
                absoluteDifference(pixels[offset], background.red),
                absoluteDifference(pixels[offset + 1], background.green),
                absoluteDifference(pixels[offset + 2], background.blue)
            )
            return signal > threshold
        }

        let verticalBand = searchBand(forSpan: bounds.height)
        let horizontalBand = searchBand(forSpan: bounds.width)
        let rowTrim = Int(Double(bounds.height) * cornerTrimFraction)
        let columnTrim = Int(Double(bounds.width) * cornerTrimFraction)
        let firstRow = max(0, bounds.y + rowTrim)
        let lastRow = min(height - 1, bounds.maxY - 1 - rowTrim)
        let firstColumn = max(0, bounds.x + columnTrim)
        let lastColumn = min(width - 1, bounds.maxX - 1 - columnTrim)

        var leftSamples: [(along: Int, across: Int)] = []
        var rightSamples: [(along: Int, across: Int)] = []
        if firstRow <= lastRow {
            for y in firstRow...lastRow {
                if let x = crossing(
                    from: max(0, bounds.x - requiredRun * 2),
                    through: min(width - 1, bounds.x + verticalBand),
                    step: 1,
                    isForeground: { foreground($0, y, threshold: thresholds.left) }
                ) {
                    leftSamples.append((along: y, across: x))
                }
                if let x = crossing(
                    from: min(width - 1, bounds.maxX - 1 + requiredRun * 2),
                    through: max(0, bounds.maxX - 1 - verticalBand),
                    step: -1,
                    isForeground: { foreground($0, y, threshold: thresholds.right) }
                ) {
                    rightSamples.append((along: y, across: x))
                }
            }
        }

        var topSamples: [(along: Int, across: Int)] = []
        var bottomSamples: [(along: Int, across: Int)] = []
        if firstColumn <= lastColumn {
            for x in firstColumn...lastColumn {
                if let y = crossing(
                    from: max(0, bounds.y - requiredRun * 2),
                    through: min(height - 1, bounds.y + horizontalBand),
                    step: 1,
                    isForeground: { foreground(x, $0, threshold: thresholds.top) }
                ) {
                    topSamples.append((along: x, across: y))
                }
                if let y = crossing(
                    from: min(height - 1, bounds.maxY - 1 + requiredRun * 2),
                    through: max(0, bounds.maxY - 1 - horizontalBand),
                    step: -1,
                    isForeground: { foreground(x, $0, threshold: thresholds.bottom) }
                ) {
                    bottomSamples.append((along: x, across: y))
                }
            }
        }

        // Sign convention, derived from rotating the rectangle's corners by φ
        // in image coordinates (x right, y down): a left or right edge runs
        // from (0,0) to (−h·sinφ, h·cosφ), so `dx/dy` is `−tanφ`, while a top
        // or bottom edge runs to (w·cosφ, w·sinφ), so `dy/dx` is `+tanφ`.
        // `MediaTiltEstimatorTests` proves this on rasterised rectangles at
        // known angles rather than leaving it as arithmetic in a comment.
        return Reading(
            left: fit(leftSamples, angleSign: -1),
            right: fit(rightSamples, angleSign: -1),
            top: fit(topSamples, angleSign: 1),
            bottom: fit(bottomSamples, angleSign: 1)
        )
    }

    /// Scans along one axis and returns the start of the first run of
    /// `requiredRun` foreground pixels, or `nil` if the band holds none.
    static func crossing(
        from start: Int,
        through end: Int,
        step: Int,
        isForeground: (Int) -> Bool
    ) -> Int? {
        var index = start
        var runStart = 0
        var run = 0
        while step > 0 ? index <= end : index >= end {
            if isForeground(index) {
                if run == 0 { runStart = index }
                run += 1
                if run >= requiredRun { return runStart }
            } else {
                run = 0
            }
            index += step
        }
        return nil
    }

    /// Robust first, precise second.
    ///
    /// Neither stage can be dropped. Least squares alone lets an artefact drag
    /// the line — the adversary here is the same one `supportedBounds` was
    /// built for, a bright streak that hijacks the edge for a few dozen rows,
    /// and TICKET-019 is the record of what it does when nothing rejects it.
    /// But a median of slopes alone cannot resolve the angles that decide this
    /// question: the edge is a staircase quantised to whole pixels, so at a
    /// 700-row baseline every pairwise slope is a multiple of 0.08°, and the
    /// median of them is too.
    ///
    /// So Theil–Sen sets the line and chooses the inliers, and ordinary least
    /// squares over those inliers averages the staircase away. On the
    /// validation fixtures that is the difference between ±0.08° and ±0.01°.
    static func fit(
        _ samples: [(along: Int, across: Int)],
        angleSign: Double
    ) -> EdgeFit? {
        guard samples.count >= 64 else { return nil }
        let ordered = samples.sorted { $0.along < $1.along }
        let baseline = ordered.count / 2
        var slopes: [Double] = []
        slopes.reserveCapacity(baseline)
        for index in 0..<baseline {
            let start = ordered[index]
            let end = ordered[index + baseline]
            let run = Double(end.along - start.along)
            guard run != 0 else { continue }
            slopes.append(Double(end.across - start.across) / run)
        }
        guard !slopes.isEmpty else { return nil }

        let robustSlope = median(slopes)
        let robustIntercept = median(
            ordered.map { Double($0.across) - robustSlope * Double($0.along) }
        )
        let deviations = ordered.map {
            abs(
                Double($0.across)
                    - (robustSlope * Double($0.along) + robustIntercept)
            )
        }
        // A floor of two pixels so a clean edge, whose scatter is legitimately
        // near zero, does not reject its own staircase.
        let tolerance = max(2.0, 4 * median(deviations))
        let inliers = zip(ordered, deviations)
            .filter { $0.1 <= tolerance }
            .map(\.0)
        guard inliers.count >= 32 else { return nil }

        let count = Double(inliers.count)
        let meanAlong = inliers.reduce(0.0) { $0 + Double($1.along) } / count
        let meanAcross = inliers.reduce(0.0) { $0 + Double($1.across) } / count
        var covariance = 0.0
        var variance = 0.0
        for sample in inliers {
            let alongOffset = Double(sample.along) - meanAlong
            covariance += alongOffset * (Double(sample.across) - meanAcross)
            variance += alongOffset * alongOffset
        }
        guard variance > 0 else { return nil }
        let slope = covariance / variance
        let intercept = meanAcross - slope * meanAlong
        let residuals = inliers.map {
            abs(Double($0.across) - (slope * Double($0.along) + intercept))
        }

        return EdgeFit(
            slope: slope,
            intercept: intercept,
            angleDegrees: angleSign * atan(slope) * 180 / .pi,
            samples: ordered.count,
            rejected: ordered.count - inliers.count,
            residualScatter: median(residuals)
        )
    }

    /// The unrotated side lengths implied by an axis-aligned bounding box and
    /// a measured angle — the true footprint of the media, which is what a
    /// squared crop has to be sized from.
    static func unrotatedExtent(
        boundingWidth: Double,
        boundingHeight: Double,
        angleDegrees: Double
    ) -> (width: Double, height: Double)? {
        let radians = abs(angleDegrees) * .pi / 180
        let cosine = cos(radians)
        let sine = sin(radians)
        let determinant = cosine * cosine - sine * sine
        guard abs(determinant) > 1e-9 else { return nil }
        let width = (cosine * boundingWidth - sine * boundingHeight)
            / determinant
        let height = (cosine * boundingHeight - sine * boundingWidth)
            / determinant
        guard width > 0, height > 0 else { return nil }
        return (width: width, height: height)
    }

    static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2)
            ? (sorted[middle - 1] + sorted[middle]) / 2
            : sorted[middle]
    }

    private static func absoluteDifference(_ first: UInt8, _ second: UInt8)
        -> UInt8
    {
        first >= second ? first - second : second - first
    }
}
