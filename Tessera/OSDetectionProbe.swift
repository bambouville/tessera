import Foundation
import Citadel

/// A high-confidence match for Tailscale's documented WSL2 MTU failure
/// shape. The inner tunnel interface is expected to stay at 1280; the
/// problematic value is the smaller-than-1340 outer/default interface that
/// has to carry the encrypted Tailscale packet.
struct WSLTailscaleMTUWarning: Codable, Equatable, Sendable {
    static let helpURL = URL(string: "http://bambouville.com/docs/wsl-mtu/")!

    let defaultInterfaceMTU: Int
    let tailscaleInterfaceMTU: Int

    var detail: String {
        "WSL2 reports an outer MTU of \(defaultInterfaceMTU) while tailscale0 uses \(tailscaleInterfaceMTU). Larger SSH replies may stall."
    }
}

enum NetworkPathAssessment: Equatable, Sendable {
    /// The host rejected the probe or did not expose enough information to
    /// classify it. Callers retain any cached warning in this case.
    case unavailable
    /// The probe completed and did not match the documented failure shape.
    /// Callers may clear a warning cached by an earlier connection.
    case notAtRisk
    case warning(WSLTailscaleMTUWarning)
}

struct OSDetectionResult: Equatable, Sendable {
    let osHint: String?
    let networkPathAssessment: NetworkPathAssessment
}

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

    private static let networkMarker = "__TESSERA_NETWORK__"

    /// Trailing `exit 0` is load-bearing: Citadel propagates the
    /// command's exit status, and missing release files (e.g.
    /// `/etc/debian_version` on macOS) make the last `cat` exit
    /// non-zero — which Citadel turns into `CommandFailed` and discards
    /// the accumulated stdout.
    private static let probeCommand = """
        uname -s 2>/dev/null
        cat /etc/os-release 2>/dev/null
        sw_vers 2>/dev/null
        cat /etc/alpine-release 2>/dev/null
        cat /etc/debian_version 2>/dev/null
        tessera_kernel=$(cat /proc/sys/kernel/osrelease 2>/dev/null)
        tessera_default_dev=
        tessera_default_mtu=
        tessera_tailscale_mtu=
        tessera_tailscale_path=unknown
        if command -v ip >/dev/null 2>&1; then
          tessera_default_dev=$(ip route show default 2>/dev/null | awk 'NR == 1 { print $5; exit }')
          case "$tessera_default_dev" in
            ""|*[!A-Za-z0-9_.:@-]*) ;;
            *) tessera_default_mtu=$(cat "/sys/class/net/$tessera_default_dev/mtu" 2>/dev/null) ;;
          esac
          if [ -e /sys/class/net/tailscale0/mtu ]; then
            tessera_tailscale_mtu=$(cat /sys/class/net/tailscale0/mtu 2>/dev/null)
            set -- $SSH_CONNECTION
            tessera_server_ip=${3:-}
            if [ -n "$tessera_server_ip" ]; then
              if ip -o addr show dev tailscale0 2>/dev/null | awk -v target="$tessera_server_ip" '{ split($4, a, "/"); if (tolower(a[1]) == tolower(target)) found=1 } END { exit found ? 0 : 1 }'; then
                tessera_tailscale_path=1
              else
                tessera_tailscale_path=0
              fi
            fi
          else
            tessera_tailscale_path=0
          fi
        fi
        printf '\n__TESSERA_NETWORK__ kernel=%s\n' "$tessera_kernel"
        printf '__TESSERA_NETWORK__ tailscale_path=%s\n' "$tessera_tailscale_path"
        printf '__TESSERA_NETWORK__ default_mtu=%s\n' "$tessera_default_mtu"
        printf '__TESSERA_NETWORK__ tailscale_mtu=%s\n' "$tessera_tailscale_mtu"
        exit 0
        """

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
                probeCommand,
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
        var fields: [String: String] = [:]
        for rawLine in probeOutput.components(separatedBy: .newlines) {
            guard rawLine.hasPrefix(networkMarker + " ") else { continue }
            let payload = rawLine.dropFirst(networkMarker.count + 1)
            let parts = payload.split(
                separator: "=",
                maxSplits: 1,
                omittingEmptySubsequences: false
            )
            guard parts.count == 2 else { continue }
            fields[String(parts[0])] = String(parts[1])
        }

        return OSDetectionResult(
            osHint: OSDetector.parse(probeOutput: probeOutput),
            networkPathAssessment: assessNetworkPath(fields: fields)
        )
    }

    private static func assessNetworkPath(
        fields: [String: String]
    ) -> NetworkPathAssessment {
        guard let kernel = fields["kernel"]?.lowercased(), !kernel.isEmpty else {
            return .unavailable
        }

        let isWSL2 = kernel.contains("microsoft") && kernel.contains("wsl2")
        guard isWSL2 else { return .notAtRisk }

        guard let tailscalePath = fields["tailscale_path"] else {
            return .unavailable
        }
        guard tailscalePath == "1" else {
            return tailscalePath == "0" ? .notAtRisk : .unavailable
        }

        guard let defaultMTU = Int(fields["default_mtu"] ?? ""),
              let tailscaleMTU = Int(fields["tailscale_mtu"] ?? ""),
              defaultMTU > 0,
              tailscaleMTU > 0
        else { return .unavailable }

        guard tailscaleMTU == 1_280, defaultMTU < 1_340 else {
            return .notAtRisk
        }

        return .warning(
            WSLTailscaleMTUWarning(
                defaultInterfaceMTU: defaultMTU,
                tailscaleInterfaceMTU: tailscaleMTU
            )
        )
    }
}
