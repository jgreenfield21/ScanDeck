import CoreGraphics
import Foundation
import ImageIO

public enum ThumbnailDecoderError: Error, Equatable, LocalizedError, Sendable {
    case unreadableImage
    case cannotDecodeThumbnail

    public var errorDescription: String? {
        switch self {
        case .unreadableImage:
            "This scan could not be opened for preview."
        case .cannotDecodeThumbnail:
            "A preview could not be generated for this scan."
        }
    }
}

/// Decodes a bounded preview straight from disk.
///
/// `SPEC.md` section 6.3 forbids binding full-resolution masters to the review
/// grid. A 600 dpi duplex card is roughly 2,000 × 2,800 pixels per side, so a
/// hundred-card batch would hold gigabytes of decoded pixels while the operator
/// is still reviewing it. `CGImageSourceCreateThumbnailAtIndex` decodes *at* the
/// requested size rather than decoding the master and shrinking it afterwards,
/// so the full image never exists in memory.
public enum ThumbnailDecoder {
    /// The review-grid preview size from `SPEC.md` section 6.3.
    public static let defaultMaximumPixelSize = 512

    public static func decode(
        contentsOf url: URL,
        maximumPixelSize: Int = defaultMaximumPixelSize
    ) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw ThumbnailDecoderError.unreadableImage
        }

        let options: [CFString: Any] = [
            // Without this, ImageIO returns only an embedded thumbnail when the
            // file happens to carry one, and nothing otherwise.
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            // Normalises EXIF orientation. Operator rotation is applied
            // separately in review and must not be baked in here.
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, maximumPixelSize),
        ]

        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(
            source,
            0,
            options as CFDictionary
        ) else {
            throw ThumbnailDecoderError.cannotDecodeThumbnail
        }
        return thumbnail
    }
}
