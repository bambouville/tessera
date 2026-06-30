import Foundation
import Citadel

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
enum OSDetectionProbe {

    /// Trailing `exit 0` is load-bearing: Citadel propagates the
    /// command's exit status, and missing release files (e.g.
    /// `/etc/debian_version` on macOS) make the last `cat` exit
    /// non-zero — which Citadel turns into `CommandFailed` and discards
    /// the accumulated stdout.
    private static let probeCommand =
        "uname -s 2>/dev/null; cat /etc/os-release 2>/dev/null; sw_vers 2>/dev/null; cat /etc/alpine-release 2>/dev/null; cat /etc/debian_version 2>/dev/null; exit 0"

    static func run(on client: SSHClient) async -> String? {
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
                probeCommand,
                maxResponseSize: 16 * 1024,
                mergeStreams: true,
                inShell: false
            )
            let bytes = output.readBytes(length: output.readableBytes) ?? []
            let probeOutput = String(decoding: bytes, as: UTF8.self)
            return OSDetector.parse(probeOutput: probeOutput)
        } catch {
            return nil
        }
    }
}
