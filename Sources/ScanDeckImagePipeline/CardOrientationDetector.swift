import CoreGraphics
import Foundation
import ImageIO
import ScanDeckCore
import Vision

/// Uses a person's body pose, then face direction, to choose an upright
/// presentation without changing the master. Ambiguous cards return nil.
public struct CardOrientationDetector: Sendable {
    public init() {}

    public func suggestedRotation(
        for sourceURL: URL,
        cropBounds: PixelRect
    ) -> QuarterTurns? {
        guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return nil }
        return suggestedRotation(for: image, cropBounds: cropBounds)
    }

    public func suggestedRotation(
        for image: CGImage,
        cropBounds: PixelRect
    ) -> QuarterTurns? {
        guard let cropped = image.cropping(to: CGRect(
            x: cropBounds.x,
            y: cropBounds.y,
            width: cropBounds.width,
            height: cropBounds.height
        )) else { return nil }

        if let poseRotation = Self.decisivePoseRotation(
            scores: poseRotationScores(for: cropped)
        ) {
            return poseRotation
        }
        if let faceRotation = Self.decisiveFaceRotation(
            scores: faceRotationScores(for: cropped)
        ) {
            return faceRotation
        }
        return nil
    }

    func poseRotationScores(for image: CGImage) -> [QuarterTurns: Double] {
        let image = downsample(image, maximumDimension: 1_200)
        return Dictionary(uniqueKeysWithValues: QuarterTurns.allCases.map { turn in
            let request = VNDetectHumanBodyPoseRequest()
            do {
                try VNImageRequestHandler(
                    cgImage: image,
                    orientation: orientation(for: turn),
                    options: [:]
                ).perform([request])
            } catch {
                return (turn, 0)
            }
            let score = (request.results ?? []).reduce(0.0) { total, observation in
                total + poseScore(observation)
            }
            return (turn, score)
        })
    }

    private func poseScore(_ observation: VNHumanBodyPoseObservation) -> Double {
        let points = (try? observation.recognizedPoints(.all)) ?? [:]
        func point(_ name: VNHumanBodyPoseObservation.JointName) -> VNRecognizedPoint? {
            guard let point = points[name], point.confidence >= 0.2 else { return nil }
            return point
        }
        func averageY(_ names: [VNHumanBodyPoseObservation.JointName]) -> Double? {
            let values = names.compactMap { point($0) }.map { Double($0.location.y) }
            guard !values.isEmpty else { return nil }
            return values.reduce(0, +) / Double(values.count)
        }

        let head = averageY([.nose, .neck])
        let shoulders = averageY([.leftShoulder, .rightShoulder, .neck])
        let hips = averageY([.leftHip, .rightHip, .root])
        let feet = averageY([.leftKnee, .rightKnee, .leftAnkle, .rightAnkle])
        var score = Double(points.values.filter { $0.confidence >= 0.2 }.count) * 0.12
        if let head, let hips, head > hips { score += 1 + (head - hips) * 2 }
        if let shoulders, let hips, shoulders > hips { score += 0.8 + (shoulders - hips) }
        if let hips, let feet, hips > feet { score += 0.8 + (hips - feet) }
        return score
    }

    static func decisivePoseRotation(scores: [QuarterTurns: Double]) -> QuarterTurns? {
        let ranked = scores.sorted { $0.value > $1.value }
        guard let best = ranked.first, ranked.count > 1 else { return nil }
        let runnerUp = ranked[1].value
        guard best.value >= 1.5, best.value - runnerUp >= 0.35 else { return nil }
        return best.key
    }

    private func faceRotationScores(for image: CGImage) -> [QuarterTurns: Double] {
        Dictionary(uniqueKeysWithValues: QuarterTurns.allCases.map { turn in
            let request = VNDetectFaceRectanglesRequest()
            do {
                try VNImageRequestHandler(
                    cgImage: image,
                    orientation: orientation(for: turn),
                    options: [:]
                ).perform([request])
            } catch {
                return (turn, 0)
            }
            let score = (request.results ?? []).reduce(0.0) { total, face in
                let area = Double(face.boundingBox.width * face.boundingBox.height)
                return total + Double(face.confidence) * (1 + min(area * 8, 2))
            }
            return (turn, score)
        })
    }

    static func decisiveFaceRotation(scores: [QuarterTurns: Double]) -> QuarterTurns? {
        let ranked = scores.sorted { $0.value > $1.value }
        guard let best = ranked.first, ranked.count > 1 else { return nil }
        let runnerUp = ranked[1].value
        guard best.value >= 0.7, best.value - runnerUp >= 0.25 else { return nil }
        return best.key
    }

    func rotationScores(for image: CGImage) -> [QuarterTurns: Double] {
        let image = downsample(image, maximumDimension: 1_000)
        return Dictionary(uniqueKeysWithValues: QuarterTurns.allCases.map { turn in
            (turn, score(image, orientation: orientation(for: turn)))
        })
    }

    static func decisiveRotation(scores: [QuarterTurns: Double]) -> QuarterTurns? {
        let ranked = scores.sorted { $0.value > $1.value }
        guard let best = ranked.first, ranked.count > 1 else { return nil }
        let runnerUp = ranked[1].value
        guard best.1 >= 4,
              best.1 - runnerUp >= 1.5,
              best.1 >= runnerUp * 1.3
        else { return nil }
        return best.key
    }

    private func downsample(_ image: CGImage, maximumDimension: Int) -> CGImage {
        let largest = max(image.width, image.height)
        guard largest > maximumDimension else { return image }
        let scale = Double(maximumDimension) / Double(largest)
        let width = max(1, Int((Double(image.width) * scale).rounded()))
        let height = max(1, Int((Double(image.height) * scale).rounded()))
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: image.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        ) else { return image }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage() ?? image
    }

    private func score(_ image: CGImage, orientation: CGImagePropertyOrientation) -> Double {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .fast
        request.usesLanguageCorrection = false
        request.recognitionLanguages = ["en-US"]
        request.minimumTextHeight = 0.012

        do {
            try VNImageRequestHandler(
                cgImage: image,
                orientation: orientation,
                options: [:]
            ).perform([request])
        } catch {
            return 0
        }

        return (request.results ?? []).reduce(0) { total, observation in
            guard let candidate = observation.topCandidates(1).first else { return total }
            let usefulCharacters = candidate.string.unicodeScalars.filter {
                CharacterSet.alphanumerics.contains($0)
            }.count
            guard usefulCharacters >= 2 else { return total }
            let lengthWeight = min(Double(usefulCharacters), 24) / 6
            return total + Double(candidate.confidence) * (1 + lengthWeight)
        }
    }

    private func orientation(for turn: QuarterTurns) -> CGImagePropertyOrientation {
        switch turn {
        case .zero: .up
        case .clockwise90: .right
        case .clockwise180: .down
        case .clockwise270: .left
        }
    }
}
