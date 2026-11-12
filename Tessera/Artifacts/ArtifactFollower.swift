import Foundation

/// Only the visible file owns a cadence. The injected sleep also lets tests
/// advance a tick without waiting for wall time or touching a host.
@MainActor
final class ArtifactFollower {
    private let sleep: @Sendable (UInt64) async throws -> Void
    private var task: Task<Void, Never>?
    private var generation = 0
    private(set) var tabID: String?

    init(sleep: @escaping @Sendable (UInt64) async throws -> Void = { try await Task.sleep(nanoseconds: $0) }) {
        self.sleep = sleep
    }

    func follow(_ tabID: String?, poll: @escaping @MainActor (String) async -> Bool) {
        guard self.tabID != tabID else { return }
        stop()
        guard let tabID else { return }
        self.tabID = tabID
        let generation = self.generation
        let sleep = self.sleep
        task = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do { try await sleep(3_000_000_000) } catch { break }
                guard !Task.isCancelled, await poll(tabID) else { break }
            }
            if self?.generation == generation { self?.tabID = nil }
        }
    }

    func stop() {
        generation &+= 1
        task?.cancel()
        task = nil
        tabID = nil
    }
}
