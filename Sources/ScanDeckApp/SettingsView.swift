import AppKit
import ScanDeckCore
import ScanDeckScanner
import SwiftUI

/// The preferences surface.
///
/// Nothing here owns state. Every control edits a store the rest of the app
/// already reads — the settings store, the destination bookmark, the job
/// counter, the session directory — so there is no second copy of a preference
/// to drift out of step with the one that is used.
struct SettingsView: View {
    let model: ScanDeckPresentationModel

    var body: some View {
        TabView {
            ScannerSettingsView(model: model)
                .tabItem {
                    Label("Scanner", systemImage: "scanner")
                }
            NumberingSettingsView(model: model)
                .tabItem {
                    Label("Numbering", systemImage: "number")
                }
            FilesSettingsView(model: model)
                .tabItem {
                    Label("Files", systemImage: "folder")
                }
            DiagnosticsSettingsView(model: model)
                .tabItem {
                    Label("Diagnostics", systemImage: "stethoscope")
                }
        }
        .frame(width: 560, height: 420)
    }
}

// MARK: - Scanner

private struct ScannerSettingsView: View {
    let model: ScanDeckPresentationModel

    private var selection: Binding<String> {
        Binding(
            get: { model.settings.preferredScannerName ?? Self.anyScannerTag },
            set: { name in
                model.setPreferredScannerName(
                    name == Self.anyScannerTag ? nil : name
                )
            }
        )
    }

    private static let anyScannerTag = ""

    /// The attached scanners, plus a pin naming one that is not.
    ///
    /// A `Picker` whose selection matches no tag renders blank, which would
    /// show an empty box where the operator's own choice should be and leave
    /// them guessing what is set. A stale pin is still the setting; it is
    /// listed, and the warning below says it is not plugged in.
    private var offeredNames: [String] {
        var names = model.selectableScannerNames
        if let pinned = model.settings.preferredScannerName,
           !names.contains(pinned)
        {
            names.append(pinned)
        }
        return names
    }

    private var pinnedButMissing: String? {
        guard let pinned = model.settings.preferredScannerName,
              !model.selectableScannerNames.contains(pinned)
        else {
            return nil
        }
        return pinned
    }

    var body: some View {
        SettingsPage {
            SettingsSection(
                title: "Scanner",
                explanation: "ScanDeck takes whichever supported scanner is "
                    + "attached. Pin one only when more than one is connected "
                    + "at the same time — a pinned name that is not there "
                    + "fails the pass rather than falling back."
            ) {
                Picker("Use", selection: selection) {
                    Text("Any supported scanner")
                        .tag(Self.anyScannerTag)
                    ForEach(offeredNames, id: \.self) { name in
                        Text(name).tag(name)
                    }
                }
                .pickerStyle(.menu)

                if let pinned = pinnedButMissing {
                    // Saying so here is the difference between a puzzling
                    // failure at the feeder and a setting the operator can see
                    // is stale.
                    Label(
                        "“\(pinned)” is not attached right now. Passes will "
                            + "fail until it is back or this is set to any "
                            + "supported scanner.",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }

            SettingsSection(title: "Status") {
                LabeledContent("Now", value: model.scannerConnection.title)
                Text(
                    model.scannerConnection.correctiveAction
                        ?? model.scannerConnection.summary
                )
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - Numbering

private struct NumberingSettingsView: View {
    let model: ScanDeckPresentationModel

    var body: some View {
        SettingsPage {
            SettingsSection(
                title: "Sheet counter",
                explanation: "Six digits, kept per profile, and never derived "
                    + "from what is already in the destination folder. "
                    + "Completing a batch advances it past the highest number "
                    + "that batch used; cancelling one burns nothing."
            ) {
                ForEach(model.profiles) { profile in
                    CounterRow(model: model, profile: profile)
                }
            }
        }
    }
}

private struct CounterRow: View {
    let model: ScanDeckPresentationModel
    let profile: ScanProfileViewData

    @State private var draft = ""
    @FocusState private var isEditing: Bool

    private var current: UInt64 {
        model.nextSheetNumber(for: profile)
    }

    private var blockReason: String? {
        model.counterEditBlockReason(for: profile)
    }

    /// What the operator would get if they pressed Set right now, or why the
    /// value they typed is not a sheet number. Shown before the press, because
    /// the whole reason to seed a counter is to choose the next number
    /// deliberately.
    private var previewMessage: String {
        guard !draft.isEmpty else {
            return "Next card: \(SheetNumber.formatted(current))"
        }
        guard let value = UInt64(draft.trimmingCharacters(in: .whitespaces)),
              value >= JobCounterStore.firstSheetNumber
        else {
            return "Enter a whole number of "
                + "\(JobCounterStore.firstSheetNumber) or more."
        }
        return "Next card becomes \(SheetNumber.formatted(value))"
    }

    private var canSet: Bool {
        guard blockReason == nil,
              let value = UInt64(draft.trimmingCharacters(in: .whitespaces))
        else {
            return false
        }
        return value >= JobCounterStore.firstSheetNumber && value != current
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 10) {
                Text(profile.name)
                Spacer(minLength: 12)
                TextField(
                    SheetNumber.formatted(current),
                    text: $draft
                )
                .frame(width: 110)
                .monospacedDigit()
                .multilineTextAlignment(.trailing)
                .focused($isEditing)
                .disabled(blockReason != nil)
                .onSubmit(set)
                .accessibilityLabel("Next sheet number for \(profile.name)")

                Button("Set", action: set)
                    .disabled(!canSet)
            }

            Text(previewMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()

            if let blockReason {
                // Not a disabled control with its reason in a tooltip: the
                // counter is locked for a reason the operator can act on, and
                // acting on it means finishing the batch.
                Label(blockReason, systemImage: "lock.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 4)
    }

    private func set() {
        guard canSet,
              let value = UInt64(draft.trimmingCharacters(in: .whitespaces))
        else {
            return
        }
        model.seedSheetNumber(value, for: profile)
        draft = ""
        isEditing = false
    }
}

// MARK: - Files

private struct FilesSettingsView: View {
    let model: ScanDeckPresentationModel
    @State private var isConfirmingRemoval = false

    var body: some View {
        // Read once and passed down. `sessionStorage` is a recursive directory
        // walk, not a stored value, so a body that touched it eight times would
        // enumerate the operator's session folder eight times per redraw.
        page(storage: model.sessionStorage)
    }

    @ViewBuilder
    private func page(storage: SessionStorageInventory) -> some View {
        SettingsPage {
            SettingsSection(
                title: "Destination",
                explanation: "Batches publish into a new folder here. ScanDeck "
                    + "resolves it at pick time and never assumes a path, so a "
                    + "renamed or unmounted folder is a question rather than a "
                    + "failed publish."
            ) {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.batchDraft.destinationDisplayName)
                        if let url = model.batchDraft.destinationURL {
                            Text(url.path)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                                .truncationMode(.middle)
                        }
                    }
                    Spacer(minLength: 8)
                    Button("Choose…") {
                        model.chooseDestination()
                    }
                    Button("Forget") {
                        model.forgetDestination()
                    }
                    .disabled(model.batchDraft.destinationURL == nil)
                }
            }

            SettingsSection(
                title: "Working files",
                explanation: "Captured pages stay on disk until their batch "
                    + "publishes and its counter commits. ScanDeck never "
                    + "deletes them on a schedule — an unfinished batch is "
                    + "offered back at the next launch, and discarding one is "
                    + "a decision you make there."
            ) {
                LabeledContent("Unfinished batches") {
                    Text(
                        storage.resumableBatchCount == 0
                            ? "None"
                            : "\(storage.resumableBatchCount) "
                                + "(\(storage.resumableCardCount) cards)"
                    )
                }
                LabeledContent("Total size") {
                    Text(
                        ByteCountFormatter.string(
                            fromByteCount: storage.totalByteCount,
                            countStyle: .file
                        )
                    )
                }
                if storage.unreadableDirectoryCount > 0 {
                    LabeledContent("Unreadable records") {
                        Text("\(storage.unreadableDirectoryCount)")
                    }
                }
                if storage.publishedRecordCount > 0 {
                    LabeledContent("Awaiting release journal") {
                        Text("\(storage.publishedRecordCount)")
                    }
                }

                HStack(spacing: 10) {
                    Button("Reveal in Finder") {
                        model.revealSessionStorageInFinder()
                    }
                    if !storage.directoriesWithoutRecord.isEmpty {
                        Button("Remove Unrestorable Files…") {
                            isConfirmingRemoval = true
                        }
                    }
                    Spacer(minLength: 0)
                }

                if !storage.directoriesWithoutRecord.isEmpty {
                    Label(
                        "\(storage.directoriesWithoutRecord.count) "
                            + "\(storage.directoriesWithoutRecord.count == 1 ? "directory holds" : "directories hold") "
                            + "images whose batch record was never written, so "
                            + "ScanDeck cannot restore them as cards. They are "
                            + "still scans — open them in Finder before "
                            + "removing anything you want.",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .confirmationDialog(
            "Delete images ScanDeck cannot restore?",
            isPresented: $isConfirmingRemoval
        ) {
            Button("Delete", role: .destructive) {
                model.removeUnrecoverableWorkingFiles()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "\(storage.directoriesWithoutRecord.count) "
                    + "\(storage.directoriesWithoutRecord.count == 1 ? "directory" : "directories") "
                    + "of captured images will be deleted permanently. They "
                    + "have no batch record, so ScanDeck can never turn them "
                    + "back into cards — but the images themselves are real."
            )
        }
    }
}

// MARK: - Diagnostics

private struct DiagnosticsSettingsView: View {
    let model: ScanDeckPresentationModel
    @State private var report = ""
    @State private var saveFailure: String?

    var body: some View {
        SettingsPage {
            SettingsSection(
                title: "Support report",
                explanation: "Versions, the scanner's own identity and whether "
                    + "ScanDeck can drive it, counter positions, and how much "
                    + "is on disk. No images, file names, folder paths, or "
                    + "batch names — read it before you send it, and it will "
                    + "say the same thing."
            ) {
                ScrollView {
                    Text(report)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                }
                .frame(height: 190)
                .background(
                    .background.secondary,
                    in: RoundedRectangle(cornerRadius: 10)
                )

                HStack(spacing: 10) {
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(report, forType: .string)
                    }
                    Button("Save…", action: save)
                    Button("Refresh") {
                        report = model.diagnosticsText()
                    }
                    Spacer(minLength: 0)
                }

                if let saveFailure {
                    // A save that quietly does nothing is worse than one that
                    // fails: the operator walks away believing the file is
                    // there. Reported here, beside the button that was pressed.
                    Label(saveFailure, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .onAppear {
            report = model.diagnosticsText()
        }
    }

    private func save() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "scandeck-diagnostics.txt"
        panel.allowedContentTypes = [.plainText]
        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }
        do {
            try report.write(to: url, atomically: true, encoding: .utf8)
            saveFailure = nil
        } catch {
            saveFailure = "The report was not saved: "
                + "\(error.localizedDescription) It is still on screen, and "
                + "Copy puts it on the clipboard."
        }
    }
}

// MARK: - Layout

private struct SettingsPage<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(22)
        }
    }
}

private struct SettingsSection<Content: View>: View {
    let title: String
    var explanation: String?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title)
                .font(.headline)
            if let explanation {
                Text(explanation)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 9) {
                content
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                .background.secondary,
                in: RoundedRectangle(cornerRadius: 12)
            )
        }
    }
}
