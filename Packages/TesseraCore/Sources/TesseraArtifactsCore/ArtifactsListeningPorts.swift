import Foundation

public struct ArtifactsListeningPort: Codable, Equatable, Sendable {
    public var port: UInt16
    public var bindAddress: String
    public var process: String?

    public init(port: UInt16, bindAddress: String, process: String? = nil) {
        self.port = port
        self.bindAddress = bindAddress
        self.process = process
    }
}

public enum ArtifactsListeningPorts {
    /// POSIX shell only. One watchdog bounds the entire fallback chain to
    /// one second. Tools run as direct children; the exit trap kills the
    /// active tool as well as the watchdog. A marker precedes each attempt;
    /// the parser uses only the final attempt's section.
    public static let probeCommand = #"""
    sh -c '
    probe_pid=
    timer_pid=
    cleanup() {
      [ -z "$probe_pid" ] || kill "$probe_pid" 2>/dev/null || :
      [ -z "$timer_pid" ] || kill "$timer_pid" 2>/dev/null || :
    }
    trap cleanup 0
    trap "exit 0" ALRM HUP INT TERM
    (sleep 1; kill -s ALRM "$$" 2>/dev/null) & timer_pid=$!
    run() {
      "$@" 2>/dev/null & probe_pid=$!
      wait "$probe_pid"
      result=$?
      probe_pid=
      return "$result"
    }
    if command -v ss >/dev/null 2>&1; then
      printf "%s\n" "TESSERA_ARTIFACTS_PORTS:ss"
      run ss -Hltnp && exit 0
    fi
    if command -v netstat >/dev/null 2>&1; then
      if [ "$(uname -s 2>/dev/null)" != Darwin ]; then
        printf "%s\n" "TESSERA_ARTIFACTS_PORTS:netstatLinux"
        run netstat -lnt && exit 0
      fi
      printf "%s\n" "TESSERA_ARTIFACTS_PORTS:netstatMacOS"
      run netstat -anv -p tcp && exit 0
    fi
    if command -v lsof >/dev/null 2>&1; then
      printf "%s\n" "TESSERA_ARTIFACTS_PORTS:lsof"
      run lsof -nP -iTCP -sTCP:LISTEN && exit 0
    fi
    printf "%s\n" "TESSERA_ARTIFACTS_PORTS:none"
    '
    """#

    /// Excludes 22 and a caller-supplied nonstandard SSH port. Multiple
    /// binds for one port collapse to one row; loopback and process-bearing
    /// rows win, then lexical bind/process order makes ties deterministic.
    public static func parse(_ output: String, sshPort: UInt16? = nil) -> [ArtifactsListeningPort] {
        var format = ""
        var rows: [ArtifactsListeningPort] = []
        for line in output.split(whereSeparator: \.isNewline).map(String.init) {
            if line.hasPrefix("TESSERA_ARTIFACTS_PORTS:") {
                format = String(line.dropFirst("TESSERA_ARTIFACTS_PORTS:".count))
                rows = []
                continue
            }
            let fields = line.split(whereSeparator: \.isWhitespace).map(String.init)
            let row: ArtifactsListeningPort?
            switch format {
            case "ss":
                guard fields.count >= 5, fields[0] == "LISTEN" else { continue }
                row = endpoint(fields[3], separator: ":", process: ssProcess(line))
            case "netstatLinux":
                guard fields.count >= 6, fields[0].hasPrefix("tcp"), fields.contains("LISTEN") else { continue }
                let process = fields.count > 6 ? fields[6].split(separator: "/", maxSplits: 1).last.map(String.init) : nil
                row = endpoint(fields[3], separator: ":", process: process == "-" ? nil : process)
            case "netstatMacOS":
                guard fields.count >= 6, fields[0].hasPrefix("tcp"), fields.contains("LISTEN") else { continue }
                row = endpoint(fields[3], separator: ".", process: nil)
            case "lsof":
                guard fields.count >= 9, fields.last == "(LISTEN)",
                      let tcp = fields.firstIndex(of: "TCP"), tcp + 1 < fields.count else { continue }
                row = endpoint(fields[tcp + 1], separator: ":", process: fields[0])
            default: row = nil
            }
            if let row, row.port != 22, row.port != sshPort { rows.append(row) }
        }
        var seen: Set<UInt16> = []
        return rows.sorted {
            if $0.port != $1.port { return $0.port < $1.port }
            let leftLoopback = ["127.0.0.1", "::1", "localhost"].contains($0.bindAddress)
            let rightLoopback = ["127.0.0.1", "::1", "localhost"].contains($1.bindAddress)
            if leftLoopback != rightLoopback { return leftLoopback }
            if ($0.process != nil) != ($1.process != nil) { return $0.process != nil }
            if $0.bindAddress != $1.bindAddress { return $0.bindAddress < $1.bindAddress }
            return ($0.process ?? "") < ($1.process ?? "")
        }.filter { seen.insert($0.port).inserted }
    }

    private static func endpoint(_ value: String, separator: Character, process: String?) -> ArtifactsListeningPort? {
        guard let index = value.lastIndex(of: separator),
              let port = UInt16(value[value.index(after: index)...]), port > 0 else { return nil }
        var bind = String(value[..<index])
        if bind.hasPrefix("["), bind.hasSuffix("]") { bind = String(bind.dropFirst().dropLast()) }
        // ss can annotate an interface (127.0.0.53%lo:53).
        if let scope = bind.firstIndex(of: "%") { bind = String(bind[..<scope]) }
        guard !bind.isEmpty else { return nil }
        return .init(port: port, bindAddress: bind, process: process)
    }

    private static func ssProcess(_ line: String) -> String? {
        guard let start = line.range(of: "users:((\"") else { return nil }
        let tail = line[start.upperBound...]
        guard let end = tail.firstIndex(of: "\"") else { return nil }
        return String(tail[..<end])
    }
}
