import Foundation
import ScanDeckCore
import Testing
@testable import ScanDeckImagePipeline

/// Measures the shipping detector across a whole directory of real captures
/// and writes one CSV row per side, carrying the intermediates the final rect
/// is derived from.
///
/// This exists because every threshold in `CardImageCropper` was chosen from a
/// handful of pairs, and TICKET-027 asks a question no single pair can answer:
/// which of the two threshold reads is wrong on the pairs that disagree, and
/// by what mechanism. A suite that can only see `mediaBounds` can report that a
/// pair disagrees; it cannot say whether the fringe pass over-extended one side
/// or the support floor amputated the other, which are opposite fixes.
///
/// Opt-in, and the images are never committed — point `SCANDECK_CORPUS_DIR` at
/// a directory of `_F`/`_B` pairs (symlinks are fine) and
/// `SCANDECK_CORPUS_REPORT` at the CSV to write.
@Suite("Real-corpus detector diagnostics")
struct CardImageCropperCorpusDiagnostics {
    @Test(
        "Profiles every real pair and writes a diagnostics CSV",
        .enabled(
            if: ProcessInfo.processInfo
                .environment["SCANDECK_CORPUS_DIR"] != nil
        ),
        .timeLimit(.minutes(30))
    )
    func profileCorpus() async throws {
        let directory = URL(
            fileURLWithPath: try #require(
                ProcessInfo.processInfo.environment["SCANDECK_CORPUS_DIR"]
            ),
            isDirectory: true
        )
        let reportURL = URL(
            fileURLWithPath: ProcessInfo.processInfo
                .environment["SCANDECK_CORPUS_REPORT"]
                ?? directory.appendingPathComponent("diagnostics.csv").path
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

        // Bounded at four, the measured knee for full-resolution decodes, and
        // the same bound `SPEC.md` section 6.3 requires of the pipeline.
        var rows: [String: SideDiagnostics] = [:]
        var cursor = 0
        await withTaskGroup(of: (String, SideDiagnostics).self) { group in
            func submit() {
                guard cursor < jobs.count else { return }
                let job = jobs[cursor]
                cursor += 1
                group.addTask {
                    (
                        "\(job.pair)|\(job.side)",
                        SideDiagnostics(pair: job.pair, side: job.side, url: job.url)
                    )
                }
            }
            for _ in 0..<min(4, jobs.count) { submit() }
            while let (key, value) = await group.next() {
                rows[key] = value
                submit()
            }
        }

        var lines = [SideDiagnostics.header]
        for job in jobs {
            if let row = rows["\(job.pair)|\(job.side)"] {
                lines.append(row.csvRow)
            }
        }
        try lines.joined(separator: "\n").appending("\n")
            .write(to: reportURL, atomically: true, encoding: .utf8)

        // The instrumented replica must reproduce the shipping detector
        // exactly, or every number in the report describes a different
        // algorithm than the one that ships.
        let drifted = rows.values
            .filter(\.replicaDisagrees)
            .map(\.label)
            .sorted()
        #expect(
            drifted.isEmpty,
            "instrumented replica drifted from detectBounds on \(drifted)"
        )
        print("corpus diagnostics written to \(reportURL.path)")
    }
}

/// One side's full detector trace.
struct SideDiagnostics: Sendable {
    let pair: String
    let side: String
    var error: String = ""
    var sourceWidth = 0
    var sourceHeight = 0
    var background = (red: UInt8(0), green: UInt8(0), blue: UInt8(0))
    var residualThreshold: UInt8 = 0
    var threshold: UInt8 = 0
    var strongerThreshold: UInt8 = 0
    var permissive: DetectionTrace?
    var conservative: DetectionTrace?
    var chosen: PixelRect?
    var chosenRead = ""
    var confidence = 0.0
    var maximumMovement = -1
    var replicaDisagrees = false

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
            background = estimate.color
            residualThreshold = estimate.residualThreshold
            threshold = UInt8(
                min(255, max(12, Int(estimate.residualThreshold) + 4))
            )
            strongerThreshold = UInt8(min(255, max(24, Int(threshold) * 2)))

            permissive = DetectionTrace(
                cropper: cropper,
                decoded: decoded,
                background: estimate.color,
                threshold: threshold,
                dpi: dpi
            )
            conservative = DetectionTrace(
                cropper: cropper,
                decoded: decoded,
                background: estimate.color,
                threshold: strongerThreshold,
                dpi: dpi
            )
            replicaDisagrees = (permissive?.replicaDisagrees ?? false)
                || (conservative?.replicaDisagrees ?? false)

            let analysis = try cropper.analyze(
                sourceURL: url,
                margins: try ScanMargins(all: 2),
                dpi: dpi
            )
            chosen = analysis.mediaBounds
            confidence = analysis.confidence
            if let primary = permissive?.rect {
                if let stronger = conservative?.rect {
                    maximumMovement = [
                        abs(primary.x - stronger.x),
                        abs(primary.y - stronger.y),
                        abs(primary.maxX - stronger.maxX),
                        abs(primary.maxY - stronger.maxY),
                    ].max() ?? 0
                }
                chosenRead = analysis.mediaBounds == primary
                    ? "permissive"
                    : "conservative"
            }
        } catch {
            self.error = "\(error)"
        }
    }

    static let header: String = [
        "pair", "side", "error", "srcW", "srcH",
        "bgR", "bgG", "bgB", "residual", "thr", "thr2",
        "movement", "chosenRead", "confidence",
        "chosenX", "chosenY", "chosenW", "chosenH",
    ].joined(separator: ",")
        + "," + DetectionTrace.header(prefix: "p")
        + "," + DetectionTrace.header(prefix: "c")

    var csvRow: String {
        let head = [
            pair, side, error,
            "\(sourceWidth)", "\(sourceHeight)",
            "\(background.red)", "\(background.green)", "\(background.blue)",
            "\(residualThreshold)", "\(threshold)", "\(strongerThreshold)",
            "\(maximumMovement)", chosenRead,
            String(format: "%.3f", confidence),
            "\(chosen?.x ?? -1)", "\(chosen?.y ?? -1)",
            "\(chosen?.width ?? -1)", "\(chosen?.height ?? -1)",
        ].joined(separator: ",")
        return head
            + "," + (permissive?.csvFields ?? DetectionTrace.emptyFields)
            + "," + (conservative?.csvFields ?? DetectionTrace.emptyFields)
    }
}

/// One threshold's read, decomposed into the stages that produce it.
struct DetectionTrace: Sendable {
    var error = ""
    var rect: PixelRect?
    var componentRect: PixelRect?
    var componentArea = 0
    var runnerUpArea = 0
    var rowFloor = 0
    var columnFloor = 0
    var bridgeGap = 0
    var fringeBudget = 0
    /// Mask-block bounds after the floor-supported walk only.
    var floorBounds: PixelRect?
    /// Mask-block bounds after the faint-fringe pass.
    var supportedBounds: PixelRect?
    var peakRowOccupancy = 0
    var peakColumnOccupancy = 0
    /// Occupancy immediately outside each floor bound, in mask blocks — the
    /// evidence the fringe pass acts on.
    var fringeGainTop = 0
    var fringeGainBottom = 0
    var fringeGainLeft = 0
    var fringeGainRight = 0
    /// The occupancy the fringe pass walks over, outward from each floor
    /// bound. This is the evidence a genuine open-end lip and a false tail
    /// have to be told apart by, so it is recorded raw rather than summarised.
    var profileTop: [Int] = []
    var profileBottom: [Int] = []
    var profileLeft: [Int] = []
    var profileRight: [Int] = []
    var replicaDisagrees = false

    init(
        cropper: CardImageCropper,
        decoded: CardImageCropper.DecodedImage,
        background: (red: UInt8, green: UInt8, blue: UInt8),
        threshold: UInt8,
        dpi: Int
    ) {
        // The shipping read, taken first so the replica below can be checked
        // against it rather than trusted.
        let shipped = try? cropper.detectBounds(
            pixels: decoded.pixels,
            width: decoded.width,
            height: decoded.height,
            background: background,
            threshold: threshold,
            dpi: dpi
        )
        rect = shipped

        let scale = 2
        let width = decoded.width
        let height = decoded.height
        let maskWidth = (width + scale - 1) / scale
        let maskHeight = (height + scale - 1) / scale
        var mask = [UInt8](repeating: 0, count: maskWidth * maskHeight)
        decoded.pixels.withUnsafeBufferPointer { pixels in
            for blockY in 0..<maskHeight {
                let startY = blockY * scale
                let endY = min(height, startY + scale)
                for blockX in 0..<maskWidth {
                    let startX = blockX * scale
                    let endX = min(width, startX + scale)
                    var foreground = false
                    for y in startY..<endY {
                        for x in startX..<endX {
                            let offset = (y * width + x) * 4
                            let signal = max(
                                cropper.absoluteDifference(
                                    pixels[offset],
                                    background.red
                                ),
                                cropper.absoluteDifference(
                                    pixels[offset + 1],
                                    background.green
                                ),
                                cropper.absoluteDifference(
                                    pixels[offset + 2],
                                    background.blue
                                )
                            )
                            if signal > threshold {
                                foreground = true
                                break
                            }
                        }
                        if foreground { break }
                    }
                    mask[blockY * maskWidth + blockX] = foreground ? 1 : 0
                }
            }
        }
        mask = cropper.close3x3(mask, width: maskWidth, height: maskHeight)
        let labeled = cropper.connectedComponents(
            mask,
            width: maskWidth,
            height: maskHeight
        )
        let minimumArea = max(32, maskWidth * maskHeight / 200)
        let viable = labeled.components.enumerated()
            .filter { $0.element.area >= minimumArea }
            .sorted { $0.element.area > $1.element.area }
        guard let dominant = viable.first else {
            error = "noMediaDetected"
            replicaDisagrees = shipped != nil
            return
        }
        componentRect = dominant.element.rect
        componentArea = dominant.element.area
        runnerUpArea = viable.count > 1 ? viable[1].element.area : 0

        var rowOccupancy = [Int](repeating: 0, count: maskHeight)
        var columnOccupancy = [Int](repeating: 0, count: maskWidth)
        let target = Int32(dominant.offset)
        for y in 0..<maskHeight {
            let rowStart = y * maskWidth
            for x in 0..<maskWidth where labeled.labels[rowStart + x] == target {
                rowOccupancy[y] += 1
                columnOccupancy[x] += 1
            }
        }
        peakRowOccupancy = rowOccupancy.max() ?? 0
        peakColumnOccupancy = columnOccupancy.max() ?? 0

        rowFloor = max(2, (8 * dpi + 300) / 600)
        columnFloor = max(2, (4 * dpi + 300) / 600)
        bridgeGap = max(4, (8 * dpi + 300) / 600)
        // The dropped fringe pass's budget, kept as the probe depth for the
        // profile columns so the decision to drop it stays re-checkable
        // against media the corpus does not hold.
        fringeBudget = max(8, (48 * dpi + 300) / 600)

        guard let anchorRow = rowOccupancy.indices.max(by: {
                  rowOccupancy[$0] < rowOccupancy[$1]
              }),
              let anchorColumn = columnOccupancy.indices.max(by: {
                  columnOccupancy[$0] < columnOccupancy[$1]
              }),
              rowOccupancy[anchorRow] >= rowFloor,
              columnOccupancy[anchorColumn] >= columnFloor
        else {
            // The shipping path falls back to the component's bounding box.
            error = "unsupportedProfile"
            return
        }

        let rowsTop = walk(rowOccupancy, from: anchorRow, step: -1)
        let rowsBottom = walk(rowOccupancy, from: anchorRow, step: 1)
        let columnsLeft = walk(
            columnOccupancy,
            from: anchorColumn,
            step: -1,
            floor: columnFloor
        )
        let columnsRight = walk(
            columnOccupancy,
            from: anchorColumn,
            step: 1,
            floor: columnFloor
        )
        floorBounds = PixelRect(
            x: columnsLeft.floor,
            y: rowsTop.floor,
            width: columnsRight.floor - columnsLeft.floor + 1,
            height: rowsBottom.floor - rowsTop.floor + 1
        )
        // The shipping detector stops at the floor bound. The fringe columns
        // below record what a faint-fringe pass *would* have added, which is
        // how the decision to drop it stays re-checkable against new media.
        supportedBounds = floorBounds
        fringeGainTop = rowsTop.floor - rowsTop.fringe
        fringeGainBottom = rowsBottom.fringe - rowsBottom.floor
        fringeGainLeft = columnsLeft.floor - columnsLeft.fringe
        fringeGainRight = columnsRight.fringe - columnsRight.floor

        func profile(_ occupancy: [Int], from bound: Int, step: Int) -> [Int] {
            var values: [Int] = []
            var index = bound + step
            while index >= 0, index < occupancy.count,
                  values.count < fringeBudget + bridgeGap + 4
            {
                values.append(occupancy[index])
                index += step
            }
            return values
        }
        profileTop = profile(rowOccupancy, from: rowsTop.floor, step: -1)
        profileBottom = profile(rowOccupancy, from: rowsBottom.floor, step: 1)
        profileLeft = profile(columnOccupancy, from: columnsLeft.floor, step: -1)
        profileRight = profile(
            columnOccupancy,
            from: columnsRight.floor,
            step: 1
        )

        guard let supported = supportedBounds else { return }
        let coarse = PixelRect(
            x: supported.x * scale,
            y: supported.y * scale,
            width: min(width, supported.maxX * scale) - supported.x * scale,
            height: min(height, supported.maxY * scale) - supported.y * scale
        )
        let refined = cropper.refine(
            coarse: coarse,
            pixels: decoded.pixels,
            width: width,
            height: height,
            background: background,
            threshold: threshold
        )
        // `detectBounds` may still throw on its area and centre guards, in
        // which case the shipping read is nil and the replica is not expected
        // to match it.
        if let shipped {
            replicaDisagrees = shipped != refined
        }
    }

    /// Mirrors `extendSupport`'s two stages, kept separate so the fringe gain
    /// is visible instead of folded into the bound.
    private func walk(
        _ occupancy: [Int],
        from anchor: Int,
        step: Int,
        floor: Int? = nil
    ) -> (floor: Int, fringe: Int) {
        let floorValue = floor ?? rowFloor
        var bound = anchor
        var gap = 0
        var index = anchor + step
        while index >= 0, index < occupancy.count, gap <= bridgeGap {
            if occupancy[index] >= floorValue {
                bound = index
                gap = 0
            } else {
                gap += 1
            }
            index += step
        }

        var fringeCandidate: Int?
        var zeroRun = 0
        var probed = 0
        index = bound + step
        while index >= 0, index < occupancy.count, probed < fringeBudget {
            if occupancy[index] > 0 {
                fringeCandidate = index
                zeroRun = 0
            } else {
                zeroRun += 1
                if zeroRun > bridgeGap {
                    return (bound, fringeCandidate ?? bound)
                }
            }
            probed += 1
            index += step
        }
        return (bound, bound)
    }

    static func header(prefix: String) -> String {
        [
            "err", "x", "y", "w", "h",
            "compX", "compY", "compW", "compH", "compArea", "runnerUp",
            "floorX", "floorY", "floorW", "floorH",
            "supX", "supY", "supW", "supH",
            "fringeTop", "fringeBottom", "fringeLeft", "fringeRight",
            "peakRow", "peakCol", "rowFloor", "colFloor", "budget",
            "profTop", "profBottom", "profLeft", "profRight",
        ]
        .map { "\(prefix)_\($0)" }
        .joined(separator: ",")
    }

    static let emptyFields = String(
        repeating: ",",
        count: header(prefix: "x").split(separator: ",").count - 1
    )

    var csvFields: String {
        [
            error,
            "\(rect?.x ?? -1)", "\(rect?.y ?? -1)",
            "\(rect?.width ?? -1)", "\(rect?.height ?? -1)",
            "\(componentRect?.x ?? -1)", "\(componentRect?.y ?? -1)",
            "\(componentRect?.width ?? -1)", "\(componentRect?.height ?? -1)",
            "\(componentArea)", "\(runnerUpArea)",
            "\(floorBounds?.x ?? -1)", "\(floorBounds?.y ?? -1)",
            "\(floorBounds?.width ?? -1)", "\(floorBounds?.height ?? -1)",
            "\(supportedBounds?.x ?? -1)", "\(supportedBounds?.y ?? -1)",
            "\(supportedBounds?.width ?? -1)", "\(supportedBounds?.height ?? -1)",
            "\(fringeGainTop)", "\(fringeGainBottom)",
            "\(fringeGainLeft)", "\(fringeGainRight)",
            "\(peakRowOccupancy)", "\(peakColumnOccupancy)",
            "\(rowFloor)", "\(columnFloor)", "\(fringeBudget)",
            profileTop.map(String.init).joined(separator: ";"),
            profileBottom.map(String.init).joined(separator: ";"),
            profileLeft.map(String.init).joined(separator: ";"),
            profileRight.map(String.init).joined(separator: ";"),
        ].joined(separator: ",")
    }
}
