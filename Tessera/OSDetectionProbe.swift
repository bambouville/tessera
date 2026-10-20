import Foundation
import Citadel
import TesseraDomainCore

/// A high-confidence match for Tailscale's documented WSL2 MTU failure
/// shape. The inner tunnel interface is expected to stay at 1280; the
/// problematic value is the smaller-than-1340 outer/default interface that
/// has to carry the encrypted Tailscale packet.
///
/// The measurement itself is shared (`TesseraDomainCore`); the help URL and
/// the localized sentence stay here, because the string has to be extracted
/// into the app's catalog to be translated at all.
typealias WSLTailscaleMTUWarning = TesseraDomainCore.WSLTailscaleMTUWarning

extension WSLTailscaleMTUWarning {
    static let helpURL = URL(string: "http://bambouville.com/docs/wsl-mtu/")!

    var detail: String {
        String(
            localized: "WSL2 reports an outer MTU of \(defaultInterfaceMTU) while tailscale0 uses \(tailscaleInterfaceMTU). Larger SSH replies may stall.",
            comment: "Path-MTU warning; the arguments are byte counts for two network interfaces"
        )
    }
}

typealias NetworkPathAssessment = TesseraDomainCore.NetworkPathAssessment
typealias OSDetectionResult = TesseraDomainCore.OSDetectionResult

/// Side-channel SSH probe that derives the remote host's OS family
/// from the same connection that's being used for the user's shell.
/// Reusable across SSH and mosh transports — mosh runs the probe
/// during bootstrap (before closing the bootstrap SSH client), SSH
/// fires it as a detached task in parallel with `withPTY`.
///
/// Returns `nil` on any failure (channel error, parse miss). Failures
/// must never propagate to the main session lifecycle — the user
/// experience for an unknown OS is "no badge update", which is also
/// the default state.
///
/// The probe script and both classifiers live in
/// `TesseraDomainCore.RemoteOSDetection`; only the Citadel channel is here.
enum OSDetectionProbe {

    static func run(on client: SSHClient) async -> OSDetectionResult? {
        do {
            // Run NON-interactively (`inShell: false` → SSH ExecRequest,
            // i.e. `$SHELL -c <probe>`) so the host's login/interactive
            // dotfiles (`.zprofile`, `.zshrc`, `.bashrc`, …) are NOT
            // sourced. A very common "auto tmux" setup runs `exec tmux`
            // from those dotfiles; an interactive probe shell would be
            // hijacked by tmux — which, with no PTY on this channel,
            // exits non-zero ("open terminal failed: not a terminal")
            // before `uname`/`sw_vers` ever run. The probe would then
            // return nil and the host would silently fall back to its
            // default (generic Linux) badge. ExecRequest sidesteps all
            // of that — it's also how the mosh bootstrap already runs.
            var output = try await client.executeCommand(
                RemoteOSDetection.probeCommand,
                maxResponseSize: 16 * 1024,
                mergeStreams: true,
                inShell: false
            )
            let bytes = output.readBytes(length: output.readableBytes) ?? []
            let probeOutput = String(decoding: bytes, as: UTF8.self)
            return parse(probeOutput: probeOutput)
        } catch {
            return nil
        }
    }

    /// Pure parser kept separate from SSH I/O so the risk classification can
    /// be tested with exact WSL/network transcripts.
    static func parse(probeOutput: String) -> OSDetectionResult {
        RemoteOSDetection.parse(probeOutput: probeOutput)
    }
}
