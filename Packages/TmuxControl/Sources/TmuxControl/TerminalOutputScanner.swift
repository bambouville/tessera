import Foundation

struct TerminalTitleEvent: Equatable, Sendable {
    let command: Int
    let title: String
}

struct TerminalOutputEvents: Equatable, Sendable {
    var audibleBell = false
    var titleEvents: [TerminalTitleEvent] = []
}

/// Scans decoded terminal output for side effects that are not ordinary
/// printable bytes. It keeps OSC state across `%output` chunks so BEL
/// terminators inside OSC strings do not look like audible bells.
struct TerminalOutputScanner: Sendable {
    private enum State: Sendable {
        case normal
        case escape
        case osc([UInt8])
        case oscEscape([UInt8])
    }

    private var state: State = .normal
    private let maxOSCBytes = 4096

    mutating func reset() {
        state = .normal
    }

    mutating func feed(_ bytes: [UInt8]) -> TerminalOutputEvents {
        var events = TerminalOutputEvents()

        for byte in bytes {
            switch state {
            case .normal:
                handleNormal(byte, events: &events)

            case .escape:
                if byte == 0x5D { // ]
                    state = .osc([])
                } else if byte == 0x1B {
                    state = .escape
                } else {
                    state = .normal
                    if byte == 0x07 {
                        events.audibleBell = true
                    }
                }

            case .osc(var buffer):
                if byte == 0x07 {
                    finishOSC(buffer, events: &events)
                    state = .normal
                } else if byte == 0x1B {
                    state = .oscEscape(buffer)
                } else {
                    buffer.append(byte)
                    state = buffer.count <= maxOSCBytes ? .osc(buffer) : .normal
                }

            case .oscEscape(var buffer):
                if byte == 0x5C { // ST: ESC \
                    finishOSC(buffer, events: &events)
                    state = .normal
                } else {
                    buffer.append(0x1B)
                    if byte == 0x1B {
                        state = buffer.count <= maxOSCBytes ? .oscEscape(buffer) : .normal
                    } else if byte == 0x07 {
                        finishOSC(buffer, events: &events)
                        state = .normal
                    } else {
                        buffer.append(byte)
                        state = buffer.count <= maxOSCBytes ? .osc(buffer) : .normal
                    }
                }
            }
        }

        return events
    }

    private mutating func handleNormal(
        _ byte: UInt8,
        events: inout TerminalOutputEvents
    ) {
        if byte == 0x07 {
            events.audibleBell = true
        } else if byte == 0x1B {
            state = .escape
        } else if byte == 0x9D {
            state = .osc([])
        } else {
            state = .normal
        }
    }

    private func finishOSC(
        _ buffer: [UInt8],
        events: inout TerminalOutputEvents
    ) {
        guard let semicolon = buffer.firstIndex(of: 0x3B),
              let command = Int(String(decoding: buffer[..<semicolon], as: UTF8.self)),
              command == 0 || command == 1 || command == 2
        else { return }

        let titleStart = buffer.index(after: semicolon)
        let title = String(decoding: buffer[titleStart...], as: UTF8.self)
        events.titleEvents.append(.init(command: command, title: title))
    }
}
