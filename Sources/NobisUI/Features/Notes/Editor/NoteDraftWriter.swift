import Foundation
import FamilyCore

/// Coalesce a short burst without postponing persistence indefinitely during typing.
@MainActor final class NoteDraftWriter {
    private var timer: Task<Void, Never>?
    private var pending: (() -> Void)?
    private var revision = UUID()

    func schedule(store: DocumentDraftStore, draft: DocumentDraft, key: UUID,
                  allowed: @escaping @MainActor () -> Bool,
                  completion: @escaping @MainActor (Result<Void, Error>) -> Void) {
        let revision = UUID()
        self.revision = revision
        pending = { [weak self] in
            guard allowed() else { return }
            store.saveInBackground(draft, key: key) { [weak self] result in
                Task { @MainActor [weak self] in
                    guard let self, self.revision == revision, allowed() else { return }
                    completion(result)
                }
            }
        }
        guard timer == nil else { return }
        timer = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
            guard let self else { return }
            self.timer = nil
            let operation = self.pending
            self.pending = nil
            operation?()
        }
    }

    /// Call before synchronous lifecycle saves/removals; the store drains earlier writes.
    func cancel() {
        revision = UUID()
        timer?.cancel()
        timer = nil
        pending = nil
    }
}
