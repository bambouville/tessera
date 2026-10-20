import Foundation

/// A high-confidence match for Tailscale's documented WSL2 MTU failure
/// shape. The inner tunnel interface is expected to stay at 1280; the
/// problematic value is the smaller-than-1340 outer/default interface that
/// has to carry the encrypted Tailscale packet.
///
/// Presentation (the help URL and the localized `detail` sentence) belongs to
/// the platform layer — this type is only the measurement.
public struct WSLTailscaleMTUWarning: Codable, Equatable, Sendable {
    public let defaultInterfaceMTU: Int
    public let tailscaleInterfaceMTU: Int

    public init(defaultInterfaceMTU: Int, tailscaleInterfaceMTU: Int) {
        self.defaultInterfaceMTU = defaultInterfaceMTU
        self.tailscaleInterfaceMTU = tailscaleInterfaceMTU
    }
}

public enum NetworkPathAssessment: Equatable, Sendable {
    /// The host rejected the probe or did not expose enough information to
    /// classify it. Callers retain any cached warning in this case.
    case unavailable
    /// The probe completed and did not match the documented failure shape.
    /// Callers may clear a warning cached by an earlier connection.
    case notAtRisk
    case warning(WSLTailscaleMTUWarning)
}

public struct OSDetectionResult: Equatable, Sendable {
    public let osHint: String?
    public let networkPathAssessment: NetworkPathAssessment

    public init(osHint: String?, networkPathAssessment: NetworkPathAssessment) {
        self.osHint = osHint
        self.networkPathAssessment = networkPathAssessment
    }
}

/// Everything about remote-OS detection that is pure text: the probe script
/// both platforms send, the OS-family classifier, and the network-path risk
/// classifier.
///
/// The transport that runs the probe, and the per-host persistence of what it
/// found, stay on each platform. Failures must never propagate to the session
/// lifecycle — the user experience for an unknown OS is "no badge update",
/// which is also the default state.
public enum RemoteOSDetection {

    /// Key/value marker the probe uses for its network fields, so they can be
    /// picked out of arbitrary shell banner noise.
    public static let networkMarker = "__TESSERA_NETWORK__"

    /// Trailing `exit 0` is load-bearing: SSH exec channels propagate the
    /// command's exit status, and missing release files (e.g.
    /// `/etc/debian_version` on macOS) make the last `cat` exit non-zero —
    /// which the client turns into a command failure and discards the
    /// accumulated stdout with.
    ///
    /// Run this NON-interactively (an SSH ExecRequest, i.e. `$SHELL -c`) so
    /// the host's login/interactive dotfiles are not sourced. A very common
    /// "auto tmux" setup runs `exec tmux` from those dotfiles; an interactive
    /// probe shell would be hijacked by tmux — which, with no PTY on this
    /// channel, exits non-zero ("open terminal failed: not a terminal")
    /// before `uname`/`sw_vers` ever run, and the host would silently fall
    /// back to its default (generic Linux) badge.
    public static let probeCommand = """
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

    /// Pure parser kept separate from SSH I/O so the risk classification can
    /// be tested with exact WSL/network transcripts.
    public static func parse(probeOutput: String) -> OSDetectionResult {
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
            osHint: parseOSFamily(probeOutput: probeOutput),
            networkPathAssessment: assessNetworkPath(fields: fields)
        )
    }

    // MARK: - OS family

    public static func parseOSFamily(probeOutput: String) -> String? {
        let lines = probeOutput
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        let lowercasedLines = lines.map { $0.lowercased() }

        // macOS: `uname -s` prints "Darwin", but a login/interactive
        // shell can emit banners (or exec into tmux) before the probe
        // command runs, so don't assume it's the first line — accept the
        // bare "Darwin" line anywhere, and also accept the `sw_vers`
        // ProductName line as a fallback signal in case `uname` output
        // never made it through.
        if lowercasedLines.contains("darwin")
            || lowercasedLines.contains(where: isMacOSProductLine) {
            return "macos"
        }

        let id = osReleaseValue("ID", in: lines)?.lowercased()
        let unameIsLinux = lowercasedLines.contains("linux")
        let lowercasedOutput = probeOutput.lowercased()
        let hasRaspbianMarker = id == "raspbian" || lowercasedOutput.contains("raspbian")
        let hasUbuntuMarker = id == "ubuntu" || lowercasedOutput.contains("ubuntu")

        if hasRaspbianMarker {
            return "raspbian"
        }

        if hasUbuntuMarker {
            return "ubuntu"
        }

        let fallbackLines = releaseFallbackLines(from: lines)
        if id == "alpine" || (unameIsLinux && fallbackLines.contains(where: isAlpineReleaseLine)) {
            return "alpine"
        }

        if id == "debian" || (unameIsLinux && fallbackLines.contains(where: isDebianVersionLine)) {
            return "debian"
        }

        if unameIsLinux {
            return "linux"
        }

        return nil
    }

    /// Matches a `sw_vers` ProductName line such as
    /// `ProductName:\t\tmacOS` (or the older `Mac OS X`). The line is
    /// expected pre-lowercased and trimmed.
    private static func isMacOSProductLine(_ line: String) -> Bool {
        guard line.hasPrefix("productname:") else { return false }
        return line.contains("macos") || line.contains("mac os") || line.contains("os x")
    }

    private static func osReleaseValue(_ key: String, in lines: [String]) -> String? {
        for line in lines {
            let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            guard parts[0].trimmingCharacters(in: .whitespacesAndNewlines) == key else {
                continue
            }

            return stripQuotes(String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines))
        }

        return nil
    }

    private static func stripQuotes(_ value: String) -> String {
        guard value.count >= 2 else { return value }

        let first = value.first
        let last = value.last
        if (first == "\"" && last == "\"") || (first == "'" && last == "'") {
            return String(value.dropFirst().dropLast())
        }

        return value
    }

    private static func releaseFallbackLines(from lines: [String]) -> [String] {
        lines.filter { line in
            guard !line.isEmpty else { return false }
            guard line.lowercased() != "linux", line.lowercased() != "darwin" else {
                return false
            }
            guard !line.contains("=") else { return false }
            guard !line.hasPrefix("ProductName:"),
                  !line.hasPrefix("ProductVersion:"),
                  !line.hasPrefix("BuildVersion:")
            else { return false }
            return true
        }
    }

    private static func isAlpineReleaseLine(_ line: String) -> Bool {
        if line.lowercased() == "edge" { return true }

        let parts = line.split(separator: ".")
        guard parts.count >= 3 else { return false }
        return parts.allSatisfy { !$0.isEmpty && $0.allSatisfy(\.isNumber) }
    }

    private static func isDebianVersionLine(_ line: String) -> Bool {
        if line.lowercased().hasSuffix("/sid") { return true }

        let parts = line.split(separator: ".")
        guard (1...2).contains(parts.count) else { return false }
        return parts.allSatisfy { !$0.isEmpty && $0.allSatisfy(\.isNumber) }
    }

    // MARK: - Network path

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
