import Foundation

/// The one authority projection a session renders and its input gates read
/// (§6.5 S3′, §6.9), identical on both platforms.
///
/// - `none`: this device may type and size the grid.
/// - `resuming`: a show or explicit open waits for its fresh read, or its
///   claim is running; also a hidden session over a peer, whose next show
///   decides. The terminal stays visible under a small indicator; the veil
///   never flashes on a resume.
/// - `veiled`: yielded to a peer with no intent and no claim.
/// - `reclaiming`: a veil tap (or the own-write-won continuation) is
///   running, or a tap waits for the control channel to come back.
///
/// `awaitingConnection` marks an intent that cannot be decided until the
/// control channel is live again: shown as "takes control when reconnected"
/// with a cancel, because R3 expires it after about 20 s.
public enum TmuxGridAuthorityPresentation: Equatable, Sendable {
    case none
    case resuming(awaitingConnection: Bool)
    case veiled(peerName: String)
    case reclaiming(peerName: String, awaitingConnection: Bool)

    /// Why a window/pane mutation or an Agent Center command must not reach
    /// tmux now. Typing has its own, stricter gate (`gatesTyping`).
    public enum MutationRefusal: String, Codable, Equatable, Sendable {
        /// A peer holds the grid: veiled, or a resume whose read has not
        /// displaced the peer yet (D7).
        case yielded
        /// A take-back is still running.
        case reclaiming
    }

    /// Derives the projection from reducer state, never from `authority`
    /// alone: while a show intent is pending the reducer still projects
    /// buffered stamp lines, which can name a peer for a moment before the
    /// show's own read begins its claim. Drawing that as a veil would flash
    /// it on every resume.
    ///
    /// - Parameters:
    ///   - hidden: between a show-rule hide edge and the next show. A hidden
    ///     session cannot be looked at, and its next appearance is a show
    ///     whose fresh read decides, so a peer projects as `resuming` rather
    ///     than drawing (and taking first responder for) a veil.
    ///   - channelLive: the control channel can carry a read or a claim now:
    ///     not in a transport gap the adapter knows about, and not stuck on
    ///     an unanswered read. A channel the reducer has not attached is
    ///     never live.
    public static func derive(
        reducer: TmuxGridAuthorityLifecycleReducer,
        hidden: Bool,
        channelLive: Bool
    ) -> Self {
        let channelLive = channelLive && reducer.channelAttached
        let authorityPeerName = reducer.authority.peerDisplayName
        if let claim = reducer.claim {
            let peerName = authorityPeerName
                ?? claim.contestedPeer?.displayName
                ?? TmuxStamplessPeer.displayName
            if claim.presentationVisible {
                switch claim.reason {
                case .show, .explicitOpen:
                    return .resuming(awaitingConnection: false)
                case .userTakeBack, .ownWriteWon:
                    return .reclaiming(peerName: peerName, awaitingConnection: false)
                }
            }
            // The presentation timed out while the claim keeps running in
            // the background (S4′): fold back to whatever the stamp says, so
            // a re-tap can restart it. Over our own or an unknown stamp it no
            // longer gates.
            guard reducer.authority.isPeer else { return .none }
            return hidden ? .resuming(awaitingConnection: !channelLive) : .veiled(peerName: peerName)
        }
        if let intent = reducer.pendingIntent {
            switch intent.source {
            case .show, .explicitOpen:
                // Even over a projected peer: the fresh read decides.
                return .resuming(awaitingConnection: !channelLive)
            case .tap:
                return .reclaiming(
                    peerName: intent.baseline?.displayName
                        ?? authorityPeerName
                        ?? TmuxStamplessPeer.displayName,
                    awaitingConnection: !channelLive
                )
            }
        }
        if let authorityPeerName {
            return hidden ? .resuming(awaitingConnection: !channelLive) : .veiled(peerName: authorityPeerName)
        }
        return .none
    }

    /// The holder the input gates weigh (`lastKnown`): the reducer's
    /// authority, except that a tap waiting for its channel stays bound to
    /// the peer its veil named (R2). A reset that forgets the peer leaves the
    /// authority unknown while the reclaiming veil still names that peer, and
    /// typing must stay refused under it.
    public static func lastKnownHolder(reducer: TmuxGridAuthorityLifecycleReducer) -> TmuxGridAuthoritySnapshot {
        if !reducer.authority.isPeer,
           let intent = reducer.pendingIntent, intent.source == .tap,
           let peer = intent.baseline {
            return .peer(deviceID: peer.deviceID, displayName: peer.displayName, generation: peer.generation)
        }
        return reducer.authority
    }

    /// Whether keys, paste, paths, mouse and mosh bytes are refused (M7).
    /// Refused while resuming, veiled or reclaiming, except while an intent
    /// only waits for the control channel: it cannot be decided for up to
    /// ~20 s, and a mosh+tmux session whose TCP side channel is down still
    /// has a live mosh link, so gating would drop every keystroke on each
    /// show. Then typing is refused only when `lastKnown`
    /// (`lastKnownHolder(reducer:)`) names a peer. Once the channel is live
    /// the claim is a round trip away, and the whole resume gates again.
    public func gatesTyping(lastKnown: TmuxGridAuthoritySnapshot) -> Bool {
        switch self {
        case .none:
            return false
        case .veiled:
            return true
        case .resuming(let awaitingConnection), .reclaiming(_, let awaitingConnection):
            return !awaitingConnection || lastKnown.isPeer
        }
    }

    /// The narrower gate for programmatic window/pane selection and Agent
    /// Center sends (D7): never while a peer holds the grid, never while a
    /// take-back runs. A resume over our own or an unknown grid may proceed.
    public func mutationRefusal(lastKnown: TmuxGridAuthoritySnapshot) -> MutationRefusal? {
        switch self {
        case .none:
            return nil
        case .veiled:
            return .yielded
        case .reclaiming:
            return .reclaiming
        case .resuming:
            return lastKnown.isPeer ? .yielded : nil
        }
    }

    /// The session's window/pane chrome stays disabled unless `none`.
    public var gatesWindowChrome: Bool { self != .none }

    /// True for the projections that draw the continued-elsewhere veil.
    public var showsVeil: Bool {
        switch self {
        case .veiled, .reclaiming: return true
        case .none, .resuming: return false
        }
    }

    /// `none`, `resuming[~]`, `veiled(<name>)` or `reclaiming(<name>)[~]`,
    /// where `~` marks awaiting a connection.
    public var traceLabel: String {
        switch self {
        case .none:
            return "none"
        case .resuming(let awaiting):
            return awaiting ? "resuming~" : "resuming"
        case .veiled(let peerName):
            return "veiled(\(peerName))"
        case .reclaiming(let peerName, let awaiting):
            return "reclaiming(\(peerName))" + (awaiting ? "~" : "")
        }
    }
}
