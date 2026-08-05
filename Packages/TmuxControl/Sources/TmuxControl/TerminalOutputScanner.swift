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
///
/// Recognition is deliberately 7-bit only (`ESC ]`, never C1 0x9D): 0x9D is
/// also the trailing byte of a curly quote (E2 80 9D), so treating it as an
/// OSC opener let ordinary prose open a phantom OSC that swallowed real
/// bells and could synthesize a title event from prose.
///
/// Hot path: this runs over every decoded output byte — once in the parser
/// for bells and once in the controller for titles — so the normal-state
/// scan is a raw-pointer skip loop and OSC accumulation lives in a stored
/// buffer. The previous shape (per-byte `for` loop with the buffer carried
/// as an enum payload) re-wrapped the payload on every byte, which measured
/// multiple microseconds per byte in Debug builds and starved the render
/// loop during TUI redraw storms.
struct TerminalOutputScanner: Sendable {
    private enum State: Sendable {
        case normal
        case escape
        case osc
        case oscEscape
    }

    private var state: State = .normal
    private var oscBuffer: [UInt8] = []
    private let maxOSCBytes = 4096

    mutating func reset() {
        state = .normal
        oscBuffer.removeAll(keepingCapacity: true)
    }

    mutating func feed(_ bytes: [UInt8]) -> TerminalOutputEvents {
        var events = TerminalOutputEvents()
        bytes.withUnsafeBufferPointer { buffer in
            var i = 0
            let count = buffer.count
            while i < count {
                let byte = buffer[i]
                switch state {
                case .normal:
                    if byte == 0x07 {
                        events.audibleBell = true
                        i += 1
                    } else if byte == 0x1B {
                        state = .escape
                        i += 1
                    } else {
                        // Printable run — skip without per-byte state churn.
                        i += 1
                        while i < count {
                            let b = buffer[i]
                            if b == 0x07 || b == 0x1B { break }
                            i += 1
                        }
                    }

                case .escape:
                    if byte == 0x5D { // ]
                        beginOSC()
                    } else if byte == 0x1B {
                        // stay in escape
                    } else {
                        state = .normal
                        if byte == 0x07 {
                            events.audibleBell = true
                        }
                    }
                    i += 1

                case .osc:
                    if byte == 0x07 {
                        finishOSC(events: &events)
                        i += 1
                    } else if byte == 0x1B {
                        state = .oscEscape
                        i += 1
                    } else {
                        // Payload run — append in one go.
                        let runStart = i
                        i += 1
                        while i < count {
                            let b = buffer[i]
                            if b == 0x07 || b == 0x1B { break }
                            i += 1
                        }
                        oscBuffer.append(
                            contentsOf: UnsafeBufferPointer(rebasing: buffer[runStart..<i])
                        )
                        if oscBuffer.count > maxOSCBytes {
                            abandonOSC()
                        }
                    }

                case .oscEscape:
                    if byte == 0x5C { // ST: ESC \
                        finishOSC(events: &events)
                    } else {
                        oscBuffer.append(0x1B)
                        if byte == 0x1B {
                            if oscBuffer.count > maxOSCBytes {
                                abandonOSC()
                            }
                            // else stay in oscEscape
                        } else if byte == 0x07 {
                            finishOSC(events: &events)
                        } else {
                            oscBuffer.append(byte)
                            if oscBuffer.count > maxOSCBytes {
                                abandonOSC()
                            } else {
                                state = .osc
                            }
                        }
                    }
                    i += 1
                }
            }
        }
        return events
    }

    private mutating func beginOSC() {
        state = .osc
        oscBuffer.removeAll(keepingCapacity: true)
    }

    private mutating func abandonOSC() {
        state = .normal
        oscBuffer.removeAll(keepingCapacity: true)
    }

    private mutating func finishOSC(events: inout TerminalOutputEvents) {
        defer {
            state = .normal
            oscBuffer.removeAll(keepingCapacity: true)
        }
        guard let semicolon = oscBuffer.firstIndex(of: 0x3B),
              let command = Int(String(decoding: oscBuffer[..<semicolon], as: UTF8.self)),
              command == 0 || command == 1 || command == 2
        else { return }

        let titleStart = oscBuffer.index(after: semicolon)
        let title = String(decoding: oscBuffer[titleStart...], as: UTF8.self)
        events.titleEvents.append(.init(command: command, title: title))
    }
}
