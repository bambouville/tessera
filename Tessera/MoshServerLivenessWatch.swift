import Foundation
import TesseraSessionCore

/// Asks the host whether a silent mosh session's server still exists, and
/// reports when it does not.
///
/// Mosh's client never gives up: a server that died with its host (a reboot,
/// an OOM kill) leaves the session `.connected` with an unreachable transport
/// forever, and only closing the tab recovers it. Unreachability by itself
/// proves nothing, so the watch probes over SSH and acts only on a `gone`
/// answer from the host. Timing and verdicts are the shared core's
/// `MoshServerLivenessPolicy`; this type is the iOS clock and task around it.
///
/// It runs only while the session is connected, its transport is unreachable,
/// the app is in the foreground and the server PID is known. Any of those
/// changing stops it, and a later loss starts over from the grace period.
@MainActor
final class MoshServerLivenessWatch {
    struct Conditions: Equatable {
        var isSessionConnected: Bool
        var isTransportReachable: Bool
        var isAppInForeground: Bool
        var serverPID: Int?

        /// The PID to watch, or nil when the watch should not run.
        var watchedPID: Int? {
            guard isSessionConnected, !isTransportReachable, isAppInForeground,
                  let serverPID, serverPID > 0
            else { return nil }
            return serverPID
        }
    }

    /// What one probe learned, and what it cost the user.
    struct ProbeAnswer: Equatable, Sendable {
        var outcome: MoshServerLivenessPolicy.Outcome
        /// The probe put an owner-authentication prompt (Face ID, the
        /// passcode) in front of the user. The shared policy then keeps the
        /// next one off a timer, or slows it — see
        /// `MoshServerLivenessPolicy.nextProbe`.
        var askedOwner = false
    }

    /// One probe, or nil when the session that owns the watch is gone.
    typealias Probe = @MainActor (_ pid: Int) async -> ProbeAnswer?
    /// Plain delay for the grace period: a path change during it does not
    /// prove anything about the server, and mosh may recover on its own.
    typealias GraceSleep = @MainActor (_ seconds: TimeInterval) async -> Bool
    /// Delay between probes; returns false when cancelled. `nil` seconds
    /// waits for a wake signal only. `wakeGeneration` was read before the
    /// probe, so a path change that landed while it ran ends the delay at
    /// once: a host that just came back is asked again straight away.
    typealias BackoffSleep = @MainActor (
        _ seconds: TimeInterval?,
        _ wakeGeneration: UInt64
    ) async -> Bool

    private let probe: Probe
    private let graceSleep: GraceSleep
    private let backoffSleep: BackoffSleep
    private let wakeGeneration: @MainActor () -> UInt64
    private let onServerGone: @MainActor (_ pid: Int) -> Void

    private var task: Task<Void, Never>?
    private var watchedPID: Int?
    private var runID: UInt64 = 0

    private(set) var probeCount = 0
    private(set) var lastOutcome: MoshServerLivenessPolicy.Outcome?

    var isRunning: Bool { task != nil }

    init(
        probe: @escaping Probe,
        graceSleep: @escaping GraceSleep = { seconds in
            do {
                try await Task.sleep(nanoseconds: UInt64((seconds * 1_000_000_000).rounded()))
                return true
            } catch {
                return false
            }
        },
        backoffSleep: @escaping BackoffSleep = { seconds, wakeGeneration in
            await ConnectivityRetryWake.shared.sleep(
                seconds: seconds,
                unlessSignalledSince: wakeGeneration
            ) != .cancelled
        },
        wakeGeneration: @escaping @MainActor () -> UInt64 = {
            ConnectivityRetryWake.shared.generation
        },
        onServerGone: @escaping @MainActor (_ pid: Int) -> Void
    ) {
        self.probe = probe
        self.graceSleep = graceSleep
        self.backoffSleep = backoffSleep
        self.wakeGeneration = wakeGeneration
        self.onServerGone = onServerGone
    }

    func update(_ conditions: Conditions) {
        let pid = conditions.watchedPID
        guard pid != watchedPID else { return }
        stop(reason: pid == nil ? "conditions" : "pid-changed")
        guard let pid else { return }
        start(pid: pid)
    }

    func stop(reason: String) {
        guard let task else { return }
        MoshDiagnostics.log(
            "server liveness watch stop pid=\(watchedPID.map(String.init) ?? "nil") reason=\(reason) probes=\(probeCount)"
        )
        task.cancel()
        self.task = nil
        watchedPID = nil
        runID &+= 1
    }

    private func start(pid: Int) {
        runID &+= 1
        let run = runID
        watchedPID = pid
        MoshDiagnostics.log(
            "server liveness watch start pid=\(pid) graceSeconds=\(MoshServerLivenessPolicy.unreachableGraceSeconds)"
        )
        task = Task { @MainActor [weak self] in
            await self?.run(pid: pid, run: run)
        }
    }

    private func run(pid: Int, run: UInt64) async {
        guard await graceSleep(MoshServerLivenessPolicy.unreachableGraceSeconds),
              isCurrent(run)
        else { return }

        var consecutiveHostFailures = 0
        while isCurrent(run) {
            let generation = wakeGeneration()
            guard let answer = await probe(pid) else {
                if isCurrent(run) { stop(reason: "owner-gone") }
                return
            }
            guard isCurrent(run) else { return }
            let outcome = answer.outcome
            probeCount += 1
            lastOutcome = outcome
            consecutiveHostFailures = outcome == .hostUnreachable
                ? consecutiveHostFailures + 1
                : 0
            let next = MoshServerLivenessPolicy.nextProbe(
                after: outcome,
                consecutiveHostFailures: consecutiveHostFailures,
                askedOwner: answer.askedOwner
            )
            if MoshServerLivenessPolicy.endsAttempt(after: outcome) {
                MoshDiagnostics.log(
                    "server liveness probe pid=\(pid) outcome=\(outcome.rawValue) probe=\(probeCount)"
                )
                task = nil
                watchedPID = nil
                onServerGone(pid)
                return
            }
            let delay: TimeInterval?
            switch next {
            case .none: return
            case .after(let seconds): delay = seconds
            case .onWake: delay = nil
            }
            MoshDiagnostics.log(
                "server liveness probe pid=\(pid) outcome=\(outcome.rawValue) probe=\(probeCount) hostFailures=\(consecutiveHostFailures) askedOwner=\(answer.askedOwner) next=\(delay.map { "\(Int($0))s" } ?? "on-wake")"
            )
            guard await backoffSleep(delay, generation) else { return }
        }
    }

    private func isCurrent(_ run: UInt64) -> Bool {
        !Task.isCancelled && runID == run
    }
}

/// What happens to a session whose host said its mosh-server is gone.
///
/// A rebuild starts the session's launch again on a fresh server: tmux modes
/// reattach to (or recreate) their session and a bare login shell opens a new
/// one, which is what reconnecting by hand does, startup snippet included. A
/// custom launch command is different — running it again is the user's call —
/// so it is rebuilt only under the restore setting that already reruns it at
/// launch. A locked app never rebuilds. A kept session stays failed, with the
/// reason and Retry on screen.
enum MoshServerLossRecovery {
    enum Decision: String, Equatable {
        case rebuild
        case keepForLaunchCommand = "launch-command"
        case keepWhileLocked = "locked"
    }

    static func decide(
        launchMode: HostLaunchMode,
        launchCommand: String?,
        restorePolicy: SessionRestorePolicy,
        isAppLocked: Bool
    ) -> Decision {
        guard !isAppLocked else { return .keepWhileLocked }
        switch launchMode {
        case .autoTmux, .pinnedTmux:
            return .rebuild
        case .customCommand:
            let command = launchCommand?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return command.isEmpty || restorePolicy == .always ? .rebuild : .keepForLaunchCommand
        }
    }
}
