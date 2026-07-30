import Foundation
import ScanDeckCore
import Testing
@testable import ScanDeckApp

/// Drives the presentation model through complete batches without hardware.
///
/// These tests exist because the reducer's safety rules are only worth as much
/// as the wiring that reaches them: the model must dispatch the right actions,
/// mint a new card identifier only when a page starts a card, and let the
/// reducer — never the UI — decide when scanning and completion are allowed.
@MainActor
@Suite("Batch workflow")
struct BatchWorkflowTests {
    @Test("A five-page pass yields two complete cards and one incomplete row")
    func oddPageCountProducesIncompleteCard() async throws {
        let context = makeModel(pagesPerPass: [5])
        let model = context.model
        armBatch(model)

        model.startOrContinueScan()
        try await waitForScanToFinish(model)
        #expect(model.activeBatch?.cards.count == 3)

        let batch = try #require(model.activeBatch)
        #expect(batch.completedCardCount == 2)
        #expect(batch.incompleteCards.count == 1)
        #expect(batch.cards.map(\.sheetNumber) == [114, 115, 116])

        // The incomplete row must block both gates, per SPEC section 4 beat 4.
        #expect(!model.canStartScan)
        #expect(!model.canCompleteBatch)
        #expect(model.notice?.title == "Incomplete card")
    }

    @Test("Retry completes the incomplete row and unblocks completion")
    func retryUnblocksCompletion() async throws {
        let context = makeModel(pagesPerPass: [5, 2])
        let model = context.model
        armBatch(model)

        model.startOrContinueScan()
        try await waitForScanToFinish(model)

        let incomplete = try #require(model.activeBatch?.incompleteCards.first)
        let retainedNumber = incomplete.sheetNumber
        model.retryCard(incomplete.id)
        try await waitForScanToFinish(model)
        #expect(model.activeBatch?.incompleteCards.isEmpty == true)

        let batch = try #require(model.activeBatch)
        #expect(batch.cards.count == 3)
        // Retry keeps the card's provisional number (SPEC section 4 beat 4).
        #expect(batch.cards.last?.sheetNumber == retainedNumber)

        try await waitUntil { model.canCompleteBatch }
        #expect(model.completionBlockReason == nil)
    }

    @Test("Deleting the incomplete row also unblocks scanning")
    func deletingIncompleteCardUnblocksScanning() async throws {
        let context = makeModel(pagesPerPass: [5])
        let model = context.model
        armBatch(model)

        model.startOrContinueScan()
        try await waitForScanToFinish(model)

        let incomplete = try #require(model.activeBatch?.incompleteCards.first)
        model.deleteCard(incomplete.id)

        #expect(model.activeBatch?.cards.count == 2)
        #expect(model.canStartScan)
        // The deletion leaves an intentional counter gap; numbers never compact.
        #expect(model.activeBatch?.cards.map(\.sheetNumber) == [114, 115])
    }

    @Test("An insufficient real margin blocks completion and names the edge")
    func insufficientMarginBlocksCompletion() async throws {
        let context = makeModel(pagesPerPass: [2])
        context.actions.marginAssessment = .insufficient(edges: [.top])
        let model = context.model
        armBatch(model)

        model.startOrContinueScan()
        try await waitForScanToFinish(model)
        try await waitUntil {
            model.activeBatch?.cards.first?.hasMarginIssue == true
        }

        #expect(!model.canCompleteBatch)
        let reason = try #require(model.completionBlockReason)
        #expect(reason.contains("top"))
        #expect(reason.contains("real background"))

        model.completeBatch()
        #expect(model.completionSummary == nil)
        #expect(context.actions.publishRequests.isEmpty)
    }

    @Test("A jammed pass offers Retry Card on the notice and it works")
    func failedPassOffersRetryAction() async throws {
        let context = makeModel(pagesPerPass: [1, 2])
        context.actions.failAfterPages = true
        let model = context.model
        armBatch(model)

        model.startOrContinueScan()
        try await waitUntil { model.notice?.kind == .error }

        // One page went through before the jam, so the card is incomplete and
        // retrying that card is the only move the reducer will accept — the
        // notice's button must be that move, and the jam copy itself must
        // survive rather than being clobbered by the generic incomplete-card
        // warning.
        let incomplete = try #require(model.activeBatch?.incompleteCards.first)
        #expect(model.notice?.title == "Scan could not finish")
        #expect(model.notice?.action == .retryCard(incomplete.id))

        context.actions.failAfterPages = false
        model.performNoticeAction()
        try await waitForScanToFinish(model)

        #expect(model.activeBatch?.incompleteCards.isEmpty == true)
        #expect(model.activeBatch?.cards.count == 1)
    }

    @Test("A failed pass that left whole cards offers Scan Again")
    func failedPassWithWholeCardsOffersContinue() async throws {
        let context = makeModel(pagesPerPass: [2])
        context.actions.failAfterPages = true
        let model = context.model
        armBatch(model)

        model.startOrContinueScan()
        try await waitUntil { model.notice?.kind == .error }

        #expect(model.notice?.action == .continueScanning)
    }

    @Test("A pair that measures two different item sizes blocks completion")
    func mismatchedPairSizeBlocksCompletion() async throws {
        let context = makeModel(pagesPerPass: [2])
        // Both sides read sufficient on their own terms — the defect class
        // where a scanner streak stretches one side's detection — so only the
        // reducer's pair-agreement gate can refuse the batch.
        context.actions.assessmentOverride = { request in
            let name = request.imageURL?.lastPathComponent ?? ""
            return .sufficient(
                mediaSize: name.hasPrefix("page-1-")
                    ? MediaPixelSize(width: 1_822, height: 3_094)
                    : MediaPixelSize(width: 1_819, height: 2_415)
            )
        }
        let model = context.model
        armBatch(model)

        model.startOrContinueScan()
        try await waitForScanToFinish(model)
        try await waitUntil {
            model.completionBlockReason?.contains("different item sizes")
                == true
        }

        #expect(!model.canCompleteBatch)
        let reason = try #require(model.completionBlockReason)
        #expect(reason.contains("Replace the card"))

        // The mismatch must announce itself the moment it arises — both
        // sides read sufficient on their own, so nothing else would ever
        // tell the operator why Complete Batch stopped working.
        let card = try #require(model.activeBatch?.cards.first)
        try await waitUntil { model.notice?.title == "Card sizes disagree" }
        #expect(model.notice?.action == .replaceCard(card.id))

        model.completeBatch()
        #expect(model.completionSummary == nil)
        #expect(context.actions.publishRequests.isEmpty)
    }

    @Test("Accepting a blocked pair publishes it and says so afterwards")
    func acceptedPairSizeMismatchPublishes() async throws {
        let context = makeModel(pagesPerPass: [2])
        // The disagreement the operator hit on `carlsofirstbox`: 1602 × 2188
        // against 1820 × 2408, 218 px apart and well past the blocking line.
        context.actions.assessmentOverride = { request in
            let name = request.imageURL?.lastPathComponent ?? ""
            return .sufficient(
                mediaSize: name.hasPrefix("page-1-")
                    ? MediaPixelSize(width: 1_820, height: 2_408)
                    : MediaPixelSize(width: 1_602, height: 2_188)
            )
        }
        let model = context.model
        armBatch(model)

        model.startOrContinueScan()
        try await waitForScanToFinish(model)
        try await waitUntil { model.notice?.title == "Card sizes disagree" }
        #expect(!model.canCompleteBatch)

        let card = try #require(model.activeBatch?.cards.first)
        // The override is offered on the banner and on the row, and both read
        // the same projected decision.
        #expect(model.noticeAcceptablePairCardID == card.id)
        #expect(
            model.activeBatch?.overridableSizeBlockedCardIDs == [card.id]
        )

        model.requestSizeAcceptance(card.id)
        #expect(model.cardPendingSizeAcceptanceConfirmation == card.id)
        // The confirmation states the two footprints and the millimetres, not
        // "are you sure?".
        let message = model.sizeAcceptanceConfirmationMessage
        #expect(message.contains("1602 × 2188"))
        #expect(message.contains("1820 × 2408"))
        // 220 px is the larger of the two per-axis differences (2408 − 2188),
        // which is what both thresholds compare against — so the millimetres
        // quoted to the operator are the worst axis, not the average.
        #expect(message.contains("9.3 mm"))
        // One card blocking means no "Publish All" button.
        #expect(model.otherBlockingPairMismatchCount == 0)

        model.confirmSizeAcceptance()

        #expect(model.canCompleteBatch)
        #expect(model.completionBlockReason == nil)
        #expect(model.notice == nil)
        // Cleared the refusal, kept the check: the row now says a person
        // overruled it rather than reverting to "Ready".
        let accepted = try #require(model.activeBatch?.cards.first)
        #expect(accepted.acceptedSizeDisagreement)
        #expect(accepted.sizeDisagreementPixels == 220)
        #expect(model.activeBatch?.cardsPublishedAnyway.count == 1)

        model.completeBatch()
        try await waitUntil { model.completionSummary != nil }
        let summary = try #require(model.completionSummary)
        #expect(summary.releasedWithAcceptedMismatches == [accepted.sheetNumber])
        #expect(summary.releasedWithWarningsOnly.isEmpty)
        #expect(context.actions.publishRequests.count == 1)
    }

    @Test("An acceptance can be taken back and the refusal returns")
    func withdrawnAcceptanceBlocksAgain() async throws {
        let context = makeModel(pagesPerPass: [2])
        context.actions.assessmentOverride = { request in
            let name = request.imageURL?.lastPathComponent ?? ""
            return .sufficient(
                mediaSize: name.hasPrefix("page-1-")
                    ? MediaPixelSize(width: 1_820, height: 2_408)
                    : MediaPixelSize(width: 1_602, height: 2_188)
            )
        }
        let model = context.model
        armBatch(model)

        model.startOrContinueScan()
        try await waitForScanToFinish(model)
        try await waitUntil { model.completionBlockReason != nil }

        let card = try #require(model.activeBatch?.cards.first)
        model.requestSizeAcceptance(card.id)
        model.confirmSizeAcceptance()
        #expect(model.canCompleteBatch)
        #expect(model.hasAcceptedSizeDisagreement(card.id))

        model.withdrawSizeAcceptance(card.id)

        #expect(!model.canCompleteBatch)
        #expect(!model.hasAcceptedSizeDisagreement(card.id))
        // Taking it back must put the explanation back too, or the batch is
        // blocked with nothing on screen saying why.
        #expect(model.notice?.title == "Card sizes disagree")
        #expect(model.activeBatch?.cardsPublishedAnyway.isEmpty == true)
    }

    @Test("Completing publishes once and reports the counter range")
    func completionPublishesOnce() async throws {
        let context = makeModel(pagesPerPass: [4])
        let model = context.model
        armBatch(model)

        model.startOrContinueScan()
        try await waitUntil { model.canCompleteBatch }

        model.completeBatch()
        try await waitUntil { model.completionSummary != nil }

        #expect(context.actions.publishRequests.count == 1)
        let summary = try #require(model.completionSummary)
        #expect(summary.batchName == "aug01-sale")
        #expect(summary.cardCount == 2)
        #expect(summary.counterRange == 114...115)

        // Every published card must carry a resolvable master.
        let request = try #require(context.actions.publishRequests.first)
        for card in request.candidate.cards {
            #expect(request.masterURLs[card.front.masterID] != nil)
            #expect(request.masterURLs[card.back.masterID] != nil)
        }
    }

    @Test("A completed batch hands its published folder to centering with counts")
    func completedBatchCanCheckCentering() async throws {
        let context = makeModel(pagesPerPass: [4])
        let model = context.model
        armBatch(model)
        model.startOrContinueScan()
        try await waitUntil { model.canCompleteBatch }
        model.completeBatch()
        try await waitUntil { model.completionSummary != nil }

        context.actions.centeringProgress = [
            CenteringCheckProgress(
                completedImages: 0,
                imageCount: 4,
                uploadedImages: 0,
                cachedImages: 0,
                failedImages: 0
            ),
            CenteringCheckProgress(
                completedImages: 2,
                imageCount: 4,
                uploadedImages: 2,
                cachedImages: 0,
                failedImages: 0
            ),
            CenteringCheckProgress(
                completedImages: 4,
                imageCount: 4,
                uploadedImages: 4,
                cachedImages: 0,
                failedImages: 0
            ),
        ]
        var sawIntermediateProgress = false
        context.actions.centeringStep = { step in
            guard step.completedImages == 2 else {
                return
            }
            let deadline = ContinuousClock.now + .seconds(2)
            while ContinuousClock.now < deadline {
                if case let .running(progress) = model.centeringCheckStatus,
                   progress.completedImages == 2 {
                    sawIntermediateProgress = true
                    return
                }
                await Task.yield()
            }
        }

        model.requestCompletedBatchCentering()
        let consent = try #require(model.centeringCheckConsent)
        #expect(context.actions.centeringRequests.isEmpty)
        #expect(consent.imageCount == 4)
        #expect(consent.title.contains("centeringcheck.com"))
        #expect(consent.title.contains("4 images"))
        #expect(consent.message.contains("will not be remembered"))
        model.confirmCompletedBatchCentering()
        #expect(model.centeringCheckConsent == nil)
        try await waitUntil {
            if case .completed = model.centeringCheckStatus {
                return true
            }
            return false
        }

        let request = try #require(context.actions.centeringRequests.first)
        #expect(context.actions.centeringRequests.count == 1)
        #expect(request.imageCount == 4)
        #expect(request.publishedFolderURL.lastPathComponent == "aug01-sale")
        #expect(sawIntermediateProgress)
        guard case let .completed(receipt) = model.centeringCheckStatus else {
            Issue.record("The centering run did not complete.")
            return
        }
        #expect(receipt.outputFolderURL.lastPathComponent == "centering")
        #expect(receipt.uploadedImages == 4)

        // Even a cache-only re-run crosses a fresh confirmation.
        model.requestCompletedBatchCentering()
        #expect(model.centeringCheckConsent?.imageCount == 4)
        #expect(context.actions.centeringRequests.count == 1)
        model.cancelCenteringCheckConsent()
        #expect(model.centeringCheckConsent == nil)
    }

    @Test("Publishing records the batch in the history that survives a relaunch")
    func publishingRecordsBatchHistory() async throws {
        let context = makeModel(pagesPerPass: [4])
        let model = context.model
        #expect(model.publishedBatches.isEmpty)
        armBatch(model)
        model.startOrContinueScan()
        try await waitUntil { model.canCompleteBatch }
        model.completeBatch()
        try await waitUntil { model.completionSummary != nil }

        let record = try #require(model.publishedBatches.first)
        #expect(model.publishedBatches.count == 1)
        #expect(record.batchName.value == "aug01-sale")
        #expect(record.cardCount == 2)
        #expect(record.firstSheetNumber == 114)
        #expect(record.lastSheetNumber == 115)
        #expect(model.publishedBatch(record.id) == record)

        // The point of the store: a second model over the same directory is a
        // relaunch, and it must still be able to name the batch. Before this,
        // the app forgot every batch it had ever produced the moment the
        // completion screen went away.
        let relaunched = context.makeRelaunchedModel()
        #expect(relaunched.publishedBatches.map(\.batchName.value)
            == ["aug01-sale"])

        // Forgetting a row never touches the published folder.
        relaunched.forgetPublishedBatch(record)
        #expect(relaunched.publishedBatches.isEmpty)
        #expect(context.makeRelaunchedModel().publishedBatches.isEmpty)
    }

    @Test("A batch from an earlier session can still be sent for centering")
    func previousBatchCanCheckCentering() async throws {
        let context = makeModel(pagesPerPass: [4])
        let model = context.model
        armBatch(model)
        model.startOrContinueScan()
        try await waitUntil { model.canCompleteBatch }
        model.completeBatch()
        try await waitUntil { model.completionSummary != nil }
        let record = try #require(model.publishedBatches.first)

        // A relaunch: no completionSummary, so the completion screen's route to
        // centering does not exist. This is exactly the state the operator was
        // in when they could not find the button.
        let relaunched = context.makeRelaunchedModel()
        #expect(relaunched.completionSummary == nil)
        let reopened = try #require(relaunched.publishedBatches.first)

        relaunched.requestCentering(for: reopened)

        let consent = try #require(relaunched.centeringCheckConsent)
        // Counted off the folder rather than from cardCount * 2: months may
        // pass and carduploader runs against these folders, so only the
        // directory says what is actually there to send.
        #expect(consent.imageCount == 4)
        #expect(consent.title.contains("centeringcheck.com"))
        // The one alert now serves several batches, so it has to name which.
        #expect(relaunched.centeringCheckConsentMessage.contains("aug01-sale"))
        #expect(context.actions.centeringRequests.isEmpty)

        relaunched.confirmCompletedBatchCentering()
        try await waitUntil {
            if case .completed = relaunched.centeringCheckStatus {
                return true
            }
            return false
        }

        let request = try #require(context.actions.centeringRequests.first)
        #expect(request.imageCount == 4)
        #expect(request.publishedFolderURL.lastPathComponent == "aug01-sale")
        #expect(record.batchName.value == reopened.batchName.value)
    }

    @Test("A previous batch whose folder is gone refuses rather than uploading")
    func previousBatchWithMissingFolderRefuses() async throws {
        let context = makeModel(pagesPerPass: [4])
        let model = context.model
        armBatch(model)
        model.startOrContinueScan()
        try await waitUntil { model.canCompleteBatch }
        model.completeBatch()
        try await waitUntil { model.completionSummary != nil }
        let record = try #require(model.publishedBatches.first)
        let folder = try #require(record.resolveDestinationURL())

        // The operator moved it, or the volume is not mounted.
        try FileManager.default.removeItem(at: folder)
        let relaunched = context.makeRelaunchedModel()
        let reopened = try #require(relaunched.publishedBatches.first)

        relaunched.requestCentering(for: reopened)

        // No consent armed, nothing uploaded, and the row still names the batch:
        // the numbers it burned are still the truth about the counter.
        #expect(relaunched.centeringCheckConsent == nil)
        #expect(context.actions.centeringRequests.isEmpty)
        #expect(relaunched.notice?.title == "Folder not found")
        #expect(relaunched.publishedBatches.count == 1)
    }

    /// The sharpest trap in the centering feature, guarded.
    ///
    /// An imported folder's `_F` may be the artwork or the card back, and front
    /// and back tolerances differ by 5×. Guessing would score every front
    /// against back limits and report ruinous cards as flawless — so an
    /// undeclared folder must refuse to upload at all, and a folder declared
    /// inverted must pass `--swap-sides`.
    @Test("An imported folder cannot be graded until its artwork side is stated")
    func importedBatchRequiresArtworkSideBeforeCentering() async throws {
        let context = makeModel(pagesPerPass: [4])
        let model = context.model
        armBatch(model)
        model.startOrContinueScan()
        try await waitUntil { model.canCompleteBatch }
        model.completeBatch()
        try await waitUntil { model.completionSummary != nil }
        let published = try #require(model.publishedBatches.first)
        let folder = try #require(published.resolveDestinationURL())

        // A folder beside it that ScanDeck did not publish — the operator's
        // legacy corpus, whose `_F` is the Pokéball back.
        let legacy = folder.deletingLastPathComponent()
            .appending(path: "july26grading", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: legacy,
            withIntermediateDirectories: true
        )
        for suffix in ["F", "B"] {
            try Data("jpeg".utf8).write(
                to: legacy.appending(
                    path: "scan_000001_\(suffix).jpg",
                    directoryHint: .notDirectory
                )
            )
        }

        let relaunched = context.makeRelaunchedModel()
        relaunched.importExistingBatches()

        let imported = try #require(
            relaunched.publishedBatches.first {
                $0.batchName.value == "july26grading"
            }
        )
        #expect(imported.isImported)
        // Undeclared, so centering is shut.
        #expect(imported.artworkSide == nil)
        #expect(!imported.canCheckCentering)
        // The batch ScanDeck published knows its own orientation.
        #expect(published.artworkSide == .frontSuffix)
        #expect(published.canCheckCentering)

        // Pressing it anyway refuses and uploads nothing.
        relaunched.requestCentering(for: imported)
        #expect(relaunched.centeringCheckConsent == nil)
        #expect(context.actions.centeringRequests.isEmpty)
        #expect(relaunched.notice?.title == "Say which side is the artwork")

        // Declared inverted, it runs — with --swap-sides.
        relaunched.declareArtworkSide(.backSuffix, for: imported)
        let declared = try #require(
            relaunched.publishedBatches.first {
                $0.batchName.value == "july26grading"
            }
        )
        #expect(declared.artworkSide == .backSuffix)
        #expect(declared.canCheckCentering)

        relaunched.requestCentering(for: declared)
        #expect(relaunched.centeringCheckConsent?.imageCount == 2)
        relaunched.confirmCompletedBatchCentering()
        try await waitUntil {
            if case .completed = relaunched.centeringCheckStatus {
                return true
            }
            return false
        }

        let request = try #require(context.actions.centeringRequests.first)
        #expect(request.swapSides)
        #expect(request.publishedFolderURL.lastPathComponent == "july26grading")
        #expect(request.imageCount == 2)
    }

    @Test("A batch ScanDeck published is never asked to swap sides")
    func publishedBatchDoesNotSwapSides() async throws {
        let context = makeModel(pagesPerPass: [4])
        let model = context.model
        armBatch(model)
        model.startOrContinueScan()
        try await waitUntil { model.canCompleteBatch }
        model.completeBatch()
        try await waitUntil { model.completionSummary != nil }

        let record = try #require(model.publishedBatches.first)
        let relaunched = context.makeRelaunchedModel()
        relaunched.requestCentering(for: try #require(
            relaunched.publishedBatches.first
        ))
        relaunched.confirmCompletedBatchCentering()
        try await waitUntil {
            if case .completed = relaunched.centeringCheckStatus {
                return true
            }
            return false
        }

        let request = try #require(context.actions.centeringRequests.first)
        #expect(!request.swapSides)
        #expect(record.artworkSide == .frontSuffix)
    }

    /// Importing must not list `centering/` or any other folder beside a batch
    /// as if it were one, and must not duplicate a batch already recorded.
    @Test("Importing skips non-batch folders and does not duplicate rows")
    func importSkipsNonBatchFoldersAndDuplicates() async throws {
        let context = makeModel(pagesPerPass: [4])
        let model = context.model
        armBatch(model)
        model.startOrContinueScan()
        try await waitUntil { model.canCompleteBatch }
        model.completeBatch()
        try await waitUntil { model.completionSummary != nil }
        let folder = try #require(
            model.publishedBatches.first?.resolveDestinationURL()
        )
        let destination = folder.deletingLastPathComponent()

        // A folder with no _F/_B pair at all.
        try FileManager.default.createDirectory(
            at: destination.appending(path: "notes", directoryHint: .isDirectory),
            withIntermediateDirectories: true
        )
        try Data("x".utf8).write(
            to: destination
                .appending(path: "notes", directoryHint: .isDirectory)
                .appending(path: "readme.txt", directoryHint: .notDirectory)
        )

        model.importExistingBatches()

        // Only the already-known batch, still exactly once, and `notes` skipped.
        #expect(model.publishedBatches.count == 1)
        #expect(model.publishedBatches.first?.batchName.value == "aug01-sale")
        #expect(model.publishedBatches.first?.isImported == false)
        #expect(model.notice?.title == "No new batches found")
    }

    @Test("A centering failure leaves the published batch complete and resumable")
    func centeringFailureDoesNotRewriteCompletion() async throws {
        let context = makeModel(pagesPerPass: [2])
        let model = context.model
        armBatch(model)
        model.startOrContinueScan()
        try await waitUntil { model.canCompleteBatch }
        model.completeBatch()
        try await waitUntil { model.completionSummary != nil }
        let summary = try #require(model.completionSummary)

        context.actions.centeringFailureMessage = "HTTP 429 after retries."
        model.requestCompletedBatchCentering()
        model.confirmCompletedBatchCentering()
        try await waitUntil {
            if case .failed = model.centeringCheckStatus {
                return true
            }
            return false
        }

        #expect(model.completionSummary == summary)
        #expect(model.activeBatch?.phase == .completed)
        guard case let .failed(message) = model.centeringCheckStatus else {
            Issue.record("The centering failure was not surfaced.")
            return
        }
        #expect(message.contains("HTTP 429"))
        #expect(message.contains("Published images are unchanged"))
        #expect(message.contains("resume"))
    }

    @Test("Centering cannot run before a batch has published")
    func centeringRequiresACompletedBatch() {
        let context = makeModel(pagesPerPass: [2])
        armBatch(context.model)

        context.model.requestCompletedBatchCentering()

        #expect(context.actions.centeringRequests.isEmpty)
        #expect(context.model.centeringCheckStatus == nil)
        #expect(context.model.centeringCheckConsent == nil)
    }

    @Test("A finished check cannot report into the next batch")
    func oldCenteringRunDoesNotCrossBatchBoundary() async throws {
        let context = makeModel(pagesPerPass: [2])
        let model = context.model
        armBatch(model)
        model.startOrContinueScan()
        try await waitUntil { model.canCompleteBatch }
        model.completeBatch()
        try await waitUntil { model.completionSummary != nil }

        context.actions.centeringDelay = .milliseconds(100)
        model.requestCompletedBatchCentering()
        model.confirmCompletedBatchCentering()
        try await waitUntil {
            context.actions.centeringRequests.count == 1
        }
        model.startNewBatchFromCompletion()

        #expect(model.completionSummary == nil)
        #expect(model.centeringCheckStatus == nil)
        try await Task.sleep(for: .milliseconds(150))
        #expect(model.centeringCheckStatus == nil)
    }

    @Test("Auto-continue starts the next pass by itself")
    func autoContinueRunsAnotherPass() async throws {
        let context = makeModel(pagesPerPass: [2, 2, 2])
        let model = context.model
        armBatch(model)
        model.autoContinueSeconds = 1
        model.isAutoContinueEnabled = true

        model.startOrContinueScan()
        try await waitForScanToFinish(model)
        #expect(model.activeBatch?.cards.count == 1)

        // Nobody pressed anything. Every pass it starts is an ordinary one, so
        // the second card arrives exactly as a pressed Continue Scanning would
        // have produced it.
        try await waitUntil { model.activeBatch?.cards.count == 2 }
        model.isAutoContinueEnabled = false
        #expect(model.autoContinueCountdown == nil)
    }

    @Test("Auto-continue stops on a failed pass rather than driving into it")
    func autoContinueStopsOnFailure() async throws {
        let context = makeModel(pagesPerPass: [2, 2])
        let model = context.model
        armBatch(model)
        model.autoContinueSeconds = 1
        model.isAutoContinueEnabled = true
        context.actions.failAfterPages = true

        model.startOrContinueScan()
        try await waitUntil { model.notice?.kind == .error }

        // A jam is not a thing to feed into again five seconds later. The
        // operator has paper to clear, and the banner says so.
        #expect(!model.isAutoContinueEnabled)
        #expect(model.autoContinueCountdown == nil)
    }

    @Test("Auto-continue stops when an incomplete card blocks scanning")
    func autoContinueStopsOnBlockedGate() async throws {
        let context = makeModel(pagesPerPass: [1])
        let model = context.model
        armBatch(model)
        model.autoContinueSeconds = 1
        model.isAutoContinueEnabled = true

        model.startOrContinueScan()
        try await waitForScanToFinish(model)

        // The odd page left a card missing a side, which the reducer refuses to
        // scan past. Auto-continue asks the same gate a press does, so it stops
        // instead of talking over the warning.
        #expect(model.activeBatch?.incompleteCards.count == 1)
        #expect(!model.isAutoContinueEnabled)
        #expect(model.notice?.title == "Incomplete card")
    }

    @Test("Arming refuses a batch name the destination already holds")
    func armingRefusesAnExistingBatchFolder() throws {
        let context = makeModel(pagesPerPass: [2])
        let model = context.model

        let destination = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: destination,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: destination) }

        model.batchDraft.destinationURL = destination
        model.batchDraft.name = "aug01-sale"
        model.refreshBatchFolderAvailability()
        #expect(model.canArmBatch)

        // Yesterday's batch, already published under that name.
        try FileManager.default.createDirectory(
            at: destination.appending(
                path: "aug01-sale",
                directoryHint: .isDirectory
            ),
            withIntermediateDirectories: true
        )
        model.refreshBatchFolderAvailability()

        // SPEC section 4 beat 2 wants this said before the feeder is loaded,
        // not at Complete Batch after 150 cards have gone through.
        #expect(!model.canArmBatch)
        let reason = try #require(model.batchSetupBlockReason)
        #expect(reason.contains("aug01-sale"))
        #expect(reason.contains("never merges"))

        // And the press itself is refused, because the folder can appear
        // between the last keystroke and the button.
        model.armBatch()
        #expect(model.activeBatch == nil)
        #expect(model.notice?.title == "That batch name is taken")

        // A different name is immediately fine.
        model.batchDraft.name = "aug02-sale"
        model.refreshBatchFolderAvailability()
        #expect(model.canArmBatch)
        model.armBatch()
        #expect(model.activeBatch?.name == "aug02-sale")
        #expect(model.notice == nil)
    }

    @Test("Arming re-checks at the press, not only at the keystroke")
    func armingReChecksAtThePress() throws {
        let context = makeModel(pagesPerPass: [2])
        let model = context.model

        let destination = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: destination,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: destination) }

        model.batchDraft.destinationURL = destination
        model.batchDraft.name = "aug01-sale"
        model.refreshBatchFolderAvailability()
        #expect(model.canArmBatch)

        // Somebody else publishes to the shared Drive folder while the setup
        // sheet sits open. The cached answer is now stale.
        try FileManager.default.createDirectory(
            at: destination.appending(
                path: "aug01-sale",
                directoryHint: .isDirectory
            ),
            withIntermediateDirectories: true
        )

        model.armBatch()
        #expect(model.activeBatch == nil)
        #expect(model.notice?.title == "That batch name is taken")
    }

    @Test("A notice does not outlive the card it is about")
    func noticeGoesWhenItsCardIsDeleted() async throws {
        let context = makeModel(pagesPerPass: [2])
        context.actions.assessmentOverride = { request in
            let name = request.imageURL?.lastPathComponent ?? ""
            return .sufficient(
                mediaSize: name.hasPrefix("page-1-")
                    ? MediaPixelSize(width: 1_822, height: 3_094)
                    : MediaPixelSize(width: 1_819, height: 2_415)
            )
        }
        let model = context.model
        armBatch(model)

        model.startOrContinueScan()
        try await waitForScanToFinish(model)
        try await waitUntil { model.notice?.title == "Card sizes disagree" }

        let blocked = try #require(model.activeBatch?.cards.first)
        #expect(model.notice?.cardID == blocked.id)

        // The row's own Delete Card, which does not route through the banner.
        model.deleteCard(blocked.id)

        // The banner is pinned now, so a notice about a card that no longer
        // exists would sit over the batch for the rest of the session offering
        // a Replace the reducer refuses.
        #expect(model.notice?.cardID != blocked.id)
        #expect(model.activeBatch?.cards.isEmpty == true)
    }

    @Test("A pass never selects a card the review grid does not show")
    func selectionSkipsDeletedCards() async throws {
        let context = makeModel(pagesPerPass: [4, 2])
        let model = context.model
        armBatch(model)

        model.startOrContinueScan()
        try await waitForScanToFinish(model)
        let first = try #require(model.activeBatch?.cards.first)
        model.deleteCard(first.id)
        model.selectedCardID = nil

        model.startOrContinueScan()
        try await waitForScanToFinish(model)

        // `session.cards` keeps the deleted row so the counter gap stays
        // explainable; the grid does not show it. Falling back to it would
        // leave the inspector blank on a card the operator cannot see.
        let selected = try #require(model.selectedCardID)
        #expect(selected != first.id)
        #expect(model.selectedCard != nil)
    }

    @Test("A blocking notice names its card and can put it on screen")
    func blockingNoticeNamesAndRevealsItsCard() async throws {
        let context = makeModel(pagesPerPass: [6])
        context.actions.assessmentOverride = { request in
            // The middle card's back detects the holder while its front
            // detects the card — `carlsoboxone`'s failure, and the one where
            // both sides read sufficient so no row can show it.
            let name = request.imageURL?.lastPathComponent ?? ""
            return .sufficient(
                mediaSize: name.hasPrefix("page-3-")
                    ? MediaPixelSize(width: 2_029, height: 2_948)
                    : MediaPixelSize(width: 1_621, height: 2_262)
            )
        }
        let model = context.model
        armBatch(model)

        model.startOrContinueScan()
        try await waitForScanToFinish(model)
        try await waitUntil { !model.canCompleteBatch }

        let cards = try #require(model.activeBatch?.cards)
        #expect(cards.count == 3)
        let blocked = cards[1]

        model.selectedCardID = cards[0].id
        model.completeBatch()

        let notice = try #require(model.notice)
        // The number, in the copy. Without it the operator is holding a button
        // that acts on a row they cannot identify.
        #expect(notice.message.contains("000115"))
        #expect(notice.cardID == blocked.id)

        // And the card itself, on screen and selected.
        model.revealNoticeCard()
        #expect(model.selectedCardID == blocked.id)
        let first = try #require(model.cardRevealRequest)
        #expect(first.cardID == blocked.id)

        // Asking again is a second request, or Show Card does nothing once the
        // operator has scrolled away and pressed it a second time.
        model.revealNoticeCard()
        let second = try #require(model.cardRevealRequest)
        #expect(second.id != first.id)
        #expect(second.cardID == blocked.id)
    }

    @Test("A pair that only warns completes, and the batch says which")
    func warnedPairCompletesAndIsRecorded() async throws {
        let context = makeModel(pagesPerPass: [6])
        context.actions.assessmentOverride = { request in
            // Card 000064 of `carlsoboxone`: the back reads 95 px taller
            // because a wide faint artefact survives the permissive
            // threshold. Wide enough to say something about, not wide enough
            // to hold the batch (TICKET-033).
            let name = request.imageURL?.lastPathComponent ?? ""
            return .sufficient(
                mediaSize: name.hasPrefix("page-3-")
                    ? MediaPixelSize(width: 1_830, height: 2_502)
                    : MediaPixelSize(width: 1_814, height: 2_407)
            )
        }
        let model = context.model
        armBatch(model)

        model.startOrContinueScan()
        try await waitForScanToFinish(model)
        try await waitUntil { model.canCompleteBatch }

        let cards = try #require(model.activeBatch?.cards)
        let warned = cards[1]
        // The row carries it, because nothing else in the row can: both sides
        // read sufficient, so it would otherwise say "Ready".
        #expect(warned.sizeDisagreementPixels == 95)
        #expect(cards[0].sizeDisagreementPixels == nil)
        #expect(model.activeBatch?.cardsWithSizeDisagreement.count == 1)
        // And it is a warning, not a refusal.
        #expect(model.activeBatch?.blockedCardIDs.isEmpty == true)

        model.completeBatch()
        try await waitUntil { model.completionSummary != nil }

        let summary = try #require(model.completionSummary)
        #expect(summary.cardCount == 3)
        #expect(
            summary.releasedWithSizeWarnings == [warned.sheetNumber]
        )
    }

    @Test("A card-specific notice offers a confirmed Delete Card")
    func noticeOffersConfirmedCardDeletion() async throws {
        let context = makeModel(pagesPerPass: [5])
        let model = context.model
        armBatch(model)

        model.startOrContinueScan()
        try await waitForScanToFinish(model)

        // The odd page left card 000116 missing a side. It blocks both gates,
        // and until now the only press the banner could offer was Retry —
        // another feeder pass for a card the operator may not want at all.
        let incomplete = try #require(model.activeBatch?.incompleteCards.first)
        let notice = try #require(model.notice)
        #expect(notice.cardID == incomplete.id)

        model.requestNoticeCardDeletion()
        #expect(model.cardPendingDeletionConfirmation == incomplete.id)
        // The confirmation names what goes, per TICKET-028's discipline.
        let message = model.deleteCardConfirmationMessage
        #expect(message.contains("000116"))
        #expect(message.contains("gap"))

        model.confirmCardDeletion()
        #expect(model.cardPendingDeletionConfirmation == nil)
        #expect(model.activeBatch?.cards.count == 2)
        #expect(model.canStartScan)
        // The notice was about the card that is now gone, so it goes with it —
        // a Retry button for a deleted row is a press that cannot work.
        #expect(model.notice?.cardID != incomplete.id)
    }

    @Test("Delete Card through the notice action routes via the confirmation")
    func deleteCardActionIsNeverUnconfirmed() async throws {
        let context = makeModel(pagesPerPass: [5])
        let model = context.model
        armBatch(model)

        model.startOrContinueScan()
        try await waitForScanToFinish(model)

        let incomplete = try #require(model.activeBatch?.incompleteCards.first)
        model.notice = ScanDeckNotice(
            kind: .warning,
            title: "Incomplete card",
            message: "Card 000116 is missing a side.",
            action: .deleteCard(incomplete.id)
        )

        model.performNoticeAction()

        // Pressed, but nothing is deleted yet: captured images do not leave the
        // batch without the operator being told what goes.
        #expect(model.cardPendingDeletionConfirmation == incomplete.id)
        #expect(model.activeBatch?.cards.count == 3)
    }

    @Test("Publication reports counts rather than only a spinner")
    func publicationReportsProgress() async throws {
        let context = makeModel(pagesPerPass: [6])
        let model = context.model
        armBatch(model)

        model.startOrContinueScan()
        try await waitUntil { model.canCompleteBatch }

        // Wait for the model to show the value just reported rather than
        // sampling after a single `Task.yield()`. The old form missed a count
        // about one run in three: a yield does not guarantee the model's
        // stream reader has drained, so the sample could jump 2 → 4 and the
        // test failed on a batch the app had published perfectly. Waiting on
        // the specific value also makes this a stronger assertion — every
        // report reaches the operator, in order.
        var seen: [BatchPublishProgress] = []
        context.actions.publishStep = { @MainActor reported in
            for _ in 0..<2_000 where model.publishProgress != reported {
                await Task.yield()
            }
            seen.append(reported)
        }

        model.completeBatch()
        try await waitUntil { model.completionSummary != nil }

        // Three cards is six files, and the operator must be able to watch the
        // number move — TICKET-030 records a motionless window being read as a
        // hang and nearly force-quit mid-batch.
        #expect(
            seen == (0...6).map {
                .writing(filesWritten: $0, fileCount: 6)
            }
        )
        #expect(
            BatchPublishProgress.writing(filesWritten: 3, fileCount: 6)
                .operatorDescription == "Publishing 3 of 6…"
        )
        // And it must be put away afterwards, or the completed batch keeps
        // claiming to be publishing.
        #expect(model.publishProgress == nil)
    }

    @Test("An empty feeder ends an automatic run without calling it a failure")
    func feederEmptyEndsTheRunAsInformation() async throws {
        let context = makeModel(pagesPerPass: [4])
        let model = context.model
        armBatch(model)
        model.autoContinueSeconds = 1
        model.isAutoContinueEnabled = true

        model.startOrContinueScan()
        try await waitForScanToFinish(model)
        #expect(model.activeBatch?.cards.count == 2)

        // The operator stops feeding. The next automatic pass finds the chute
        // empty — the ordinary way a run ends, and until now the way it ended
        // was a red "Scan could not finish" quoting a driver error code.
        context.actions.reportFeederEmpty = true
        try await waitUntil { model.notice?.title == "Feeder is empty" }

        let notice = try #require(model.notice)
        #expect(notice.kind == .information)
        #expect(notice.message.contains("Automatic scanning stopped"))
        #expect(notice.message.contains("2 cards captured"))
        // Not the driver's error code, and not "could not finish".
        #expect(!notice.message.contains("0x03800320"))

        // It still stops the run: an empty feeder is a clean end, not a reason
        // to open another session every few seconds against nothing.
        #expect(!model.isAutoContinueEnabled)
        // And every card is still here, which is the whole reason it is safe
        // to say this quietly.
        #expect(model.activeBatch?.cards.count == 2)
    }

    @Test("An empty feeder is not remembered as a driver error either")
    func feederEmptyIsNotStoredAsDriverWording() async throws {
        let context = makeModel(pagesPerPass: [2])
        let model = context.model
        armBatch(model)

        model.startOrContinueScan()
        try await waitForScanToFinish(model)

        context.actions.reportFeederEmpty = true
        model.startOrContinueScan()
        try await waitForScanToFinish(model)

        // The reducer keeps this string and hands it back when the batch is
        // recovered, so substituting it only in the banner would still greet
        // the operator with the driver's error code tomorrow morning.
        let issue = try #require(model.session?.lastIssue)
        #expect(!issue.message.contains("0x03800320"))
        #expect(!issue.message.contains("Expected at least one scanned page"))
        #expect(issue.message.contains("feeder was empty"))
        #expect(issue.capturedCardsRemainSafe)
    }

    @Test("An empty feeder on a pressed pass says so without blaming the run")
    func feederEmptyOnAManualPassIsAlsoInformation() async throws {
        let context = makeModel(pagesPerPass: [2])
        let model = context.model
        armBatch(model)

        model.startOrContinueScan()
        try await waitForScanToFinish(model)

        context.actions.reportFeederEmpty = true
        model.startOrContinueScan()
        try await waitForScanToFinish(model)

        let notice = try #require(model.notice)
        #expect(notice.title == "Feeder is empty")
        #expect(notice.kind == .information)
        // Nobody handed the button over, so nothing "stopped".
        #expect(notice.message.contains("nothing was scanned"))
        #expect(notice.action == .continueScanning)
    }

    @Test("A jam is still a failure, in the driver's own words")
    func jamRemainsAFailure() async throws {
        let context = makeModel(pagesPerPass: [2])
        let model = context.model
        armBatch(model)
        context.actions.failAfterPages = true

        model.startOrContinueScan()
        try await waitUntil { model.notice != nil }

        let notice = try #require(model.notice)
        #expect(notice.title == "Scan could not finish")
        #expect(notice.kind == .error)
        #expect(notice.message.contains("Paper jammed in the ADF."))
    }

    @Test("The interval is clamped and survives a relaunch")
    func autoContinueIntervalPersists() {
        let storage = InMemoryScanDeckSettingsStorage()
        let context = makeModel(pagesPerPass: [2], settingsStorage: storage)
        context.model.autoContinueSeconds = 900
        #expect(context.model.autoContinueSeconds == 60)
        context.model.autoContinueSeconds = 0
        #expect(context.model.autoContinueSeconds == 1)
        context.model.autoContinueSeconds = 8

        let relaunched = makeModel(pagesPerPass: [2], settingsStorage: storage)
        #expect(relaunched.model.autoContinueSeconds == 8)
        // Not the switch, though: a batch that resumes scanning by itself at
        // launch, before anyone has looked at the feeder, is not a convenience.
        #expect(!relaunched.model.isAutoContinueEnabled)
    }

    @Test("Arming requires both a valid name and a destination")
    func armingRequiresNameAndDestination() {
        // A first launch, before any destination has been picked. The harness
        // otherwise remembers one — which is the normal state and what Add
        // Existing Batches reads — so this test asks for the other one.
        let context = makeModel(pagesPerPass: [2], rememberDestination: false)
        let model = context.model

        #expect(model.batchDraft.destinationURL == nil)
        #expect(!model.canArmBatch)
        #expect(model.batchSetupBlockReason == "Enter a batch name.")

        model.batchDraft.name = "aug01-sale"
        #expect(!model.canArmBatch)
        #expect(model.batchSetupBlockReason == "Choose a destination folder.")

        model.batchDraft.destinationURL = URL(
            fileURLWithPath: "/tmp/scandeck-tests",
            isDirectory: true
        )
        #expect(model.canArmBatch)

        model.batchDraft.name = "bad/name"
        #expect(!model.canArmBatch)
        model.armBatch()
        #expect(model.activeBatch == nil)
    }

    @Test("A failed pass keeps captured cards and says they are safe")
    func failedPassRetainsCapturedCards() async throws {
        let context = makeModel(pagesPerPass: [2])
        context.actions.failAfterPages = true
        let model = context.model
        armBatch(model)

        model.startOrContinueScan()
        try await waitUntil { model.notice?.kind == .error }

        #expect(model.activeBatch?.cards.count == 1)
        let message = try #require(model.notice?.message)
        #expect(message.contains("safe"))
    }

    @Test("Completing advances the persistent counter past the batch")
    func completionAdvancesPersistentCounter() async throws {
        let context = makeModel(pagesPerPass: [4])
        let model = context.model
        let jobID = JobID(rawValue: context.profile.id)
        #expect(context.counterStore.nextSheetNumber(for: jobID) == 114)

        armBatch(model)
        model.startOrContinueScan()
        try await waitUntil { model.canCompleteBatch }
        model.completeBatch()
        try await waitUntil { model.completionSummary != nil }

        // Two cards used 114 and 115, so the next batch starts at 116.
        #expect(context.counterStore.nextSheetNumber(for: jobID) == 116)
        #expect(model.notice?.title != "The counter did not advance")
    }

    @Test("An abandoned batch burns no sheet numbers")
    func abandonedBatchBurnsNoNumbers() async throws {
        let context = makeModel(pagesPerPass: [4])
        let model = context.model
        let jobID = JobID(rawValue: context.profile.id)

        armBatch(model)
        model.startOrContinueScan()
        try await waitForScanToFinish(model)
        #expect(model.activeBatch?.cards.count == 2)

        // Walk away without completing, exactly as Cancel Batch would.
        model.startNewBatchFromCompletion()

        #expect(context.counterStore.nextSheetNumber(for: jobID) == 114)
    }

    @Test("A deleted card leaves a gap the counter still skips")
    func deletedCardLeavesCounterGap() async throws {
        let context = makeModel(pagesPerPass: [6])
        let model = context.model
        let jobID = JobID(rawValue: context.profile.id)

        armBatch(model)
        model.startOrContinueScan()
        try await waitForScanToFinish(model)

        let middle = try #require(model.activeBatch?.cards[1])
        model.deleteCard(middle.id)
        #expect(model.activeBatch?.cards.map(\.sheetNumber) == [114, 116])

        try await waitUntil { model.canCompleteBatch }
        model.completeBatch()
        try await waitUntil { model.completionSummary != nil }

        // The counter advances past the highest provisional number, not the
        // card count, so 115 stays permanently unused.
        #expect(context.counterStore.nextSheetNumber(for: jobID) == 117)
    }

    // MARK: - Harness

    private struct Context {
        let model: ScanDeckPresentationModel
        let actions: ScriptedActions
        let counterStore: JobCounterStore
        let sessionStore: BatchSessionStore
        let profile: ScanProfileViewData
        /// Everything persistent this context owns, so a second model over the
        /// same directories is a relaunch rather than a fresh installation.
        let storeDirectory: URL
        let bookmarkStore: DestinationBookmarkStore

        @MainActor
        func makeRelaunchedModel() -> ScanDeckPresentationModel {
            ScanDeckPresentationModel(
                profiles: [profile],
                scannerStatus: ScannerStatusMonitor(
                    source: ScriptedScannerInventorySource()
                ),
                actions: actions,
                destinationPicker: StubDestinationPicker(),
                destinationBookmarkStore: bookmarkStore,
                jobCounterStore: counterStore,
                sessionStore: sessionStore,
                settingsStore: ScanDeckSettingsStore(
                    storage: InMemoryScanDeckSettingsStorage()
                ),
                publishedBatchStore: PublishedBatchStore(
                    directory: storeDirectory
                )
            )
        }
    }

    /// Every model gets its own counter and session directories. Both defaults
    /// live in Application Support, and a test that writes there corrupts the
    /// operator's real counters and unfinished batches.
    private func makeModel(
        pagesPerPass: [Int],
        firstSheetNumber: UInt64 = 114,
        settingsStorage: any ScanDeckSettingsStorage =
            InMemoryScanDeckSettingsStorage(),
        rememberDestination: Bool = true
    ) -> Context {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let counterStore = JobCounterStore(directory: directory)
        let sessionStore = BatchSessionStore(
            directory: directory.appending(
                path: "Sessions",
                directoryHint: .isDirectory
            )
        )
        let profile = ScanProfileViewData.cards600FullBorder
        try? counterStore.seed(
            firstSheetNumber,
            for: JobID(rawValue: profile.id)
        )

        // The destination exists and is remembered, the way it is after the
        // operator has picked it through the open panel once. `armBatch` sets
        // the draft directly and so never went through the picker, which left
        // the bookmark store empty — and Add Existing Batches reads the
        // remembered destination, per invariant #3.
        try? FileManager.default.createDirectory(
            at: destinationRoot,
            withIntermediateDirectories: true
        )
        let bookmarkStore = DestinationBookmarkStore(
            storage: InMemoryDestinationBookmarkStorage()
        )
        if rememberDestination {
            try? bookmarkStore.save(destinationRoot)
        }

        let actions = ScriptedActions(pagesPerPass: pagesPerPass)
        let model = ScanDeckPresentationModel(
            profiles: [profile],
            // These tests are about the batch rules, so the scanner is present
            // and stays present. `ScannerStatusTests` covers what happens when
            // it is not.
            scannerStatus: ScannerStatusMonitor(
                source: ScriptedScannerInventorySource()
            ),
            actions: actions,
            destinationPicker: StubDestinationPicker(),
            destinationBookmarkStore: bookmarkStore,
            jobCounterStore: counterStore,
            sessionStore: sessionStore,
            settingsStore: ScanDeckSettingsStore(storage: settingsStorage),
            publishedBatchStore: PublishedBatchStore(directory: directory)
        )
        return Context(
            model: model,
            actions: actions,
            counterStore: counterStore,
            sessionStore: sessionStore,
            profile: profile,
            storeDirectory: directory,
            bookmarkStore: bookmarkStore
        )
    }

    /// A destination per test rather than one shared `/tmp/scandeck-tests`.
    ///
    /// Swift Testing builds a fresh suite instance per test, so this is unique
    /// where a static path was not. It matters now that the fake publisher
    /// writes real files and one test deletes a published folder: on a shared
    /// path, two tests publishing `aug01-sale` in parallel would overwrite each
    /// other's files and the deletion would break whichever was still running.
    private let destinationRoot = FileManager.default.temporaryDirectory
        .appending(
            path: "scandeck-tests-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )

    private func armBatch(_ model: ScanDeckPresentationModel) {
        model.batchDraft.name = "aug01-sale"
        model.batchDraft.destinationURL = destinationRoot
        model.armBatch()
    }

    /// Waits for the pass to leave `.scanning`.
    ///
    /// Asserting on card counts alone is racy: midway through a five-page pass
    /// the batch legitimately holds one incomplete card, which satisfies naive
    /// conditions like "one incomplete card exists" before the pass has ended.
    private func waitForScanToFinish(
        _ model: ScanDeckPresentationModel,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
        try await waitUntil(
            { model.activeBatch?.phase != .scanning },
            sourceLocation: sourceLocation
        )
    }

    private func waitUntil(
        _ condition: @MainActor () -> Bool,
        within timeout: Duration = .seconds(30),
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
private final class ScriptedActions: ScanDeckAppActions {
    var marginAssessment: MarginAssessment = .sufficient(mediaSize: nil)
    /// When set, decides each verdict from its request. The page URL
    /// distinguishes sides, because this fake minted those URLs itself.
    var assessmentOverride:
        (@MainActor (MarginAssessmentRequest) -> MarginAssessment)?
    var failAfterPages = false

    /// Ends the next pass the way an emptied chute does: no pages, and the
    /// driver's own sentence about it.
    var reportFeederEmpty = false

    /// Awaited between published files, so a test can observe the counts
    /// mid-flight instead of only their end state.
    /// Called after each progress report with the value just reported, so a
    /// test can wait for the model to catch up with *that* value rather than
    /// sampling and hoping.
    var publishStep: (@MainActor (BatchPublishProgress) async -> Void)?
    private(set) var publishRequests: [BatchPublishRequest] = []

    var centeringProgress: [CenteringCheckProgress] = []
    var centeringStep: (@MainActor (CenteringCheckProgress) async -> Void)?
    var centeringFailureMessage: String?
    var centeringDelay: Duration?
    private(set) var centeringRequests: [CenteringCheckRequest] = []

    private let pagesPerPass: [Int]
    private var passIndex = 0

    init(pagesPerPass: [Int]) {
        self.pagesPerPass = pagesPerPass
    }

    func scan(_ request: ScanPassRequest) -> AsyncStream<ScanPassProgress> {
        let pageCount = passIndex < pagesPerPass.count
            ? pagesPerPass[passIndex]
            : 2
        passIndex += 1
        let shouldFail = failAfterPages

        if reportFeederEmpty {
            return AsyncStream { continuation in
                continuation.yield(
                    .finished(
                        .failed(
                            message: "Expected at least one scanned page, but "
                                + "received none. Scanner reported: No "
                                + "documents in the ADF paper chute. "
                                + "(Error Code: 0x03800320)",
                            reason: .feederEmpty
                        )
                    )
                )
                continuation.finish()
            }
        }

        return AsyncStream { continuation in
            for index in 0..<pageCount {
                continuation.yield(
                    .page(
                        URL(
                            fileURLWithPath:
                                "/tmp/scandeck-tests/page-\(index)-\(UUID().uuidString).jpg"
                        )
                    )
                )
            }
            continuation.yield(
                .finished(
                    shouldFail
                        ? .failed(message: "Paper jammed in the ADF.")
                        : .succeeded
                )
            )
            continuation.finish()
        }
    }

    func assessMargin(
        _ request: MarginAssessmentRequest
    ) async -> MarginAssessmentOutcome {
        MarginAssessmentOutcome(
            assessment: assessmentOverride?(request) ?? marginAssessment,
            publishedCrop: nil
        )
    }

    func publish(
        _ request: BatchPublishRequest,
        progress: @escaping @Sendable (BatchPublishProgress) -> Void
    ) async throws -> BatchPublishReceipt {
        publishRequests.append(request)
        // Reported the way the real publisher does — one step per side, then
        // the rename — so the model's stream is exercised rather than stubbed.
        let fileCount = request.candidate.cards.count * 2
        for index in 0...fileCount {
            let step = BatchPublishProgress.writing(
                filesWritten: index,
                fileCount: fileCount
            )
            progress(step)
            await publishStep?(step)
        }
        progress(.placingFolder)

        let folder = request.destinationURL
            .appending(
                path: request.candidate.batchName.value,
                directoryHint: .isDirectory
            )
        // Real files, because two things downstream read the folder rather than
        // the receipt: the history record's bookmark, which cannot be taken of a
        // directory that does not exist, and centering's image count, which is
        // counted off disk on purpose. A publisher that returned a path without
        // creating it made both untestable.
        try? FileManager.default.createDirectory(
            at: folder,
            withIntermediateDirectories: true
        )
        for card in request.candidate.cards {
            let number = String(
                format: "%06llu",
                card.provisionalSheetNumber
            )
            for suffix in ["F", "B"] {
                try? Data("jpeg".utf8).write(
                    to: folder.appending(
                        path: "scan_\(number)_\(suffix).jpg",
                        directoryHint: .notDirectory
                    )
                )
            }
        }
        return BatchPublishReceipt(
            publishedFolderURL: folder,
            destinationDescription: folder.lastPathComponent
        )
    }

    func checkCentering(
        _ request: CenteringCheckRequest,
        progress: @escaping @Sendable (CenteringCheckProgress) -> Void
    ) async throws -> CenteringCheckReceipt {
        centeringRequests.append(request)
        for step in centeringProgress {
            progress(step)
            await centeringStep?(step)
        }
        if let centeringFailureMessage {
            throw CenteringCheckFailure(message: centeringFailureMessage)
        }
        if let centeringDelay {
            try? await Task.sleep(for: centeringDelay)
        }
        return CenteringCheckReceipt(
            outputFolderURL: request.publishedFolderURL
                .appending(path: "centering", directoryHint: .isDirectory),
            imageCount: request.imageCount,
            uploadedImages: request.imageCount,
            cachedImages: 0
        )
    }

    func showInFinder(_ url: URL?) {}
}

@MainActor
private final class StubDestinationPicker: DestinationPicking {
    var result: URL?

    func pickDestination(startingAt url: URL?) -> URL? {
        result
    }
}
