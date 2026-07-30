import Foundation
import ScanDeckCore
import Testing
@testable import ScanDeckApp

/// What the model costs at the size a real batch actually reaches.
///
/// TICKET-030 was observed on a 186-card batch: pressing Complete Batch left
/// the operator watching an unresponsive window for about a minute with no
/// explanation, and the press had in fact been *refused* — 27 cards failed the
/// pair gate. The distinction matters enormously (fix 27 cards, or force-quit
/// and lose the evening) and the app was unable to draw it.
///
/// The ticket asks for the mechanism to be measured rather than assumed, so
/// these tests measure it. They assert budgets rather than absolute times:
/// a projection that is linear in the card count and rebuilt several times per
/// redraw is the shape of the defect, and the budgets are set far enough above
/// the fixed version that only a return to that shape trips them.
@MainActor
@Suite("Batch scale")
struct BatchScaleTests {
    /// The size a real batch actually reaches.
    ///
    /// It was 186 — the size TICKET-030 was reported at — until the operator
    /// said a normal batch is 300–400 cards (D-10, TICKET-036). So the number
    /// every performance figure in the tracker was taken at turns out to be
    /// *half* a working batch, and this suite is the cheapest place for
    /// anything superlinear to show itself. 400 cards is 800 sides and 800
    /// rows to project.
    private static let realBatchCardCount = 400

    /// The size the defects in the comments below were observed at, kept so
    /// those stories still describe the batch they happened to.
    private static let reportedBatchCardCount = 186

    @Test("A refused Complete Batch press says so before it returns")
    func refusedCompletionIsImmediate() async throws {
        let context = try await makeLargeBatch(
            mismatchedPairsFromCardIndex: 0
        )
        let model = context.model

        #expect(model.activeBatch?.cards.count == Self.realBatchCardCount)
        #expect(!model.canCompleteBatch)

        // The press itself, timed. A refusal must be a synchronous answer: the
        // notice is already written, and what the operator lost was it ever
        // being painted.
        let clock = ContinuousClock()
        let elapsed = clock.measure {
            model.completeBatch()
        }

        print(
            "scale: refused Complete Batch press \(elapsed) at "
                + "\(Self.realBatchCardCount) cards"
        )
        let notice = try #require(model.notice)
        #expect(notice.title == "Batch is not ready")
        #expect(context.actions.publishRequests.isEmpty)
        #expect(
            elapsed < .milliseconds(100),
            Comment(
                rawValue: "A refused Complete Batch press took \(elapsed) at "
                    + "\(Self.realBatchCardCount) cards. The operator reads "
                    + "that delay as a publish in progress."
            )
        )
    }

    @Test("A blocked batch does not report itself ready")
    func blockedCardsAreVisibleInTheProjection() async throws {
        // 27 blocked cards — the count the operator hit on `carlsoboxone`
        // before TICKET-027 fixed the detector and TICKET-033 relaxed the
        // gate, and still the right size for this test: what is under
        // examination is whether a projection can carry the reducer's verdict
        // at batch scale, not how often the verdict arises. These pairs
        // disagree by 408 × 686 px, far past the blocking threshold.
        let context = try await makeLargeBatch(
            mismatchedPairsFromCardIndex: Self.realBatchCardCount - 27
        )
        let batch = try #require(context.model.activeBatch)

        #expect(!context.model.canCompleteBatch)
        #expect(batch.blockedCardIDs.count == 27)

        // The two signals the review UI had are both blind to this failure: a
        // mismatched pair requires *both* sides to have read `.sufficient`
        // before it can arise, so no row is marked and nothing is incomplete.
        // The batch therefore described itself as 186 cards ready while 27 of
        // them could not be published — and the only thing that disagreed was
        // a banner scrolled off the top of a 186-row list.
        #expect(batch.incompleteCards.isEmpty)
        #expect(batch.cardsWithMarginIssues.isEmpty)
        #expect(batch.completedCardCount == Self.realBatchCardCount)

        // So the projection has to carry the reducer's own verdict.
        let blocked = batch.blockedCards
        #expect(blocked.count == 27)
        #expect(blocked.allSatisfy { batch.blockedCardIDs.contains($0.id) })
    }

    @Test("The batch projection stays cheap enough to rebuild on every redraw")
    func projectionCostAtRealBatchSize() async throws {
        let context = try await makeLargeBatch()
        let model = context.model

        // A single redraw of the workspace reads `activeBatch`, `selectedCard`
        // and `completionBlockReason` between them several times over — the
        // sidebar, the inspector, the row list and the action bar each ask.
        // Ten reads is a conservative stand-in for one redraw.
        let clock = ContinuousClock()
        let elapsed = clock.measure {
            for _ in 0..<10 {
                _ = model.activeBatch
                _ = model.selectedCard
                _ = model.completionBlockReason
                _ = model.canCompleteBatch
            }
        }

        print(
            "scale: ten redraws' worth of projection reads \(elapsed) at "
                + "\(Self.realBatchCardCount) cards"
        )
        #expect(
            elapsed < .milliseconds(50),
            Comment(
                rawValue: "Ten redraws' worth of projection reads took "
                    + "\(elapsed) at \(Self.realBatchCardCount) cards."
            )
        )
    }

    @Test("Selecting a card does not rebuild the whole batch")
    func selectedCardIsNotAWholeBatchRebuild() async throws {
        let context = try await makeLargeBatch()
        let model = context.model
        let batch = try #require(model.activeBatch)
        model.selectedCardID = batch.cards.last?.id

        let clock = ContinuousClock()
        let wholeBatch = clock.measure {
            for _ in 0..<20 {
                _ = model.activeBatch
            }
        }
        let oneCard = clock.measure {
            for _ in 0..<20 {
                _ = model.selectedCard
            }
        }

        print(
            "scale: 20 whole-batch projections \(wholeBatch), "
                + "20 single-card projections \(oneCard), at "
                + "\(Self.realBatchCardCount) cards"
        )
        #expect(model.selectedCard?.id == batch.cards.last?.id)
        // `selectedCard` used to be `activeBatch?.cards.first { … }`, which
        // built 186 rows and 372 sides to hand back one of them — and views
        // read it beside `activeBatch`, so the batch was projected twice per
        // redraw to show one inspector pane.
        #expect(
            oneCard < wholeBatch,
            Comment(
                rawValue: "Reading one card cost \(oneCard) against "
                    + "\(wholeBatch) for the whole batch, so it is still "
                    + "projecting everything."
            )
        )
    }

    @Test("Doubling the batch does not more than double the projection")
    func projectionGrowsLinearly() async throws {
        // TICKET-036's actual question. Every performance figure in the
        // tracker was taken at 186 cards, which turned out to be half a real
        // batch (D-10) — so the thing worth guarding is not any single
        // number, it is the *shape*. A projection that is linear in the card
        // count stays affordable at 400 and at 800; one that is quadratic is
        // the defect TICKET-030 was, and it would first become visible here.
        //
        // Measured on the reference machine, debug, per whole-batch
        // projection: 0.471 ms at 186, 1.007 ms at 400, 2.085 ms at 800 —
        // 2.14× for 2.15× the cards, then 2.07× for 2×.
        //
        // One timed pass per size is not a measurement of this, though, and
        // that is how the guard was first written. `swift test` runs 24 suites
        // in parallel and the `CardImageCropper` debug suites saturate the
        // machine for eighty seconds, so a single pass samples whatever load
        // happened to be in flight when it ran. Inside the full debug suite it
        // read 3.09 on one run — a failure — and 0.44 on the next. A ratio of
        // 0.44 says 400 cards cost *less* than 200, which cannot happen: the
        // number was reporting contention, not shape, and a guard that noisy
        // can fail a linear projection and pass a quadratic one. Run alone the
        // same code reads 1.81–2.05.
        //
        // So build both batches before timing anything, interleave the passes
        // so the two sizes see the same load window, and keep the *fastest*
        // pass at each size. A loaded scheduler steals time from a sample and
        // never gives any back, so the minimum is the closest available
        // estimate of what the projection itself costs.
        let smallModel = try await makeLargeBatch(cardCount: 200).model
        let largeModel = try await makeLargeBatch(cardCount: 400).model
        // One untimed pass each, so lazily-built state is charged to neither.
        _ = smallModel.activeBatch
        _ = largeModel.activeBatch

        func pass(_ model: ScanDeckPresentationModel) -> Duration {
            ContinuousClock().measure {
                for _ in 0..<20 {
                    _ = model.activeBatch
                }
            }
        }

        var smallSamples: [Duration] = []
        var largeSamples: [Duration] = []
        for _ in 0..<5 {
            smallSamples.append(pass(smallModel))
            largeSamples.append(pass(largeModel))
        }
        let small = try #require(smallSamples.min())
        let large = try #require(largeSamples.min())
        let ratio = Double(large.components.attoseconds)
            / Double(max(small.components.attoseconds, 1))
        print(
            "scale: projection cost \(small) at 200 cards, \(large) at 400 — "
                + "ratio \(ratio) (best of 5 interleaved passes each)"
        )
        // Linear is 2.0 and quadratic is 4.0. Budgeted at 3.0, which is
        // generous enough for a loaded machine and still nowhere near
        // quadratic.
        #expect(
            ratio < 3.0,
            Comment(
                rawValue: "Doubling the batch multiplied the projection cost "
                    + "by \(ratio) (\(small) → \(large)). Linear is 2."
            )
        )
    }

    // MARK: - Harness

    private struct Context {
        let model: ScanDeckPresentationModel
        let actions: ScaleTestActions
    }

    /// Feeds `realBatchCardCount` complete cards through the model the way a
    /// real run does — one pass, pages in delivery order — so the state under
    /// measurement is the state the operator had.
    ///
    /// - Parameter mismatchedPairsFromCardIndex: When set, every card from that
    ///   index on measures a different media size front to back, which is the
    ///   condition that refused the operator's press.
    private func makeLargeBatch(
        cardCount: Int? = nil,
        mismatchedPairsFromCardIndex: Int? = nil
    ) async throws -> Context {
        let cardCount = cardCount ?? Self.realBatchCardCount
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let profile = ScanProfileViewData.cards600FullBorder
        let counterStore = JobCounterStore(directory: directory)
        try counterStore.seed(1, for: JobID(rawValue: profile.id))

        let actions = ScaleTestActions(
            pageCount: cardCount * 2,
            mismatchedPairsFromCardIndex: mismatchedPairsFromCardIndex
        )
        let model = ScanDeckPresentationModel(
            profiles: [profile],
            scannerStatus: ScannerStatusMonitor(
                source: ScriptedScannerInventorySource()
            ),
            actions: actions,
            destinationPicker: StubScaleDestinationPicker(),
            destinationBookmarkStore: DestinationBookmarkStore(
                storage: InMemoryDestinationBookmarkStorage()
            ),
            jobCounterStore: counterStore,
            sessionStore: BatchSessionStore(
                directory: directory.appending(
                    path: "Sessions",
                    directoryHint: .isDirectory
                )
            ),
            settingsStore: ScanDeckSettingsStore(
                storage: InMemoryScanDeckSettingsStorage()
            ),
            publishedBatchStore: PublishedBatchStore(directory: directory)
        )

        model.batchDraft.name = "carlsoboxone"
        model.batchDraft.destinationURL = URL(
            fileURLWithPath: "/tmp/scandeck-tests",
            isDirectory: true
        )
        model.armBatch()

        // 400 cards is 800 scripted pages through the reducer, and a debug
        // build takes well over the default 30 s to feed them. The timeout is
        // about how slow an unoptimised build is, not about how long the app
        // takes: the same suite runs in about 15 s in release.
        let assembly = Duration.seconds(300)
        model.startOrContinueScan()
        try await waitUntil(
            { model.activeBatch?.phase != .scanning },
            within: assembly
        )
        // Margin verdicts land asynchronously, one detached analysis per side,
        // and the pair gate cannot be measured until every one has arrived.
        try await waitUntil(
            {
                model.activeBatch?.cards.allSatisfy { card in
                    card.front?.marginAssessment != .pending
                        && card.back?.marginAssessment != .pending
                } == true
            },
            within: assembly
        )

        return Context(model: model, actions: actions)
    }

    private func waitUntil(
        _ condition: @MainActor () -> Bool,
        within timeout: Duration = .seconds(60),
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition() {
                return
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record(
            "Condition was never satisfied.",
            sourceLocation: sourceLocation
        )
    }
}

@MainActor
private final class ScaleTestActions: ScanDeckAppActions {
    private(set) var publishRequests: [BatchPublishRequest] = []

    private let pageCount: Int
    private let mismatchedPairsFromCardIndex: Int?
    private var pageIndex = 0

    init(pageCount: Int, mismatchedPairsFromCardIndex: Int?) {
        self.pageCount = pageCount
        self.mismatchedPairsFromCardIndex = mismatchedPairsFromCardIndex
    }

    func scan(_ request: ScanPassRequest) -> AsyncStream<ScanPassProgress> {
        let pageCount = pageCount
        return AsyncStream { continuation in
            for index in 0..<pageCount {
                continuation.yield(
                    .page(
                        URL(
                            fileURLWithPath:
                                "/tmp/scandeck-tests/page-\(index).jpg"
                        )
                    )
                )
            }
            continuation.yield(.finished(.succeeded))
            continuation.finish()
        }
    }

    func assessMargin(
        _ request: MarginAssessmentRequest
    ) async -> MarginAssessmentOutcome {
        // The page URL carries its own delivery index, which is what says
        // whether this side is a front and which card it belongs to.
        let name = request.imageURL?.deletingPathExtension().lastPathComponent
        let index = Int(name?.replacingOccurrences(of: "page-", with: "") ?? "")
            ?? pageIndex
        pageIndex += 1

        let cardIndex = index / 2
        let isBack = index.isMultiple(of: 2) == false
        let mismatched = mismatchedPairsFromCardIndex.map { cardIndex >= $0 }
            ?? false

        // The real failure was not two sizes of one framing: the front detected
        // the card (~69 mm) and the back detected the holder (~85 mm).
        let size = mismatched && isBack
            ? MediaPixelSize(width: 2_029, height: 2_948)
            : MediaPixelSize(width: 1_621, height: 2_262)
        return MarginAssessmentOutcome(
            assessment: .sufficient(mediaSize: size),
            publishedCrop: nil
        )
    }

    func publish(
        _ request: BatchPublishRequest,
        progress: @escaping @Sendable (BatchPublishProgress) -> Void
    ) async throws -> BatchPublishReceipt {
        publishRequests.append(request)
        let folder = request.destinationURL.appending(
            path: request.candidate.batchName.value,
            directoryHint: .isDirectory
        )
        return BatchPublishReceipt(
            publishedFolderURL: folder,
            destinationDescription: folder.lastPathComponent
        )
    }

    func showInFinder(_ url: URL?) {}
}

@MainActor
private final class StubScaleDestinationPicker: DestinationPicking {
    func pickDestination(startingAt url: URL?) -> URL? { nil }
}
