import Foundation
import TesseraDomainCore

/// Remote-OS detection: the probe script both platforms send, the OS-family
/// classifier, and the WSL/Tailscale MTU risk classifier.
///
/// The transport that runs the probe and the per-host persistence of what it
/// found stay on each platform. What must not diverge is the probe text — its
/// trailing `exit 0` is load-bearing, because SSH exec channels propagate the
/// command's status and a missing release file makes the last `cat` exit
/// non-zero, which a client turns into a command failure and discards the
/// accumulated stdout with.

/// `{"osHint":"macos","networkPath":{"kind":"warning",
///   "warning":{"defaultInterfaceMTU":1280,"tailscaleInterfaceMTU":1280}}}`
///
/// `kind` is `unavailable` (the host rejected the probe or said too little —
/// keep any cached warning), `notAtRisk` (the probe completed and did not
/// match the documented failure shape — a cached warning may be cleared), or
/// `warning` (with the measurement). `osHint` is null when nothing in the
/// output identified a family.
public struct RemoteOSDetectionABIResponse: Codable, Equatable, Sendable {
    public struct NetworkPath: Codable, Equatable, Sendable {
        public enum Kind: String, Codable, Sendable {
            case unavailable, notAtRisk, warning
        }

        public var kind: Kind
        public var warning: WSLTailscaleMTUWarning?
    }

    public var osHint: String?
    public var networkPath: NetworkPath
}

/// The probe command, verbatim. Returns the byte count under the string
/// contract.
///
/// Run it NON-interactively (an SSH ExecRequest, i.e. `$SHELL -c`) so the
/// host's login/interactive dotfiles are not sourced: a very common "auto
/// tmux" setup runs `exec tmux` from those, and with no PTY on this channel
/// tmux exits before `uname`/`sw_vers` ever run.
@_cdecl("tessera_os_detection_probe_command")
public func tesseraOSDetectionProbeCommand(
    outputBytes: UnsafeMutablePointer<UInt8>?,
    outputCapacity: Int
) -> Int32 {
    SharedABI.copyOut(RemoteOSDetection.probeCommand, outputBytes, outputCapacity)
}

/// Parses probe output into an OS hint and a network-path assessment. Returns
/// the byte count under the string contract, or -1 for invalid arguments.
@_cdecl("tessera_os_detection_parse")
public func tesseraOSDetectionParse(
    probeOutputBytes: UnsafePointer<UInt8>?,
    probeOutputCount: Int,
    outputBytes: UnsafeMutablePointer<UInt8>?,
    outputCapacity: Int
) -> Int32 {
    guard let probeOutput = SharedABI.requiredString(probeOutputBytes, probeOutputCount)
    else { return -1 }
    let result = RemoteOSDetection.parse(probeOutput: probeOutput)
    let networkPath: RemoteOSDetectionABIResponse.NetworkPath
    switch result.networkPathAssessment {
    case .unavailable:
        networkPath = .init(kind: .unavailable, warning: nil)
    case .notAtRisk:
        networkPath = .init(kind: .notAtRisk, warning: nil)
    case let .warning(warning):
        networkPath = .init(kind: .warning, warning: warning)
    }
    return SharedABI.copyOutJSON(
        RemoteOSDetectionABIResponse(osHint: result.osHint, networkPath: networkPath),
        outputBytes,
        outputCapacity
    )
}

/// The OS family alone, for a caller that wants only the badge. Returns the
/// byte count under the string contract, or -1 when the output identifies no
/// family (which is the ordinary "no badge update" outcome, not a failure to
/// report to the user).
@_cdecl("tessera_os_detection_parse_family")
public func tesseraOSDetectionParseFamily(
    probeOutputBytes: UnsafePointer<UInt8>?,
    probeOutputCount: Int,
    outputBytes: UnsafeMutablePointer<UInt8>?,
    outputCapacity: Int
) -> Int32 {
    guard let probeOutput = SharedABI.requiredString(probeOutputBytes, probeOutputCount),
          let family = RemoteOSDetection.parseOSFamily(probeOutput: probeOutput),
          !family.isEmpty
    else { return -1 }
    return SharedABI.copyOut(family, outputBytes, outputCapacity)
}
