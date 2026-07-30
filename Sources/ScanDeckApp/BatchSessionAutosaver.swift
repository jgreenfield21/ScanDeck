import Foundation
import ScanDeckCore

/// Keeps the recovery record current without making the operator wait for it.
///
/// A full device flush measures around 20 ms, and autosave runs on every
/// acknowledged page and every review edit. Doing that synchronously would
/// block the main actor through an entire feed — roughly eight seconds of
/// stutter across a hundred-card batch — so the write happens off the main
/// actor while the ordering that makes it safe stays on it.
///
/// Only the newest snapshot is written. `BatchSession` is event-sourced and
/// only ever accumulates, so a newer snapshot already contains everything an
/// older one did; writing a superseded one afterwards would move recovery
/// backwards. Coalescing therefore loses nothing that a crash would not have
/// lost anyway.
///
/// Discard is routed through here too. A queued save must never be allowed to
/// resurrect a record that was just deleted after a successful publication.
@MainActor
final class BatchSessionAutosaver {
    private let store: BatchSessionStore
    private let onFailure: @MainActor (any Error) -> Void

    private var pending: PersistedBatchSession?
    private var drainTask: Task<Void, Never>?

    init(
        store: BatchSessionStore,
        onFailure: @escaping @MainActor (any Error) -> Void
    ) {
        self.store = store
        self.onFailure = onFailure
    }

    func save(_ record: PersistedBatchSession) {
        pending = record
        startDraining()
    }

    /// Removes a batch and every master it captured, after any queued save for
    /// it has been dealt with.
    func discard(_ batchID: BatchID) async throws {
        if pending?.session.id == batchID {
            pending = nil
        }
        await waitForQuiet()
        try store.discard(batchID)
    }

    /// Waits until nothing is queued or in flight. Production never needs this;
    /// tests do, because a record's arrival on disk is otherwise a race.
    func flush() async {
        await waitForQuiet()
    }

    private func startDraining() {
        guard drainTask == nil else {
            // A drain is already running and will pick up `pending` itself.
            return
        }

        drainTask = Task { @MainActor [store, onFailure] in
            defer { drainTask = nil }

            while let record = pending {
                pending = nil
                do {
                    try await Task.detached(priority: .utility) {
                        try store.save(record)
                    }.value
                } catch {
                    onFailure(error)
                }
            }
        }
    }

    private func waitForQuiet() async {
        while let task = drainTask {
            await task.value
        }
    }
}
