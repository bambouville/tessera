import Foundation
import Network
import UIKit

/// Cuts connection backoffs short the moment a retry could succeed again.
///
/// A retry ladder that sleeps on a timer pays its whole delay even when the
/// cause cleared a moment after it started — a VPN coming up after a wake, a
/// DNS name resolving again, or the app returning from a suspension that froze
/// the timer half way. Field logs showed a resumed mosh session waiting out a
/// 10 s rung after the host name failed to resolve once while Tailscale came
/// up. Loops that sleep here instead wake when the network path changes to a
/// usable one or the app returns to the foreground, and retry at once.
///
/// A signal is a hint, not a promise: callers keep their own attempt caps, so
/// a flapping path costs at most one early attempt per change.
@MainActor
final class ConnectivityRetryWake {
    static let shared = ConnectivityRetryWake(observesSystemEvents: true)

    enum Outcome: String, Equatable, Sendable {
        /// The full delay passed.
        case elapsed
        /// The path changed or the app returned to the foreground; retry now.
        case signalled
        /// The sleeping task was cancelled.
        case cancelled
    }

    /// Advances on every signal. A loop reads it before an attempt and passes
    /// it to `sleep`, so a change that lands while the attempt is still running
    /// wakes the backoff that follows instead of being lost. Reading it starts
    /// the observers, so the first attempt's changes count too.
    var generation: UInt64 {
        startIfNeeded()
        return signalCount
    }
    private var signalCount: UInt64 = 0

    private let observesSystemEvents: Bool
    private var didStart = false
    private var monitor: NWPathMonitor?
    private var hasSeenFirstPath = false
    private var lastPathSignature: String?
    private var foregroundObserver: NSObjectProtocol?
    private var waiters: [UUID: (continuation: CheckedContinuation<Outcome, Never>, timer: Task<Void, Never>?)] = [:]

    init(observesSystemEvents: Bool) {
        self.observesSystemEvents = observesSystemEvents
    }

    /// Sleep for `seconds`, or less if the wake is signalled meanwhile — or was
    /// signalled at any point after `generation` was read. `nil` sleeps until
    /// a signal or cancellation.
    func sleep(
        seconds: TimeInterval?,
        unlessSignalledSince observed: UInt64? = nil
    ) async -> Outcome {
        startIfNeeded()
        if Task.isCancelled { return .cancelled }
        if let observed, observed != signalCount { return .signalled }

        let token = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(returning: .cancelled)
                    return
                }
                let timer = seconds.map { seconds in
                    let nanoseconds = UInt64((max(seconds, 0) * 1_000_000_000).rounded())
                    return Task { @MainActor [weak self] in
                        try? await Task.sleep(nanoseconds: nanoseconds)
                        guard !Task.isCancelled else { return }
                        self?.finish(token, with: .elapsed)
                    }
                }
                waiters[token] = (continuation, timer)
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.finish(token, with: .cancelled)
            }
        }
    }

    /// Wake every sleeper now. Exposed for the system observers below and for
    /// tests; production code has no other reason to call it.
    func signal(reason: String) {
        signalCount &+= 1
        guard !waiters.isEmpty else { return }
        MoshDiagnostics.log(
            "connectivity retry wake reason=\(reason) sleepers=\(waiters.count) generation=\(signalCount)"
        )
        for token in Array(waiters.keys) {
            finish(token, with: .signalled)
        }
    }

    var sleeperCount: Int { waiters.count }

    private func finish(_ token: UUID, with outcome: Outcome) {
        guard let waiter = waiters.removeValue(forKey: token) else { return }
        waiter.timer?.cancel()
        waiter.continuation.resume(returning: outcome)
    }

    private func startIfNeeded() {
        guard observesSystemEvents, !didStart else { return }
        didStart = true

        // Foreground, not active: a Face ID or passcode sheet resigns and
        // regains activity without the app ever leaving the screen, and a
        // probe's own prompt must not wake the probe that raised it.
        foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.signal(reason: "app-foreground")
            }
        }

        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let usable = path.status == .satisfied
            let signature = Self.signature(of: path)
            Task { @MainActor [weak self] in
                self?.handlePathUpdate(usable: usable, signature: signature)
            }
        }
        monitor.start(queue: DispatchQueue(label: "tessera.connectivity-retry-wake"))
        self.monitor = monitor
    }

    private func handlePathUpdate(usable: Bool, signature: String) {
        defer { lastPathSignature = signature }
        // The first callback reports the path as it already was.
        guard hasSeenFirstPath else {
            hasSeenFirstPath = true
            return
        }
        guard usable, signature != lastPathSignature else { return }
        signal(reason: "path")
    }

    /// Interfaces and DNS support, which is what changes when a VPN comes up
    /// or the device moves between networks while the path stays satisfied.
    private nonisolated static func signature(of path: NWPath) -> String {
        let interfaces = path.availableInterfaces
            .map { "\($0.name):\($0.type)" }
            .joined(separator: ",")
        return "\(path.status)|\(path.supportsDNS)|\(path.supportsIPv4)|\(path.supportsIPv6)|\(interfaces)"
    }
}
