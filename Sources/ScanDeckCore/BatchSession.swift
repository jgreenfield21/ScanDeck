import Foundation

public struct BatchID: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: UUID

    public init(rawValue: UUID) {
        self.rawValue = rawValue
    }
}

public struct JobID: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: UUID

    public init(rawValue: UUID) {
        self.rawValue = rawValue
    }
}

public struct CardID: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: UUID

    public init(rawValue: UUID) {
        self.rawValue = rawValue
    }
}

public struct MasterID: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: UUID

    public init(rawValue: UUID) {
        self.rawValue = rawValue
    }
}

public struct ScanPassID: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: UUID

    public init(rawValue: UUID) {
        self.rawValue = rawValue
    }
}

public struct ReleaseAttemptID: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: UUID

    public init(rawValue: UUID) {
        self.rawValue = rawValue
    }
}

public enum ScanEdge: String, Codable, CaseIterable, Hashable, Sendable {
    case top
    case right
    case bottom
    case left
}

public enum QuarterTurns: Int, Codable, CaseIterable, Sendable {
    case zero = 0
    case clockwise90 = 1
    case clockwise180 = 2
    case clockwise270 = 3

    fileprivate func applying(_ direction: RotationDirection) -> QuarterTurns {
        let delta = switch direction {
        case .clockwise:
            1
        case .counterclockwise:
            3
        }
        return QuarterTurns(rawValue: (rawValue + delta) % 4)!
    }
}

public enum RotationDirection: Sendable {
    case clockwise
    case counterclockwise
}

/// The pixel footprint of the physical item one side captured, measured on the
/// master before any rotation is applied.
///
/// Front and back image the same physical object, so their footprints must
/// agree. Disagreement means one side's detection was wrong — the defect class
/// that motivated this measured 679 px of scanner streak inflating one side of
/// a real toploader pass — and a batch must never silently publish a pair
/// whose two files show different-sized items.
public struct MediaPixelSize: Codable, Equatable, Hashable, Sendable {
    public let width: Int
    public let height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }

    /// How far the two sides of one card may disagree, in pixels, before the
    /// pair is worth the operator's attention.
    ///
    /// 24 px is 1 mm at 600 dpi. Measured across 186 real pairs with the
    /// detector TICKET-027 landed, 183 agree inside it and the largest of
    /// them sits at 24 exactly. The comparison holds in master coordinates:
    /// the capture rotation (180° on the fi-8170) and any operator
    /// quarter-turns change how a side is displayed, never the footprint the
    /// scanner measured.
    public static let pairAgreementTolerancePixels = 24

    /// How far they may disagree before the pair refuses the batch.
    ///
    /// 140 px is 5.9 mm at 600 dpi, and it is a decision rather than a
    /// measurement — the operator's, taken 2026-07-29 with the distribution
    /// in front of them (TICKET-033 / D-09). What the measurement supplies is
    /// the shape of the choice: after TICKET-027 the same 186 pairs leave
    /// **nothing at all between 24 px and 95 px**, so the three survivors are
    /// 95, 132 and 383. A line at 140 releases the two whose extra extent is
    /// a faint artefact on one side — 4.0 mm and 5.6 mm of surplus border on
    /// an image that still contains the whole card — and holds the one where
    /// both thresholds agree the back images something 16 mm longer than the
    /// front, which no amount of margin explains.
    ///
    /// This is the number to revisit if the detector changes again, and it
    /// should be revisited by re-measuring rather than by argument. The
    /// masters that produced those three are kept in
    /// `TestAssets/carlsoboxone-ten/`.
    public static let pairBlockingDisagreementPixels = 140

    /// The larger of the two per-axis differences, which is what both
    /// thresholds are compared against.
    public func disagreementPixels(from other: MediaPixelSize) -> Int {
        max(abs(width - other.width), abs(height - other.height))
    }

    public func agrees(with other: MediaPixelSize) -> Bool {
        disagreementPixels(from: other) <= Self.pairAgreementTolerancePixels
    }

    /// Whether the disagreement is wide enough to refuse the batch over.
    public func blocksCompletion(against other: MediaPixelSize) -> Bool {
        disagreementPixels(from: other)
            > Self.pairBlockingDisagreementPixels
    }
}

/// A card whose two sides measured different item sizes by more than the
/// agreement tolerance, but not by enough to refuse the batch.
///
/// It exists because relaxing the gate must not make the check silent. The
/// pair cross-check is still the only thing in ScanDeck that has ever noticed
/// a bad crop — both sides read `.sufficient` on their own terms, so no row
/// and no per-side badge can see it — and dropping it to a wider threshold
/// without saying anything would throw that away as surely as deleting it.
/// The two footprints the operator was shown when they accepted a pair that
/// disagrees past `pairBlockingDisagreementPixels`.
///
/// It stores the measurements rather than a bare `accepted` flag, and that is
/// the whole point of the type. Replace re-scans the card and re-measures both
/// sides, so a flag would carry consent forward onto numbers nobody has seen:
/// the operator would accept 218 px, replace the card, land a 400 px
/// disagreement, and publish it silently. An acceptance is consent to *these*
/// two footprints and nothing else, so the gate returns the moment they change.
public struct AcceptedPairSizeMismatch: Codable, Equatable, Sendable {
    public let front: MediaPixelSize
    public let back: MediaPixelSize

    public init(front: MediaPixelSize, back: MediaPixelSize) {
        self.front = front
        self.back = back
    }

    public var disagreementPixels: Int {
        front.disagreementPixels(from: back)
    }

    /// Whether this acceptance still describes what the card measures now.
    public func covers(
        front: MediaPixelSize,
        back: MediaPixelSize
    ) -> Bool {
        self.front == front && self.back == back
    }
}

public struct PairSizeWarning: Equatable, Sendable {
    public let cardID: CardID
    public let provisionalSheetNumber: UInt64
    public let front: MediaPixelSize
    public let back: MediaPixelSize

    /// True when this pair is wide enough to refuse the batch and the operator
    /// accepted it anyway.
    ///
    /// An accepted pair stays in this list rather than disappearing from it.
    /// Dropping it would make the override the one gate in the app that goes
    /// quiet when it fires, and `SPEC.md` §6.2 says in as many words that this
    /// check never becomes silent — the badge, the action-bar count and the
    /// completion record all read from here.
    public let isOperatorAccepted: Bool

    public var disagreementPixels: Int {
        front.disagreementPixels(from: back)
    }

    public init(
        cardID: CardID,
        provisionalSheetNumber: UInt64,
        front: MediaPixelSize,
        back: MediaPixelSize,
        isOperatorAccepted: Bool = false
    ) {
        self.cardID = cardID
        self.provisionalSheetNumber = provisionalSheetNumber
        self.front = front
        self.back = back
        self.isOperatorAccepted = isOperatorAccepted
    }
}

public enum MarginAssessment: Codable, Equatable, Sendable {
    case pending
    /// The requested real-background margin fits inside the captured frame.
    /// Carries the measured media footprint so the reducer can hold a card's
    /// front against its back; `nil` only when the measurement predates this
    /// field, which forgoes the pair check rather than inventing a size.
    case sufficient(mediaSize: MediaPixelSize?)
    case insufficient(edges: Set<ScanEdge>)

    public var mediaSize: MediaPixelSize? {
        guard case let .sufficient(size) = self else { return nil }
        return size
    }
}

public struct ScannedSide: Codable, Equatable, Sendable {
    public let masterID: MasterID
    public let captureSequence: UInt64
    public internal(set) var rotation: QuarterTurns
    public internal(set) var marginAssessment: MarginAssessment
    public internal(set) var manualCrop: ManualCropRect?

    public init(
        masterID: MasterID,
        captureSequence: UInt64,
        rotation: QuarterTurns = .zero,
        marginAssessment: MarginAssessment = .pending,
        manualCrop: ManualCropRect? = nil
    ) {
        self.masterID = masterID
        self.captureSequence = captureSequence
        self.rotation = rotation
        self.marginAssessment = marginAssessment
        self.manualCrop = manualCrop
    }
}

public struct CardSides: Codable, Equatable, Sendable {
    public internal(set) var front: ScannedSide?
    public internal(set) var back: ScannedSide?

    public init(front: ScannedSide? = nil, back: ScannedSide? = nil) {
        self.front = front
        self.back = back
    }

    public var isComplete: Bool {
        front != nil && back != nil
    }

    public var missingSides: Set<OutputSide> {
        var result: Set<OutputSide> = []
        if front == nil {
            result.insert(.front)
        }
        if back == nil {
            result.insert(.back)
        }
        return result
    }

    public subscript(side: OutputSide) -> ScannedSide? {
        get {
            switch side {
            case .front:
                front
            case .back:
                back
            }
        }
        set {
            switch side {
            case .front:
                front = newValue
            case .back:
                back = newValue
            }
        }
    }

    fileprivate var referencedMasterIDs: Set<MasterID> {
        Set([front?.masterID, back?.masterID].compactMap { $0 })
    }

    fileprivate var referencedSides: [ScannedSide] {
        [front, back].compactMap { $0 }
    }
}

public enum CardDisposition: Codable, Equatable, Sendable {
    case active(CardSides)
    case deleted
}

public struct BatchCard: Identifiable, Codable, Equatable, Sendable {
    public let id: CardID
    public let provisionalSheetNumber: UInt64
    public internal(set) var disposition: CardDisposition

    /// Set when the operator chose to publish this card despite its two sides
    /// disagreeing past `pairBlockingDisagreementPixels`.
    ///
    /// Optional so a session record written before the override existed decodes
    /// unchanged — Swift's synthesised decoder treats an optional property as
    /// `decodeIfPresent`, so an in-flight batch survives the upgrade.
    public internal(set) var acceptedPairSizeMismatch: AcceptedPairSizeMismatch?

    public init(
        id: CardID,
        provisionalSheetNumber: UInt64,
        disposition: CardDisposition,
        acceptedPairSizeMismatch: AcceptedPairSizeMismatch? = nil
    ) {
        self.id = id
        self.provisionalSheetNumber = provisionalSheetNumber
        self.disposition = disposition
        self.acceptedPairSizeMismatch = acceptedPairSizeMismatch
    }

    /// The footprints this card's two sides currently measure, when both are
    /// present and both were assessed.
    ///
    /// Every pair rule reads through here so the override, the warning list and
    /// the completion gate can never disagree about what the card measures.
    public var assessedPairSizes: (front: MediaPixelSize, back: MediaPixelSize)? {
        guard case let .active(sides) = disposition,
              let front = sides.front, let back = sides.back,
              case let .sufficient(frontSize) = front.marginAssessment,
              case let .sufficient(backSize) = back.marginAssessment,
              let frontSize, let backSize
        else {
            return nil
        }
        return (frontSize, backSize)
    }

    /// Whether a person explicitly chose at least one of this card's bounds.
    /// A manual crop is the authoritative item boundary, so the automatic
    /// front/back footprint comparison must not overrule it afterward.
    public var hasManualCrop: Bool {
        guard let activeSides else {
            return false
        }
        return activeSides.front?.manualCrop != nil
            || activeSides.back?.manualCrop != nil
    }

    /// Whether the operator's acceptance still describes what this card
    /// measures. A Replace that re-measures the pair invalidates it.
    public var hasLiveAcceptedPairSizeMismatch: Bool {
        guard let acceptedPairSizeMismatch, let sizes = assessedPairSizes else {
            return false
        }
        return acceptedPairSizeMismatch.covers(
            front: sizes.front,
            back: sizes.back
        )
    }

    public var activeSides: CardSides? {
        guard case let .active(sides) = disposition else {
            return nil
        }
        return sides
    }

    public var isDeleted: Bool {
        if case .deleted = disposition {
            return true
        }
        return false
    }

    public var isIncomplete: Bool {
        guard let activeSides else {
            return false
        }
        return !activeSides.isComplete
    }
}

public struct IncompleteCardBlocker: Equatable, Sendable {
    public let cardID: CardID
    public let provisionalSheetNumber: UInt64
    public let missingSides: Set<OutputSide>
}

/// Why the batch cannot be completed, and which card is responsible.
///
/// Every card-specific case carries its provisional sheet number as well as its
/// identifier. The number is the only name the operator has for a card — it is
/// what the row shows and what the published file will be called — and a
/// blocker that cannot state it leaves them hunting through a 186-row list for
/// a card the app already knows (TICKET-032).
public enum CompletionBlocker: Equatable, Sendable {
    case noActiveCards
    case incomplete(
        cardID: CardID,
        provisionalSheetNumber: UInt64,
        missingSides: Set<OutputSide>
    )
    case marginPending(
        cardID: CardID,
        provisionalSheetNumber: UInt64,
        side: OutputSide
    )
    case insufficientRealMargin(
        cardID: CardID,
        provisionalSheetNumber: UInt64,
        side: OutputSide,
        edges: Set<ScanEdge>
    )
    case mismatchedPairMediaSize(
        cardID: CardID,
        provisionalSheetNumber: UInt64,
        front: MediaPixelSize,
        back: MediaPixelSize
    )

    /// The card this blocker is about, or `nil` for the one blocker that is
    /// about the batch as a whole.
    public var cardID: CardID? {
        switch self {
        case .noActiveCards:
            nil
        case let .incomplete(cardID, _, _),
             let .marginPending(cardID, _, _),
             let .insufficientRealMargin(cardID, _, _, _),
             let .mismatchedPairMediaSize(cardID, _, _, _):
            cardID
        }
    }

    public var provisionalSheetNumber: UInt64? {
        switch self {
        case .noActiveCards:
            nil
        case let .incomplete(_, number, _),
             let .marginPending(_, number, _),
             let .insufficientRealMargin(_, number, _, _),
             let .mismatchedPairMediaSize(_, number, _, _):
            number
        }
    }
}

public enum BatchIssueKind: String, Codable, Sendable {
    case scanFailed
    case scanInterrupted
    case invalidReplacementPageCount
    case releaseFailed
}

public struct BatchIssue: Codable, Equatable, Sendable {
    public let kind: BatchIssueKind
    public let message: String
    public let capturedCardsRemainSafe: Bool

    public init(
        kind: BatchIssueKind,
        message: String,
        capturedCardsRemainSafe: Bool = true
    ) {
        self.kind = kind
        self.message = message
        self.capturedCardsRemainSafe = capturedCardsRemainSafe
    }
}

public enum ScanOutcome: Equatable, Sendable {
    case completed
    case failed(BatchIssue)
}

public enum ScanOperation: Codable, Equatable, Sendable {
    case append(pendingCardID: CardID?)
    case retry(target: CardID, staged: [ScannedSide])
    case replace(target: CardID, staged: [ScannedSide])

    fileprivate var stagedSides: [ScannedSide] {
        switch self {
        case .append:
            []
        case let .retry(_, staged), let .replace(_, staged):
            staged
        }
    }
}

public struct ActiveScanPass: Codable, Equatable, Sendable {
    public let id: ScanPassID
    public internal(set) var operation: ScanOperation

    public init(id: ScanPassID, operation: ScanOperation) {
        self.id = id
        self.operation = operation
    }
}

public struct ReleaseAttempt: Codable, Equatable, Sendable {
    public let id: ReleaseAttemptID

    public init(id: ReleaseAttemptID) {
        self.id = id
    }
}

public struct CompletionSummary: Codable, Equatable, Sendable {
    public let cardCount: Int
    public let firstSheetNumber: UInt64?
    public let lastSheetNumber: UInt64?
    public let nextPersistentCounter: UInt64
    public let destinationDescription: String

    /// Sheet numbers whose two sides measured different item sizes and were
    /// released anyway.
    ///
    /// TICKET-033 stopped a disagreement under
    /// `MediaPixelSize.pairBlockingDisagreementPixels` from refusing the
    /// batch. What it must not do is let one leave without a record: these
    /// are the cards where the app knows one of the two crops is wrong and
    /// published it regardless, and the batch should be able to say so
    /// afterwards rather than only while it was on screen.
    public let releasedWithSizeWarnings: [UInt64]

    /// Sheet numbers the operator explicitly waved through (TICKET-037).
    ///
    /// A subset of `releasedWithSizeWarnings`, kept apart because it is a
    /// different fact. A 95 px warning is the app saying "look at this"; an
    /// entry here is a card the app *refused* and a person overrode, which is
    /// the only place in ScanDeck where a completion blocker was cleared by
    /// decision rather than by fixing the card. If a published pair is ever
    /// found badly cropped, this list is what says whether the app let it
    /// through or was told to.
    public let releasedWithAcceptedMismatches: [UInt64]

    public init(
        cardCount: Int,
        firstSheetNumber: UInt64?,
        lastSheetNumber: UInt64?,
        nextPersistentCounter: UInt64,
        destinationDescription: String,
        releasedWithSizeWarnings: [UInt64] = [],
        releasedWithAcceptedMismatches: [UInt64] = []
    ) {
        self.cardCount = cardCount
        self.firstSheetNumber = firstSheetNumber
        self.lastSheetNumber = lastSheetNumber
        self.nextPersistentCounter = nextPersistentCounter
        self.destinationDescription = destinationDescription
        self.releasedWithSizeWarnings = releasedWithSizeWarnings
        self.releasedWithAcceptedMismatches = releasedWithAcceptedMismatches
    }

    // Decoded with a default so a session written before TICKET-033 still
    // opens. An empty list is the truthful answer for one of those: it was
    // written by a build in which no card could be released while warned.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        cardCount = try container.decode(Int.self, forKey: .cardCount)
        firstSheetNumber = try container.decodeIfPresent(
            UInt64.self,
            forKey: .firstSheetNumber
        )
        lastSheetNumber = try container.decodeIfPresent(
            UInt64.self,
            forKey: .lastSheetNumber
        )
        nextPersistentCounter = try container.decode(
            UInt64.self,
            forKey: .nextPersistentCounter
        )
        destinationDescription = try container.decode(
            String.self,
            forKey: .destinationDescription
        )
        releasedWithSizeWarnings = try container.decodeIfPresent(
            [UInt64].self,
            forKey: .releasedWithSizeWarnings
        ) ?? []
        releasedWithAcceptedMismatches = try container.decodeIfPresent(
            [UInt64].self,
            forKey: .releasedWithAcceptedMismatches
        ) ?? []
    }
}

public enum BatchPhase: Codable, Equatable, Sendable {
    case ready
    case scanning(ActiveScanPass)
    case review
    case releasing(ReleaseAttempt)
    case completed(CompletionSummary)
}

public struct CompletionSide: Codable, Equatable, Sendable {
    public let masterID: MasterID
    public let rotation: QuarterTurns
    public let manualCrop: ManualCropRect?
    public let mediaSize: MediaPixelSize?

    public init(
        masterID: MasterID,
        rotation: QuarterTurns,
        manualCrop: ManualCropRect? = nil,
        mediaSize: MediaPixelSize? = nil
    ) {
        self.masterID = masterID
        self.rotation = rotation
        self.manualCrop = manualCrop
        self.mediaSize = mediaSize
    }
}

public struct CompletionCard: Identifiable, Codable, Equatable, Sendable {
    public let id: CardID
    public let provisionalSheetNumber: UInt64
    public let front: CompletionSide
    public let back: CompletionSide
}

public struct CompletionCandidate: Codable, Equatable, Sendable {
    public let attemptID: ReleaseAttemptID
    public let batchID: BatchID
    public let jobID: JobID
    public let batchName: BatchName
    public let requestedMargins: ScanMargins
    public let cards: [CompletionCard]
    public let nextPersistentCounter: UInt64
}

public enum BatchEffect: Equatable, Sendable {
    case assessMargin(
        masterID: MasterID,
        rotation: QuarterTurns,
        manualCrop: ManualCropRect?,
        requestedMargins: ScanMargins
    )
    /// Marks masters as retired from the current review graph. The storage
    /// layer must retain them for recovery and must not physically delete them
    /// before batch publication and the counter commit are both durable.
    case mastersBecameUnreferenced(Set<MasterID>)
    /// The coordinator must durably save the releasing session/journal before
    /// executing this effect. `resumeCompletion` regenerates the same candidate
    /// after relaunch, keyed by its release-attempt identifier.
    case prepareCompletion(CompletionCandidate)
}

public enum BatchAction: Sendable {
    case beginAppend(passID: ScanPassID)
    case beginRetry(cardID: CardID, passID: ScanPassID)
    case beginReplace(cardID: CardID, passID: ScanPassID)
    case pageReceived(
        passID: ScanPassID,
        masterID: MasterID,
        captureSequence: UInt64,
        newCardID: CardID?
    )
    case marginAssessed(
        masterID: MasterID,
        rotation: QuarterTurns,
        result: MarginAssessment
    )
    case automaticallyOrient(
        masterID: MasterID,
        expectedRotation: QuarterTurns,
        rotation: QuarterTurns
    )
    case scanEnded(passID: ScanPassID, outcome: ScanOutcome)
    case recoverInterruptedScan
    case rotate(
        cardID: CardID,
        side: OutputSide,
        direction: RotationDirection
    )
    case setManualCrop(cardID: CardID, side: OutputSide, crop: ManualCropRect?)
    case deleteSide(cardID: CardID, side: OutputSide)
    case deleteCard(cardID: CardID)
    /// The operator's decision to publish a card whose two sides disagree past
    /// `pairBlockingDisagreementPixels`.
    ///
    /// It is an action rather than a flag the UI sets because the reducer owns
    /// every gate: it is the only layer that knows the card is blocking, and a
    /// presentation model that could clear a blocker by itself would be able to
    /// publish a pair the domain still refuses.
    case acceptPairSizeMismatch(cardID: CardID)
    /// Take the acceptance back. An override with no way out is a trap — the
    /// operator finds the real problem two cards later and cannot un-say it.
    case withdrawPairSizeMismatchAcceptance(cardID: CardID)
    case requestCompletion(attemptID: ReleaseAttemptID)
    /// Re-emits the immutable completion candidate after relaunch. The release
    /// coordinator uses the attempt ID as its idempotency key.
    case resumeCompletion(attemptID: ReleaseAttemptID)
    case completionFailed(attemptID: ReleaseAttemptID, issue: BatchIssue)
    case completionSucceeded(
        attemptID: ReleaseAttemptID,
        destinationDescription: String
    )
}

public enum BatchSessionError: Error, Equatable, LocalizedError, Sendable {
    case unsupportedSchemaVersion(Int)
    case invalidState(String)
    case invalidPhase(String)
    case incompleteCardsBlockContinue
    case cardNotFound(CardID)
    case cardDeleted(CardID)
    case cardMustBeComplete(CardID)
    case cardMustBeIncomplete(CardID)
    /// Accepting a pair that is not refusing the batch would record consent to
    /// a decision the operator was never shown.
    case cardHasNoBlockingPairMismatch(CardID)
    case pairMismatchNotAccepted(CardID)
    case sideNotPresent(cardID: CardID, side: OutputSide)
    case duplicateCardID(CardID)
    case duplicateMasterID(MasterID)
    case staleScanPass(ScanPassID)
    case reusedScanPass(ScanPassID)
    case staleReleaseAttempt(ReleaseAttemptID)
    case reusedReleaseAttempt(ReleaseAttemptID)
    case missingNewCardID
    case unexpectedNewCardID
    case unexpectedCaptureSequence(expected: UInt64, actual: UInt64)
    case counterExhausted
    case captureSequenceExhausted
    case completionBlocked([CompletionBlocker])
    case masterNotReferenced(MasterID)
    case staleMarginAssessment(
        masterID: MasterID,
        assessedRotation: QuarterTurns,
        currentRotation: QuarterTurns
    )

    public var errorDescription: String? {
        switch self {
        case let .unsupportedSchemaVersion(version):
            "Unsupported batch-session schema version \(version)."
        case let .invalidState(message), let .invalidPhase(message):
            message
        case .incompleteCardsBlockContinue:
            "Retry or delete every incomplete card before continuing."
        case .cardNotFound:
            "The requested card was not found."
        case .cardDeleted:
            "The requested card has been deleted."
        case .cardMustBeComplete:
            "Replace Card requires a complete card."
        case .cardMustBeIncomplete:
            "Retry requires an incomplete card."
        case .cardHasNoBlockingPairMismatch:
            "That card's two sides do not disagree enough to need accepting."
        case .pairMismatchNotAccepted:
            "That card's size disagreement has not been accepted."
        case .sideNotPresent:
            "The requested card side is missing."
        case .duplicateCardID:
            "The card identifier has already been used."
        case .duplicateMasterID:
            "The master identifier has already been used."
        case .staleScanPass:
            "Ignored a callback from a stale scan pass."
        case .reusedScanPass:
            "The scan-pass identifier has already been used."
        case .staleReleaseAttempt:
            "Ignored a callback from a stale release attempt."
        case .reusedReleaseAttempt:
            "The release-attempt identifier has already been used."
        case .missingNewCardID:
            "The first page of an appended card requires a card identifier."
        case .unexpectedNewCardID:
            "Only the first page of a newly appended card accepts a card identifier."
        case let .unexpectedCaptureSequence(expected, actual):
            "Expected capture sequence \(expected), received \(actual)."
        case .counterExhausted:
            "The provisional card counter is exhausted."
        case .captureSequenceExhausted:
            "The capture sequence is exhausted."
        case .completionBlocked:
            "The batch is not ready to complete."
        case .masterNotReferenced:
            "The requested master is no longer part of this batch."
        case .staleMarginAssessment:
            "Ignored a margin result for an earlier image rotation."
        }
    }
}

public struct BatchSession: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let id: BatchID
    public let jobID: JobID
    public let batchName: BatchName
    public let firstSheetNumber: UInt64
    public let deliveryOrder: DuplexDeliveryOrder
    public let requestedMargins: ScanMargins

    /// How every captured side is turned before the operator ever sees it.
    ///
    /// A property of the scanner, not a judgement about the card: an fi-8170
    /// duplex pass delivers both faces rotated 180°, because the sheet meets the
    /// second sensor the other way up. Seeding it here rather than asking the
    /// operator to turn every side means review shows cards the right way up
    /// from the first page, and the operator's own rotations stay corrections
    /// rather than chores.
    public let captureRotation: QuarterTurns

    public private(set) var nextSheetNumber: UInt64
    public private(set) var nextCaptureSequence: UInt64
    public private(set) var cards: [BatchCard]
    public private(set) var phase: BatchPhase
    public private(set) var lastIssue: BatchIssue?

    private var usedMasterIDs: Set<MasterID>
    private var usedScanPassIDs: Set<ScanPassID>
    private var usedReleaseAttemptIDs: Set<ReleaseAttemptID>

    public init(
        id: BatchID,
        jobID: JobID,
        batchName: BatchName,
        firstSheetNumber: UInt64,
        deliveryOrder: DuplexDeliveryOrder,
        requestedMargins: ScanMargins = .cardDefault,
        captureRotation: QuarterTurns = .zero
    ) {
        schemaVersion = Self.currentSchemaVersion
        self.id = id
        self.jobID = jobID
        self.batchName = batchName
        self.firstSheetNumber = firstSheetNumber
        self.deliveryOrder = deliveryOrder
        self.requestedMargins = requestedMargins
        self.captureRotation = captureRotation
        nextSheetNumber = firstSheetNumber
        nextCaptureSequence = 0
        cards = []
        phase = .ready
        lastIssue = nil
        usedMasterIDs = []
        usedScanPassIDs = []
        usedReleaseAttemptIDs = []
    }

    public var continuationBlockers: [IncompleteCardBlocker] {
        cards.compactMap { card in
            guard case let .active(sides) = card.disposition,
                  !sides.isComplete
            else {
                return nil
            }
            return IncompleteCardBlocker(
                cardID: card.id,
                provisionalSheetNumber: card.provisionalSheetNumber,
                missingSides: sides.missingSides
            )
        }
    }

    public var canContinueScanning: Bool {
        switch phase {
        case .ready, .review:
            continuationBlockers.isEmpty
        case .scanning, .releasing, .completed:
            false
        }
    }

    public var completionBlockers: [CompletionBlocker] {
        contentCompletionBlockers()
    }

    /// Cards worth a second look that are not worth refusing the batch over.
    ///
    /// Projected from the same measurements as `completionBlockers` and never
    /// overlapping it: a pair wide enough to block appears there, not here.
    public var pairSizeWarnings: [PairSizeWarning] {
        cards.compactMap { card in
            guard !card.isDeleted,
                  !card.hasManualCrop,
                  let sizes = card.assessedPairSizes,
                  !sizes.front.agrees(with: sizes.back)
            else {
                return nil
            }
            // Between the two thresholds the pair warns. Past the blocking one
            // it normally appears in `completionBlockers` instead — unless the
            // operator accepted it, and then it warns here for the rest of the
            // batch's life. That is the price of the override being allowed to
            // exist: it moves a card out of the refusal and never out of sight.
            let isBlocking = sizes.front.blocksCompletion(against: sizes.back)
            let isAccepted = card.hasLiveAcceptedPairSizeMismatch
            guard !isBlocking || isAccepted else {
                return nil
            }
            return PairSizeWarning(
                cardID: card.id,
                provisionalSheetNumber: card.provisionalSheetNumber,
                front: sizes.front,
                back: sizes.back,
                isOperatorAccepted: isBlocking && isAccepted
            )
        }
    }

    /// The cards the operator chose to publish despite a blocking disagreement.
    ///
    /// TICKET-006b's release journal and the completion screen both read this,
    /// because "which cards did I wave through, and by how much" is the one
    /// question an override has to be able to answer afterwards.
    public var acceptedPairSizeMismatches: [PairSizeWarning] {
        pairSizeWarnings.filter(\.isOperatorAccepted)
    }

    public var canCompleteBatch: Bool {
        guard case .review = phase else {
            return false
        }
        return completionBlockers.isEmpty
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        id = try container.decode(BatchID.self, forKey: .id)
        jobID = try container.decode(JobID.self, forKey: .jobID)
        batchName = try container.decode(BatchName.self, forKey: .batchName)
        firstSheetNumber = try container.decode(
            UInt64.self,
            forKey: .firstSheetNumber
        )
        deliveryOrder = try container.decode(
            DuplexDeliveryOrder.self,
            forKey: .deliveryOrder
        )
        requestedMargins = try container.decode(
            ScanMargins.self,
            forKey: .requestedMargins
        )
        // Absent in batches written before capture orientation existed. Those
        // sides already carry whatever rotation they were given, and this only
        // seeds pages captured from here on, so no turn is the honest default.
        captureRotation = try container.decodeIfPresent(
            QuarterTurns.self,
            forKey: .captureRotation
        ) ?? .zero
        nextSheetNumber = try container.decode(
            UInt64.self,
            forKey: .nextSheetNumber
        )
        nextCaptureSequence = try container.decode(
            UInt64.self,
            forKey: .nextCaptureSequence
        )
        cards = try container.decode([BatchCard].self, forKey: .cards)
        phase = try container.decode(BatchPhase.self, forKey: .phase)
        lastIssue = try container.decodeIfPresent(
            BatchIssue.self,
            forKey: .lastIssue
        )
        usedMasterIDs = try container.decode(
            Set<MasterID>.self,
            forKey: .usedMasterIDs
        )
        usedScanPassIDs = try container.decode(
            Set<ScanPassID>.self,
            forKey: .usedScanPassIDs
        )
        usedReleaseAttemptIDs = try container.decode(
            Set<ReleaseAttemptID>.self,
            forKey: .usedReleaseAttemptIDs
        )

        try validate()
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(id, forKey: .id)
        try container.encode(jobID, forKey: .jobID)
        try container.encode(batchName, forKey: .batchName)
        try container.encode(firstSheetNumber, forKey: .firstSheetNumber)
        try container.encode(deliveryOrder, forKey: .deliveryOrder)
        try container.encode(requestedMargins, forKey: .requestedMargins)
        try container.encode(captureRotation, forKey: .captureRotation)
        try container.encode(nextSheetNumber, forKey: .nextSheetNumber)
        try container.encode(nextCaptureSequence, forKey: .nextCaptureSequence)
        try container.encode(cards, forKey: .cards)
        try container.encode(phase, forKey: .phase)
        try container.encodeIfPresent(lastIssue, forKey: .lastIssue)
        try container.encode(usedMasterIDs, forKey: .usedMasterIDs)
        try container.encode(usedScanPassIDs, forKey: .usedScanPassIDs)
        try container.encode(
            usedReleaseAttemptIDs,
            forKey: .usedReleaseAttemptIDs
        )
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case id
        case jobID
        case batchName
        case firstSheetNumber
        case deliveryOrder
        case requestedMargins
        case captureRotation
        case nextSheetNumber
        case nextCaptureSequence
        case cards
        case phase
        case lastIssue
        case usedMasterIDs
        case usedScanPassIDs
        case usedReleaseAttemptIDs
    }
}

public enum BatchSessionReducer {
    @discardableResult
    public static func reduce(
        _ action: BatchAction,
        into state: inout BatchSession
    ) throws -> [BatchEffect] {
        var candidate = state
        let effects = try candidate.apply(action)
        try candidate.validate()
        state = candidate
        return effects
    }
}

private extension BatchSession {
    mutating func apply(_ action: BatchAction) throws -> [BatchEffect] {
        switch action {
        case let .beginAppend(passID):
            return try beginAppend(passID: passID)

        case let .beginRetry(cardID, passID):
            return try beginTargetedScan(
                cardID: cardID,
                passID: passID,
                isReplacement: false
            )

        case let .beginReplace(cardID, passID):
            return try beginTargetedScan(
                cardID: cardID,
                passID: passID,
                isReplacement: true
            )

        case let .pageReceived(
            passID,
            masterID,
            captureSequence,
            newCardID
        ):
            return try receivePage(
                passID: passID,
                masterID: masterID,
                captureSequence: captureSequence,
                newCardID: newCardID
            )

        case let .marginAssessed(masterID, rotation, result):
            return try applyMarginAssessment(
                masterID: masterID,
                rotation: rotation,
                result: result
            )

        case let .automaticallyOrient(masterID, expectedRotation, rotation):
            return try automaticallyOrient(
                masterID: masterID,
                expectedRotation: expectedRotation,
                rotation: rotation
            )

        case let .scanEnded(passID, outcome):
            return try endScan(passID: passID, outcome: outcome)

        case .recoverInterruptedScan:
            return try recoverInterruptedScan()

        case let .rotate(cardID, side, direction):
            return try rotate(
                cardID: cardID,
                side: side,
                direction: direction
            )

        case let .setManualCrop(cardID, side, crop):
            return try setManualCrop(cardID: cardID, side: side, crop: crop)

        case let .deleteSide(cardID, side):
            return try deleteSide(cardID: cardID, side: side)

        case let .deleteCard(cardID):
            return try deleteCard(cardID: cardID)

        case let .acceptPairSizeMismatch(cardID):
            return try acceptPairSizeMismatch(cardID: cardID)

        case let .withdrawPairSizeMismatchAcceptance(cardID):
            return try withdrawPairSizeMismatchAcceptance(cardID: cardID)

        case let .requestCompletion(attemptID):
            return try requestCompletion(attemptID: attemptID)

        case let .resumeCompletion(attemptID):
            return try resumeCompletion(attemptID: attemptID)

        case let .completionFailed(attemptID, issue):
            return try failCompletion(attemptID: attemptID, issue: issue)

        case let .completionSucceeded(attemptID, destinationDescription):
            return try succeedCompletion(
                attemptID: attemptID,
                destinationDescription: destinationDescription
            )
        }
    }

    mutating func beginAppend(passID: ScanPassID) throws -> [BatchEffect] {
        guard canStartAppendFromCurrentPhase else {
            throw BatchSessionError.invalidPhase(
                "Continue Scanning is available only while ready or reviewing."
            )
        }
        guard continuationBlockers.isEmpty else {
            throw BatchSessionError.incompleteCardsBlockContinue
        }
        guard usedScanPassIDs.insert(passID).inserted else {
            throw BatchSessionError.reusedScanPass(passID)
        }

        phase = .scanning(
            ActiveScanPass(
                id: passID,
                operation: .append(pendingCardID: nil)
            )
        )
        lastIssue = nil
        return []
    }

    mutating func beginTargetedScan(
        cardID: CardID,
        passID: ScanPassID,
        isReplacement: Bool
    ) throws -> [BatchEffect] {
        guard case .review = phase else {
            throw BatchSessionError.invalidPhase(
                "Retry and Replace Card are available only during review."
            )
        }

        let index = try activeCardIndex(for: cardID)
        guard case let .active(sides) = cards[index].disposition else {
            throw BatchSessionError.cardDeleted(cardID)
        }
        if isReplacement {
            guard sides.isComplete else {
                throw BatchSessionError.cardMustBeComplete(cardID)
            }
        } else {
            guard !sides.isComplete else {
                throw BatchSessionError.cardMustBeIncomplete(cardID)
            }
        }
        guard usedScanPassIDs.insert(passID).inserted else {
            throw BatchSessionError.reusedScanPass(passID)
        }

        let operation: ScanOperation = isReplacement
            ? .replace(target: cardID, staged: [])
            : .retry(target: cardID, staged: [])
        phase = .scanning(ActiveScanPass(id: passID, operation: operation))
        lastIssue = nil
        return []
    }

    mutating func receivePage(
        passID: ScanPassID,
        masterID: MasterID,
        captureSequence: UInt64,
        newCardID: CardID?
    ) throws -> [BatchEffect] {
        guard case var .scanning(activePass) = phase,
              activePass.id == passID
        else {
            throw BatchSessionError.staleScanPass(passID)
        }
        guard captureSequence == nextCaptureSequence else {
            throw BatchSessionError.unexpectedCaptureSequence(
                expected: nextCaptureSequence,
                actual: captureSequence
            )
        }
        guard nextCaptureSequence < UInt64.max else {
            throw BatchSessionError.captureSequenceExhausted
        }
        guard !usedMasterIDs.contains(masterID) else {
            throw BatchSessionError.duplicateMasterID(masterID)
        }

        let scannedSide = ScannedSide(
            masterID: masterID,
            captureSequence: captureSequence,
            rotation: captureRotation
        )

        switch activePass.operation {
        case let .append(pendingCardID):
            if let pendingCardID {
                guard newCardID == nil else {
                    throw BatchSessionError.unexpectedNewCardID
                }
                let index = try activeCardIndex(for: pendingCardID)
                guard case var .active(sides) = cards[index].disposition,
                      !sides.isComplete
                else {
                    throw BatchSessionError.invalidState(
                        "The pending appended card is not incomplete."
                    )
                }

                let expectedSecondSide: OutputSide = switch deliveryOrder {
                case .frontFirst:
                    .back
                case .backFirst:
                    .front
                }
                guard sides[expectedSecondSide] == nil else {
                    throw BatchSessionError.invalidState(
                        "The pending appended card already has its second side."
                    )
                }

                sides[expectedSecondSide] = scannedSide
                cards[index].disposition = .active(sides)
                activePass.operation = .append(pendingCardID: nil)
            } else {
                guard let newCardID else {
                    throw BatchSessionError.missingNewCardID
                }
                guard !cards.contains(where: { $0.id == newCardID }) else {
                    throw BatchSessionError.duplicateCardID(newCardID)
                }
                guard nextSheetNumber < UInt64.max else {
                    throw BatchSessionError.counterExhausted
                }

                let firstSide: OutputSide = switch deliveryOrder {
                case .frontFirst:
                    .front
                case .backFirst:
                    .back
                }
                var sides = CardSides()
                sides[firstSide] = scannedSide
                cards.append(
                    BatchCard(
                        id: newCardID,
                        provisionalSheetNumber: nextSheetNumber,
                        disposition: .active(sides)
                    )
                )
                nextSheetNumber += 1
                activePass.operation = .append(
                    pendingCardID: newCardID
                )
            }

        case let .retry(target, staged):
            guard newCardID == nil else {
                throw BatchSessionError.unexpectedNewCardID
            }
            activePass.operation = .retry(
                target: target,
                staged: staged + [scannedSide]
            )

        case let .replace(target, staged):
            guard newCardID == nil else {
                throw BatchSessionError.unexpectedNewCardID
            }
            activePass.operation = .replace(
                target: target,
                staged: staged + [scannedSide]
            )
        }

        nextCaptureSequence += 1
        usedMasterIDs.insert(masterID)
        phase = .scanning(activePass)

        return [
            .assessMargin(
                masterID: masterID,
                rotation: scannedSide.rotation,
                manualCrop: nil,
                requestedMargins: requestedMargins
            )
        ]
    }

    mutating func applyMarginAssessment(
        masterID: MasterID,
        rotation: QuarterTurns,
        result: MarginAssessment
    ) throws -> [BatchEffect] {
        for index in cards.indices {
            guard case var .active(sides) = cards[index].disposition else {
                continue
            }
            for side in [OutputSide.front, .back] {
                guard var scannedSide = sides[side],
                      scannedSide.masterID == masterID
                else {
                    continue
                }
                guard scannedSide.rotation == rotation else {
                    throw BatchSessionError.staleMarginAssessment(
                        masterID: masterID,
                        assessedRotation: rotation,
                        currentRotation: scannedSide.rotation
                    )
                }
                scannedSide.marginAssessment = result
                sides[side] = scannedSide
                cards[index].disposition = .active(sides)
                return []
            }
        }

        guard case var .scanning(activePass) = phase else {
            throw BatchSessionError.masterNotReferenced(masterID)
        }

        switch activePass.operation {
        case .append:
            throw BatchSessionError.masterNotReferenced(masterID)

        case let .retry(target, staged):
            guard let index = staged.firstIndex(where: {
                $0.masterID == masterID
            }) else {
                throw BatchSessionError.masterNotReferenced(masterID)
            }
            guard staged[index].rotation == rotation else {
                throw BatchSessionError.staleMarginAssessment(
                    masterID: masterID,
                    assessedRotation: rotation,
                    currentRotation: staged[index].rotation
                )
            }
            var updated = staged
            updated[index].marginAssessment = result
            activePass.operation = .retry(target: target, staged: updated)

        case let .replace(target, staged):
            guard let index = staged.firstIndex(where: {
                $0.masterID == masterID
            }) else {
                throw BatchSessionError.masterNotReferenced(masterID)
            }
            guard staged[index].rotation == rotation else {
                throw BatchSessionError.staleMarginAssessment(
                    masterID: masterID,
                    assessedRotation: rotation,
                    currentRotation: staged[index].rotation
                )
            }
            var updated = staged
            updated[index].marginAssessment = result
            activePass.operation = .replace(target: target, staged: updated)
        }

        phase = .scanning(activePass)
        return []
    }

    mutating func automaticallyOrient(
        masterID: MasterID,
        expectedRotation: QuarterTurns,
        rotation: QuarterTurns
    ) throws -> [BatchEffect] {
        func effect(for side: ScannedSide) -> BatchEffect {
            .assessMargin(
                masterID: side.masterID,
                rotation: side.rotation,
                manualCrop: side.manualCrop,
                requestedMargins: requestedMargins
            )
        }

        for index in cards.indices {
            guard case var .active(sides) = cards[index].disposition else { continue }
            for outputSide in [OutputSide.front, .back] {
                guard var side = sides[outputSide], side.masterID == masterID else { continue }
                guard side.rotation == expectedRotation else { return [] }
                guard rotation != expectedRotation else { return [] }
                let delta = (rotation.rawValue - expectedRotation.rawValue + 4) % 4
                side.rotation = rotation
                side.marginAssessment = .pending
                sides[outputSide] = side
                var changed = [side]
                let partnerSide: OutputSide = outputSide == .front ? .back : .front
                if var partner = sides[partnerSide],
                   let partnerRotation = QuarterTurns(
                    // The reverse image from the duplex transport is physically
                    // inverted relative to the first image. Preserve the
                    // detected correction, then add the half-turn required to
                    // make the opposite face upright.
                    rawValue: (partner.rotation.rawValue + delta + 2) % 4
                   ) {
                    partner.rotation = partnerRotation
                    partner.marginAssessment = .pending
                    sides[partnerSide] = partner
                    changed.append(partner)
                }
                cards[index].disposition = .active(sides)
                return changed.map(effect)
            }
        }

        guard case var .scanning(activePass) = phase else {
            throw BatchSessionError.masterNotReferenced(masterID)
        }
        switch activePass.operation {
        case .append:
            throw BatchSessionError.masterNotReferenced(masterID)
        case let .retry(target, staged):
            guard let index = staged.firstIndex(where: { $0.masterID == masterID }) else {
                throw BatchSessionError.masterNotReferenced(masterID)
            }
            guard staged[index].rotation == expectedRotation else { return [] }
            var updated = staged
            updated[index].rotation = rotation
            if rotation != expectedRotation { updated[index].marginAssessment = .pending }
            activePass.operation = .retry(target: target, staged: updated)
            phase = .scanning(activePass)
            return rotation == expectedRotation ? [] : [effect(for: updated[index])]
        case let .replace(target, staged):
            guard let index = staged.firstIndex(where: { $0.masterID == masterID }) else {
                throw BatchSessionError.masterNotReferenced(masterID)
            }
            guard staged[index].rotation == expectedRotation else { return [] }
            var updated = staged
            updated[index].rotation = rotation
            if rotation != expectedRotation { updated[index].marginAssessment = .pending }
            activePass.operation = .replace(target: target, staged: updated)
            phase = .scanning(activePass)
            return rotation == expectedRotation ? [] : [effect(for: updated[index])]
        }
    }

    mutating func endScan(
        passID: ScanPassID,
        outcome: ScanOutcome
    ) throws -> [BatchEffect] {
        guard case let .scanning(activePass) = phase,
              activePass.id == passID
        else {
            throw BatchSessionError.staleScanPass(passID)
        }

        switch activePass.operation {
        case .append:
            phase = .review
            switch outcome {
            case .completed:
                lastIssue = nil
            case let .failed(issue):
                lastIssue = issue
            }
            return []

        case let .retry(target, staged):
            return try finishTargetedScan(
                target: target,
                staged: staged,
                outcome: outcome
            )

        case let .replace(target, staged):
            return try finishTargetedScan(
                target: target,
                staged: staged,
                outcome: outcome
            )
        }
    }

    mutating func finishTargetedScan(
        target: CardID,
        staged: [ScannedSide],
        outcome: ScanOutcome
    ) throws -> [BatchEffect] {
        let stagedIDs = Set(staged.map(\.masterID))

        guard case .completed = outcome, staged.count == 2 else {
            phase = .review
            if case let .failed(issue) = outcome {
                lastIssue = issue
            } else {
                lastIssue = BatchIssue(
                    kind: .invalidReplacementPageCount,
                    message: "Retry/Replace Card expected exactly two pages "
                        + "but received \(staged.count)."
                )
            }
            return stagedIDs.isEmpty
                ? []
                : [.mastersBecameUnreferenced(stagedIDs)]
        }

        let index = try activeCardIndex(for: target)
        guard case let .active(oldSides) = cards[index].disposition else {
            throw BatchSessionError.cardDeleted(target)
        }

        let mapped = mapDuplexPair(first: staged[0], second: staged[1])
        cards[index].disposition = .active(
            CardSides(front: mapped.front, back: mapped.back)
        )
        phase = .review
        lastIssue = nil

        let oldMasterIDs = oldSides.referencedMasterIDs
        return oldMasterIDs.isEmpty
            ? []
            : [.mastersBecameUnreferenced(oldMasterIDs)]
    }

    mutating func recoverInterruptedScan() throws -> [BatchEffect] {
        guard case let .scanning(activePass) = phase else {
            throw BatchSessionError.invalidPhase(
                "There is no interrupted scan to recover."
            )
        }

        phase = .review
        lastIssue = BatchIssue(
            kind: .scanInterrupted,
            message: "Scanning was interrupted. Captured cards remain safe."
        )

        let stagedIDs = Set(activePass.operation.stagedSides.map(\.masterID))
        return stagedIDs.isEmpty
            ? []
            : [.mastersBecameUnreferenced(stagedIDs)]
    }

    mutating func rotate(
        cardID: CardID,
        side: OutputSide,
        direction: RotationDirection
    ) throws -> [BatchEffect] {
        try requireReviewPhase()
        let index = try activeCardIndex(for: cardID)
        guard case var .active(sides) = cards[index].disposition,
              var scannedSide = sides[side]
        else {
            throw BatchSessionError.sideNotPresent(
                cardID: cardID,
                side: side
            )
        }

        scannedSide.rotation = scannedSide.rotation.applying(direction)
        scannedSide.marginAssessment = .pending
        sides[side] = scannedSide
        cards[index].disposition = .active(sides)

        return [
            .assessMargin(
                masterID: scannedSide.masterID,
                rotation: scannedSide.rotation,
                manualCrop: scannedSide.manualCrop,
                requestedMargins: requestedMargins
            )
        ]
    }

    mutating func setManualCrop(
        cardID: CardID,
        side: OutputSide,
        crop: ManualCropRect?
    ) throws -> [BatchEffect] {
        try requireReviewPhase()
        if let crop, !crop.isValid {
            throw BatchSessionError.invalidState("The manual crop is outside the master image.")
        }
        let index = try activeCardIndex(for: cardID)
        guard case var .active(sides) = cards[index].disposition,
              var scannedSide = sides[side]
        else {
            throw BatchSessionError.sideNotPresent(cardID: cardID, side: side)
        }
        scannedSide.manualCrop = crop
        scannedSide.marginAssessment = .pending
        sides[side] = scannedSide
        cards[index].disposition = .active(sides)
        cards[index].acceptedPairSizeMismatch = nil
        return [
            .assessMargin(
                masterID: scannedSide.masterID,
                rotation: scannedSide.rotation,
                manualCrop: crop,
                requestedMargins: requestedMargins
            )
        ]
    }

    mutating func deleteSide(
        cardID: CardID,
        side: OutputSide
    ) throws -> [BatchEffect] {
        try requireReviewPhase()
        let index = try activeCardIndex(for: cardID)
        guard case var .active(sides) = cards[index].disposition,
              let removed = sides[side]
        else {
            throw BatchSessionError.sideNotPresent(
                cardID: cardID,
                side: side
            )
        }

        sides[side] = nil
        cards[index].disposition = .active(sides)
        return [.mastersBecameUnreferenced([removed.masterID])]
    }

    mutating func deleteCard(cardID: CardID) throws -> [BatchEffect] {
        try requireReviewPhase()
        let index = try activeCardIndex(for: cardID)
        guard case let .active(sides) = cards[index].disposition else {
            throw BatchSessionError.cardDeleted(cardID)
        }

        cards[index].disposition = .deleted
        let masterIDs = sides.referencedMasterIDs
        return masterIDs.isEmpty
            ? []
            : [.mastersBecameUnreferenced(masterIDs)]
    }

    /// Records the operator's consent to one card's wide size disagreement.
    ///
    /// Refuses unless the card is blocking the batch *right now*. That guard is
    /// what makes the stored footprints meaningful: consent can only ever be
    /// given to a disagreement the app is currently refusing and has therefore
    /// already put in front of the operator, with both measurements in the
    /// message. It also makes the action idempotent in the only way that
    /// matters — pressing twice re-records the same two numbers.
    mutating func acceptPairSizeMismatch(
        cardID: CardID
    ) throws -> [BatchEffect] {
        try requireReviewPhase()
        let index = try activeCardIndex(for: cardID)
        guard let sizes = cards[index].assessedPairSizes,
              sizes.front.blocksCompletion(against: sizes.back)
        else {
            throw BatchSessionError.cardHasNoBlockingPairMismatch(cardID)
        }
        cards[index].acceptedPairSizeMismatch = AcceptedPairSizeMismatch(
            front: sizes.front,
            back: sizes.back
        )
        return []
    }

    mutating func withdrawPairSizeMismatchAcceptance(
        cardID: CardID
    ) throws -> [BatchEffect] {
        try requireReviewPhase()
        let index = try activeCardIndex(for: cardID)
        guard cards[index].acceptedPairSizeMismatch != nil else {
            throw BatchSessionError.pairMismatchNotAccepted(cardID)
        }
        cards[index].acceptedPairSizeMismatch = nil
        return []
    }

    mutating func requestCompletion(
        attemptID: ReleaseAttemptID
    ) throws -> [BatchEffect] {
        try requireReviewPhase()
        let blockers = contentCompletionBlockers()
        guard blockers.isEmpty else {
            throw BatchSessionError.completionBlocked(blockers)
        }
        guard usedReleaseAttemptIDs.insert(attemptID).inserted else {
            throw BatchSessionError.reusedReleaseAttempt(attemptID)
        }

        let candidate = try makeCompletionCandidate(attemptID: attemptID)
        phase = .releasing(ReleaseAttempt(id: attemptID))
        lastIssue = nil
        return [.prepareCompletion(candidate)]
    }

    mutating func failCompletion(
        attemptID: ReleaseAttemptID,
        issue: BatchIssue
    ) throws -> [BatchEffect] {
        guard case let .releasing(attempt) = phase,
              attempt.id == attemptID
        else {
            throw BatchSessionError.staleReleaseAttempt(attemptID)
        }

        phase = .review
        lastIssue = issue
        return []
    }

    func resumeCompletion(
        attemptID: ReleaseAttemptID
    ) throws -> [BatchEffect] {
        guard case let .releasing(attempt) = phase,
              attempt.id == attemptID
        else {
            throw BatchSessionError.staleReleaseAttempt(attemptID)
        }

        return [
            .prepareCompletion(
                try makeCompletionCandidate(attemptID: attemptID)
            )
        ]
    }

    mutating func succeedCompletion(
        attemptID: ReleaseAttemptID,
        destinationDescription: String
    ) throws -> [BatchEffect] {
        guard case let .releasing(attempt) = phase,
              attempt.id == attemptID
        else {
            throw BatchSessionError.staleReleaseAttempt(attemptID)
        }

        let liveCards = cards.filter { !$0.isDeleted }
        // Read before the phase moves, because `pairSizeWarnings` projects
        // the cards and this is the last moment they describe a batch that
        // has not yet been released.
        let warnings = pairSizeWarnings
        let warnedSheetNumbers = warnings.map(\.provisionalSheetNumber)
        let acceptedSheetNumbers = warnings
            .filter(\.isOperatorAccepted)
            .map(\.provisionalSheetNumber)
        phase = .completed(
            CompletionSummary(
                cardCount: liveCards.count,
                firstSheetNumber: liveCards.first?.provisionalSheetNumber,
                lastSheetNumber: liveCards.last?.provisionalSheetNumber,
                nextPersistentCounter: nextSheetNumber,
                destinationDescription: destinationDescription,
                releasedWithSizeWarnings: warnedSheetNumbers,
                releasedWithAcceptedMismatches: acceptedSheetNumbers
            )
        )
        lastIssue = nil
        return []
    }

    func makeCompletionCandidate(
        attemptID: ReleaseAttemptID
    ) throws -> CompletionCandidate {
        let completionCards = try cards.compactMap {
            card -> CompletionCard? in
            guard case let .active(sides) = card.disposition else {
                return nil
            }
            guard let front = sides.front, let back = sides.back else {
                throw BatchSessionError.cardMustBeComplete(card.id)
            }

            return CompletionCard(
                id: card.id,
                provisionalSheetNumber: card.provisionalSheetNumber,
                front: CompletionSide(
                    masterID: front.masterID,
                    rotation: front.rotation,
                    manualCrop: front.manualCrop,
                    mediaSize: front.marginAssessment.mediaSize
                ),
                back: CompletionSide(
                    masterID: back.masterID,
                    rotation: back.rotation,
                    manualCrop: back.manualCrop,
                    mediaSize: back.marginAssessment.mediaSize
                )
            )
        }

        return CompletionCandidate(
            attemptID: attemptID,
            batchID: id,
            jobID: jobID,
            batchName: batchName,
            requestedMargins: requestedMargins,
            cards: completionCards,
            nextPersistentCounter: nextSheetNumber
        )
    }

    func mapDuplexPair(
        first: ScannedSide,
        second: ScannedSide
    ) -> (front: ScannedSide, back: ScannedSide) {
        switch deliveryOrder {
        case .frontFirst:
            (front: first, back: second)
        case .backFirst:
            (front: second, back: first)
        }
    }

    var canStartAppendFromCurrentPhase: Bool {
        switch phase {
        case .ready, .review:
            true
        case .scanning, .releasing, .completed:
            false
        }
    }

    mutating func requireReviewPhase() throws {
        guard case .review = phase else {
            throw BatchSessionError.invalidPhase(
                "This action is available only during review."
            )
        }
    }

    func activeCardIndex(for cardID: CardID) throws -> Int {
        guard let index = cards.firstIndex(where: { $0.id == cardID }) else {
            throw BatchSessionError.cardNotFound(cardID)
        }
        guard !cards[index].isDeleted else {
            throw BatchSessionError.cardDeleted(cardID)
        }
        return index
    }

    func contentCompletionBlockers() -> [CompletionBlocker] {
        let activeCards = cards.filter { !$0.isDeleted }
        guard !activeCards.isEmpty else {
            return [.noActiveCards]
        }

        var blockers: [CompletionBlocker] = []
        for card in activeCards {
            guard case let .active(sides) = card.disposition else {
                continue
            }
            guard sides.isComplete else {
                blockers.append(
                    .incomplete(
                        cardID: card.id,
                        provisionalSheetNumber:
                            card.provisionalSheetNumber,
                        missingSides: sides.missingSides
                    )
                )
                continue
            }

            for side in [OutputSide.front, .back] {
                guard let scannedSide = sides[side] else {
                    continue
                }
                switch scannedSide.marginAssessment {
                case .pending:
                    blockers.append(
                        .marginPending(
                            cardID: card.id,
                            provisionalSheetNumber:
                                card.provisionalSheetNumber,
                            side: side
                        )
                    )
                case .sufficient:
                    break
                case let .insufficient(edges):
                    blockers.append(
                        .insufficientRealMargin(
                            cardID: card.id,
                            provisionalSheetNumber:
                                card.provisionalSheetNumber,
                            side: side,
                            edges: edges
                        )
                    )
                }
            }

            // Front and back captured the same physical item, so their
            // measured footprints must agree. Per-side analysis can be fooled
            // — a scanner streak once stretched a real back 679 px past its
            // own front — and when that happens both sides still read
            // `sufficient` on their own terms. The pair is the cross-check,
            // and it belongs here because publishing two different-sized
            // images of one card is exactly the silent wrong output the
            // reducer exists to refuse.
            //
            // Only a *wide* disagreement refuses the batch
            // (`pairBlockingDisagreementPixels`); between the two thresholds
            // the card is reported through `pairSizeWarnings` instead, so the
            // check keeps its voice without holding the batch hostage. That
            // split is TICKET-033, and it is a deliberate loosening of
            // invariant #2's spirit — see `SPEC.md` section 6.2, which says so
            // in as many words rather than leaving it to be discovered here.
            // The operator may accept one card's wide disagreement and publish
            // it anyway (TICKET-037). That acceptance is consent to the two
            // footprints it was granted against, so `hasLiveAcceptedPairSize
            // Mismatch` re-checks them rather than trusting a flag: a Replace
            // re-measures the pair, and consent must not survive onto numbers
            // nobody was shown. The card stays in `pairSizeWarnings` either
            // way, so accepting silences the *refusal* and never the check.
            if !card.hasManualCrop,
               let sizes = card.assessedPairSizes,
               sizes.front.blocksCompletion(against: sizes.back),
               !card.hasLiveAcceptedPairSizeMismatch
            {
                blockers.append(
                    .mismatchedPairMediaSize(
                        cardID: card.id,
                        provisionalSheetNumber: card.provisionalSheetNumber,
                        front: sizes.front,
                        back: sizes.back
                    )
                )
            }
        }
        return blockers
    }

    func validate() throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw BatchSessionError.unsupportedSchemaVersion(schemaVersion)
        }

        var expectedNumber = firstSheetNumber
        var cardIDs: Set<CardID> = []
        var referencedMasterIDs: Set<MasterID> = []
        var referencedSequences: Set<UInt64> = []

        for card in cards {
            guard cardIDs.insert(card.id).inserted else {
                throw BatchSessionError.duplicateCardID(card.id)
            }
            guard card.provisionalSheetNumber == expectedNumber else {
                throw BatchSessionError.invalidState(
                    "Card numbers are not contiguous allocation tombstones."
                )
            }
            guard expectedNumber < UInt64.max else {
                throw BatchSessionError.invalidState(
                    "An allocated card number has no representable successor."
                )
            }
            expectedNumber += 1

            guard case let .active(sides) = card.disposition else {
                continue
            }
            try validate(
                sides.referencedSides,
                referencedMasterIDs: &referencedMasterIDs,
                referencedSequences: &referencedSequences
            )
            if let front = sides.front, let back = sides.back {
                let isAdjacentDuplexPair = switch deliveryOrder {
                case .frontFirst:
                    front.captureSequence < UInt64.max
                        && back.captureSequence
                            == front.captureSequence + 1
                case .backFirst:
                    back.captureSequence < UInt64.max
                        && front.captureSequence
                            == back.captureSequence + 1
                }
                guard isAdjacentDuplexPair else {
                    throw BatchSessionError.invalidState(
                        "A complete card is not an adjacent duplex pair in "
                            + "the configured delivery order."
                    )
                }
            }
        }

        guard nextSheetNumber == expectedNumber else {
            throw BatchSessionError.invalidState(
                "The provisional counter does not match allocated card slots."
            )
        }

        switch phase {
        case .ready:
            guard cards.isEmpty,
                  nextCaptureSequence == 0,
                  usedMasterIDs.isEmpty,
                  usedScanPassIDs.isEmpty,
                  usedReleaseAttemptIDs.isEmpty,
                  lastIssue == nil
            else {
                throw BatchSessionError.invalidState(
                    "A ready batch cannot contain cards or operation history."
                )
            }

        case let .scanning(activePass):
            guard usedScanPassIDs.contains(activePass.id) else {
                throw BatchSessionError.invalidState(
                    "The active scan-pass identifier was not registered."
                )
            }
            switch activePass.operation {
            case let .append(pendingCardID):
                let incompleteCards = cards.filter { $0.isIncomplete }
                if let pendingCardID {
                    let expectedFirstSide: OutputSide = switch deliveryOrder {
                    case .frontFirst:
                        .front
                    case .backFirst:
                        .back
                    }
                    let expectedSecondSide: OutputSide =
                        expectedFirstSide == .front ? .back : .front
                    let pendingSides = incompleteCards.first?.activeSides
                    guard incompleteCards.count == 1,
                          incompleteCards.first?.id == pendingCardID,
                          cards.last?.id == pendingCardID,
                          pendingSides?.referencedSides.count == 1,
                          pendingSides?[expectedFirstSide] != nil,
                          pendingSides?[expectedSecondSide] == nil,
                          nextCaptureSequence > 0,
                          pendingSides?[expectedFirstSide]?.captureSequence
                            == nextCaptureSequence - 1
                    else {
                        throw BatchSessionError.invalidState(
                            "The append pass has an invalid pending card."
                        )
                    }
                } else {
                    guard incompleteCards.isEmpty else {
                        throw BatchSessionError.invalidState(
                            "An append pass without a pending card has an "
                                + "incomplete row."
                        )
                    }
                }

            case let .retry(target, staged):
                let index = try activeCardIndex(for: target)
                guard cards[index].isIncomplete else {
                    throw BatchSessionError.invalidState(
                        "The active Retry target is not incomplete."
                    )
                }
                try validate(
                    staged,
                    referencedMasterIDs: &referencedMasterIDs,
                    referencedSequences: &referencedSequences
                )
                try validateStagedCaptureOrder(staged)

            case let .replace(target, staged):
                let index = try activeCardIndex(for: target)
                guard cards[index].activeSides?.isComplete == true else {
                    throw BatchSessionError.invalidState(
                        "The active Replace target is not complete."
                    )
                }
                try validate(
                    staged,
                    referencedMasterIDs: &referencedMasterIDs,
                    referencedSequences: &referencedSequences
                )
                try validateStagedCaptureOrder(staged)
            }

        case .review:
            break

        case let .releasing(attempt):
            guard usedReleaseAttemptIDs.contains(attempt.id),
                  contentCompletionBlockers().isEmpty
            else {
                throw BatchSessionError.invalidState(
                    "The releasing batch is not a valid completion candidate."
                )
            }

        case let .completed(summary):
            let liveCards = cards.filter { !$0.isDeleted }
            guard contentCompletionBlockers().isEmpty,
                  summary.cardCount == liveCards.count,
                  summary.firstSheetNumber
                    == liveCards.first?.provisionalSheetNumber,
                  summary.lastSheetNumber
                    == liveCards.last?.provisionalSheetNumber,
                  summary.nextPersistentCounter == nextSheetNumber
            else {
                throw BatchSessionError.invalidState(
                    "The completed-batch summary does not match its cards."
                )
            }
        }

        guard usedMasterIDs.isSuperset(of: referencedMasterIDs) else {
            throw BatchSessionError.invalidState(
                "A referenced master identifier was not registered."
            )
        }
        guard UInt64(usedMasterIDs.count) == nextCaptureSequence else {
            throw BatchSessionError.invalidState(
                "The capture high-water mark does not match received masters."
            )
        }
        guard referencedSequences.allSatisfy({
            $0 < nextCaptureSequence
        }) else {
            throw BatchSessionError.invalidState(
                "A referenced capture sequence is outside the high-water mark."
            )
        }
    }

    func validate(
        _ sides: [ScannedSide],
        referencedMasterIDs: inout Set<MasterID>,
        referencedSequences: inout Set<UInt64>
    ) throws {
        for side in sides {
            if case let .insufficient(edges) = side.marginAssessment,
               edges.isEmpty
            {
                throw BatchSessionError.invalidState(
                    "An insufficient-margin assessment must name an edge."
                )
            }
            guard referencedMasterIDs.insert(side.masterID).inserted else {
                throw BatchSessionError.duplicateMasterID(side.masterID)
            }
            guard referencedSequences.insert(side.captureSequence).inserted else {
                throw BatchSessionError.invalidState(
                    "A capture sequence is referenced more than once."
                )
            }
        }
    }

    func validateStagedCaptureOrder(_ staged: [ScannedSide]) throws {
        let count = UInt64(staged.count)
        guard count <= nextCaptureSequence else {
            throw BatchSessionError.invalidState(
                "Staged pages exceed the capture high-water mark."
            )
        }

        let firstSequence = nextCaptureSequence - count
        for (offset, side) in staged.enumerated() {
            guard side.captureSequence == firstSequence + UInt64(offset) else {
                throw BatchSessionError.invalidState(
                    "Staged pages are not the latest capture-sequence suffix "
                        + "in arrival order."
                )
            }
        }
    }
}
