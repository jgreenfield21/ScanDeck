import Foundation
import ScanDeckCore
import ScanDeckScanner
import Testing
@testable import ScanDeckApp

/// Covers what the app does with a live report of which scanners are attached.
///
/// The status used to be the constant `.ready(name: "fi-8170")`, so the app
/// claimed a scanner it had never looked for and offered Scan with the cable
/// out. These tests are the substitute for pulling a USB cable: the source is
/// scripted, and every rule below is about the app's reaction to it.
@MainActor
@Suite("Scanner status")
struct ScannerStatusTests {
    @Test("Before the first sweep finishes, nothing is claimed either way")
    func firstEnumerationIsItsOwnState() {
        let context = makeModel(
            inventory: ScannerInventory(
                scanners: [],
                hasCompletedFirstEnumeration: false
            )
        )

        // Announcing "no scanner found" here would send the operator to check a
        // cable for a device that is about to enumerate.
        #expect(context.model.scannerConnection == .searching)
        #expect(!context.model.canStartScan)
    }

    @Test("An attached supported scanner reads ready and lets a scan start")
    func attachedScannerIsReady() {
        let context = makeModel()
        armBatch(context.model)

        #expect(context.model.scannerConnection == .ready(name: "fi-8170"))
        #expect(context.model.canStartScan)
    }

    @Test("Unplugging blocks Scan and says what to do about it")
    func unpluggingBlocksScanning() async throws {
        let context = makeModel()
        armBatch(context.model)
        #expect(context.model.canStartScan)

        context.source.report(.nothingAttached)
        try await waitUntil {
            context.model.scannerConnection == .disconnected
        }

        #expect(!context.model.canStartScan)

        // The press has to say why rather than doing nothing: the reason
        // belongs on screen, never in a tooltip (TICKET-023).
        context.model.startOrContinueScan()
        let notice = try #require(context.model.notice)
        #expect(notice.title == "No scanner found")
        #expect(notice.message.contains("Connect the scanner"))
        #expect(context.actions.scanRequests.isEmpty)
    }

    @Test("Plugging back in returns to ready with nothing to press")
    func repluggingRestoresReady() async throws {
        let context = makeModel(inventory: .nothingAttached)
        armBatch(context.model)
        #expect(!context.model.canStartScan)

        context.source.report(.oneSupportedScanner)
        try await waitUntil { context.model.canStartScan }

        #expect(context.model.scannerConnection == .ready(name: "fi-8170"))
    }

    @Test("An attached scanner ScanDeck cannot drive is named, not ignored")
    func unsupportedScannerIsDistinctFromNoScanner() {
        let context = makeModel(
            inventory: ScannerInventory(
                scanners: [.unsupportedScanner],
                hasCompletedFirstEnumeration: true
            )
        )

        // "No scanner found" would be a lie the operator can see through — the
        // device is in Image Capture — and would send them to check a cable
        // that is fine.
        #expect(
            context.model.scannerConnection
                == .unsupported(names: ["Generic Flatbed 4200"])
        )
        #expect(!context.model.canStartScan)
        #expect(
            context.model.scannerConnection.correctiveAction?
                .contains("Generic Flatbed 4200") == true
        )
    }

    @Test("Two supported scanners block the pass the probe would refuse anyway")
    func ambiguousScannerSelectionBlocksScanning() {
        let context = makeModel(
            inventory: ScannerInventory(
                scanners: [.fi8170, .secondFi8170],
                hasCompletedFirstEnumeration: true
            )
        )

        // The probe refuses to guess between two supported devices. Saying so
        // before a pass starts beats saying it after the operator has loaded
        // the feeder.
        guard case let .severalScanners(names) =
            context.model.scannerConnection
        else {
            Issue.record("Two supported scanners did not read as ambiguous.")
            return
        }
        #expect(names == ["fi-8170", "fi-8170 (2)"])
        #expect(!context.model.canStartScan)
    }

    @Test("A scanner that blinks off the bus while idle keeps Scan available")
    func aBlinkIsNotAnUnplug() async throws {
        // A window no test will outlast, so "the loss was seen and deliberately
        // not adopted" is an assertion rather than a race.
        let context = makeModel(settleWindow: .seconds(60))
        armBatch(context.model)

        context.source.report(.nothingAttached)
        try await waitUntil {
            context.status.observedInventory == .nothingAttached
        }

        // The report has arrived and is being held. The fi-8170 re-enumerates
        // over USB around sleep, so a device that disappears and comes right
        // back has not been unplugged — and taking Scan away for that blink
        // would disable the app's main action on a working scanner.
        #expect(context.model.scannerConnection == .ready(name: "fi-8170"))
        #expect(context.model.canStartScan)

        context.source.report(.oneSupportedScanner)
        try await settle()
        #expect(context.model.scannerConnection == .ready(name: "fi-8170"))
        #expect(context.model.canStartScan)
    }

    @Test("A scanner that bounces off the bus mid-pass does not flap the UI")
    func midPassBounceDoesNotFlapTheStatus() async throws {
        let context = makeModel()
        let model = context.model
        armBatch(model)

        context.actions.holdPassOpen = true
        model.startOrContinueScan()
        try await waitUntil { context.actions.isPassOpen }

        // The fi-8170 re-enumerates over USB when it wakes, and opening a
        // session is what wakes it, so the browser sees its own scanner leave
        // and rejoin during a perfectly healthy pass (TICKET-022). The probe
        // owns that policy; the status line must not contradict it.
        context.source.report(.nothingAttached)
        try await settle()
        #expect(model.scannerConnection == .ready(name: "fi-8170"))

        context.source.report(.oneSupportedScanner)
        context.actions.finishHeldPass()
        try await waitUntil { model.activeBatch?.phase != .scanning }
        #expect(model.scannerConnection == .ready(name: "fi-8170"))
    }

    @Test("A scanner genuinely lost during a pass is reported once it ends")
    func aRealDisconnectSurfacesWhenThePassEnds() async throws {
        let context = makeModel()
        let model = context.model
        armBatch(model)

        context.actions.holdPassOpen = true
        model.startOrContinueScan()
        try await waitUntil { context.actions.isPassOpen }

        context.source.report(.nothingAttached)
        context.actions.failHeldPass(
            message: "The selected scanner was disconnected."
        )
        try await waitUntil { model.activeBatch?.phase != .scanning }

        // Holding the status still is only right *during* a pass. Once the pass
        // is over the bus is the authority again, and it says the cable is out.
        try await waitUntil { model.scannerConnection == .disconnected }
        #expect(!model.canStartScan)
    }

    @Test("A pass held by another application explains itself and recovers")
    func busyScannerIsExplainedAndCleared() async throws {
        let context = makeModel()
        let model = context.model
        armBatch(model)

        context.actions.holdPassOpen = true
        model.startOrContinueScan()
        try await waitUntil { context.actions.isPassOpen }

        context.actions.send(
            .notice(.scannerInUseElsewhere(name: "fi-8170"))
        )
        try await waitUntil {
            model.scannerConnection == .inUseElsewhere(name: "fi-8170")
        }

        // Nothing else would say this. The pass is neither failing nor
        // delivering, so without the notice the operator watches a spinner
        // until the probe's deadline runs out.
        let notice = try #require(model.notice)
        #expect(notice.title == "fi-8170 is in use")
        #expect(notice.message.contains("Quit that app"))

        context.actions.send(.notice(.scannerAvailableAgain))
        try await waitUntil { model.notice == nil }
        #expect(model.scannerConnection == .ready(name: "fi-8170"))

        context.actions.finishHeldPass()
        try await waitUntil { model.activeBatch?.phase != .scanning }
    }

    @Test("A stalled-scanner banner never outlives the pass that raised it")
    func busyNoticeCannotSurviveThePass() async throws {
        let context = makeModel()
        let model = context.model
        armBatch(model)

        context.actions.holdPassOpen = true
        model.startOrContinueScan()
        try await waitUntil { context.actions.isPassOpen }

        context.actions.send(.notice(.scannerInUseElsewhere(name: "fi-8170")))
        try await waitUntil {
            model.scannerConnection == .inUseElsewhere(name: "fi-8170")
        }

        // The pass now succeeds without the transport ever saying the scanner
        // came back — which the probe can genuinely do, because a device that
        // bounces off the bus while parked on -9925 leaves the busy wait
        // through the reconnect path rather than through
        // `scannerDeviceDidBecomeAvailable`. A banner with only one way down
        // would sit there reading "another application is holding the scanner"
        // over a batch that just scanned perfectly.
        context.actions.finishHeldPass()
        try await waitUntil { model.activeBatch?.phase != .scanning }

        #expect(model.notice == nil)
        #expect(model.scannerConnection == .ready(name: "fi-8170"))
        #expect(model.canStartScan)
    }

    @Test("Retry with the scanner gone is refused before a pass begins")
    func retryWithoutAScannerIsRefused() async throws {
        let context = makeModel(pagesPerPass: [1])
        let model = context.model
        armBatch(model)

        model.startOrContinueScan()
        try await waitUntil { model.activeBatch?.phase != .scanning }
        let incomplete = try #require(model.activeBatch?.incompleteCards.first)

        context.source.report(.nothingAttached)
        try await waitUntil { model.scannerConnection == .disconnected }

        let requestsBefore = context.actions.scanRequests.count
        model.retryCard(incomplete.id)

        // Retry does not route through `canStartScan`, so without its own guard
        // it would open a pass whose only possible outcome is a hardware
        // failure banner — and would leave the batch in `.scanning` meanwhile.
        #expect(context.actions.scanRequests.count == requestsBefore)
        #expect(model.activeBatch?.phase != .scanning)
        #expect(model.notice?.title == "No scanner found")
    }

    // MARK: - Harness

    private struct Context {
        let model: ScanDeckPresentationModel
        let source: ScriptedScannerInventorySource
        let status: ScannerStatusMonitor
        let actions: HoldableScriptedActions
    }

    /// Every model gets its own counter and session directories: both defaults
    /// live in Application Support, and a test that writes there corrupts the
    /// operator's real counters and unfinished batches.
    private func makeModel(
        inventory: ScannerInventory = .oneSupportedScanner,
        pagesPerPass: [Int] = [2],
        settleWindow: Duration = .milliseconds(30)
    ) -> Context {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let profile = ScanProfileViewData.cards600FullBorder
        let counterStore = JobCounterStore(directory: directory)
        try? counterStore.seed(114, for: JobID(rawValue: profile.id))

        let source = ScriptedScannerInventorySource(inventory: inventory)
        let actions = HoldableScriptedActions(pagesPerPass: pagesPerPass)
        // Short enough not to pace the suite; the production window is sized
        // for a scanner blinking off the bus, and what is under test here is
        // that the rule exists rather than how long it waits.
        let status = ScannerStatusMonitor(
            source: source,
            disappearanceSettleWindow: settleWindow
        )
        let model = ScanDeckPresentationModel(
            profiles: [profile],
            scannerStatus: status,
            actions: actions,
            destinationPicker: NoopDestinationPicker(),
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
            publishedBatchStore: PublishedBatchStore(directory: directory)
        )
        return Context(
            model: model,
            source: source,
            status: status,
            actions: actions
        )
    }

    private func armBatch(_ model: ScanDeckPresentationModel) {
        model.batchDraft.name = "aug01-sale"
        model.batchDraft.destinationURL = URL(
            fileURLWithPath: "/tmp/scandeck-tests",
            isDirectory: true
        )
        model.armBatch()
    }

    /// Lets every queued main-actor hop run, so "the status did *not* change"
    /// is an assertion about the rule rather than about being quick enough.
    private func settle() async throws {
        for _ in 0..<20 {
            try await Task.sleep(for: .milliseconds(5))
        }
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

/// A page source whose pass can be left open, so the hardware states that only
/// exist mid-pass are reachable.
@MainActor
private final class HoldableScriptedActions: ScanDeckAppActions {
    var holdPassOpen = false
    private(set) var scanRequests: [ScanPassRequest] = []

    /// Whether a held pass is actually accepting events yet.
    ///
    /// The model calls `scan` from inside its own task, so the pass exists in
    /// the reducer a turn before the stream does. A test that sends into it on
    /// the strength of the phase alone drops the event on the floor.
    var isPassOpen: Bool {
        openContinuation != nil
    }

    private let pagesPerPass: [Int]
    private var passIndex = 0
    private var openContinuation: AsyncStream<ScanPassProgress>.Continuation?

    init(pagesPerPass: [Int]) {
        self.pagesPerPass = pagesPerPass
    }

    func scan(_ request: ScanPassRequest) -> AsyncStream<ScanPassProgress> {
        scanRequests.append(request)
        let pageCount = passIndex < pagesPerPass.count
            ? pagesPerPass[passIndex]
            : 2
        passIndex += 1
        let holdOpen = holdPassOpen

        let pair = AsyncStream<ScanPassProgress>.makeStream(
            bufferingPolicy: .unbounded
        )
        for index in 0..<pageCount {
            pair.continuation.yield(
                .page(
                    URL(
                        fileURLWithPath:
                            "/tmp/scandeck-tests/page-\(index)-\(UUID().uuidString).jpg"
                    )
                )
            )
        }
        if holdOpen {
            openContinuation = pair.continuation
        } else {
            pair.continuation.yield(.finished(.succeeded))
            pair.continuation.finish()
        }
        return pair.stream
    }

    func send(_ progress: ScanPassProgress) {
        openContinuation?.yield(progress)
    }

    func finishHeldPass() {
        openContinuation?.yield(.finished(.succeeded))
        openContinuation?.finish()
        openContinuation = nil
    }

    func failHeldPass(message: String) {
        openContinuation?.yield(.finished(.failed(message: message)))
        openContinuation?.finish()
        openContinuation = nil
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
private final class NoopDestinationPicker: DestinationPicking {
    func pickDestination(startingAt url: URL?) -> URL? { nil }
}
