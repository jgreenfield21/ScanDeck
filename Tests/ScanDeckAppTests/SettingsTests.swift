import Foundation
import ScanDeckCore
import ScanDeckScanner
import Testing
@testable import ScanDeckApp

/// Covers the preferences surface: what it changes, what it refuses to change,
/// and what the support report is allowed to contain.
///
/// Every model below is given its own temporary counter, session, settings, and
/// bookmark storage. The production defaults for all four live in the
/// operator's Application Support and defaults database, and a test that writes
/// there does not fail — it quietly changes the app they scan with.
@MainActor
@Suite("Settings")
struct SettingsTests {
    @Test("The published filename style survives a relaunch")
    func publishedFilenameStylePersists() {
        let storage = InMemoryScanDeckSettingsStorage()
        let first = makeModel(settingsStorage: storage)

        #expect(first.model.publishedFilenameStyle == .abbreviated)
        first.model.publishedFilenameStyle = .descriptive

        #expect(makeModel(settingsStorage: storage).model.publishedFilenameStyle == .descriptive)
    }

    @Test("The export background survives a relaunch")
    func exportBackgroundPersists() {
        let storage = InMemoryScanDeckSettingsStorage()
        let first = makeModel(settingsStorage: storage)

        #expect(first.model.exportBackground == .original)
        first.model.exportBackground = .black

        #expect(makeModel(settingsStorage: storage).model.exportBackground == .black)
    }

    @Test("A pinned scanner survives a relaunch")
    func preferredScannerPersists() {
        let storage = InMemoryScanDeckSettingsStorage()
        let first = makeModel(settingsStorage: storage)

        #expect(first.model.settings.preferredScannerName == nil)
        first.model.setPreferredScannerName("fi-8170")
        #expect(first.model.settings.preferredScannerName == "fi-8170")

        // A second model over the same storage is what the next launch builds.
        let relaunched = makeModel(settingsStorage: storage)
        #expect(relaunched.model.settings.preferredScannerName == "fi-8170")

        relaunched.model.setPreferredScannerName(nil)
        #expect(makeModel(settingsStorage: storage).model.settings
            .preferredScannerName == nil)
    }

    @Test("The chooser offers the scanners that are actually attached")
    func chooserOffersAttachedScanners() {
        let context = makeModel(
            inventory: ScannerInventory(
                scanners: [.fi8170, .unsupportedScanner],
                hasCompletedFirstEnumeration: true
            )
        )

        // Only devices a pass could take. Offering one the probe refuses would
        // let the operator pin a scanner that can never work.
        #expect(context.model.selectableScannerNames == ["fi-8170"])
    }

    @Test("Two scanners sharing a name are offered once, not twice")
    func chooserDeduplicatesNames() {
        let context = makeModel(
            inventory: ScannerInventory(
                scanners: [.fi8170, .fi8170, .secondFi8170],
                hasCompletedFirstEnumeration: true
            )
        )

        // The pin reaches the probe as a name, so two entries reading "fi-8170"
        // would be a choice that changes nothing while looking like it does —
        // and identical values in a `ForEach(id: \.self)` are duplicate
        // identifiers, which is undefined rather than merely useless.
        #expect(
            context.model.selectableScannerNames == ["fi-8170", "fi-8170 (2)"]
        )
    }

    @Test("Pinning a scanner resolves the ambiguity that blocked scanning")
    func pinningResolvesSeveralScanners() {
        let context = makeModel(
            inventory: ScannerInventory(
                scanners: [.fi8170, .secondFi8170],
                hasCompletedFirstEnumeration: true
            )
        )
        let model = context.model
        armBatch(model)

        // Two supported scanners: the probe refuses to guess, so Scan is off.
        #expect(!model.canStartScan)

        model.setPreferredScannerName("fi-8170 (2)")

        // Picking one is the entire purpose of the pin, and the pane says so.
        // A status projection blind to it would leave Scan disabled in exactly
        // the situation the chooser was built for, with no way out but
        // unplugging hardware.
        #expect(model.scannerConnection == .ready(name: "fi-8170 (2)"))
        #expect(model.canStartScan)
    }

    @Test("A pin naming a scanner that is not attached blocks the pass up front")
    func pinnedButAbsentScannerBlocksScanning() {
        let context = makeModel()
        let model = context.model
        armBatch(model)
        #expect(model.canStartScan)

        model.setPreferredScannerName("Some Other Scanner")

        // The probe would refuse this pass — a pinned name that is not there
        // fails rather than falling back, which the pane promises. Reporting
        // ready and letting the operator load the feeder first would make them
        // find that out the expensive way.
        #expect(
            model.scannerConnection
                == .pinnedScannerMissing(name: "Some Other Scanner")
        )
        #expect(!model.canStartScan)
        #expect(
            model.scannerConnection.correctiveAction?.contains("Settings")
                == true
        )
    }

    @Test("A pin matches the way the probe matches, not by equality")
    func pinMatchesBySubstring() {
        let context = makeModel(
            inventory: ScannerInventory(
                scanners: [.fi8170, .secondFi8170],
                hasCompletedFirstEnumeration: true
            )
        )
        let model = context.model

        // `deviceNameContains` is a substring test, so "fi-8170" still matches
        // both units and the ambiguity stands. If the status used equality it
        // would report ready for a pass the probe then refuses — the status and
        // the device a pass takes have to be decided by one rule.
        model.setPreferredScannerName("fi-8170")
        guard case .severalScanners = model.scannerConnection else {
            Issue.record("A substring pin resolved an ambiguity the probe keeps.")
            return
        }
        #expect(!model.canStartScan)
    }

    @Test("Seeding the counter changes the number arming will show")
    func seedingRoundTripsIntoArming() {
        let context = makeModel()
        let profile = context.profile

        #expect(context.model.nextSheetNumber(for: profile) == 114)
        context.model.seedSheetNumber(900, for: profile)

        // The setup sheet reads this same accessor, so this is the assertion
        // that the operator sees their new number before they scan.
        #expect(context.model.nextSheetNumber(for: profile) == 900)
        #expect(context.counterStore.nextSheetNumber(
            for: JobID(rawValue: profile.id)
        ) == 900)
        #expect(context.model.notice?.title == "Counter set")
    }

    @Test("The counter may be seeded downwards, unlike a commit")
    func seedingMovesEitherDirection() {
        let context = makeModel()
        context.model.seedSheetNumber(900, for: context.profile)
        context.model.seedSheetNumber(7, for: context.profile)

        // `SPEC.md` section 3 makes the counter seedable on purpose: commit is
        // monotonic so a replayed publication cannot reuse numbers, and seed is
        // the operator saying otherwise deliberately.
        #expect(context.model.nextSheetNumber(for: context.profile) == 7)
    }

    @Test("The counter is locked while a batch is using its numbers")
    func activeBatchLocksTheCounter() {
        let context = makeModel()
        armBatch(context.model)

        #expect(
            context.model.counterEditBlockReason(for: context.profile)?
                .contains("aug01-sale") == true
        )

        context.model.seedSheetNumber(900, for: context.profile)

        // Seeding under a live batch does not renumber it — the batch reserved
        // its numbers when it was armed. What it does is arrange for the
        // counter commit to fail *after* the batch folder has published, which
        // is the worst failure in the app.
        #expect(context.model.nextSheetNumber(for: context.profile) == 114)
        #expect(context.model.notice?.title == "The counter is in use")
    }

    @Test("A recovered batch locks the counter before it is even resumed")
    func recoveredBatchLocksTheCounter() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let profile = ScanProfileViewData.cards600FullBorder
        let sessionStore = BatchSessionStore(
            directory: root.appending(
                path: "Sessions",
                directoryHint: .isDirectory
            )
        )
        try saveRecoverableBatch(
            named: "yesterdays-batch",
            jobID: JobID(rawValue: profile.id),
            in: sessionStore
        )

        // The next launch, with that batch waiting to be offered back.
        let context = makeModel(
            sessionStore: sessionStore,
            profile: profile
        )
        #expect(context.model.recoveredBatches.count == 1)

        // It reserved its numbers in a previous run and Resume brings them back
        // unchanged, so it holds the counter every bit as firmly as an open
        // batch. Guarding only on the in-memory session would let the operator
        // seed past it here, and then a resumed batch publishes and its commit
        // is refused for moving backwards — the counter failing *after* the
        // folder exists, which is the failure this lock is for.
        let reason = context.model.counterEditBlockReason(for: profile)
        #expect(reason?.contains("yesterdays-batch") == true)

        context.model.seedSheetNumber(900, for: profile)
        #expect(context.model.nextSheetNumber(for: profile) == 114)
        #expect(context.model.notice?.title == "The counter is in use")
    }

    @Test("Forgetting the destination clears it for the next batch only")
    func forgettingTheDestination() {
        let bookmarkStorage = InMemoryDestinationBookmarkStorage()
        let context = makeModel(bookmarkStorage: bookmarkStorage)
        context.model.batchDraft.destinationURL = URL(
            fileURLWithPath: "/tmp/scandeck-tests",
            isDirectory: true
        )
        armBatch(context.model)
        let armedDestination = context.model.activeBatch?.destinationURL

        context.model.forgetDestination()

        #expect(context.model.batchDraft.destinationURL == nil)
        #expect(bookmarkStorage.destinationBookmark == nil)
        // The active batch's pages are already promised somewhere; forgetting a
        // preference must not strand them.
        #expect(context.model.activeBatch?.destinationURL == armedDestination)
    }

    @Test("The support report carries no path, file name, or batch name")
    func diagnosticsAreContentFree() async throws {
        let context = makeModel()
        let model = context.model
        model.batchDraft.destinationURL = URL(
            fileURLWithPath: "/tmp/scandeck-secret-destination",
            isDirectory: true
        )
        model.batchDraft.name = "operators-private-batch"
        model.armBatch()

        model.startOrContinueScan()
        try await waitUntil { model.activeBatch?.phase != .scanning }
        let masterURL = try #require(
            model.activeBatch?.cards.first?.front?.imageURL
        )

        let report = model.diagnosticsText()

        // The report exists to be pasted into an issue without reading it
        // first, so nothing that names the operator's work may reach it. The
        // input type has no field a path could go in; this is the check that
        // the assembly did not find another way.
        #expect(!report.contains("operators-private-batch"))
        #expect(!report.contains("scandeck-secret-destination"))
        #expect(!report.contains(masterURL.lastPathComponent))
        #expect(!report.contains(masterURL.path))
        #expect(!report.contains(context.sessionsDirectory.path))

        // And it still says the things a hardware or storage bug needs.
        #expect(report.contains("fi-8170"))
        #expect(report.contains("0x04c5:0x15ff"))
        #expect(report.contains("Configured: yes"))
        #expect(report.contains(SheetNumber.formatted(114)))
        #expect(report.contains("Active batch: 2 cards"))
    }

    @Test("The support report names a scanner it cannot drive")
    func diagnosticsNameUnsupportedHardware() {
        let context = makeModel(
            inventory: ScannerInventory(
                scanners: [.unsupportedScanner],
                hasCompletedFirstEnumeration: true
            )
        )

        // "Will my scanner even work?" is the question this report exists to
        // answer, so the device ScanDeck refused is the one line that matters
        // most.
        let report = context.model.diagnosticsText()
        #expect(report.contains("Generic Flatbed 4200"))
        #expect(report.contains("not supported"))
    }

    // MARK: - Harness

    private struct Context {
        let model: ScanDeckPresentationModel
        let counterStore: JobCounterStore
        let sessionsDirectory: URL
        let profile: ScanProfileViewData
    }

    private func makeModel(
        inventory: ScannerInventory = .oneSupportedScanner,
        settingsStorage: any ScanDeckSettingsStorage =
            InMemoryScanDeckSettingsStorage(),
        bookmarkStorage: any DestinationBookmarkStorage =
            InMemoryDestinationBookmarkStorage(),
        sessionStore: BatchSessionStore? = nil,
        profile: ScanProfileViewData = .cards600FullBorder
    ) -> Context {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let sessionsDirectory = sessionStore?.storageDirectory
            ?? root.appending(path: "Sessions", directoryHint: .isDirectory)
        let counterStore = JobCounterStore(directory: root)
        try? counterStore.seed(114, for: JobID(rawValue: profile.id))

        let model = ScanDeckPresentationModel(
            profiles: [profile],
            scannerStatus: ScannerStatusMonitor(
                source: ScriptedScannerInventorySource(inventory: inventory)
            ),
            actions: SettingsScriptedActions(),
            destinationPicker: NoDestinationPicker(),
            destinationBookmarkStore: DestinationBookmarkStore(
                storage: bookmarkStorage
            ),
            jobCounterStore: counterStore,
            sessionStore: sessionStore
                ?? BatchSessionStore(directory: sessionsDirectory),
            settingsStore: ScanDeckSettingsStore(storage: settingsStorage),
            publishedBatchStore: PublishedBatchStore(directory: root)
        )
        return Context(
            model: model,
            counterStore: counterStore,
            sessionsDirectory: sessionsDirectory,
            profile: profile
        )
    }

    /// Writes the record a previous run would have left behind, so the next
    /// model built over this store finds a batch waiting to be offered back.
    private func saveRecoverableBatch(
        named name: String,
        jobID: JobID,
        in store: BatchSessionStore
    ) throws {
        var session = BatchSession(
            id: BatchID(rawValue: UUID()),
            jobID: jobID,
            batchName: try BatchName(name),
            firstSheetNumber: 114,
            deliveryOrder: .backFirst,
            requestedMargins: try ScanMargins(all: 3),
            captureRotation: .clockwise180
        )
        let passID = ScanPassID(rawValue: UUID())
        _ = try BatchSessionReducer.reduce(
            .beginAppend(passID: passID),
            into: &session
        )
        var masterURLs: [MasterID: URL] = [:]
        for index in 0..<2 {
            let masterID = MasterID(rawValue: UUID())
            masterURLs[masterID] = URL(
                fileURLWithPath: "/tmp/scandeck-tests/recovered-\(index).jpg"
            )
            _ = try BatchSessionReducer.reduce(
                .pageReceived(
                    passID: passID,
                    masterID: masterID,
                    captureSequence: session.nextCaptureSequence,
                    newCardID: index == 0 ? CardID(rawValue: UUID()) : nil
                ),
                into: &session
            )
        }
        _ = try BatchSessionReducer.reduce(
            .scanEnded(passID: passID, outcome: .completed),
            into: &session
        )
        try store.save(
            PersistedBatchSession(
                session: session,
                masterURLs: masterURLs,
                startedAt: .now,
                savedAt: .now,
                destinationBookmark: nil
            )
        )
    }

    private func armBatch(_ model: ScanDeckPresentationModel) {
        model.batchDraft.name = "aug01-sale"
        model.batchDraft.destinationURL = model.batchDraft.destinationURL
            ?? URL(fileURLWithPath: "/tmp/scandeck-tests", isDirectory: true)
        model.armBatch()
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

/// Four pages down a path that looks like a real session directory, so the
/// diagnostics test has genuine file names to check the report against.
@MainActor
private final class SettingsScriptedActions: ScanDeckAppActions {
    func scan(_ request: ScanPassRequest) -> AsyncStream<ScanPassProgress> {
        AsyncStream { continuation in
            for index in 0..<4 {
                continuation.yield(
                    .page(
                        URL(
                            fileURLWithPath:
                                "/tmp/scandeck-tests/\(request.batchID.rawValue.uuidString)"
                                    + "/master-secret-\(index).jpg"
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
        MarginAssessmentOutcome(
            assessment: .sufficient(mediaSize: nil),
            publishedCrop: nil
        )
    }

    func publish(
        _ request: BatchPublishRequest,
        progress: @escaping @Sendable (BatchPublishProgress) -> Void
    ) async throws -> BatchPublishReceipt {
        BatchPublishReceipt(
            publishedFolderURL: request.destinationURL,
            destinationDescription: "test"
        )
    }

    func showInFinder(_ url: URL?) {}
}

@MainActor
private final class NoDestinationPicker: DestinationPicking {
    func pickDestination(startingAt url: URL?) -> URL? { nil }
}
