import Foundation

/// Keeps a live CSI/ESC instruction atomic across a synthetic capture repaint.
/// Printable bytes leave immediately. Only an unfinished control prefix is
/// retained, per pane, even while the ledger gates pre-capture output.
public struct TmuxLiveOutputFramer: Sendable {
    private enum State: Sendable { case ground, escape, csi, string, discardCSI }
    private var state = State.ground
    private var pending: [UInt8] = []
    private var utf8Remaining = 0
    public var isGround: Bool { state == .ground && utf8Remaining == 0 }
    public init() {}

    /// The Apple renderer cooperatively slices live output. Extend its
    /// nominal slice through a CSI final byte so a yielded repaint cannot
    /// separate a prefix which has already left this framer from its suffix.
    public static func chunkEnd(in bytes: ArraySlice<UInt8>, from start: Int, maximumCount: Int) -> Int {
        let nominalEnd = min(bytes.endIndex, start + max(1, maximumCount))
        var mode = 0 // ground, ESC/intermediate, CSI
        var utf8 = 0
        var index = start
        while index < bytes.endIndex {
            let byte = bytes[index]
            if byte == 0x1B { mode = 1; utf8 = 0 }
            else if mode == 1 {
                if byte == 0x18 || byte == 0x1A { mode = 0 }
                else if byte < 0x20 || byte == 0x7F { /* execute/ignore without leaving ESC */ }
                else if byte == 0x5B { mode = 2 }
                else if !(0x20...0x2F).contains(byte) { mode = 0 }
            } else if mode == 2 {
                if (0x40...0x7E).contains(byte) || byte == 0x18 || byte == 0x1A { mode = 0 }
            } else if utf8 > 0 && byte & 0xC0 == 0x80 { utf8 -= 1 }
            else if byte == 0x9B { mode = 2 }
            else {
                utf8 = byte >= 0xC2 && byte <= 0xDF ? 1
                    : byte >= 0xE0 && byte <= 0xEF ? 2
                    : byte >= 0xF0 && byte <= 0xF4 ? 3 : 0
            }
            index += 1
            if index >= nominalEnd && mode == 0 && utf8 == 0 { return index }
        }
        return bytes.endIndex
    }

    public mutating func process(_ bytes: [UInt8]) -> [UInt8] {
        if isGround && !bytes.contains(where: { $0 == 0x1B || $0 >= 0x80 }) { return bytes }
        var output: [UInt8] = []
        output.reserveCapacity(bytes.count + pending.count)
        for byte in bytes {
            switch state {
            case .ground:
                if utf8Remaining > 0 && byte & 0xC0 == 0x80 {
                    utf8Remaining -= 1
                    output.append(byte)
                } else if byte == 0x1B {
                    utf8Remaining = 0
                    pending = [byte]
                    state = .escape
                } else if byte == 0x9B {
                    pending = [byte]
                    state = .csi
                } else {
                    utf8Remaining = byte >= 0xC2 && byte <= 0xDF ? 1
                        : byte >= 0xE0 && byte <= 0xEF ? 2
                        : byte >= 0xF0 && byte <= 0xF4 ? 3 : 0
                    output.append(byte)
                }
            case .escape:
                if byte == 0x1B { pending = [byte]; continue }
                if byte == 0x18 || byte == 0x1A {
                    pending.removeAll(keepingCapacity: true)
                    output.append(byte); state = .ground
                    continue
                }
                pending.append(byte)
                if byte < 0x20 || byte == 0x7F {
                    if pending.count > 4096 {
                        pending.removeAll(keepingCapacity: true)
                        state = .discardCSI
                    }
                    continue
                }
                if byte == 0x5B { state = .csi }
                else if [0x5D, 0x50, 0x5F, 0x5E, 0x58].contains(byte) {
                    // String payloads (including images) stream without a
                    // size-dependent reserve. Embedded CSI text stays opaque.
                    output += pending; pending.removeAll(keepingCapacity: true)
                    state = .string
                } else if !(0x20...0x2F).contains(byte) {
                    output += pending; pending.removeAll(keepingCapacity: true)
                    state = .ground
                }
            case .csi:
                if byte == 0x1B {
                    pending = [byte]; state = .escape
                } else if byte == 0x18 || byte == 0x1A {
                    pending.removeAll(keepingCapacity: true)
                    output.append(byte); state = .ground
                } else {
                    pending.append(byte)
                    if (0x40...0x7E).contains(byte) {
                        output += pending; pending.removeAll(keepingCapacity: true)
                        state = .ground
                    }
                }
            case .string:
                if utf8Remaining > 0 && byte & 0xC0 == 0x80 {
                    utf8Remaining -= 1
                    output.append(byte)
                } else if byte == 0x1B {
                    // ESC terminates/cancels the string and starts a new
                    // instruction, including ESC \ or a replacement CSI.
                    utf8Remaining = 0
                    pending = [byte]
                    state = .escape
                } else {
                    output.append(byte)
                    if [0x07, 0x18, 0x1A, 0x9C].contains(byte) { state = .ground }
                    utf8Remaining = byte >= 0xC2 && byte <= 0xDF ? 1
                        : byte >= 0xE0 && byte <= 0xEF ? 2
                        : byte >= 0xF0 && byte <= 0xF4 ? 3 : 0
                }
            case .discardCSI:
                if byte == 0x1B { pending = [byte]; state = .escape }
                else if (0x40...0x7E).contains(byte) || byte == 0x18 || byte == 0x1A { state = .ground }
            }
            // Malformed unbounded parameter strings must not retain memory
            // forever or turn their numeric suffix into printable output.
            if pending.count > 4096 {
                pending.removeAll(keepingCapacity: true)
                state = .discardCSI
            }
        }
        return output
    }
}
