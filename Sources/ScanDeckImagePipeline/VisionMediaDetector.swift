import CoreGraphics
import Foundation
import ScanDeckCore
import Vision

/// A second, independent reading of rectangular media in a scan.
///
/// The pixel detector remains the primary path because it preserves faint,
/// irregular sleeve edges well when they contrast with the scan bed. Vision is
/// useful for the opposite failure: the threshold mask fragments on a nearly
/// white card or clear sleeve even though its four geometric edges remain
/// visible as a rectangle.
struct VisionMediaDetector {
    struct Candidate: Equatable, Sendable {
        let bounds: PixelRect
        let confidence: Double
    }

    static func candidates(in image: CGImage) throws -> [Candidate] {
        let request = VNDetectRectanglesRequest()
        request.maximumObservations = 12
        request.minimumConfidence = 0.20
        request.minimumSize = 0.20
        // Trading cards, penny sleeves, and top loaders all fall between 2:3
        // and 3:4. Vision defines this as shorter side / longer side.
        request.minimumAspectRatio = 0.60
        request.maximumAspectRatio = 0.82
        request.quadratureTolerance = 16

        let handler = VNImageRequestHandler(cgImage: image, orientation: .up)
        try handler.perform([request])

        return (request.results ?? []).compactMap { observation in
            let normalized = observation.boundingBox
            let minimumX = Int(
                (normalized.minX * Double(image.width)).rounded(.down)
            )
            let maximumX = Int(
                (normalized.maxX * Double(image.width)).rounded(.up)
            )
            // Vision coordinates are y-up; PixelRect coordinates are y-down.
            let minimumY = Int(
                ((1 - normalized.maxY) * Double(image.height)).rounded(.down)
            )
            let maximumY = Int(
                ((1 - normalized.minY) * Double(image.height)).rounded(.up)
            )
            guard minimumX >= 0, minimumY >= 0,
                  maximumX <= image.width, maximumY <= image.height,
                  minimumX < maximumX, minimumY < maximumY
            else { return nil }
            return Candidate(
                bounds: PixelRect(
                    x: minimumX,
                    y: minimumY,
                    width: maximumX - minimumX,
                    height: maximumY - minimumY
                ),
                confidence: Double(observation.confidence)
            )
        }
    }

    /// Chooses one physical item, or declines when Vision appears to have found
    /// multiple cards. Returning nil is intentional: selecting one rectangle
    /// from a double-fed scan would silently discard acknowledged pixels.
    static func mediaBounds(
        in image: CGImage,
        dpi: Int,
        requiredInsets: PixelInsets,
        pairedMediaSize: MediaPixelSize? = nil
    ) throws -> PixelRect? {
        mediaBounds(
            from: try candidates(in: image),
            imageWidth: image.width,
            imageHeight: image.height,
            dpi: dpi,
            requiredInsets: requiredInsets,
            pairedMediaSize: pairedMediaSize
        )
    }

    static func mediaBounds(
        from candidates: [Candidate],
        imageWidth: Int,
        imageHeight: Int,
        dpi: Int,
        requiredInsets: PixelInsets = PixelInsets(
            top: 0,
            right: 0,
            bottom: 0,
            left: 0
        ),
        pairedMediaSize: MediaPixelSize? = nil
    ) -> PixelRect? {
        // Nominal penny-sleeve dimensions (2.625 × 3.625 in) are not a safe
        // crop floor. The fi-8170 session that motivated this fallback measures
        // intact sleeves around 2_230 × 1_595 px at 600 dpi, while Vision's
        // printed-card rectangles can stop 25–30 px inside the clear plastic.
        // A 2.70 × 3.75 in recovery floor clears that measured envelope with a
        // small allowance for glare and scanner scale error. Any surplus is real
        // captured background; using the nominal dimensions could amputate the
        // sleeve, which is the unsafe direction.
        let minimumShort = Int((2.70 * Double(dpi)).rounded())
        let minimumLong = Int((3.75 * Double(dpi)).rounded())
        let maximumShort = Int((3.25 * Double(dpi)).rounded())
        let maximumLong = Int((4.25 * Double(dpi)).rounded())

        let plausible = candidates.filter { candidate in
            let short = min(candidate.bounds.width, candidate.bounds.height)
            let long = max(candidate.bounds.width, candidate.bounds.height)
            return short >= Int(Double(minimumShort) * 0.82)
                && short <= maximumShort
                && long >= Int(Double(minimumLong) * 0.82)
                && long <= maximumLong
        }
        guard let largest = plausible.max(by: { area($0.bounds) < area($1.bounds) })
        else { return nil }

        // A larger near-square envelope commonly means two cards overlapped in
        // the feeder. It is not a media rectangle even if Vision also found one
        // constituent card inside it.
        if candidates.contains(where: { candidate in
            let short = Double(min(candidate.bounds.width, candidate.bounds.height))
            let long = Double(max(candidate.bounds.width, candidate.bounds.height))
            return area(candidate.bounds) > area(largest.bounds)
                && short / long > 0.85
        }) {
            return nil
        }

        // Nested rectangles are the sleeve, card edge, and printed frame of one
        // item. Spatially separate plausible rectangles are multiple cards and
        // must remain ambiguous.
        if plausible.contains(where: { candidate in
            candidate != largest
                && overlap(candidate.bounds, largest.bounds)
                    < 0.50 * Double(min(area(candidate.bounds), area(largest.bounds)))
        }) {
            return nil
        }

        // Vision sometimes sees the printed card edge but not a clear sleeve.
        // Grow only to the minimum penny-sleeve footprint. This can retain a
        // little extra real background around a bare card, but cannot amputate
        // the physical item—the safe direction for automatic recovery.
        let source = largest.bounds
        let landscape = source.width >= source.height
        let recoveryFloor: (width: Int, height: Int)
        if let paired = pairedMediaSize,
           paired.width > 0, paired.height > 0
        {
            // Duplex sensors do not share pixel coordinates, but they image the
            // same physical sleeve. Match the partner's orientation to this
            // observation and use its measured footprint instead of a generic
            // sleeve size. The local Vision rectangle still supplies position.
            let directDifference = abs(source.width - paired.width)
                + abs(source.height - paired.height)
            let swappedDifference = abs(source.width - paired.height)
                + abs(source.height - paired.width)
            recoveryFloor = directDifference <= swappedDifference
                ? (paired.width, paired.height)
                : (paired.height, paired.width)
        } else {
            recoveryFloor = (
                landscape ? minimumLong : minimumShort,
                landscape ? minimumShort : minimumLong
            )
        }
        let targetWidth = max(source.width, recoveryFloor.width)
        let targetHeight = max(source.height, recoveryFloor.height)
        let grown = PixelRect(
            x: source.x - (targetWidth - source.width) / 2,
            y: source.y - (targetHeight - source.height) / 2,
            width: targetWidth,
            height: targetHeight
        )
        let clipped = grown.intersection(width: imageWidth, height: imageHeight)
        guard clipped == grown else { return nil }

        // The recovery floor is deliberately larger than Vision's rectangle.
        // Centering that floor can put it a few pixels into a requested margin
        // even when the scan visibly contains enough background. Move the
        // uncertainty box—not the pixels—by at most 1 mm so the full requested
        // crop uses real captured pixels. Larger corrections remain warnings.
        let uncertainty = max(1, Int((Double(dpi) / 25.4).rounded()))
        let minimumX = requiredInsets.left
        let maximumX = imageWidth - requiredInsets.right - grown.width
        let minimumY = requiredInsets.top
        let maximumY = imageHeight - requiredInsets.bottom - grown.height
        guard minimumX <= maximumX, minimumY <= maximumY else { return grown }

        let shiftedX = min(max(grown.x, minimumX), maximumX)
        let shiftedY = min(max(grown.y, minimumY), maximumY)
        guard abs(shiftedX - grown.x) <= uncertainty,
              abs(shiftedY - grown.y) <= uncertainty
        else { return grown }

        return PixelRect(
            x: shiftedX,
            y: shiftedY,
            width: grown.width,
            height: grown.height
        )
    }

    private static func area(_ rect: PixelRect) -> Int {
        rect.width * rect.height
    }

    private static func overlap(_ first: PixelRect, _ second: PixelRect) -> Double {
        let width = max(0, min(first.maxX, second.maxX) - max(first.x, second.x))
        let height = max(0, min(first.maxY, second.maxY) - max(first.y, second.y))
        return Double(width * height)
    }
}
