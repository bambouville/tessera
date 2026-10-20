import Citadel
import Foundation
import NIOCore
import NIOSSH
import PortForwarding

/// Whether anything answers at a forward's *target* — the far side of the
/// tunnel — as opposed to whether Tessera's own listener is up. A listening
/// tunnel to a dev server that has not started yet is still a tunnel; this is
/// what tells the two apart for the top-bar glyph and the status rows.
public enum ForwardedServiceState: Equatable, Sendable {
    /// Not looked at yet, or no look so far could tell.
    case unknown
    case serving
    case notServing
}

/// What one look at a forward's target said.
enum ForwardedServiceProbeResult: Equatable, Sendable {
    /// The SSH server connected to the target: something accepts there.
    case serving
    /// The SSH server tried, and the target refused or could not be reached.
    case notServing
    /// The SSH server refuses direct-tcpip altogether (`AllowTcpForwarding
    /// no`, a `permitopen` that excludes the target): no page can come through
    /// this tunnel, but that says nothing about the service behind it.
    case forwardingProhibited
    /// A timeout, a dropped connection, anything else: no evidence either way.
    case inconclusive

    /// Classifies a failed direct-tcpip open by its RFC 4254 §5.1 reason code.
    static func classifying(_ error: Error) -> ForwardedServiceProbeResult {
        if case DirectTCPIPError.channelOpenFailed(let underlying) = error {
            return classifying(underlying)
        }
        guard let ssh = error as? NIOSSHError, ssh.type == .channelSetupRejected else {
            return .inconclusive
        }
        return classifying(openFailureDescription: String(describing: ssh))
    }

    /// swift-nio-ssh keeps the reason code private to `NIOSSHError` and only
    /// spells it into the description — `…channelSetupRejected: Reason: 2
    /// connect failed: Connection refused` — so that spelling is what is read.
    static func classifying(openFailureDescription description: String) -> ForwardedServiceProbeResult {
        guard let marker = description.range(of: "Reason: ") else { return .inconclusive }
        let digits = description[marker.upperBound...].prefix { $0.isASCII && $0.isNumber }
        switch UInt32(digits) {
        case 1: return .forwardingProhibited // SSH_OPEN_ADMINISTRATIVELY_PROHIBITED
        case 2: return .notServing // SSH_OPEN_CONNECT_FAILED
        default: return .inconclusive
        }
    }
}

/// How often a forward's target is looked at while someone is watching it.
/// Android's `PortForwardingManager` keeps the same intervals.
enum ForwardedServiceCadence {
    /// A target nobody has seen answer is the interesting one: a dev server
    /// coming up is the transition the glyph exists to show.
    static let unconfirmed: Duration = .seconds(5)
    /// How many unconfirmed looks in a row run at `unconfirmed` — about a
    /// minute — before settling to `unconfirmedBackoff`. OpenSSH's sshd logs
    /// every refused direct-tcpip connect as an error, so a dead port
    /// probed every five seconds for as long as a session stays on screen
    /// would fill the host's journal. The streak restarts whenever someone
    /// starts looking again, and a real connection reports at once anyway.
    static let unconfirmedBurst = 12
    static let unconfirmedBackoff: Duration = .seconds(30)
    /// Real connections through the tunnel also report, so a server that
    /// goes away is usually noticed before this comes round.
    static let serving: Duration = .seconds(15)
    /// The SSH server forbids forwarding; asking again soon changes nothing.
    static let prohibited: Duration = .seconds(60)
    /// An open with no answer by then says nothing either way.
    static let timeout: TimeAmount = .seconds(8)
    /// Looks in a row with no answer before what was known is dropped. The
    /// app keeps no SSH keepalive, so a transport that died quietly — or a
    /// target whose connect hangs past `timeout` — answers every probe
    /// inconclusively, and a glyph that kept its last answer would stay green
    /// on a tunnel that can no longer carry a page. Two, not one, so a single
    /// slow answer on a busy link does not flicker it.
    static let inconclusiveLooksBeforeUnknown = 2

    static func isDue(
        service: ForwardedServiceState,
        forwardingProhibited: Bool,
        unconfirmedStreak: Int,
        lastChecked: ContinuousClock.Instant?,
        now: ContinuousClock.Instant
    ) -> Bool {
        guard let lastChecked else { return true }
        let interval: Duration
        if forwardingProhibited {
            interval = prohibited
        } else if service == .serving {
            interval = serving
        } else if unconfirmedStreak < unconfirmedBurst {
            interval = unconfirmed
        } else {
            interval = unconfirmedBackoff
        }
        return lastChecked.duration(to: now) >= interval
    }
}

/// Asks the SSH server to connect to `target` exactly as a forwarded
/// connection would, and closes the channel the moment it opens. That is the
/// question the in-app browser is about to ask, so the answer cannot disagree
/// with it — including for a target that is not the SSH host itself.
///
/// The target sees one TCP connection accepted and closed with no bytes,
/// which an HTTP server answers with silence.
func probeForwardedService(
    over client: SSHClient,
    target: PortForwardEndpoint
) async -> ForwardedServiceProbeResult {
    let originator: SocketAddress
    do {
        originator = try SocketAddress(ipAddress: "127.0.0.1", port: 0)
    } catch {
        return .inconclusive
    }

    let opened = client.createDirectTCPIPChannelFuture(
        using: SSHChannelType.DirectTCPIP(
            targetHost: target.host,
            targetPort: Int(target.port),
            originatorAddress: originator
        ),
        initialize: { $0.eventLoop.makeSucceededVoidFuture() }
    )
    // Only the open's answer is wanted. The channel is closed whenever it
    // arrives — including after the deadline below has stopped waiting for
    // it, so a slow open never leaves a channel behind.
    opened.whenSuccess { $0.close(promise: nil) }

    let answer = opened.eventLoop.makePromise(of: ForwardedServiceProbeResult.self)
    let deadline = opened.eventLoop.scheduleTask(in: ForwardedServiceCadence.timeout) {
        answer.succeed(.inconclusive)
    }
    opened.whenComplete { result in
        deadline.cancel()
        switch result {
        case .success:
            answer.succeed(.serving)
        case .failure(let error):
            answer.succeed(.classifying(error))
        }
    }
    return (try? await answer.futureResult.get()) ?? .inconclusive
}

extension PortForwarder {
    /// The status line for a listener with no connection in flight — the one
    /// state where whether anything answers behind it is still a question.
    /// Shared by the session bar's tunnel sheet and the Tunnels page.
    var listeningStatusText: String {
        switch service {
        case .serving:
            return String(localized: "serving · 0 active")
        case .notServing:
            // A string, not a number: a port is not grouped ("3,000").
            let port = String(rule.target?.port ?? rule.bind.port)
            return String(
                localized: "listening · nothing serving on remote port \(port)",
                comment: "Port forwarding status; the argument is the TCP port on the remote side of the tunnel"
            )
        case .unknown:
            // A rule that is never probed, or whose server refuses to forward
            // at all, has nothing pending: "checking" would never resolve.
            return probesServiceActively && !forwardingProhibited
                ? String(localized: "listening · checking…")
                : String(localized: "listening · 0 active")
        }
    }
}
