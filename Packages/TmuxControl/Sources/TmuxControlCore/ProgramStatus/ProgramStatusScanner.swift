public enum ProgramStatusScanEvent: Equatable, Sendable {
    case sequence(ProgramStatusSequence)
    case promptStart
    case reset
}

/// Retains only candidate protocol OSCs, so unrelated titles and images cannot
/// grow the buffer. Normal terminal redraws use a single pointer skip loop.
public struct ProgramStatusScanner: Sendable {
    private enum State: Sendable {
        case normal, escape, osc, oscEscape, skip, skipEscape
    }

    private var state: State = .normal
    private var buffer: [UInt8] = []
    private static let statusPrefix: [UInt8] = Array("7501;".utf8)
    private static let promptPrefix: [UInt8] = Array("133;".utf8)

    public init() {}

    // The monitor can bypass a mutable dictionary access for plain output,
    // including when its value storage is shared through copy-on-write.
    var isInNormalState: Bool { state == .normal }

    public mutating func reset() {
        state = .normal
        buffer.removeAll(keepingCapacity: true)
    }

    public mutating func feed(_ bytes: [UInt8]) -> [ProgramStatusScanEvent] {
        feed(bytes[...])
    }

    public mutating func feed(_ bytes: ArraySlice<UInt8>) -> [ProgramStatusScanEvent] {
        var events: [ProgramStatusScanEvent] = []
        bytes.withUnsafeBufferPointer { bytes in
            var index = 0
            while index < bytes.count {
                let byte = bytes[index]
                switch state {
                case .normal:
                    while index < bytes.count && bytes[index] != 0x1B { index += 1 }
                    if index < bytes.count { state = .escape; index += 1 }
                    continue
                case .escape:
                    consumeEscape(byte, events: &events)
                case .osc, .skip:
                    if byte == 0x07 {
                        finish(events: &events)
                    } else if byte == 0x18 || byte == 0x1A {
                        reset()
                    } else if byte == 0x1B {
                        state = state == .osc ? .oscEscape : .skipEscape
                    } else if state == .osc {
                        buffer.append(byte)
                        if buffer.count + 3 > 4096 || !isCandidate {
                            buffer.removeAll(keepingCapacity: true)
                            state = .skip
                        }
                    }
                case .oscEscape, .skipEscape:
                    if byte == 0x5C {
                        finish(events: &events)
                    } else {
                        // The pending ESC aborts the old OSC and is also the
                        // opener of a replacement escape, including RIS.
                        buffer.removeAll(keepingCapacity: true)
                        consumeEscape(byte, events: &events)
                    }
                }
                index += 1
            }
        }
        return events
    }

    private var isCandidate: Bool {
        matches(Self.statusPrefix) || matches(Self.promptPrefix)
    }

    private func matches(_ prefix: [UInt8]) -> Bool {
        buffer.count >= prefix.count ? buffer.starts(with: prefix) : prefix.starts(with: buffer)
    }

    private mutating func consumeEscape(_ byte: UInt8, events: inout [ProgramStatusScanEvent]) {
        switch byte {
        case 0x5D:
            buffer.removeAll(keepingCapacity: true)
            state = .osc
        case 0x1B: state = .escape
        case 0x63:
            state = .normal
            events.append(.reset)
        default: state = .normal
        }
    }

    private mutating func finish(events: inout [ProgramStatusScanEvent]) {
        // The opener and the actual terminator belong to the sequence limit.
        let terminatorCount = state == .oscEscape ? 2 : 1
        if (state == .osc || state == .oscEscape), buffer.count + 2 + terminatorCount <= 4096 {
            if buffer.starts(with: Self.statusPrefix),
               let sequence = ProgramStatusParser.parse(body: buffer.dropFirst(5)) {
                events.append(.sequence(sequence))
            } else if buffer.starts(with: Self.promptPrefix), buffer.count >= 5,
                      buffer[4] == 0x41, buffer.count == 5 || buffer[5] == 0x3B {
                events.append(.promptStart)
            }
        }
        reset()
    }
}
