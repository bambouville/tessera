import Foundation

/// What a liveness probe learned about a session's detached mosh-server.
/// Spelled exactly as the probe prints it after
/// `MoshBootstrapGrammar.serverLivenessMarker`.
public enum MoshServerLiveness: String, Equatable, Sendable, CaseIterable {
    /// The PID still runs mosh-server.
    case alive
    /// No such process, or the PID now belongs to something else.
    case gone
    /// The host answered but could not say. Never evidence of loss.
    case unknown
}

/// When a mosh session that has lost contact asks its host whether its server
/// is still there, and what it does with the answer.
///
/// Mosh's client never gives up on its own: a server that died with its host
/// leaves the session calling itself connected for as long as the app keeps it
/// open, and only closing the tab and reconnecting recovers it. Unreachability
/// alone proves nothing — roaming, a sleeping radio or a VPN still coming up
/// all look the same from the client — so the session asks the host over SSH,
/// and only a host that answers `gone` ends the attempt. A host that cannot be
/// reached is still rebooting or still out of reach; the session keeps waiting
/// and asks again.
///
/// Platforms probe only while the app is in the foreground and the transport
/// is unreachable; the timing below starts from the moment both became true.
public enum MoshServerLivenessPolicy {
    /// What one probe produced. `hostUnreachable` is the platform's verdict
    /// when SSH itself failed, so the script never ran.
    public enum Outcome: String, Equatable, Sendable, CaseIterable {
        case alive
        case gone
        case unknown
        case hostUnreachable

        public init(_ liveness: MoshServerLiveness) {
            switch liveness {
            case .alive: self = .alive
            case .gone: self = .gone
            case .unknown: self = .unknown
            }
        }
    }

    /// How long mosh must stay unreachable in the foreground before the first
    /// probe. A live server answers a resumed client within a round trip once
    /// mosh hops to a fresh socket, so this only spares that common case an
    /// SSH login.
    public static let unreachableGraceSeconds: TimeInterval = 3

    /// Delays after consecutive `hostUnreachable` outcomes, one-based. A
    /// rebooting host comes back within the first two minutes of this ladder;
    /// past that the host is off or out of reach for longer, and the delay
    /// stretches to the last rung and holds there. Platforms also cut a delay
    /// short when the network path changes or the app becomes active, so the
    /// long tail costs little when the host's network returns.
    public static let hostUnreachableLadderSeconds: [TimeInterval] = [
        2, 4, 8, 15, 15, 15, 15, 30, 30, 60,
    ]

    /// Delay after an answer that settled nothing (`alive`, `unknown`). The
    /// server is there or the host cannot tell; mosh recovers on its own when
    /// the path allows. Asking again catches a server that dies later without
    /// turning a blocked UDP path into an SSH login every few seconds.
    public static let settledRecheckSeconds: TimeInterval = 60

    /// Only a host that says the server is gone ends the attempt.
    public static func endsAttempt(after outcome: Outcome) -> Bool {
        outcome == .gone
    }

    /// When the probe after this one runs.
    public enum NextProbe: Equatable, Sendable {
        /// The attempt ended; there is none.
        case none
        /// After this many seconds, or sooner when the network path changes
        /// or the app returns to the foreground.
        case after(TimeInterval)
        /// Only when the network path changes, the app returns to the
        /// foreground or is unlocked: no timer at all.
        case onWake
    }

    /// The next probe, given whether this one asked the device owner for
    /// anything (Face ID, the passcode, a key-use approval). A check nobody
    /// asked for must not put that in front of the user on a schedule:
    /// - After `alive` or `unknown` the server is there, or the user declined
    ///   or could not answer. Nothing a timer could change; wait for a wake.
    /// - After `hostUnreachable` the destination may still be coming back —
    ///   behind a jump host the prompt can come before the destination is
    ///   reached — so it is asked again, but no more often than the settled
    ///   interval.
    /// A probe that asked nothing keeps `nextProbeDelaySeconds`.
    public static func nextProbe(
        after outcome: Outcome,
        consecutiveHostFailures: Int,
        askedOwner: Bool
    ) -> NextProbe {
        guard let delay = nextProbeDelaySeconds(
            after: outcome,
            consecutiveHostFailures: consecutiveHostFailures
        ) else { return .none }
        guard askedOwner else { return .after(delay) }
        switch outcome {
        case .gone:
            return .none
        case .alive, .unknown:
            return .onWake
        case .hostUnreachable:
            return .after(max(delay, settledRecheckSeconds))
        }
    }

    /// Delay before the next probe, or `nil` when there is none to make.
    /// `consecutiveHostFailures` counts this outcome when it is
    /// `hostUnreachable`, and is ignored otherwise.
    public static func nextProbeDelaySeconds(
        after outcome: Outcome,
        consecutiveHostFailures: Int
    ) -> TimeInterval? {
        switch outcome {
        case .gone:
            return nil
        case .alive, .unknown:
            return settledRecheckSeconds
        case .hostUnreachable:
            let index = min(
                max(consecutiveHostFailures, 1) - 1,
                hostUnreachableLadderSeconds.count - 1
            )
            return hostUnreachableLadderSeconds[index]
        }
    }
}
