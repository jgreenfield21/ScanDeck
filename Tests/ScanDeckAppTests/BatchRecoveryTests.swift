import Foundation
import ScanDeckCore
import Testing
@testable import ScanDeckApp

/// Drives a crash and a relaunch.
///
/// A second `ScanDeckPresentationModel` built against the same session store is
/// exactly what the next launch sees, so these tests exercise the real path
/// rather than calling the recovery methods directly. This is invariant #1's
/// last mile: the masters were already durable, and what is being proved here
/// is that the state giving them meaning survives too.
@MainActor
@Suite("Crash recovery")
struct BatchRecoveryTests {
    @Test("A batch interrupted mid-pass is offered back at the next launch")
    func interruptedBatchIsRecovered() async throws {
        let harness = Harness()
        let first = harness.makeModel(stallAfterPages: 3)
        harness.arm(first)

        first.startOrContinueScan()
        try await waitUntil { first.activeBatch?.cards.count == 2 }
        await first.flushPendingSaves()

        // The process dies here: no scanEnded, no completion, no cleanup.
        let relaunched = harness.makeModel()

        #expect(relaunched.recoveredBatches.count == 1)
        #expect(relaunched.isRecoveryPresented)
        let recovered = try #require(relaunched.recoveredBatches.first)
        #expect(recovered.batchName == "aug01-sale")
        #expect(recovered.wasInterruptedMidScan)
        #expect(recovered.cardCount == 2)
        #expect(recovered.counterRange == 114...115)
        #expect(relaunched.recoveryHeadline.contains("2-card"))
    }

    @Test("Resuming restores the cards, their images, and the destination")
    func resumeRestoresTheWholeBatch() async throws {
        let harness = Harness()
        let first = harness.makeModel()
        harness.arm(first)
        first.startOrContinueScan()
        try await waitForScanToFinish(first)
        await first.flushPendingSaves()

        let captured = try #require(first.activeBatch)
        let relaunched = harness.makeModel()
        let recovered = try #require(relaunched.recoveredBatches.first)
        relaunched.resumeRecoveredBatch(recovered.id)

        let resumed = try #require(relaunched.activeBatch)
        #expect(resumed.id == captured.id)
        #expect(resumed.name == "aug01-sale")
        #expect(resumed.cards.map(\.sheetNumber) == captured.cards.map(\.sheetNumber))
        // Bookmark resolution returns the canonical path, so /var arrives as
        // /private/var. Same folder, spelled the way the filesystem spells it.
        #expect(
            resumed.destinationURL?.resolvingSymlinksInPath()
                == harness.destination.resolvingSymlinksInPath()
        )
        #expect(relaunched.recoveredBatches.isEmpty)
        #expect(!relaunched.isRecoveryPresented)

        // A card with no image is a card that cannot be published, so every
        // side must come back pointing at a file that is really there.
        for card in resumed.cards {
            for side in [card.front, card.back] {
                let url = try #require(side?.imageURL)
                #expect(FileManager.default.fileExists(atPath: url.path))
            }
        }
    }

    @Test("Resuming an interrupted pass lands in review and says cards are safe")
    func resumingAnInterruptedPassIsSafe() async throws {
        let harness = Harness()
        let first = harness.makeModel(stallAfterPages: 3)
        harness.arm(first)
        first.startOrContinueScan()
        try await waitUntil { first.activeBatch?.cards.count == 2 }
        await first.flushPendingSaves()

        let relaunched = harness.makeModel()
        let recovered = try #require(relaunched.recoveredBatches.first)
        relaunched.resumeRecoveredBatch(recovered.id)

        // The reducer owns this: an interrupted pass becomes a reviewable
        // batch, and the half-captured third card is retired rather than left
        // as a phantom side.
        #expect(relaunched.activeBatch?.phase != .scanning)
        let message = try #require(relaunched.notice?.message)
        #expect(message.contains("safe"))
        #expect(relaunched.activeBatch?.cards.count == 2)
    }

    @Test("A resumed batch can still be completed")
    func resumedBatchCompletesNormally() async throws {
        let harness = Harness()
        let first = harness.makeModel()
        harness.arm(first)
        first.startOrContinueScan()
        try await waitForScanToFinish(first)
        await first.flushPendingSaves()

        let relaunched = harness.makeModel()
        let recovered = try #require(relaunched.recoveredBatches.first)
        relaunched.resumeRecoveredBatch(recovered.id)

        try await waitUntil { relaunched.canCompleteBatch }
        relaunched.completeBatch()
        try await waitUntil { relaunched.completionSummary != nil }

        #expect(relaunched.completionSummary?.cardCount == 2)
        // Numbers survive the crash: the resumed batch keeps the ones it
        // reserved rather than starting over.
        #expect(relaunched.completionSummary?.counterRange == 114...115)
    }

    @Test("A card whose image vanished blocks completion instead of failing late")
    func missingMasterBlocksCompletion() async throws {
        let harness = Harness()
        let first = harness.makeModel()
        harness.arm(first)
        first.startOrContinueScan()
        try await waitForScanToFinish(first)
        await first.flushPendingSaves()

        // Something removed a master while ScanDeck was not running.
        let vanished = try #require(
            first.activeBatch?.cards.first?.front?.imageURL
        )
        try FileManager.default.removeItem(at: vanished)

        let relaunched = harness.makeModel()
        let recovered = try #require(relaunched.recoveredBatches.first)
        relaunched.resumeRecoveredBatch(recovered.id)

        // The persisted verdict said this side was fine, and it was — when it
        // was written. Re-assessing against the file that is actually there now
        // is what turns a publish that fails at the very end into a blocker the
        // operator can act on while reviewing.
        try await waitUntil {
            relaunched.activeBatch?.cards.first?.hasMarginIssue == true
        }
        #expect(!relaunched.canCompleteBatch)
        #expect(relaunched.completionBlockReason != nil)
    }

    @Test("Discarding removes the batch and every page it captured")
    func discardDeletesTheImagesToo() async throws {
        let harness = Harness()
        let first = harness.makeModel()
        harness.arm(first)
        first.startOrContinueScan()
        try await waitForScanToFinish(first)
        await first.flushPendingSaves()

        let masterURLs = (first.activeBatch?.cards ?? []).flatMap {
            [$0.front?.imageURL, $0.back?.imageURL].compactMap { $0 }
        }
        #expect(!masterURLs.isEmpty)

        let relaunched = harness.makeModel()
        let recovered = try #require(relaunched.recoveredBatches.first)
        relaunched.discardRecoveredBatch(recovered.id)

        try await waitUntil { relaunched.recoveredBatches.isEmpty }
        #expect(!relaunched.isRecoveryPresented)
        for url in masterURLs {
            #expect(!FileManager.default.fileExists(atPath: url.path))
        }
        #expect(harness.sessionStore.load().records.isEmpty)
    }

    @Test("Cancelling a batch deletes its pages and burns no numbers")
    func cancellingDeletesEverythingAndKeepsTheNumbers() async throws {
        let harness = Harness()
        let model = harness.makeModel()
        harness.arm(model)
        model.startOrContinueScan()
        try await waitForScanToFinish(model)
        await model.flushPendingSaves()

        let masterURLs = (model.activeBatch?.cards ?? []).flatMap {
            [$0.front?.imageURL, $0.back?.imageURL].compactMap { $0 }
        }
        #expect(masterURLs.count == 4)
        #expect(model.canCancelBatch)

        model.cancelActiveBatch()
        try await waitUntil { model.notice?.title == "Batch cancelled" }

        // Nothing left in the app, nothing left on disk, and — the part that
        // makes cancelling safe to reach for — the counter is untouched, so the
        // rescan gets the same numbers back (invariant #7).
        #expect(model.activeBatch == nil)
        for url in masterURLs {
            #expect(!FileManager.default.fileExists(atPath: url.path))
        }
        #expect(harness.sessionStore.load().records.isEmpty)
        #expect(
            harness.counterStore.nextSheetNumber(
                for: JobID(rawValue: harness.profile.id)
            ) == 114
        )

        // And it does not come back as a recovered batch at the next launch.
        let relaunched = harness.makeModel()
        #expect(relaunched.recoveredBatches.isEmpty)
    }

    @Test("A batch cannot be cancelled out from under a feeding scanner")
    func cancellingIsRefusedMidPass() async throws {
        let harness = Harness()
        let model = harness.makeModel(stallAfterPages: 3)
        harness.arm(model)

        model.startOrContinueScan()
        try await waitUntil { model.activeBatch?.cards.count == 2 }

        // The scanner is moving paper and is about to hand over pages that
        // would have nowhere to go. The phase says so; this adds no rule.
        #expect(model.activeBatch?.phase == .scanning)
        #expect(!model.canCancelBatch)

        model.cancelActiveBatch()
        #expect(model.activeBatch != nil)
    }

    @Test("A published batch leaves nothing to recover")
    func completionClearsTheRecord() async throws {
        let harness = Harness()
        let model = harness.makeModel()
        harness.arm(model)
        model.startOrContinueScan()
        try await waitUntil { model.canCompleteBatch }
        model.completeBatch()
        try await waitUntil { model.completionSummary != nil }
        await model.flushPendingSaves()

        // Publication and the counter commit both landed, so the working files
        // have nothing left to protect and the next launch is clean.
        #expect(harness.sessionStore.load().records.isEmpty)
        #expect(harness.makeModel().recoveredBatches.isEmpty)
    }

    @Test("A crash between the folder landing and the counter fixes itself")
    func releaseJournalFinishesTheCounter() async throws {
        let harness = Harness()
        let model = harness.makeModel()
        harness.arm(model)
        model.startOrContinueScan()
        try await waitUntil { model.canCompleteBatch }

        // The counter store is made unwritable for the length of the press, so
        // the batch folder lands and the commit does not. That is the window
        // TICKET-006b exists for, produced by the real path rather than by
        // hand-writing a record.
        harness.setCounterStoreWritable(false)
        model.completeBatch()
        try await waitUntil { model.completionSummary != nil }
        await model.flushPendingSaves()
        harness.setCounterStoreWritable(true)

        // Before recovery: the folder is on the destination, the numbers were
        // never reserved, and the record is still there as the journal.
        #expect(
            FileManager.default.fileExists(
                atPath: harness.destination
                    .appending(path: "aug01-sale").path
            )
        )
        #expect(harness.counterStore.nextSheetNumber(for: harness.jobID) == 114)
        #expect(harness.sessionStore.load().records.count == 1)
        #expect(harness.sessionStore.load().resumable.isEmpty)
        #expect(harness.sessionStore.load().interruptedReleases.count == 1)

        // The next launch finishes it, and says that it did.
        let relaunched = harness.makeModel()
        #expect(harness.counterStore.nextSheetNumber(for: harness.jobID) == 116)
        #expect(harness.sessionStore.load().records.isEmpty)
        #expect(relaunched.recoveredBatches.isEmpty)
        let notice = try #require(relaunched.notice)
        #expect(notice.title == "Finished saving a counter")
        #expect(notice.message.contains("aug01-sale"))
        #expect(notice.message.contains("000116"))

        // And a third launch has nothing left to do — the journal is idempotent
        // against a crash during recovery, which is the whole reason it is a
        // journal rather than a flag.
        let third = harness.makeModel()
        #expect(third.notice == nil)
        #expect(harness.counterStore.nextSheetNumber(for: harness.jobID) == 116)
    }

    @Test("A batch whose folder never landed goes back to review, unburnt")
    func releaseJournalReturnsAnUnpublishedBatchToReview() async throws {
        let harness = Harness()
        let model = harness.makeModel(publishNeverReturns: true)
        harness.arm(model)
        model.startOrContinueScan()
        try await waitUntil { model.canCompleteBatch }

        // Pressed, and the process dies before the rename: the record reaches
        // `.releasing` and stops there.
        model.completeBatch()
        try await waitUntil { model.activeBatch?.phase == .completing }
        await model.flushPendingSaves()
        #expect(harness.sessionStore.load().interruptedReleases.count == 1)
        #expect(
            !FileManager.default.fileExists(
                atPath: harness.destination
                    .appending(path: "aug01-sale").path
            )
        )

        let relaunched = harness.makeModel()

        // Nothing was published, so nothing may be spent: the batch comes back
        // for review with the same numbers it reserved.
        #expect(harness.counterStore.nextSheetNumber(for: harness.jobID) == 114)
        let recovered = try #require(relaunched.recoveredBatches.first)
        #expect(recovered.batchName == "aug01-sale")
        #expect(recovered.counterRange == 114...115)
        let notice = try #require(relaunched.notice)
        #expect(notice.title == "A batch never reached the destination")

        // And it really can be published now, on the numbers it kept.
        relaunched.resumeRecoveredBatch(recovered.id)
        try await waitUntil { relaunched.canCompleteBatch }
        relaunched.completeBatch()
        try await waitUntil { relaunched.completionSummary != nil }
        #expect(relaunched.completionSummary?.counterRange == 114...115)
        #expect(harness.counterStore.nextSheetNumber(for: harness.jobID) == 116)
    }

    @Test("An unfinished batch is recoverable before a single page is scanned")
    func armedBatchIsRecoverable() async throws {
        let harness = Harness()
        let first = harness.makeModel()
        harness.arm(first)
        await first.flushPendingSaves()

        // The name, destination, and starting number are operator input and
        // worth keeping even when no card has been fed yet.
        let recovered = try #require(
            harness.makeModel().recoveredBatches.first
        )
        #expect(recovered.batchName == "aug01-sale")
        #expect(recovered.cardCount == 0)
    }

    @Test("Closing the prompt keeps every recovered batch")
    func decideLaterDiscardsNothing() async throws {
        let harness = Harness()
        let first = harness.makeModel()
        harness.arm(first)
        first.startOrContinueScan()
        try await waitForScanToFinish(first)
        await first.flushPendingSaves()

        let relaunched = harness.makeModel()
        relaunched.dismissRecovery()

        #expect(!relaunched.isRecoveryPresented)
        // Dismissing is not a decision about the pages.
        #expect(harness.sessionStore.load().resumable.count == 1)
        #expect(harness.makeModel().recoveredBatches.count == 1)
    }

    // MARK: - Harness

    /// One temporary directory shared by every model in a test, so a second
    /// model is a relaunch rather than a different installation.
    private final class Harness {
        let root: URL
        let destination: URL
        let sessionStore: BatchSessionStore
        let counterStore: JobCounterStore
        let profile = ScanProfileViewData.cards600FullBorder

        init() {
            root = FileManager.default.temporaryDirectory
                .appending(path: UUID().uuidString, directoryHint: .isDirectory)
            destination = root.appending(
                path: "destination",
                directoryHint: .isDirectory
            )
            try? FileManager.default.createDirectory(
                at: destination,
                withIntermediateDirectories: true
            )
            sessionStore = BatchSessionStore(
                directory: root.appending(
                    path: "Sessions",
                    directoryHint: .isDirectory
                )
            )
            counterStore = JobCounterStore(
                directory: root.appending(
                    path: "Jobs",
                    directoryHint: .isDirectory
                )
            )
            try? counterStore.seed(114, for: JobID(rawValue: profile.id))
        }

        var jobID: JobID { JobID(rawValue: profile.id) }

        /// Makes the counter commit fail without touching the counter's value,
        /// which is how the release journal's window is reproduced through the
        /// real completion path.
        func setCounterStoreWritable(_ writable: Bool) {
            let jobs = root.appending(path: "Jobs", directoryHint: .isDirectory)
            try? FileManager.default.setAttributes(
                [.posixPermissions: writable ? 0o755 : 0o555],
                ofItemAtPath: jobs.path
            )
        }

        @MainActor
        func makeModel(
            stallAfterPages: Int? = nil,
            publishNeverReturns: Bool = false
        ) -> ScanDeckPresentationModel {
            ScanDeckPresentationModel(
                profiles: [profile],
                scannerStatus: ScannerStatusMonitor(
                    source: ScriptedScannerInventorySource()
                ),
                actions: RecoveryScriptedActions(
                    sessionStore: sessionStore,
                    pagesPerPass: 4,
                    stallAfterPages: stallAfterPages,
                    publishNeverReturns: publishNeverReturns
                ),
                destinationPicker: NoDestinationPicker(),
                destinationBookmarkStore: DestinationBookmarkStore(
                    storage: InMemoryDestinationBookmarkStorage()
                ),
                jobCounterStore: counterStore,
                sessionStore: sessionStore,
                publishedBatchStore: PublishedBatchStore(
                    directory: root.appending(
                        path: "History",
                        directoryHint: .isDirectory
                    )
                )
            )
        }

        @MainActor
        func arm(_ model: ScanDeckPresentationModel) {
            model.batchDraft.name = "aug01-sale"
            model.batchDraft.destinationURL = destination
            model.armBatch()
        }
    }

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

/// Writes real files for pages and judges margins by whether the file is still
/// there — which is what makes the vanished-master case testable at all.
@MainActor
private final class RecoveryScriptedActions: ScanDeckAppActions {
    private let sessionStore: BatchSessionStore
    private let pagesPerPass: Int
    private let stallAfterPages: Int?
    /// Leaves the batch in `.releasing` forever, which is the on-disk state a
    /// crash between pressing Complete Batch and the rename produces.
    let publishNeverReturns: Bool

    init(
        sessionStore: BatchSessionStore,
        pagesPerPass: Int,
        stallAfterPages: Int?,
        publishNeverReturns: Bool = false
    ) {
        self.sessionStore = sessionStore
        self.pagesPerPass = pagesPerPass
        self.stallAfterPages = stallAfterPages
        self.publishNeverReturns = publishNeverReturns
    }

    func scan(_ request: ScanPassRequest) -> AsyncStream<ScanPassProgress> {
        // The same layout `ScanDeckWorkflowActions` uses: a directory per pass
        // inside the batch's own directory. Discard removes that directory, so
        // a test writing masters anywhere else would prove nothing about
        // whether discarding really deletes the operator's images.
        let directory = sessionStore
            .directory(for: request.batchID)
            .appending(
                path: request.passID.rawValue.uuidString,
                directoryHint: .isDirectory
            )
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )

        let count = stallAfterPages ?? pagesPerPass
        let stalls = stallAfterPages != nil

        return AsyncStream { continuation in
            for index in 0..<count {
                let url = directory.appending(
                    path: "master-\(index).jpg",
                    directoryHint: .notDirectory
                )
                try? Data([0xFF, 0xD8, 0xFF, 0xD9]).write(to: url)
                continuation.yield(.page(url))
            }
            guard stalls else {
                continuation.yield(.finished(.succeeded))
                continuation.finish()
                return
            }
            // The process dies here. No terminal event ever arrives, which is
            // what leaves the persisted phase mid-pass.
        }
    }

    func assessMargin(
        _ request: MarginAssessmentRequest
    ) async -> MarginAssessmentOutcome {
        guard let url = request.imageURL,
              FileManager.default.fileExists(atPath: url.path)
        else {
            // Mirrors production: a master that cannot be analysed must never
            // read as publishable.
            return .unpublishable
        }
        return MarginAssessmentOutcome(
            assessment: .sufficient(mediaSize: nil),
            publishedCrop: nil
        )
    }

    func publish(
        _ request: BatchPublishRequest,
        progress: @escaping @Sendable (BatchPublishProgress) -> Void
    ) async throws -> BatchPublishReceipt {
        let folder = request.destinationURL.appending(
            path: request.candidate.batchName.value,
            directoryHint: .isDirectory
        )
        if publishNeverReturns {
            // The batch is left in `.releasing` on disk, which is the state a
            // crash between the press and the rename produces.
            try await Task.sleep(for: .seconds(600))
        }
        // The folder really appears, because the release journal's whole job
        // is to ask whether it did (TICKET-006b).
        try FileManager.default.createDirectory(
            at: folder,
            withIntermediateDirectories: true
        )
        return BatchPublishReceipt(
            publishedFolderURL: folder,
            destinationDescription: folder.lastPathComponent
        )
    }

    func showInFinder(_ url: URL?) {}
}

@MainActor
private final class NoDestinationPicker: DestinationPicking {
    func pickDestination(startingAt url: URL?) -> URL? { nil }
}
