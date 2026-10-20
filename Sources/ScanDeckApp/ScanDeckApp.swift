import AppKit
import ScanDeckCore
import ScanDeckScanner
import SwiftUI

@main
struct ScanDeckApp: App {
    @NSApplicationDelegateAdaptor(ScanDeckApplicationDelegate.self)
    private var applicationDelegate

    /// One store, read by both the model that edits the preference and the
    /// provider that obeys it.
    ///
    /// `ScanDeckSettingsStore` is a value over `UserDefaults`, so two copies
    /// are two views of the same data. That is what lets the scan provider read
    /// the pinned scanner at the moment a pass starts without holding a
    /// reference to the UI, and what stops a preference from existing twice.
    private static let settingsStore = ScanDeckSettingsStore()

    @State private var model = ScanDeckPresentationModel(
        scannerStatus: ScannerStatusMonitor(
            source: makeScannerInventorySource()
        ),
        actions: ScanDeckWorkflowActions(scanner: makeScanner()),
        destinationPicker: AppKitDestinationPicker(),
        settingsStore: settingsStore
    )

    /// The real scanner, unless this run is deliberately exercising the app
    /// without one.
    ///
    /// `SyntheticScanPassProvider` writes real JPEG masters, so a synthetic run
    /// still drives production crop analysis, margin verdicts, and atomic
    /// publication — only the hardware is stood in for. Keeping it reachable is
    /// what lets a contributor without an fi-8170 exercise the whole workflow,
    /// and lets anyone reproduce a UI bug without burning a card through the
    /// feeder.
    @MainActor
    private static func makeScanner() -> any ScanPassProviding {
        if isSyntheticRun {
            return SyntheticScanPassProvider()
        }
        // Read per pass rather than captured once: the operator can change the
        // pinned scanner in Settings between one pass and the next, and a
        // provider holding the value it was built with would keep driving the
        // old choice until the app was relaunched.
        let settingsStore = settingsStore
        return ImageCaptureScanPassProvider(
            preferredScannerName: { settingsStore.load().preferredScannerName }
        )
    }

    /// A synthetic run has no device to report on, so it reports one anyway.
    ///
    /// The point of `--synthetic` is to exercise the production workflow
    /// without an fi-8170; a status source that correctly says "no scanner
    /// found" would disable Scan and make the mode useless. The stand-in is
    /// named as such rather than impersonating a real model, so nothing on
    /// screen claims hardware that is not there.
    @MainActor
    private static func makeScannerInventorySource() -> any ScannerInventorySource {
        if isSyntheticRun {
            return SyntheticScannerInventorySource()
        }
        return ImageCaptureScannerInventoryBrowser()
    }

    private static var isSyntheticRun: Bool {
        ProcessInfo.processInfo.environment["SCANDECK_SYNTHETIC_SCANNER"] == "1"
    }

    var body: some Scene {
        WindowGroup {
            ScanDeckRootView(model: model)
                .frame(minWidth: 1_040, minHeight: 720)
        }
        .defaultSize(width: 1_280, height: 820)
        .windowStyle(.titleBar)
        // Keep the title and toolbar in one system-managed row. The expanded
        // two-row style can restore a NavigationSplitView with its first list
        // rows inside the upper title-bar band, leaving them clipped above the
        // scrollable region. Unified gives every column one stable safe-area
        // boundary below the window controls.
        .windowToolbarStyle(.unified)
        .windowResizability(.contentMinSize)
        .commands {
            ScanDeckCommands(model: model)
        }

        Settings {
            SettingsView(model: model)
        }
    }
}

private final class ScanDeckApplicationDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Bare SwiftPM executables register with LaunchServices as
        // BackgroundOnly and otherwise can never become active or receive key
        // events. These calls are harmless when ScanDeck runs in its real bundle.
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate()
        NSApplication.shared.windows.first?.makeKeyAndOrderFront(nil)
    }

    func applicationShouldTerminateAfterLastWindowClosed(
        _ sender: NSApplication
    ) -> Bool {
        true
    }
}

private struct ScanDeckCommands: Commands {
    let model: ScanDeckPresentationModel

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button(model.activeBatch == nil ? "New Batch…" : "Resume Active Batch") {
                if model.activeBatch == nil, let profile = model.profiles.first {
                    model.selectProfile(profile)
                } else {
                    model.resumeActiveBatch()
                }
            }
            .keyboardShortcut("n", modifiers: .command)
        }

        CommandMenu("Batch") {
            Button(model.scanButtonTitle) {
                model.startOrContinueScan()
            }
            .keyboardShortcut("r", modifiers: .command)
            .disabled(!model.canStartScan)

            Button("Complete Batch") {
                model.completeBatch()
            }
            .keyboardShortcut(.return, modifiers: [.command, .shift])
            .disabled(!model.canCompleteBatch)

            Divider()

            Button("Show Completed Batch in Finder") {
                model.showCompletedBatchInFinder()
            }
            .disabled(model.completionSummary == nil)

            Divider()

            Button("Cancel Batch…") {
                model.isCancelBatchConfirmationPresented = true
            }
            .disabled(!model.canCancelBatch)
        }

        CommandMenu("Card") {
            Button("Retry Incomplete Card") {
                model.retrySelectedCard()
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])
            .disabled(model.selectedCard?.isIncomplete != true)

            Button("Replace Card…") {
                model.replaceSelectedCard()
            }
            .disabled(model.selectedCard == nil)

            Divider()

            Button("Rotate Front Clockwise") {
                model.rotateSelectedCardSide(.front)
            }
            .keyboardShortcut("]", modifiers: .command)
            .disabled(model.selectedCard?.front == nil)

            Button("Rotate Back Clockwise") {
                model.rotateSelectedCardSide(.back)
            }
            .keyboardShortcut("[", modifiers: .command)
            .disabled(model.selectedCard?.back == nil)

            Divider()

            Button("Delete Card") {
                model.deleteSelectedCard()
            }
            .keyboardShortcut(.delete, modifiers: [])
            .disabled(model.selectedCard == nil)
        }

        CommandGroup(after: .sidebar) {
            Button(model.isInspectorPresented ? "Hide Inspector" : "Show Inspector") {
                model.toggleInspector()
            }
            .keyboardShortcut("i", modifiers: [.command, .option])
        }
    }
}
