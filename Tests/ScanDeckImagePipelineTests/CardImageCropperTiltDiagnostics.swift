import Foundation
import ScanDeckCore
import Testing
@testable import ScanDeckImagePipeline

/// Measures the media's tilt on every side of a real corpus and writes one CSV
/// row per side.
///
/// TICKET-039 proposes deskew and asks three questions, of which the third —
/// *how square is square enough* — has never had a number behind it. D-06's
/// "under ~0.5°" is a bounding box compared against a nominal holder size,
/// which is an upper bound that also absorbs every source of size error (see
/// `MediaTiltEstimator`). This suite replaces that inference with a
/// measurement, and it does so **offline**: the alternative the ticket
/// proposes is forty uploads of the operator's card images to a third party,
/// and this runs first because if the input tilt turns out to sit well below
/// the residual those uploads would be chasing, they are not worth spending.
///
/// It measures at both of `analyze`'s thresholds for the same reason the
/// detector consults both: agreement between them is evidence the reading is
/// of media rather than of an artefact.
///
/// Opt-in, and the images are never committed — point `SCANDECK_TILT_DIR` at a
/// directory of `_F`/`_B` pairs (symlinks are fine) and, optionally,
/// `SCANDECK_TILT_REPORT` at the CSV to write.
@Suite("Real-corpus tilt diagnostics")
struct CardImageCropperTiltDiagnostics {
    @Test(
        "Measures the tilt of every real pair and writes a diagnostics CSV",
        .enabled(
            if: ProcessInfo.processInfo.environment["SCANDECK_TILT_DIR"] != nil
        ),
        .timeLimit(.minutes(30))
    )
    func profileTilt() async throws {
        let directory = URL(
            fileURLWithPath: try #require(
                ProcessInfo.processInfo.environment["SCANDECK_TILT_DIR"]
            ),
            isDirectory: true
        )
        let reportURL = URL(
            fileURLWithPath: ProcessInfo.processInfo
                .environment["SCANDECK_TILT_REPORT"]
                ?? directory.appendingPathComponent("tilt.csv").path
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

        var jobs: [(pair: String, side: String, url: URL)] = []
        for front in fronts {
            let back = directory.appendingPathComponent(
                front.lastPathComponent.replacingOccurrences(of: "_F", with: "_B")
            )
            guard FileManager.default.fileExists(atPath: back.path) else {
                continue
            }
            let pair = front.deletingPathExtension().lastPathComponent
                .replacingOccurrences(of: "_F", with: "")
            jobs.append((pair, "F", front))
            jobs.append((pair, "B", back))
        }

        // Bounded at four, the same bound `SPEC.md` section 6.3 requires of
        // the pipeline and for the same reason: a 3232 × 4248 master is 55 MB
        // of pixels and this corpus is twenty of them.
        var rows: [String: TiltDiagnostics] = [:]
        var cursor = 0
        await withTaskGroup(of: (String, TiltDiagnostics).self) { group in
            func submit() {
                guard cursor < jobs.count else { return }
                let job = jobs[cursor]
                cursor += 1
                group.addTask {
                    (
                        "\(job.pair)|\(job.side)",
                        TiltDiagnostics(pair: job.pair, side: job.side, url: job.url)
                    )
                }
            }
            for _ in 0..<min(4, jobs.count) { submit() }
            while let (key, value) = await group.next() {
                rows[key] = value
                submit()
            }
        }

        var lines = [TiltDiagnostics.header]
        for job in jobs {
            if let row = rows["\(job.pair)|\(job.side)"] {
                lines.append(row.csvRow)
            }
        }
        try lines.joined(separator: "\n").appending("\n")
            .write(to: reportURL, atomically: true, encoding: .utf8)

        report(jobs: jobs, rows: rows)
        print("tilt diagnostics written to \(reportURL.path)")

        let failed = rows.values.filter { !$0.error.isEmpty }.map(\.label).sorted()
        #expect(failed.isEmpty, "could not measure \(failed)")
    }

    /// Runs the real publication path over the corpus and measures what came
    /// out.
    ///
    /// The synthetic fixtures in `CardImageCropperDeskewTests` are perfect
    /// rectangles on a flat background. A toploader is frosted, its corners are
    /// rounded, and one camera smears streaks off the frame edge into it — so
    /// a deskew that squares a fixture proves nothing about a card. This is the
    /// test that does, and it needs no scanner: the masters are already on
    /// disk.
    @Test(
        "Publishes the corpus and measures what is left of the tilt",
        .enabled(
            if: ProcessInfo.processInfo.environment["SCANDECK_TILT_DIR"] != nil
        ),
        .timeLimit(.minutes(30))
    )
    func deskewsTheCorpus() async throws {
        let directory = URL(
            fileURLWithPath: try #require(
                ProcessInfo.processInfo.environment["SCANDECK_TILT_DIR"]
            ),
            isDirectory: true
        )
        let staging = URL(
            fileURLWithPath: NSTemporaryDirectory(),
            isDirectory: true
        )
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: staging,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: staging) }

        let sides = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        .filter {
            $0.lastPathComponent.contains("_F")
                || $0.lastPathComponent.contains("_B")
        }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
        try #require(!sides.isEmpty)

        struct Outcome: Sendable {
            let label: String
            let applied: Double?
            let before: Double?
            let after: Double?
            let outputWidth: Int
            let outputHeight: Int
            let error: String
            var skipped = false
        }

        var outcomes: [Outcome] = []
        var cursor = 0
        await withTaskGroup(of: Outcome.self) { group in
            func submit() {
                guard cursor < sides.count else { return }
                let side = sides[cursor]
                let index = cursor
                cursor += 1
                group.addTask {
                    let cropper = CardImageCropper()
                    let label = side.deletingPathExtension().lastPathComponent
                    let output = staging
                        .appendingPathComponent("\(index).jpg")
                    do {
                        let before = try TiltReader.tilt(of: side, cropper)
                        let result = try cropper.crop(
                            sourceURL: side,
                            destinationURL: output,
                            margins: try ScanMargins(all: 3),
                            dpi: 600,
                            quality: 0.95
                        )
                        let after = try TiltReader.tilt(of: output, cropper)
                        return Outcome(
                            label: label,
                            applied: result.analysis.tiltDegrees,
                            before: before,
                            after: after,
                            outputWidth: result.analysis.outputWidth,
                            outputHeight: result.analysis.outputHeight,
                            error: ""
                        )
                    } catch let error as CardImageCropperError {
                        // A published crop is already media plus 3 mm, so
                        // asking it for another 3 mm correctly refuses. That
                        // means the file is not a master and this suite has
                        // nothing to say about it — but every *other* failure
                        // is a regression and still fails the run.
                        if case .insufficientRealBackground = error {
                            return Outcome(
                                label: label, applied: nil, before: nil,
                                after: nil, outputWidth: 0, outputHeight: 0,
                                error: "", skipped: true
                            )
                        }
                        return Outcome(
                            label: label, applied: nil, before: nil,
                            after: nil, outputWidth: 0, outputHeight: 0,
                            error: "\(error)"
                        )
                    } catch {
                        return Outcome(
                            label: label, applied: nil, before: nil,
                            after: nil, outputWidth: 0, outputHeight: 0,
                            error: "\(error)"
                        )
                    }
                }
            }
            for _ in 0..<min(4, sides.count) { submit() }
            while let outcome = await group.next() {
                outcomes.append(outcome)
                submit()
            }
        }
        outcomes.sort { $0.label < $1.label }

        print("")
        print("side                 before   applied    after   published")
        var improvements: [Double] = []
        var residuals: [Double] = []
        for outcome in outcomes {
            guard outcome.error.isEmpty else {
                print("\(outcome.label)  FAILED  \(outcome.error)")
                continue
            }
            if outcome.skipped {
                print(
                    "\(outcome.label)  skipped — already a published crop, "
                        + "not a master"
                )
                continue
            }
            let applied = outcome.applied.map {
                String(format: "%+7.3f", $0)
            } ?? "      —"
            print(
                String(
                    format: "%-20@ %+7.3f  %@  %+7.3f   %d×%d",
                    outcome.label as NSString,
                    outcome.before ?? .nan,
                    applied as NSString,
                    outcome.after ?? .nan,
                    outcome.outputWidth,
                    outcome.outputHeight
                )
            )
            if outcome.applied != nil,
               let before = outcome.before,
               let after = outcome.after
            {
                improvements.append(abs(before) - abs(after))
                residuals.append(abs(after))
            }
        }

        let corrected = residuals.count
        print("")
        print(
            String(
                format:
                    "%d of %d sides corrected; residual median %.3f°, "
                    + "worst %.3f°",
                corrected,
                outcomes.filter { !$0.skipped }.count,
                corrected == 0 ? .nan : MediaTiltEstimator.median(residuals),
                residuals.max() ?? .nan
            )
        )

        #expect(
            outcomes.allSatisfy { $0.error.isEmpty },
            "publication failed on \(outcomes.filter { !$0.error.isEmpty }.map(\.label))"
        )
        // Every correction must actually reduce the tilt. A sign error would
        // double it, and on real media that is the failure mode no eye would
        // catch on a single card.
        for (outcome, improvement) in zip(
            outcomes.filter { $0.applied != nil && $0.error.isEmpty },
            improvements
        ) {
            #expect(
                improvement > 0,
                "\(outcome.label) got worse: \(outcome.before ?? .nan)° → \(outcome.after ?? .nan)°"
            )
        }
        for residual in residuals {
            #expect(
                residual < MediaTiltEstimator.floorDegrees,
                "a corrected side still reads \(residual)°"
            )
        }
    }

    /// Prints the readable summary. The CSV is the record; this is the answer.
    private func report(
        jobs: [(pair: String, side: String, url: URL)],
        rows: [String: TiltDiagnostics]
    ) {
        print("")
        print("pair       side  angle    spread  scatter  rejected  bounds")
        var magnitudes: [Double] = []
        var pairs: [(pair: String, front: Double, back: Double)] = []
        for job in jobs {
            guard let row = rows["\(job.pair)|\(job.side)"],
                  let angle = row.permissive?.consensusDegrees
            else { continue }
            magnitudes.append(abs(angle))
            print(
                String(
                    format: "%-10@ %-5@ %+7.3f°  %6.3f°  %6.2f  %8d  %d×%d",
                    row.pair as NSString,
                    row.side as NSString,
                    angle,
                    row.permissive?.spreadDegrees ?? .nan,
                    row.permissive?.worstScatter ?? .nan,
                    row.permissive?.totalRejected ?? -1,
                    row.boundsWidth,
                    row.boundsHeight
                )
            )
        }

        for pairName in Set(jobs.map(\.pair)).sorted() {
            guard
                let front = rows["\(pairName)|F"]?.permissive?.consensusDegrees,
                let back = rows["\(pairName)|B"]?.permissive?.consensusDegrees
            else { continue }
            pairs.append((pairName, front, back))
        }

        guard !magnitudes.isEmpty else { return }
        let sorted = magnitudes.sorted()
        print("")
        print(
            String(
                format:
                    "|tilt| over %d sides: median %.3f°, p90 %.3f°, max %.3f°",
                sorted.count,
                sorted[sorted.count / 2],
                sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.9))],
                sorted[sorted.count - 1]
            )
        )
        // Two sides of one card went through the transport together, so their
        // angles are not independent samples — the back camera images the
        // reverse face, which presents the same physical tilt mirrored. Front
        // plus back near zero is that relationship holding, and it is the only
        // check on the estimator available without ground truth.
        let sums = pairs.map { abs($0.front + $0.back) }
        if let worst = sums.max() {
            print(
                String(
                    format:
                        "front+back (expect ≈0 if the back is mirrored): "
                        + "median %.3f°, worst %.3f°",
                    MediaTiltEstimator.median(sums),
                    worst
                )
            )
        }
        let differences = pairs.map { abs($0.front - $0.back) }
        if let worst = differences.max() {
            print(
                String(
                    format: "front−back: median %.3f°, worst %.3f°",
                    MediaTiltEstimator.median(differences),
                    worst
                )
            )
        }
    }
}

/// Reads the tilt of an image the way the pipeline does, for use before and
/// after publication.
enum TiltReader {
    static func tilt(of url: URL, _ cropper: CardImageCropper) throws -> Double? {
        let decoded = try cropper.decode(url)
        let estimate = cropper.estimateBackground(
            pixels: decoded.pixels,
            width: decoded.width,
            height: decoded.height
        )
        let threshold = UInt8(
            min(255, max(12, Int(estimate.residualThreshold) + 4))
        )
        let bounds = try cropper.detectBounds(
            pixels: decoded.pixels,
            width: decoded.width,
            height: decoded.height,
            background: estimate.color,
            threshold: threshold,
            dpi: 600
        )
        return MediaTiltEstimator.measure(
            pixels: decoded.pixels,
            width: decoded.width,
            height: decoded.height,
            bounds: bounds,
            background: estimate.color,
            threshold: threshold
        )
        .consensusDegrees
    }
}

/// One side's tilt reading at both of the detector's thresholds.
struct TiltDiagnostics: Sendable {
    let pair: String
    let side: String
    var error = ""
    var sourceWidth = 0
    var sourceHeight = 0
    var boundsWidth = 0
    var boundsHeight = 0
    /// Captured background between the media and each frame edge. This is the
    /// budget a rotation actually has to spend, and it is not the 376 px of
    /// overscan: the media is far smaller than the A6 window the overscan
    /// surrounds, so the real clearance is whatever the transport's
    /// registration leaves. Nothing can be claimed about rotating inside
    /// captured pixels without it.
    var clearanceLeft = 0
    var clearanceRight = 0
    var clearanceTop = 0
    var clearanceBottom = 0
    var threshold: UInt8 = 0
    var strongerThreshold: UInt8 = 0
    var permissive: MediaTiltEstimator.Reading?
    var conservative: MediaTiltEstimator.Reading?
    /// The side lengths left once the measured rotation is removed. D-06 read
    /// a 19 × 15 px excess over nominal as tilt; this is what that excess
    /// actually was.
    var unrotatedWidth = 0.0
    var unrotatedHeight = 0.0

    var label: String { "\(pair)_\(side)" }

    init(pair: String, side: String, url: URL) {
        self.pair = pair
        self.side = side
        let cropper = CardImageCropper()
        let dpi = 600
        do {
            let decoded = try cropper.decode(url)
            sourceWidth = decoded.width
            sourceHeight = decoded.height
            let estimate = cropper.estimateBackground(
                pixels: decoded.pixels,
                width: decoded.width,
                height: decoded.height
            )
            threshold = UInt8(
                min(255, max(12, Int(estimate.residualThreshold) + 4))
            )
            strongerThreshold = UInt8(min(255, max(24, Int(threshold) * 2)))

            // The bounds the shipping crop actually uses, so the tilt is
            // measured on the same rectangle that publishes rather than on a
            // second opinion about where the media is.
            let analysis = try cropper.analyze(
                decoded: decoded,
                margins: try ScanMargins(all: 2),
                dpi: dpi
            )
            boundsWidth = analysis.mediaBounds.width
            boundsHeight = analysis.mediaBounds.height
            clearanceLeft = analysis.mediaBounds.x
            clearanceTop = analysis.mediaBounds.y
            clearanceRight = decoded.width - analysis.mediaBounds.maxX
            clearanceBottom = decoded.height - analysis.mediaBounds.maxY

            permissive = MediaTiltEstimator.measure(
                pixels: decoded.pixels,
                width: decoded.width,
                height: decoded.height,
                bounds: analysis.mediaBounds,
                background: estimate.color,
                threshold: threshold
            )
            conservative = MediaTiltEstimator.measure(
                pixels: decoded.pixels,
                width: decoded.width,
                height: decoded.height,
                bounds: analysis.mediaBounds,
                background: estimate.color,
                threshold: strongerThreshold
            )
            if let angle = permissive?.consensusDegrees,
               let extent = MediaTiltEstimator.unrotatedExtent(
                   boundingWidth: Double(boundsWidth),
                   boundingHeight: Double(boundsHeight),
                   angleDegrees: angle
               )
            {
                unrotatedWidth = extent.width
                unrotatedHeight = extent.height
            }
        } catch {
            self.error = "\(error)"
        }
    }

    static let header: String = [
        "pair", "side", "error", "srcW", "srcH",
        "boundsW", "boundsH", "thr", "thr2",
        "unrotatedW", "unrotatedH",
        "clearLeft", "clearRight", "clearTop", "clearBottom",
    ].joined(separator: ",")
        + "," + readingHeader(prefix: "p")
        + "," + readingHeader(prefix: "c")

    static func readingHeader(prefix: String) -> String {
        var fields = ["consensus", "spread", "scatter", "rejected", "edges"]
        for edge in ["left", "right", "top", "bottom"] {
            fields += ["\(edge)Angle", "\(edge)Samples", "\(edge)Rejected"]
        }
        return fields.map { "\(prefix)_\($0)" }.joined(separator: ",")
    }

    var csvRow: String {
        let head = [
            pair, side, error,
            "\(sourceWidth)", "\(sourceHeight)",
            "\(boundsWidth)", "\(boundsHeight)",
            "\(threshold)", "\(strongerThreshold)",
            String(format: "%.1f", unrotatedWidth),
            String(format: "%.1f", unrotatedHeight),
            "\(clearanceLeft)", "\(clearanceRight)",
            "\(clearanceTop)", "\(clearanceBottom)",
        ].joined(separator: ",")
        return head
            + "," + Self.fields(permissive)
            + "," + Self.fields(conservative)
    }

    static func fields(_ reading: MediaTiltEstimator.Reading?) -> String {
        guard let reading else {
            return Array(
                repeating: "",
                count: readingHeader(prefix: "x").split(separator: ",").count
            ).joined(separator: ",")
        }
        var values = [
            reading.consensusDegrees.map { String(format: "%.4f", $0) } ?? "",
            reading.spreadDegrees.map { String(format: "%.4f", $0) } ?? "",
            String(format: "%.2f", reading.worstScatter),
            "\(reading.totalRejected)",
            "\(reading.edges.count)",
        ]
        for edge in [reading.left, reading.right, reading.top, reading.bottom] {
            values += [
                edge.map { String(format: "%.4f", $0.angleDegrees) } ?? "",
                edge.map { "\($0.samples)" } ?? "",
                edge.map { "\($0.rejected)" } ?? "",
            ]
        }
        return values.joined(separator: ",")
    }
}
