import Foundation
import ScanDeckCore

// Presentation vocabulary for the domain types that live in `ScanDeckCore`.
//
// The app deliberately does not redeclare `ScanEdge`, a side type, a rotation
// type, or a margin-state type of its own. A second copy in this module would
// shadow the domain's during name lookup and let the shipped rules drift away
// from the 1,260 lines of reducer tests that guard them.

extension OutputSide {
    /// Front before back, independent of the scanner's delivery order.
    static let displayOrder: [OutputSide] = [.front, .back]

    var title: String {
        switch self {
        case .front:
            "Front"
        case .back:
            "Back"
        }
    }

    /// The `<OutputSide>` filename token from `SPEC.md` section 3.
    var shortTitle: String {
        rawValue
    }
}

extension ScanEdge {
    var title: String {
        rawValue.capitalized
    }
}

extension QuarterTurns {
    var degrees: Double {
        Double(rawValue * 90)
    }

    /// Whether displaying at this rotation swaps the image's axes — a quarter
    /// turn shows a portrait scan landscape, so anything sized around the
    /// image must trade width for height.
    var swapsDisplayAxes: Bool {
        self == .clockwise90 || self == .clockwise270
    }
}

extension MarginAssessment {
    /// True until the crop pipeline has confirmed the real border is present.
    /// Display only — the reducer owns whether completion is actually blocked.
    var requiresAttention: Bool {
        if case .sufficient = self {
            false
        } else {
            true
        }
    }

    var insufficientEdges: Set<ScanEdge> {
        if case let .insufficient(edges) = self {
            edges
        } else {
            []
        }
    }
}

extension ScanMargins {
    var summary: String {
        let values = [
            topMillimeters,
            rightMillimeters,
            bottomMillimeters,
            leftMillimeters,
        ]
        let formatted = values.map {
            $0.formatted(.number.precision(.fractionLength(0...1)))
        }
        guard Set(values).count > 1 else {
            return "\(formatted[0]) mm all edges"
        }
        return "T \(formatted[0]) · R \(formatted[1]) · "
            + "B \(formatted[2]) · L \(formatted[3]) mm"
    }
}

extension CompletionBlocker {
    /// One operator-facing sentence naming the next corrective action.
    var operatorMessage: String {
        switch self {
        case .noActiveCards:
            "Scan at least one card."
        case let .incomplete(_, provisionalSheetNumber, missingSides):
            "Card \(Self.formatted(provisionalSheetNumber)) is missing its "
                + missingSides
                .map(\.title)
                .sorted()
                .joined(separator: " and ")
                .lowercased()
                + ". Retry or delete the card."
        case let .marginPending(_, provisionalSheetNumber, side):
            "Still checking the real border on card "
                + "\(Self.formatted(provisionalSheetNumber))'s "
                + "\(side.title.lowercased()) image."
        case let .insufficientRealMargin(_, provisionalSheetNumber, side, edges):
            "Card \(Self.formatted(provisionalSheetNumber))'s "
                + "\(side.title.lowercased()) image did not capture enough real "
                + "background on the "
                + edges.map(\.title).sorted().joined(separator: ", ").lowercased()
                + " edge. Retry the card or reduce that margin."
        case let .mismatchedPairMediaSize(_, provisionalSheetNumber, front, back):
            "Card \(Self.formatted(provisionalSheetNumber))'s front and back "
                + "captured different item sizes — \(front.width) × "
                + "\(front.height) px against \(back.width) × \(back.height) px "
                + "— so one side's crop cannot be trusted. Replace the card, or "
                + "publish it as it is."
        }
    }

    static func formatted(_ sheetNumber: UInt64) -> String {
        String(format: "%06llu", sheetNumber)
    }
}
