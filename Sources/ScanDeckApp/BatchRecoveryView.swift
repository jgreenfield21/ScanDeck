import ScanDeckCore
import SwiftUI

/// What the operator sees when ScanDeck restarts holding work it never finished.
///
/// Two rules shape it. Every batch is described concretely — name, card count,
/// numbers — because "some work was recovered" asks the operator to gamble on
/// Discard. And Resume is the only single-click action: discarding is the one
/// path in ScanDeck that destroys acknowledged pages, so it is confirmed
/// separately, per the alert policy that reserves that ceremony for intentional
/// irreversible loss.
struct BatchRecoveryView: View {
    @Bindable var model: ScanDeckPresentationModel

    @State private var batchPendingDiscard: RecoveredBatchViewData?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            ScrollView {
                VStack(spacing: 12) {
                    ForEach(model.recoveredBatches) { batch in
                        row(for: batch)
                    }
                }
                .padding(24)
            }

            Divider()
            footer
        }
        .frame(width: 560)
        .frame(minHeight: 300, maxHeight: 560)
        .confirmationDialog(
            batchPendingDiscard.map {
                "Discard \($0.batchName) and its \($0.cardCount) "
                    + "card\($0.cardCount == 1 ? "" : "s")?"
            } ?? "",
            isPresented: .init(
                get: { batchPendingDiscard != nil },
                set: { if !$0 { batchPendingDiscard = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Discard Batch", role: .destructive) {
                if let batch = batchPendingDiscard {
                    model.discardRecoveredBatch(batch.id)
                }
                batchPendingDiscard = nil
            }
            Button("Keep Batch", role: .cancel) {
                batchPendingDiscard = nil
            }
        } message: {
            Text(
                "The scanned images are deleted and cannot be recovered. "
                    + "Nothing has been written to the destination folder."
            )
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            ZStack {
                RoundedRectangle(cornerRadius: 15)
                    .fill(Color.accentColor.gradient)
                    .frame(width: 54, height: 54)
                Image(systemName: "clock.arrow.circlepath")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.white)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(model.recoveryHeadline)
                    .font(.title2.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                Text("Nothing has been written to your destination folder yet.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(24)
        .accessibilityElement(children: .combine)
    }

    private func row(for batch: RecoveredBatchViewData) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(batch.batchName)
                    .font(.headline)
                Spacer(minLength: 0)
                Text(batch.savedAt, format: .relative(presentation: .named))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text(batch.summary)
                .font(.callout)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .fixedSize(horizontal: false, vertical: true)

            if batch.wasInterruptedMidScan {
                Label(
                    "Interrupted while scanning. Every completed card is safe.",
                    systemImage: "exclamationmark.triangle"
                )
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 10) {
                Spacer(minLength: 0)
                Button("Discard…", role: .destructive) {
                    batchPendingDiscard = batch
                }
                .buttonStyle(.glass)
                .accessibilityHint("Deletes this batch and its scanned images")

                Button("Resume") {
                    model.resumeRecoveredBatch(batch.id)
                }
                .buttonStyle(.glassProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .background(
            .background.secondary,
            in: RoundedRectangle(cornerRadius: 14)
        )
    }

    private var footer: some View {
        HStack(alignment: .center) {
            Text("Recovered batches stay here until you resume or discard them.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 12)

            Button("Decide Later") {
                model.dismissRecovery()
            }
            .buttonStyle(.glass)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }
}
