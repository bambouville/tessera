import Foundation

enum OSDetector {
    static func parse(probeOutput: String) -> String? {
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
}
