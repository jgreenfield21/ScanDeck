import ScanDeckCore
import SwiftUI

struct ScanDeckRootView: View {
    @Bindable var model: ScanDeckPresentationModel

    var body: some View {
        NavigationSplitView {
            ScanDeckSidebar(model: model)
        } detail: {
            workspace
                .background {
                    LinearGradient(
                        colors: [
                            Color.accentColor.opacity(0.055),
                            Color.clear,
                        ],
                        startPoint: .topLeading,
                        endPoint: .center
                    )
                    .ignoresSafeArea()
                }
        }
        .navigationSplitViewStyle(.balanced)
        .toolbar {
            ScanDeckToolbar(model: model)
        }
        .inspector(isPresented: $model.isInspectorPresented) {
            ScanDeckInspector(model: model)
                .inspectorColumnWidth(min: 250, ideal: 286, max: 340)
        }
        .sheet(isPresented: $model.isBatchSetupPresented) {
            BatchSetupView(model: model)
        }
        .sheet(isPresented: $model.isRecoveryPresented) {
            BatchRecoveryView(model: model)
        }
        // Hosted once, at the root, so every route to Cancel Batch passes
        // through the same confirmation. A deletion of captured pages should
        // not have two copies of its warning to keep in step.
        .confirmationDialog(
            "Cancel this batch and delete its cards?",
            isPresented: $model.isCancelBatchConfirmationPresented
        ) {
            Button("Cancel Batch", role: .destructive) {
                model.cancelActiveBatch()
            }
            Button("Keep Scanning", role: .cancel) {}
        } message: {
            Text(model.cancelBatchConfirmationMessage)
        }
        // Hosted beside Cancel Batch's so there is one copy of the warning, but
        // reached only from the notice banner's Delete Card. The row's context
        // menu, the inspector button and the ⌘-menu command all delete without
        // asking, and that asymmetry is the point: those three act on a card
        // the operator is looking at, while the banner's acts on one that may
        // be a hundred rows away and off screen — which is the whole reason
        // TICKET-032 exists. See `requestNoticeCardDeletion`.
        .confirmationDialog(
            "Delete this card?",
            isPresented: Binding(
                get: { model.cardPendingDeletionConfirmation != nil },
                set: { presented in
                    if !presented {
                        model.cardPendingDeletionConfirmation = nil
                    }
                }
            )
        ) {
            Button("Delete Card", role: .destructive) {
                model.confirmCardDeletion()
            }
            Button("Keep Card", role: .cancel) {}
        } message: {
            Text(model.deleteCardConfirmationMessage)
        }
        // The only control in ScanDeck that clears a completion blocker by
        // decision rather than by fixing the card (TICKET-037), so it is hosted
        // here with the other two irreversible ones and its message states the
        // cost rather than asking "are you sure?".
        .confirmationDialog(
            model.sizeAcceptanceConfirmationTitle,
            isPresented: Binding(
                get: { model.cardPendingSizeAcceptanceConfirmation != nil },
                set: { presented in
                    if !presented {
                        model.cancelSizeAcceptance()
                    }
                }
            )
        ) {
            Button(model.sizeAcceptanceConfirmationActionTitle) {
                model.confirmSizeAcceptance()
            }
            if model.otherBlockingPairMismatchCount > 0 {
                Button(
                    "Publish All \(model.blockingPairMismatchCardIDs.count) Anyway"
                ) {
                    model.confirmSizeAcceptanceForAllBlockedCards()
                }
            }
            Button("Keep It Blocked", role: .cancel) {
                model.cancelSizeAcceptance()
            }
        } message: {
            Text(model.sizeAcceptanceConfirmationMessage)
        }
        // Hosted here rather than on the completion screen, because a batch
        // published in an earlier session can be checked too and the egress
        // confirmation D-12 requires must be one copy, not one per screen that
        // can start a run. When it lived on the completion view, pressing Check
        // Centering on a previous batch armed a consent with no alert to
        // present it.
        .alert(
            model.centeringCheckConsent?.title ?? "Check Centering?",
            isPresented: Binding(
                get: { model.centeringCheckConsent != nil },
                set: { presented in
                    if !presented {
                        model.cancelCenteringCheckConsent()
                    }
                }
            )
        ) {
            if let consent = model.centeringCheckConsent {
                Button(consent.actionTitle) {
                    model.confirmCompletedBatchCentering()
                }
            }
            Button("Cancel", role: .cancel) {
                model.cancelCenteringCheckConsent()
            }
        } message: {
            Text(model.centeringCheckConsentMessage)
        }
    }

    @ViewBuilder
    private var workspace: some View {
        switch model.sidebarSelection {
        case .activeBatch:
            if model.activeBatch != nil {
                BatchWorkspaceView(model: model)
            } else {
                ProfileLibraryView(model: model)
            }
        case .completedBatch:
            if let summary = model.completionSummary {
                BatchCompletionView(model: model, summary: summary)
            } else if model.activeBatch != nil {
                BatchWorkspaceView(model: model)
            } else {
                ProfileLibraryView(model: model)
            }
        case let .publishedBatch(batchID):
            if let record = model.publishedBatch(batchID) {
                PublishedBatchView(model: model, record: record)
            } else {
                ProfileLibraryView(model: model)
            }
        case .profiles, .none:
            ProfileLibraryView(model: model)
        }
    }
}

/// Its own view because the sidebar's `body` stopped type-checking in
/// reasonable time once this was inlined into it — four sections of nested
/// `Label`/`VStack` is past what the solver will take in one expression.
private struct PreviousBatchesSection: View {
    let model: ScanDeckPresentationModel

    /// Card count and date, which is what tells two `samplebox` batches apart.
    private static func subtitle(for record: PublishedBatchRecord) -> String {
        let date = record.publishedAt.formatted(
            .dateTime.month(.abbreviated).day()
        )
        return "\(record.cardCount) cards · \(date)"
    }

    var body: some View {
        Section("Previous Batches") {
            // Explicit `id:` because SwiftUI's newer section- and
            // subview-shaped `ForEach` overloads make the Identifiable one
            // ambiguous inside a `Section`.
            ForEach(model.publishedBatches, id: \.id) { record in
                row(for: record)
            }
            // Always offered, and it is the only thing in the section on a
            // fresh install: the history starts empty, so without this the
            // operator's existing folders would never appear no matter how many
            // batches they had already published.
            Button {
                model.importExistingBatches()
            } label: {
                Label(
                    "Add Existing Batches…",
                    systemImage: "folder.badge.plus"
                )
                .font(.callout)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help(
                "Look in the remembered destination for batch folders that are "
                    + "not listed yet"
            )
        }
    }

    private func row(for record: PublishedBatchRecord) -> some View {
        let wasOverruled = !record.releasedWithAcceptedMismatches.isEmpty
        return Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(record.batchName.value)
                    .lineLimit(1)
                Text(Self.subtitle(for: record))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        } icon: {
            Image(
                systemName: wasOverruled
                    ? "exclamationmark.shield"
                    : "shippingbox"
            )
            .foregroundStyle(wasOverruled ? AnyShapeStyle(.orange)
                                          : AnyShapeStyle(.secondary))
        }
        .tag(ScanDeckSidebarItem.publishedBatch(record.id))
        .contextMenu {
            Button("Show in Finder") {
                model.showPublishedBatchInFinder(record)
            }
            Button("Check Centering…") {
                model.requestCentering(for: record)
            }
            Divider()
            Button("Remove from This List", role: .destructive) {
                model.forgetPublishedBatch(record)
            }
        }
    }
}

private struct ScanDeckSidebar: View {
    @Bindable var model: ScanDeckPresentationModel

    var body: some View {
        List(selection: $model.sidebarSelection) {
            Section("ScanDeck") {
                Label("Profiles", systemImage: "square.grid.2x2")
                    .tag(ScanDeckSidebarItem.profiles)
            }

            if let batch = model.activeBatch, batch.phase != .completed {
                Section("Current Batch") {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(batch.name)
                                .lineLimit(1)
                            Text(batch.cards.isEmpty
                                 ? "Ready to scan"
                                 : "\(batch.cards.count) cards")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "rectangle.stack")
                    }
                    .tag(ScanDeckSidebarItem.activeBatch)
                }
            }

            if let summary = model.completionSummary {
                Section("Completed") {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(summary.batchName)
                                .lineLimit(1)
                            Text("\(summary.cardCount) cards")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "checkmark.circle")
                            .foregroundStyle(.green)
                    }
                    .tag(ScanDeckSidebarItem.completedBatch)
                }
            }

            // The list the operator asked for. Read from the persisted history,
            // so it survives a relaunch — which is the whole point: before this,
            // the app could not name a single batch it had produced once the
            // window moved on, and Check Centering was unreachable with it.
            PreviousBatchesSection(model: model)
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 210, ideal: 242, max: 280)
        .safeAreaInset(edge: .bottom) {
            ScannerSidebarStatus(connection: model.scannerConnection)
        }
    }
}

private struct ScannerSidebarStatus: View {
    let connection: ScannerConnection

    private var color: Color {
        switch connection {
        case .ready:
            .green
        case .searching:
            .secondary
        case .inUseElsewhere, .severalScanners, .pinnedScannerMissing:
            .orange
        case .disconnected, .unsupported:
            .red
        }
    }

    /// A shape as well as a colour, because colour alone is not a signal
    /// somebody with a colour vision deficiency can read — the same rule
    /// TICKET-010 will apply across the app.
    private var symbol: String {
        switch connection {
        case .ready:
            "checkmark.circle.fill"
        case .searching:
            "ellipsis.circle"
        case .inUseElsewhere, .severalScanners, .pinnedScannerMissing:
            "exclamationmark.triangle.fill"
        case .disconnected, .unsupported:
            "xmark.octagon.fill"
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(color)
                .font(.callout)

            VStack(alignment: .leading, spacing: 1) {
                Text(connection.title)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                Text(connection.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(.bar)
        .help(connection.correctiveAction ?? connection.summary)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Scanner: \(connection.title)")
        .accessibilityValue(connection.correctiveAction ?? connection.summary)
    }
}

private struct ScanDeckToolbar: ToolbarContent {
    let model: ScanDeckPresentationModel

    var body: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button {
                model.toggleInspector()
            } label: {
                Label("Inspector", systemImage: "sidebar.right")
            }
            .buttonStyle(.glass)
            .help(model.isInspectorPresented ? "Hide Inspector" : "Show Inspector")
            .accessibilityLabel(
                model.isInspectorPresented ? "Hide Inspector" : "Show Inspector"
            )
        }
    }
}

struct ProfileLibraryView: View {
    let model: ScanDeckPresentationModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Scan profiles")
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                    Text("Choose a workflow, name the batch, then load the feeder.")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }

                LazyVGrid(
                    columns: [
                        GridItem(.adaptive(minimum: 330, maximum: 440), spacing: 22),
                    ],
                    alignment: .leading,
                    spacing: 22
                ) {
                    ForEach(model.profiles) { profile in
                        ProfileTile(
                            profile: profile,
                            hasActiveBatch: model.activeBatch?.profile.id == profile.id
                                && model.activeBatch?.phase != .completed
                        ) {
                            model.selectProfile(profile)
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 10) {
                    Label("Production defaults", systemImage: "checkmark.seal")
                        .font(.headline)
                    Text(
                        "Duplex is always on. Blank-page skip, multifeed detection, "
                            + "and pre-pick stay off so every trading-card back is preserved."
                    )
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
                .padding(20)
                .frame(maxWidth: 680, alignment: .leading)
                .background(.background.secondary, in: RoundedRectangle(cornerRadius: 18))
            }
            .frame(maxWidth: 980, alignment: .leading)
            .padding(40)
        }
        .navigationTitle("Profiles")
    }
}

private struct ProfileTile: View {
    let profile: ScanProfileViewData
    let hasActiveBatch: Bool
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 22) {
                HStack(alignment: .top) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 17)
                            .fill(Color.accentColor.gradient)
                            .frame(width: 64, height: 64)
                        Image(systemName: profile.symbolName)
                            .font(.system(size: 28, weight: .semibold))
                            .foregroundStyle(.white)
                            .symbolRenderingMode(.hierarchical)
                    }

                    Spacer()

                    if hasActiveBatch {
                        Label("Active", systemImage: "clock.arrow.circlepath")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.orange)
                    }
                }

                VStack(alignment: .leading, spacing: 7) {
                    Text(profile.name)
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(profile.detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                        .lineLimit(2)
                }

                HStack(spacing: 8) {
                    ProfileFact(title: "\(profile.resolutionDPI) dpi", symbol: "scope")
                    ProfileFact(title: "Duplex", symbol: "square.2.layers.3d")
                    ProfileFact(
                        title: "\(profile.defaultMarginMillimeters.formatted()) mm",
                        symbol: "arrow.up.left.and.arrow.down.right"
                    )
                }

                HStack {
                    Text(hasActiveBatch ? "Resume Batch" : "Start Batch")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.primary)
                    Spacer()
                    Image(systemName: "arrow.right")
                        .fontWeight(.semibold)
                }
                .padding(.horizontal, 15)
                .frame(height: 40)
                .glassEffect(
                    .regular
                        .tint(Color.accentColor.opacity(0.16))
                        .interactive(),
                    in: Capsule()
                )
            }
            .padding(24)
            .frame(maxWidth: .infinity, minHeight: 300, alignment: .leading)
            .background(
                .background,
                in: RoundedRectangle(cornerRadius: 24, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .stroke(
                        isHovering ? Color.accentColor.opacity(0.7) : Color.primary.opacity(0.08),
                        lineWidth: isHovering ? 1.5 : 1
                    )
            }
            .shadow(
                color: Color.black.opacity(isHovering ? 0.14 : 0.07),
                radius: isHovering ? 20 : 10,
                y: isHovering ? 9 : 4
            )
            .scaleEffect(isHovering ? 1.008 : 1)
            .animation(.snappy(duration: 0.22), value: isHovering)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityLabel(profile.name)
        .accessibilityValue(
            "\(profile.resolutionDPI) dpi, duplex, "
                + "\(profile.defaultMarginMillimeters.formatted()) millimeter margins"
        )
        .accessibilityHint(hasActiveBatch ? "Resumes the active batch" : "Opens batch setup")
    }
}

private struct ProfileFact: View {
    let title: String
    let symbol: String

    var body: some View {
        Label(title, systemImage: symbol)
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.quaternary, in: Capsule())
    }
}

/// Why Create Batch is unavailable, and what to do about it.
///
/// Its own view because `BatchSetupView.body` is already at the edge of what
/// the SwiftUI type-checker will solve in reasonable time — inlining these
/// eight lines tipped it over.
private struct BatchSetupBlockReason: View {
    @Bindable var model: ScanDeckPresentationModel

    var body: some View {
        if let reason = model.batchSetupBlockReason {
            Label(reason, systemImage: "exclamationmark.circle")
                .font(.caption)
                .foregroundStyle(.orange)

            // `SPEC.md` §4 beat 2 asks a name collision to offer a different
            // name *or* Show in Finder. Renaming is the field above; this is
            // the other half, and it matters because the first question about
            // a folder the operator does not remember creating is what is
            // inside it.
            if model.batchFolderConflict != nil {
                Button("Show the existing folder in Finder") {
                    model.showConflictingBatchFolderInFinder()
                }
                .buttonStyle(.link)
                .font(.caption)
            }
        }
    }
}

struct BatchSetupView: View {
    @Bindable var model: ScanDeckPresentationModel
    @FocusState private var nameIsFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 16) {
                ZStack {
                    RoundedRectangle(cornerRadius: 15)
                        .fill(Color.accentColor.gradient)
                        .frame(width: 54, height: 54)
                    Image(systemName: "rectangle.stack.badge.plus")
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(.white)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("New card batch")
                        .font(.title2.weight(.semibold))
                    Text("Cards 600 Full Border")
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(24)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    VStack(alignment: .leading, spacing: 9) {
                        Text("Batch name")
                            .font(.headline)
                        TextField("aug01-sale", text: $model.batchDraft.name)
                            .textFieldStyle(.roundedBorder)
                            .font(.title3)
                            .focused($nameIsFocused)
                            .onSubmit {
                                if model.canArmBatch {
                                    model.armBatch()
                                }
                            }
                            .accessibilityLabel("Batch name")

                        if let message = model.batchNameValidationMessage,
                           !model.batchDraft.name.isEmpty {
                            Label(message, systemImage: "exclamationmark.circle")
                                .font(.caption)
                                .foregroundStyle(.red)
                        } else {
                            Text("Creates a new folder in the destination when you complete the batch.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    VStack(alignment: .leading, spacing: 13) {
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Real-background margin")
                                    .font(.headline)
                                Text("Added outside the detected card edge")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Toggle("Link edges", isOn: linkedMargins)
                                .toggleStyle(.switch)
                                .controlSize(.small)
                        }

                        LazyVGrid(
                            columns: [
                                GridItem(.flexible()),
                                GridItem(.flexible()),
                            ],
                            spacing: 10
                        ) {
                            ForEach(ScanEdge.allCases, id: \.self) { edge in
                                MarginField(
                                    edge: edge,
                                    value: marginBinding(for: edge)
                                )
                            }
                        }
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        Text("Destination")
                            .font(.headline)
                        HStack(spacing: 12) {
                            Image(systemName: "folder.fill")
                                .foregroundStyle(
                                    model.batchDraft.destinationURL == nil
                                        ? AnyShapeStyle(.red)
                                        : AnyShapeStyle(.tint)
                                )
                                .font(.title3)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(model.batchDraft.destinationDisplayName)
                                    .foregroundStyle(
                                        model.batchDraft.destinationURL == nil
                                            ? .red
                                            : .primary
                                    )
                                if let destinationURL =
                                    model.batchDraft.destinationURL {
                                    Text(destinationURL.path)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                        .truncationMode(.middle)
                                        .help(destinationURL.path)
                                } else {
                                    Text("Required before this batch can be created.")
                                        .font(.caption)
                                        .foregroundStyle(.red)
                                }
                                Text(
                                    "A new batch folder is published here only when complete."
                                )
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Choose…") {
                                model.chooseDestination()
                            }
                            .buttonStyle(.glass)
                        }
                        .padding(14)
                        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14))
                        .overlay {
                            RoundedRectangle(cornerRadius: 14)
                                .stroke(
                                    model.batchDraft.destinationURL == nil
                                        ? Color.red.opacity(0.65)
                                        : Color.clear
                                )
                        }
                    }

                    if let profile = model.profiles.first {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Numbering")
                                .font(.headline)
                            HStack(spacing: 12) {
                                Image(systemName: "number")
                                    .foregroundStyle(.tint)
                                    .font(.title3)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(
                                        "First card "
                                            + SheetNumber.formatted(
                                                model.nextSheetNumber(for: profile)
                                            )
                                    )
                                    .monospacedDigit()
                                    Text(
                                        "Continues this profile's counter. "
                                            + "Completing the batch advances it; "
                                            + "cancelling burns no numbers."
                                    )
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(14)
                            .background(
                                .background.secondary,
                                in: RoundedRectangle(cornerRadius: 14)
                            )
                            .accessibilityElement(children: .combine)
                        }
                    }
                }
                .padding(24)
            }

            Divider()

            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("One active unreleased batch per profile")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    BatchSetupBlockReason(model: model)
                }

                Spacer()

                GlassEffectContainer(spacing: 10) {
                    HStack(spacing: 10) {
                        Button("Cancel") {
                            model.dismissBatchSetup()
                        }
                        .buttonStyle(.glass)
                        .keyboardShortcut(.cancelAction)

                        Button("Create Batch") {
                            model.armBatch()
                        }
                        .buttonStyle(.glassProminent)
                        .keyboardShortcut(.defaultAction)
                        .disabled(!model.canArmBatch)
                    }
                }
            }
            .padding(18)
            .background(.bar)
        }
        .frame(width: 610, height: 760)
        .onAppear {
            nameIsFocused = true
            model.refreshBatchFolderAvailability()
        }
        // Driven from here rather than computed inside `batchSetupBlockReason`,
        // because answering costs a `stat` against what is usually a Google
        // Drive mount and that getter is read on every keystroke of this body.
        .onChange(of: model.batchDraft.name) {
            model.refreshBatchFolderAvailability()
        }
        .onChange(of: model.batchDraft.destinationURL) {
            model.refreshBatchFolderAvailability()
        }
    }

    private var linkedMargins: Binding<Bool> {
        Binding(
            get: { model.batchDraft.margins.linked },
            set: { linked in
                model.batchDraft.margins.linked = linked
                if linked {
                    model.batchDraft.margins.right = model.batchDraft.margins.top
                    model.batchDraft.margins.bottom = model.batchDraft.margins.top
                    model.batchDraft.margins.left = model.batchDraft.margins.top
                }
            }
        )
    }

    private func marginBinding(for edge: ScanEdge) -> Binding<Double> {
        Binding(
            get: { model.batchDraft.margins[edge] },
            set: { model.batchDraft.margins[edge] = min(max($0, 0), 25) }
        )
    }
}

private struct MarginField: View {
    let edge: ScanEdge
    @Binding var value: Double

    var body: some View {
        HStack {
            Text(edge.title)
                .foregroundStyle(.secondary)
            Spacer()
            TextField(
                "Margin",
                value: $value,
                format: .number.precision(.fractionLength(0...1))
            )
            .multilineTextAlignment(.trailing)
            .frame(width: 62)
            .accessibilityLabel("\(edge.title) margin in millimeters")
            Text("mm")
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12)
        .frame(height: 38)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
    }
}

struct BatchCompletionView: View {
    let model: ScanDeckPresentationModel
    let summary: BatchCompletionSummary

    @ViewBuilder
    private var releasedWithWarnings: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Two paragraphs rather than one list, because the two facts are
            // not the same size. TICKET-033 releases the first group on its own
            // authority; the second group is where ScanDeck refused and a person
            // overruled it (TICKET-037), and that never gets folded into a
            // gentler sentence written for the first.
            if !summary.releasedWithAcceptedMismatches.isEmpty {
                let numbers = summary.releasedWithAcceptedMismatches
                    .map(SheetNumber.formatted)
                    .joined(separator: ", ")
                let count = summary.releasedWithAcceptedMismatches.count
                VStack(alignment: .leading, spacing: 6) {
                    Label(
                        count == 1
                            ? "1 card was published anyway, over a refusal"
                            : "\(count) cards were published anyway, over a "
                                + "refusal",
                        systemImage: "exclamationmark.shield.fill"
                    )
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.orange)

                    Text(
                        "Their two sides disagreed widely enough for ScanDeck "
                            + "to hold the batch, and you accepted them. One "
                            + "border on each is not the real one, so a "
                            + "centering result for these cards is measuring a "
                            + "crop the app could not verify: \(numbers)."
                    )
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                }
            }

            if !summary.releasedWithWarningsOnly.isEmpty {
                let numbers = summary.releasedWithWarningsOnly
                    .map(SheetNumber.formatted)
                    .joined(separator: ", ")
                let count = summary.releasedWithWarningsOnly.count
                VStack(alignment: .leading, spacing: 6) {
                    Label(
                        count == 1
                            ? "1 card was published with sides that differ"
                            : "\(count) cards were published with sides that "
                                + "differ",
                        systemImage: "ruler"
                    )
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.yellow)

                    Text(
                        "Their front and back measured different item sizes, so "
                            + "one side's crop of each is wrong — close enough "
                            + "to publish, not close enough to be silent about. "
                            + "Rescan them if the border matters: \(numbers)."
                    )
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: 680, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14))
        .accessibilityElement(children: .combine)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                ZStack {
                    Circle()
                        .fill(Color.green.opacity(0.14))
                        .frame(width: 118, height: 118)
                    Circle()
                        .fill(Color.green.gradient)
                        .frame(width: 82, height: 82)
                    Image(systemName: "checkmark")
                        .font(.system(size: 38, weight: .bold))
                        .foregroundStyle(.white)
                }
                .accessibilityHidden(true)

                VStack(spacing: 8) {
                    Text("Batch complete")
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                    Text(summary.batchName)
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 0) {
                    CompletionMetric(
                        value: "\(summary.cardCount)",
                        label: summary.cardCount == 1 ? "Card" : "Cards"
                    )
                    Divider()
                        .frame(height: 48)
                    CompletionMetric(
                        value: formattedRange(summary.counterRange),
                        label: "Counter range"
                    )
                    Divider()
                        .frame(height: 48)
                    CompletionMetric(
                        value: summary.completedAt.formatted(date: .omitted, time: .shortened),
                        label: "Completed"
                    )
                }
                .padding(.vertical, 20)
                .frame(maxWidth: 680)
                .background(.background, in: RoundedRectangle(cornerRadius: 20))
                .overlay {
                    RoundedRectangle(cornerRadius: 20)
                        .stroke(Color.primary.opacity(0.08))
                }

                Label(summary.destinationDisplayName, systemImage: "folder.fill")
                    .foregroundStyle(.secondary)

                // The batch was released over an objection the app raised and
                // the operator chose not to act on. It says so here rather
                // than only on the review screen that is now gone, because
                // this is the page that is still open when they go looking for
                // the folder.
                if !summary.releasedWithSizeWarnings.isEmpty {
                    releasedWithWarnings
                }

                if let status = model.centeringCheckStatus {
                    centeringStatus(status)
                }

                GlassEffectContainer(spacing: 12) {
                    HStack(spacing: 12) {
                        Button {
                            model.showCompletedBatchInFinder()
                        } label: {
                            Label("Show in Finder", systemImage: "folder")
                        }
                        .buttonStyle(.glass)

                        Button {
                            model.requestCompletedBatchCentering()
                        } label: {
                            Label("Check Centering", systemImage: "scope")
                        }
                        .buttonStyle(.glass)
                        .disabled(model.isCenteringCheckRunning)

                        Button {
                            model.startNewBatchFromCompletion()
                        } label: {
                            Label("New Batch", systemImage: "plus")
                        }
                        .buttonStyle(.glassProminent)
                    }
                }
            }
            .frame(maxWidth: 800)
            .padding(52)
        }
        .navigationTitle("Completed Batch")
    }

    @ViewBuilder
    private func centeringStatus(_ status: CenteringCheckStatus) -> some View {
        CenteringStatusPanel(model: model, status: status)
    }

    private func formattedRange(_ range: ClosedRange<UInt64>?) -> String {
        guard let range else {
            return "—"
        }
        return SheetNumber.formatted(range.lowerBound)
            + "–"
            + SheetNumber.formatted(range.upperBound)
    }
}

/// The centering panel, shared by the completion screen and any previous batch.
///
/// One copy because there is one run at a time: the model holds a single
/// `centeringCheckStatus`, and two panels rendering it from two screens is a
/// feature, not a duplication — whichever screen the operator is on shows the
/// run they started.
private struct CenteringStatusPanel: View {
    let model: ScanDeckPresentationModel
    let status: CenteringCheckStatus

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch status {
            case let .running(progress):
                Label("Checking centering", systemImage: "arrow.up.circle")
                    .font(.callout.weight(.semibold))
                ProgressView(
                    value: Double(progress.completedImages),
                    total: Double(max(progress.imageCount, 1))
                )
                Text(progress.operatorDescription)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            case let .completed(receipt):
                Label(
                    "Centering overlays organized",
                    systemImage: "checkmark.circle.fill"
                )
                .font(.callout.weight(.semibold))
                .foregroundStyle(.green)
                Text(
                    "\(receipt.imageCount) images checked — "
                        + "\(receipt.uploadedImages) uploaded, "
                        + "\(receipt.cachedImages) reused from cache."
                )
                .font(.callout)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                Button("Show Centering Results") {
                    model.showCenteringResultsInFinder()
                }
                .buttonStyle(.link)
            case let .failed(message):
                Label(
                    "Centering check needs attention",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.callout.weight(.semibold))
                .foregroundStyle(.orange)
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .frame(maxWidth: 680, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14))
    }
}

/// A batch published earlier, opened from the sidebar.
///
/// Its job is to make two things reachable that were previously only reachable
/// in the seconds after a batch published: the folder, and Check Centering. It
/// deliberately shows no card rows — the masters are gone by now and the
/// published JPEGs belong to `carduploader`, so a thumbnail grid here would be
/// a second reader of files this app no longer owns.
struct PublishedBatchView: View {
    let model: ScanDeckPresentationModel
    let record: PublishedBatchRecord

    private var folderExists: Bool {
        record.resolveDestinationURL() != nil
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(record.batchName.value)
                        .font(.largeTitle.weight(.semibold))
                        .textSelection(.enabled)
                    Text(
                        record.publishedAt.formatted(
                            date: .abbreviated,
                            time: .shortened
                        )
                    )
                    .font(.callout)
                    .foregroundStyle(.secondary)
                }

                HStack(alignment: .top, spacing: 34) {
                    CompletionMetric(
                        value: "\(record.cardCount)",
                        label: "Cards"
                    )
                    CompletionMetric(
                        value: formattedRange,
                        label: "Sheet numbers"
                    )
                    CompletionMetric(
                        value: record.destinationDisplayName,
                        label: "Destination"
                    )
                }

                if !record.releasedWithAcceptedMismatches.isEmpty {
                    warningPanel(
                        systemImage: "exclamationmark.shield.fill",
                        tint: .orange,
                        title: record.releasedWithAcceptedMismatches.count == 1
                            ? "1 card was published anyway, over a refusal"
                            : "\(record.releasedWithAcceptedMismatches.count) "
                                + "cards were published anyway, over a refusal",
                        message: "Their two sides disagreed widely enough for "
                            + "ScanDeck to hold the batch, and they were "
                            + "accepted. One border on each is not the real "
                            + "one: "
                            + record.releasedWithAcceptedMismatches
                            .map(SheetNumber.formatted)
                            .joined(separator: ", ")
                            + "."
                    )
                }

                if !warnedOnly.isEmpty {
                    warningPanel(
                        systemImage: "ruler",
                        tint: .yellow,
                        title: warnedOnly.count == 1
                            ? "1 card was published with sides that differ"
                            : "\(warnedOnly.count) cards were published with "
                                + "sides that differ",
                        message: "One side's crop of each is wrong — close "
                            + "enough to publish, not close enough to be "
                            + "silent about: "
                            + warnedOnly
                            .map(SheetNumber.formatted)
                            .joined(separator: ", ")
                            + "."
                    )
                }

                if !folderExists {
                    warningPanel(
                        systemImage: "questionmark.folder",
                        tint: .orange,
                        title: "This batch's folder cannot be found",
                        message: "It may have been moved, renamed, or be on a "
                            + "volume that is not mounted. The published images "
                            + "are not gone — ScanDeck simply cannot reach them "
                            + "from here, so Show in Finder and Check Centering "
                            + "are unavailable."
                    )
                }

                if record.artworkSide == nil {
                    orientationPrompt
                }

                if let status = model.centeringCheckStatus,
                   model.centeringTargetBatchName == record.batchName.value
                {
                    CenteringStatusPanel(model: model, status: status)
                }

                GlassEffectContainer(spacing: 12) {
                    HStack(spacing: 12) {
                        Button {
                            model.showPublishedBatchInFinder(record)
                        } label: {
                            Label(
                                "Show in Finder",
                                systemImage: "folder"
                            )
                        }
                        .buttonStyle(.glass)
                        .disabled(!folderExists)

                        Button {
                            model.requestCentering(for: record)
                        } label: {
                            Label(
                                model.hasCenteringResults(for: record)
                                    ? "Check Centering Again"
                                    : "Check Centering",
                                systemImage: "scope"
                            )
                        }
                        .buttonStyle(.glass)
                        .disabled(
                            !folderExists
                                || model.isCenteringCheckRunning
                                || !record.canCheckCentering
                        )
                    }
                }

                Spacer(minLength: 0)
            }
            .frame(maxWidth: 760, alignment: .leading)
            .padding(52)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle(record.batchName.value)
    }

    /// The question that has to be answered before an imported folder can be
    /// graded, and the reason it cannot be answered by the app.
    ///
    /// Two buttons rather than a toggle with a default, because there is no safe
    /// default: ScanDeck's own batches have the artwork in `_F` and the
    /// operator's older ones have the card back there, and the penalty for
    /// assuming is a ruinous card reported as flawless.
    private var orientationPrompt: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(
                "Which side is the artwork?",
                systemImage: "questionmark.square.dashed"
            )
            .font(.callout.weight(.semibold))

            Text(
                "This folder was found on disk, so ScanDeck does not know "
                    + "whether the files ending _F hold the card's artwork or "
                    + "its back. Front and back centering are graded five times "
                    + "apart — PSA allows 55/45 on a front and 75/25 on a back "
                    + "— so answering wrong would score every front against "
                    + "back limits and report bad cards as perfect. Open one "
                    + "_F file and look."
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                Button("_F is the artwork") {
                    model.declareArtworkSide(.frontSuffix, for: record)
                }
                .buttonStyle(.glass)
                Button("_F is the card back") {
                    model.declareArtworkSide(.backSuffix, for: record)
                }
                .buttonStyle(.glass)
            }
        }
        .padding(16)
        .frame(maxWidth: 680, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14))
    }

    private var warnedOnly: [UInt64] {
        let accepted = Set(record.releasedWithAcceptedMismatches)
        return record.releasedWithSizeWarnings.filter { !accepted.contains($0) }
    }

    private var formattedRange: String {
        guard let first = record.firstSheetNumber,
              let last = record.lastSheetNumber
        else {
            return "—"
        }
        return SheetNumber.formatted(first) + "–" + SheetNumber.formatted(last)
    }

    private func warningPanel(
        systemImage: String,
        tint: Color,
        title: String,
        message: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: systemImage)
                .font(.callout.weight(.semibold))
                .foregroundStyle(tint)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .padding(16)
        .frame(maxWidth: 680, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14))
        .accessibilityElement(children: .combine)
    }
}

private struct CompletionMetric: View {
    let value: String
    let label: String

    var body: some View {
        VStack(spacing: 5) {
            Text(value)
                .font(.title3.weight(.semibold))
                .monospacedDigit()
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }
}

private struct ScanDeckInspector: View {
    let model: ScanDeckPresentationModel

    var body: some View {
        Group {
            if let card = model.selectedCard {
                CardInspector(model: model, card: card)
            } else if let batch = model.activeBatch {
                BatchInspector(model: model, batch: batch)
            } else {
                ProfileInspector(profile: model.profiles.first)
            }
        }
        .padding(18)
    }
}

private struct CardInspector: View {
    let model: ScanDeckPresentationModel
    let card: CardPairViewData

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Card \(SheetNumber.formatted(card.sheetNumber))")
                    .font(.title3.weight(.semibold))
                Label(
                    card.isIncomplete ? "Incomplete" : "Front and back",
                    systemImage: card.isIncomplete
                        ? "exclamationmark.triangle.fill"
                        : "checkmark.circle.fill"
                )
                .font(.caption)
                .foregroundStyle(card.isIncomplete ? .orange : .green)
            }

            Divider()

            VStack(alignment: .leading, spacing: 12) {
                InspectorRow(title: "Front", side: card.front)
                InspectorRow(title: "Back", side: card.back)
            }

            Divider()

            VStack(spacing: 9) {
                if card.isIncomplete {
                    Button {
                        model.retryCard(card.id)
                    } label: {
                        Label("Retry Card", systemImage: "arrow.clockwise")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glassProminent)
                } else {
                    Button {
                        model.replaceCard(card.id)
                    } label: {
                        Label("Replace Card…", systemImage: "arrow.triangle.2.circlepath")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glass)
                }

                Button(role: .destructive) {
                    model.deleteCard(card.id)
                } label: {
                    Label("Delete Card", systemImage: "trash")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glass)
            }

            Spacer()
        }
    }
}

private struct InspectorRow: View {
    let title: String
    let side: ScanSideViewData?

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            if let side {
                if side.marginAssessment.requiresAttention {
                    Image(systemName: "exclamationmark.circle.fill")
                        .foregroundStyle(.orange)
                } else {
                    Text("\(Int(side.rotation.degrees))°")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("Missing")
                    .foregroundStyle(.orange)
            }
        }
        .font(.callout)
    }
}

private struct BatchInspector: View {
    let model: ScanDeckPresentationModel
    let batch: ActiveBatchViewData

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Batch details")
                    .font(.title3.weight(.semibold))
                Text(batch.name)
                    .foregroundStyle(.secondary)
            }

            Divider()

            VStack(spacing: 12) {
                LabeledContent("Profile", value: batch.profile.name)
                LabeledContent("Cards", value: "\(batch.cards.count)")
                LabeledContent("Complete", value: "\(batch.completedCardCount)")
                LabeledContent("Margins", value: batch.margins.summary)
                LabeledContent("Next number") {
                    Text(SheetNumber.formatted(batch.nextSheetNumber))
                        .monospacedDigit()
                }
            }
            .font(.callout)

            Divider()

            Label(batch.destinationDisplayName, systemImage: "folder")
                .font(.callout)
                .foregroundStyle(.secondary)

            Spacer()

            // The way out of a batch that should never have been started — the
            // wrong holder, the wrong stack. Without it the only escape is
            // quitting the app and discarding from the recovery sheet at the
            // next launch, which is not a control, it is a trick.
            Button(role: .destructive) {
                model.isCancelBatchConfirmationPresented = true
            } label: {
                Label("Cancel Batch…", systemImage: "trash")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glass)
            .disabled(!model.canCancelBatch)
            .help(
                model.canCancelBatch
                    ? "Deletes this batch and its cards. No sheet numbers are used."
                    : "Wait for the current pass to finish."
            )
        }
    }
}

private struct ProfileInspector: View {
    let profile: ScanProfileViewData?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Profile details")
                .font(.title3.weight(.semibold))
            if let profile {
                LabeledContent("Resolution", value: "\(profile.resolutionDPI) dpi")
                LabeledContent("Sides", value: "Duplex")
                LabeledContent(
                    "Default margin",
                    value: "\(profile.defaultMarginMillimeters.formatted()) mm"
                )
                LabeledContent("Color", value: "24-bit RGB")
                LabeledContent("Encoding", value: "JPEG q95")
            }
            Spacer()
        }
        .font(.callout)
    }
}
