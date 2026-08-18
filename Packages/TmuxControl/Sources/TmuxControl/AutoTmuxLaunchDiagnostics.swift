import Foundation

/// Privacy-safe description of what a host said while a tmux launch was
/// still waiting for control mode.
///
/// The diagnostics file is meant to be sent to a developer, so it redacts
/// raw terminal text — which is correct (output can contain secrets) but
/// left "stuck at starting tmux" reports undiagnosable: all that survived
/// was chunk sizes. This classifier derives facts that cannot carry user
/// data instead: structural markers we emitted or requested ourselves, and
/// a fixed vocabulary of tmux/shell failure strings. Nothing from the
/// chunk is ever echoed back into the log.
public enum AutoTmuxLaunchDiagnostics {

    /// Known remote failures, each a literal tmux or shell message. The
    /// needle list is ours, so reporting which one matched leaks nothing.
    public enum Marker: String, CaseIterable, Sendable {
        case noServerRunning = "no server running"
        case nestedSession = "sessions should be nested"
        case protocolMismatch = "protocol version mismatch"
        case openTerminalFailed = "open terminal failed"
        case unsuitableTerminal = "missing or unsuitable terminal"
        case notATerminal = "not a terminal"
        case sessionNotFound = "can't find session"
        case duplicateSession = "duplicate session"
        case lostServer = "lost server"
        case serverExited = "server exited unexpectedly"
        case configError = "config-error"
        case unknownOption = "invalid option"
        case commandNotFound = "command not found"
        case permissionDenied = "permission denied"
        case noSuchFile = "no such file or directory"
        case noSpace = "no space left on device"
        case connectionRefused = "connection refused"
    }

    /// Structural facts about a pre-control-mode chunk.
    public struct Shape: Equatable, Sendable {
        /// tmux's control-mode prologue (`ESC P 1 0 0 0 p`).
        public var hasControlPrologue = false
        /// Any DCS introducer, even without the tmux prologue.
        public var hasDCS = false
        /// Alt-screen enter — something full-screen took the terminal.
        public var entersAltScreen = false
        /// The host echoed our own launch command back at us.
        public var echoesLaunchCommand = false
        /// Bracketed-paste enable, i.e. an interactive shell drew a prompt.
        /// Logged as `bracketedPaste` because `DiagnosticLogStore` redacts
        /// any `prompt=` field as potentially user-bearing.
        public var hasShellPromptMarker = false
        public var printableCount = 0
        public var controlCount = 0
        public var markers: [Marker] = []

        /// Compact `key=value` rendering for one log line.
        public var logDescription: String {
            var fields = [
                "prologue=\(hasControlPrologue ? 1 : 0)",
                "dcs=\(hasDCS ? 1 : 0)",
                "alt=\(entersAltScreen ? 1 : 0)",
                "echo=\(echoesLaunchCommand ? 1 : 0)",
                "bracketedPaste=\(hasShellPromptMarker ? 1 : 0)",
                "printable=\(printableCount)",
                "control=\(controlCount)",
            ]
            if !markers.isEmpty {
                fields.append("markers=\(markers.map(\.logName).joined(separator: "|"))")
            }
            return fields.joined(separator: " ")
        }
    }

    /// Classify one output chunk.
    ///
    /// `launchCommand` is the exact one-liner we wrote, used only to
    /// recognise the host echoing it back; no part of it is logged.
    public static func classify(
        chunk: [UInt8],
        launchCommand: String?
    ) -> Shape {
        var shape = Shape()
        for byte in chunk {
            // DEL and C0 controls except tab/newline/carriage return.
            if byte < 0x20 && byte != 0x09 && byte != 0x0A && byte != 0x0D || byte == 0x7F {
                shape.controlCount += 1
            } else {
                shape.printableCount += 1
            }
        }

        shape.hasControlPrologue = contains(chunk, Array("\u{1B}P1000p".utf8))
        shape.hasDCS = shape.hasControlPrologue || contains(chunk, Array("\u{1B}P".utf8))
        shape.entersAltScreen = contains(chunk, Array("\u{1B}[?1049h".utf8))
        shape.hasShellPromptMarker = contains(chunk, Array("\u{1B}[?2004h".utf8))

        let lowercased = String(decoding: chunk, as: UTF8.self).lowercased()
        if let launchCommand {
            // The echo is recognised by a distinctive fragment rather than
            // the whole line, which arrives split across chunks.
            let fragment = "tessera_no_tmux"
            shape.echoesLaunchCommand = lowercased.contains(fragment)
                || (launchCommand.count > 24 && lowercased.contains("command -v tmux"))
        }
        shape.markers = Marker.allCases.filter { lowercased.contains($0.rawValue) }

        return shape
    }

    private static func contains(_ haystack: [UInt8], _ needle: [UInt8]) -> Bool {
        AutoTmuxScript.contains(needle, in: haystack)
    }
}

extension AutoTmuxLaunchDiagnostics.Marker {
    /// Stable short name for logs — never the raw message.
    public var logName: String {
        switch self {
        case .noServerRunning:    return "no-server"
        case .nestedSession:      return "nested"
        case .protocolMismatch:   return "protocol-mismatch"
        case .openTerminalFailed: return "open-terminal-failed"
        case .unsuitableTerminal: return "unsuitable-terminal"
        case .notATerminal:       return "not-a-terminal"
        case .sessionNotFound:    return "session-not-found"
        case .duplicateSession:   return "duplicate-session"
        case .lostServer:         return "lost-server"
        case .serverExited:       return "server-exited"
        case .configError:        return "config-error"
        case .unknownOption:      return "invalid-option"
        case .commandNotFound:    return "command-not-found"
        case .permissionDenied:   return "permission-denied"
        case .noSuchFile:         return "no-such-file"
        case .noSpace:            return "no-space"
        case .connectionRefused:  return "connection-refused"
        }
    }
}
