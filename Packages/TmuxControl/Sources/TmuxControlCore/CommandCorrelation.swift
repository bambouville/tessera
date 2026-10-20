public struct TmuxCommandGuard: Equatable, Sendable {
    public let time: Int
    public let commandNumber: Int
    public let flags: Int

    public init(time: Int, commandNumber: Int, flags: Int) {
        self.time = time
        self.commandNumber = commandNumber
        self.flags = flags
    }
}

public enum TmuxCommandFrameStatus: String, Equatable, Sendable {
    case success
    case error
}

public struct TmuxCommandFrame: Equatable, Sendable {
    public let status: TmuxCommandFrameStatus
    public let begin: TmuxCommandGuard?
    public let end: TmuxCommandGuard
    public let effectiveFlags: Int
    public let guardMatches: Bool
    public let lines: [String]

    public var isClientResponse: Bool { effectiveFlags >= 0 && effectiveFlags & 1 == 1 }

    public init(
        status: TmuxCommandFrameStatus,
        begin: TmuxCommandGuard?,
        end: TmuxCommandGuard,
        effectiveFlags: Int,
        guardMatches: Bool,
        lines: [String]
    ) {
        self.status = status
        self.begin = begin
        self.end = end
        self.effectiveFlags = effectiveFlags
        self.guardMatches = guardMatches
        self.lines = lines
    }
}

public enum TmuxCorrelationEvent: Equatable, Sendable {
    case frameStarted(current: TmuxCommandGuard, discarded: TmuxCommandGuard?, discardedLineCount: Int)
    case frameCompleted(TmuxCommandFrame)
}

/// Pure FIFO-independent response-framing seam. It classifies server frames
/// versus client command replies from the opening guard, preserves body lines,
/// and reports torn/mismatched guards deterministically.
public struct TmuxCommandResponseCorrelator: Sendable {
    private var openGuard: TmuxCommandGuard?
    private var lines: [String] = []

    public init() {}

    public mutating func reset() {
        openGuard = nil
        lines.removeAll(keepingCapacity: true)
    }

    public mutating func consume(_ message: TmuxMessage) -> TmuxCorrelationEvent? {
        switch message {
        case .begin(let time, let number, let flags):
            let next = TmuxCommandGuard(time: time, commandNumber: number, flags: flags)
            let discarded = openGuard
            let discardedLineCount = lines.count
            openGuard = next
            lines.removeAll(keepingCapacity: true)
            return .frameStarted(
                current: next,
                discarded: discarded,
                discardedLineCount: discardedLineCount
            )
        case .commandOutputLine(let line):
            lines.append(line)
            return nil
        case .end(let time, let number, let flags):
            return finish(.success, end: .init(time: time, commandNumber: number, flags: flags))
        case .error(let time, let number, let flags):
            return finish(.error, end: .init(time: time, commandNumber: number, flags: flags))
        default:
            return nil
        }
    }

    private mutating func finish(
        _ status: TmuxCommandFrameStatus,
        end: TmuxCommandGuard
    ) -> TmuxCorrelationEvent {
        let begin = openGuard
        let body = lines
        openGuard = nil
        lines.removeAll(keepingCapacity: true)
        let effectiveFlags: Int
        if let begin {
            if begin.flags >= 0 {
                // A real server frame must never consume a client reply slot,
                // even if its closing flags disagree.
                effectiveFlags = begin.flags
            } else if begin.time >= 0, begin.commandNumber >= 0,
                      begin.time == end.time, begin.commandNumber == end.commandNumber,
                      end.flags >= 0 {
                // Repair only an invalid opening classification with a valid
                // close for the exact same frame, never a different command.
                effectiveFlags = end.flags
            } else {
                effectiveFlags = -1
            }
        } else {
            effectiveFlags = end.flags
        }
        return .frameCompleted(.init(
            status: status,
            begin: begin,
            end: end,
            effectiveFlags: effectiveFlags,
            guardMatches: begin == end,
            lines: body
        ))
    }
}
