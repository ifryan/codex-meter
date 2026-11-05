// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// Each provider owns its task. A generation change rejects even a transport that ignores cancellation.
@MainActor
final class UsageLoader<Snapshot: Sendable> {
    private(set) var snapshot: Snapshot?
    private(set) var error: Error?
    private(set) var isLoading = false
    private var generation = UUID()
    private var task: Task<Void, Never>?

    func seed(_ snapshot: Snapshot) { self.snapshot = snapshot }

    @discardableResult
    func refresh(
        fetch: @escaping () async throws -> Snapshot,
        onSuccess: @escaping (Snapshot?, Snapshot) -> Void = { _, _ in },
        onChange: @escaping () -> Void = {}
    ) -> Task<Void, Never>? {
        guard !isLoading else { return nil }
        let requestGeneration = generation
        let previous = snapshot
        isLoading = true
        error = nil
        onChange()
        let request = Task { [weak self] in
            do {
                let result = try await fetch()
                guard let self, self.generation == requestGeneration else { return }
                try Task.checkCancellation()
                self.snapshot = result
                self.error = nil
                self.isLoading = false
                self.task = nil
                onSuccess(previous, result)
                onChange()
            } catch {
                guard let self, self.generation == requestGeneration else { return }
                self.isLoading = false
                self.task = nil
                if !(error is CancellationError) { self.error = error }
                onChange()
            }
        }
        task = request
        return request
    }

    func cancel() {
        generation = UUID()
        task?.cancel()
        task = nil
        isLoading = false
    }

    func invalidate() {
        cancel()
        snapshot = nil
        error = nil
    }
}
