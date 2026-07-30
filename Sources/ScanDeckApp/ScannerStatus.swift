import Foundation
import Observation
import ScanDeckScanner

/// The scanner's condition as the operator needs it stated.
///
/// Each case carries its own copy rather than being handed a message, because a
/// state that cannot say what to do about itself leaves the operator staring at
/// a disabled Scan button with no next move — the same trap TICKET-023 closed
/// for blocking notices.
enum ScannerConnection: Equatable {
    /// The first sweep has not finished. Distinct from finding nothing.
    case searching
    case ready(name: String)
    case disconnected
    case unsupported(names: [String])
    case severalScanners(names: [String])
    case pinnedScannerMissing(name: String)
    case inUseElsewhere(name: String)

    var title: String {
        switch self {
        case .searching:
            "Looking for a scanner…"
        case let .ready(name):
            name
        case .disconnected:
            "No scanner found"
        case .unsupported:
            "Scanner not supported"
        case .severalScanners:
            "More than one scanner"
        case let .pinnedScannerMissing(name):
            "\(name) is not connected"
        case let .inUseElsewhere(name):
            "\(name) is in use"
        }
    }

    /// The second line of the sidebar pill. Kept to a phrase: the pill is
    /// narrow, and a sentence truncated at its most useful clause says less
    /// than a phrase that fits.
    var summary: String {
        switch self {
        case .searching:
            "Searching…"
        case .ready:
            "Ready"
        case .disconnected:
            "Not connected"
        case .unsupported:
            "Not supported"
        case .severalScanners:
            "Choose one"
        case .pinnedScannerMissing:
            "Pinned, not here"
        case .inUseElsewhere:
            "Held by another app"
        }
    }

    /// What the operator does about it, in full. `nil` when there is nothing to
    /// do, which is the only state allowed to say nothing.
    var correctiveAction: String? {
        switch self {
        case .searching:
            "ScanDeck is asking Image Capture what is attached."
        case .ready:
            nil
        case .disconnected:
            "Connect the scanner over USB and switch it on. ScanDeck picks it "
                + "up on its own — there is nothing to press here."
        case let .unsupported(names):
            "ScanDeck found \(Self.list(names)), which it has not been tested "
                + "against. It drives the fi-8170 through the PFU driver's "
                + "Overscan mode, which is what captures the real background "
                + "border every published card needs. Connect a supported "
                + "scanner."
        case let .severalScanners(names):
            "ScanDeck found \(Self.list(names)) and cannot tell which one you "
                + "mean. Pick one in Settings › Scanner, or disconnect the "
                + "ones you are not scanning with."
        case let .pinnedScannerMissing(name):
            "Settings pins ScanDeck to “\(name)”, which is not attached. "
                + "Connect it, or choose any supported scanner in "
                + "Settings › Scanner."
        case .inUseElsewhere:
            "Another application is holding it — Image Capture, Preview, or "
                + "another scanning tool. Quit that app and ScanDeck carries "
                + "on by itself."
        }
    }

    var isReady: Bool {
        if case .ready = self {
            true
        } else {
            false
        }
    }

    private static func list(_ names: [String]) -> String {
        switch names.count {
        case 0:
            "a scanner"
        case 1:
            names[0]
        case 2:
            "\(names[0]) and \(names[1])"
        default:
            names.dropLast().joined(separator: ", ") + ", and \(names[names.count - 1])"
        }
    }
}

/// Where the live view of attached scanners comes from.
///
/// A protocol so the whole status surface can be driven from a script: plugging
/// and unplugging an fi-8170 is not something a test suite can do, and the rules
/// worth testing — that Scan blocks, that a mid-pass bounce does not flap the
/// UI, that a busy scanner explains itself — are all about what the app does
/// with the report rather than how the report is obtained.
@MainActor
protocol ScannerInventorySource: AnyObject {
    /// What is attached right now, readable without waiting.
    var inventory: ScannerInventory { get }

    /// The inventory as it stands, then every change to it.
    func inventoryUpdates() -> AsyncStream<ScannerInventory>
}

extension ImageCaptureScannerInventoryBrowser: ScannerInventorySource {}

/// Assembles the scanner status from two sources that are each authoritative
/// about different things.
///
/// The device browser knows what is attached. It cannot know whether another
/// application is holding the device, because Image Capture publishes no such
/// property — that is learned only by asking for a session, which is precisely
/// what a pass does. So a running pass outranks the bus, and the bus is believed
/// the rest of the time.
@MainActor
@Observable
final class ScannerStatusMonitor {
    /// How long a scanner may be missing before its absence is believed.
    ///
    /// A device that vanishes and comes straight back is a bounce, not an
    /// unplug: the fi-8170 re-enumerates over USB around sleep, which is why
    /// the probe already waits out a removal before a pass rather than failing
    /// on it (TICKET-022). Repainting the sidebar and disabling Scan for a
    /// blink would take the app's main action away from a scanner that is
    /// sitting there working. Arrivals are never delayed — good news costs
    /// nothing to believe — so this only slows down bad news.
    static let defaultDisappearanceSettleWindow = Duration.seconds(2.5)

    /// The inventory the status is drawn from. Held still while a pass runs.
    private var stableInventory: ScannerInventory = .searching

    /// The most recent report, kept even while it is not being shown, so the
    /// truth is available again the moment a pass ends. Readable so a test can
    /// tell "the report arrived and was deliberately not adopted" from "the
    /// report has not arrived yet".
    private(set) var observedInventory: ScannerInventory = .searching

    private var isPassInFlight = false
    private var scannerHeldElsewhere: String?

    /// The scanner the operator pinned in Settings, or `nil` for whichever
    /// supported one is attached.
    ///
    /// The status has to know this or it is describing a different device from
    /// the one a pass would take. Pinning is precisely how the operator
    /// resolves `.severalScanners`, so a projection blind to the pin leaves
    /// Scan disabled in the one situation the pin exists for — and, the other
    /// way round, reports `.ready` for a pass the probe will refuse because the
    /// pinned device is not there.
    var preferredScannerName: String?

    @ObservationIgnored
    private let source: (any ScannerInventorySource)?

    @ObservationIgnored
    private let disappearanceSettleWindow: Duration

    @ObservationIgnored
    private var subscription: Task<Void, Never>?

    @ObservationIgnored
    private var pendingDisappearance: Task<Void, Never>?

    init(
        source: (any ScannerInventorySource)?,
        disappearanceSettleWindow: Duration = defaultDisappearanceSettleWindow
    ) {
        self.source = source
        self.disappearanceSettleWindow = disappearanceSettleWindow
    }

    deinit {
        subscription?.cancel()
        pendingDisappearance?.cancel()
    }

    /// Begins listening. Separate from `init` so a caller decides when the app
    /// starts talking to Image Capture.
    func start() {
        guard subscription == nil, let source else {
            return
        }
        let updates = source.inventoryUpdates()
        // Take the current value synchronously as well as through the stream.
        // The stream would deliver it, but not before the consuming task next
        // runs, and that would make "what does the app think is attached
        // immediately after launch" depend on scheduling rather than on the
        // source. It is the same value either way; taking it here makes the
        // seam deterministic.
        receive(source.inventory)
        subscription = Task { [weak self] in
            for await inventory in updates {
                guard let self else {
                    return
                }
                receive(inventory)
            }
        }
    }

    var connection: ScannerConnection {
        if let scannerHeldElsewhere {
            return .inUseElsewhere(name: scannerHeldElsewhere)
        }
        guard stableInventory.hasCompletedFirstEnumeration else {
            return .searching
        }

        let selected = selectedScanners
        if selected.count == 1 {
            return .ready(name: selected[0].name)
        }
        if selected.count > 1 {
            return .severalScanners(names: selected.map(\.name))
        }

        // Nothing the pass could take. Which of the three reasons it is decides
        // what the operator does next, and they are three different jobs.
        if let pinned = preferredScannerName, !pinned.isEmpty,
           !stableInventory.supportedScanners.isEmpty
        {
            return .pinnedScannerMissing(name: pinned)
        }

        let unsupported = stableInventory.unsupportedScanners
        if !unsupported.isEmpty {
            return .unsupported(names: unsupported.map(\.name))
        }
        return .disconnected
    }

    /// The supported scanners a pass would actually consider.
    ///
    /// Matched by the same substring rule the probe applies to
    /// `deviceNameContains`, not by equality. If these two ever disagree the
    /// status describes one device while the pass takes another — the same
    /// class of drift that put the supported-USB set in one place.
    private var selectedScanners: [ScannerDeviceIdentity] {
        let supported = stableInventory.supportedScanners
        guard let pinned = preferredScannerName, !pinned.isEmpty else {
            return supported
        }
        return supported.filter {
            $0.name.localizedCaseInsensitiveContains(pinned)
        }
    }

    /// Every supported scanner currently attached, for a chooser to offer.
    var supportedScanners: [ScannerDeviceIdentity] {
        stableInventory.supportedScanners
    }

    /// Everything the browser can see, supported or not. A diagnostics report
    /// wants the device it cannot drive most of all.
    var attachedScanners: [ScannerDeviceIdentity] {
        stableInventory.scanners
    }

    func passDidStart() {
        isPassInFlight = true
    }

    /// Hands the bus back the last word.
    ///
    /// The held-elsewhere claim is dropped with it: it was only ever true
    /// because a session request said so, and once ScanDeck stops asking it has
    /// no idea whether the other application let go.
    func passDidEnd() {
        isPassInFlight = false
        scannerHeldElsewhere = nil
        pendingDisappearance?.cancel()
        pendingDisappearance = nil
        stableInventory = observedInventory
    }

    func receive(_ notice: ScanPassNotice) {
        switch notice {
        case let .scannerInUseElsewhere(name):
            scannerHeldElsewhere = name
        case .scannerAvailableAgain:
            scannerHeldElsewhere = nil
        }
    }

    private func receive(_ inventory: ScannerInventory) {
        observedInventory = inventory
        guard !isPassInFlight else {
            // The fi-8170 re-enumerates over USB when it wakes, and opening a
            // session is exactly what wakes it, so a pass routinely watches its
            // own scanner leave and rejoin the bus (TICKET-022). The probe
            // already owns that policy — it waits out the bounce, restarts from
            // session open, and fails the pass for real if the device does not
            // come back. Repainting the status from the bus in the meantime
            // would flash "No scanner found" across the screen while a card is
            // physically feeding.
            return
        }

        pendingDisappearance?.cancel()
        pendingDisappearance = nil

        guard Self.losesAScanner(shown: stableInventory, reported: inventory)
        else {
            stableInventory = inventory
            return
        }

        pendingDisappearance = Task { [weak self] in
            guard let window = self?.disappearanceSettleWindow else {
                return
            }
            try? await Task.sleep(for: window)
            guard let self, !Task.isCancelled else {
                return
            }
            pendingDisappearance = nil
            guard !isPassInFlight else {
                return
            }
            // It really is gone, or gone long enough to be worth saying so.
            stableInventory = observedInventory
        }
    }

    /// Whether a report has lost a scanner the shown status still claims.
    ///
    /// Counted rather than set-compared: two identical units are two devices,
    /// and losing one of them is exactly the case the operator most needs told
    /// about, because it is what turns an ambiguous choice into a usable one.
    static func losesAScanner(
        shown: ScannerInventory,
        reported: ScannerInventory
    ) -> Bool {
        var remaining = Dictionary(
            reported.scanners.map { ($0, 1) },
            uniquingKeysWith: +
        )
        for scanner in shown.scanners {
            guard let count = remaining[scanner], count > 0 else {
                return true
            }
            remaining[scanner] = count - 1
        }
        return false
    }
}
