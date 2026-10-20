/// Keys whose terminal byte sequences are independent of a UI framework.
public enum TerminalKey: String, CaseIterable, Codable, Sendable {
    case escape
    case controlJ
    case controlC
    case controlL
    /// Carriage return — what a terminal's Return key sends. Distinct from
    /// `controlJ`, which is the line feed a shell only sometimes treats the
    /// same way.
    case enter
    case tab
    case left
    case down
    case up
    case right
    case home
    case end
    case pageUp
    case pageDown
    case f1
    case f2
    case f3
    case f4
    case f5
    case f6
    case f7
    case f8
    case f9
    case f10
    case f11
    case f12
    case pipe
    case tilde
    case slash
    case backslash
    case dollar
    case leftBrace
    case rightBrace
    case leftBracket
    case rightBracket
    case lessThan
    case greaterThan
}

public struct TerminalKeyMode: Equatable, Hashable, Codable, Sendable {
    public var applicationCursorKeys: Bool

    public init(applicationCursorKeys: Bool = false) {
        self.applicationCursorKeys = applicationCursorKeys
    }
}

public enum TerminalKeySequenceEncoder {
    public static func encode(
        _ key: TerminalKey,
        modifiers: TerminalModifiers = .none,
        mode: TerminalKeyMode = .init()
    ) -> [UInt8] {
        switch key {
        case .escape:
            return [0x1B]
        case .controlJ:
            return [0x0A]
        case .controlC:
            return [0x03]
        case .controlL:
            return [0x0C]
        case .enter:
            // Alt+Return is meta-Return, the one modifier a terminal encodes
            // for this key; Ctrl and Shift leave a bare CR, as xterm does
            // without modifyOtherKeys.
            return modifiers.alternate ? [0x1B, 0x0D] : [0x0D]
        case .tab:
            return modifiers.shift ? [0x1B, 0x5B, 0x5A] : [0x09]
        case .left, .down, .up, .right:
            return encodeArrow(key, modifiers: modifiers, mode: mode)
        case .home, .end:
            return encodeHomeEnd(key, modifiers: modifiers, mode: mode)
        case .pageUp, .pageDown:
            return encodePage(key, modifiers: modifiers)
        case .f1, .f2, .f3, .f4:
            return encodeLowFunctionKey(key, modifiers: modifiers)
        case .f5, .f6, .f7, .f8, .f9, .f10, .f11, .f12:
            return encodeTildeFunctionKey(key, modifiers: modifiers)
        case .pipe, .tilde, .slash, .backslash, .dollar,
             .leftBrace, .rightBrace, .leftBracket, .rightBracket,
             .lessThan, .greaterThan:
            return encodeSymbol(key, modifiers: modifiers)
        }
    }

    private static func encodeArrow(
        _ key: TerminalKey,
        modifiers: TerminalModifiers,
        mode: TerminalKeyMode
    ) -> [UInt8] {
        let final = arrowFinalByte(for: key)
        if modifiers.hasTerminalModifier {
            return csiModified(prefix: [0x31], modifiers: modifiers, final: final)
        }
        return [0x1B, mode.applicationCursorKeys ? 0x4F : 0x5B, final]
    }

    private static func encodeHomeEnd(
        _ key: TerminalKey,
        modifiers: TerminalModifiers,
        mode: TerminalKeyMode
    ) -> [UInt8] {
        let final: UInt8 = key == .home ? 0x48 : 0x46
        if modifiers.hasTerminalModifier {
            return csiModified(prefix: [0x31], modifiers: modifiers, final: final)
        }
        return [0x1B, mode.applicationCursorKeys ? 0x4F : 0x5B, final]
    }

    private static func encodePage(
        _ key: TerminalKey,
        modifiers: TerminalModifiers
    ) -> [UInt8] {
        let pageDigit: UInt8 = key == .pageUp ? 0x35 : 0x36
        if modifiers.hasTerminalModifier {
            return [0x1B, 0x5B, pageDigit, 0x3B]
                + asciiDigits(for: modifiers.xtermParameter)
                + [0x7E]
        }
        return [0x1B, 0x5B, pageDigit, 0x7E]
    }

    private static func encodeLowFunctionKey(
        _ key: TerminalKey,
        modifiers: TerminalModifiers
    ) -> [UInt8] {
        let final = lowFunctionFinalByte(for: key)
        if modifiers.hasTerminalModifier {
            return csiModified(prefix: [0x31], modifiers: modifiers, final: final)
        }
        return [0x1B, 0x4F, final]
    }

    private static func encodeTildeFunctionKey(
        _ key: TerminalKey,
        modifiers: TerminalModifiers
    ) -> [UInt8] {
        var bytes: [UInt8] = [0x1B, 0x5B]
        bytes.append(contentsOf: asciiDigits(for: tildeFunctionNumber(for: key)))
        if modifiers.hasTerminalModifier {
            bytes.append(0x3B)
            bytes.append(contentsOf: asciiDigits(for: modifiers.xtermParameter))
        }
        bytes.append(0x7E)
        return bytes
    }

    private static func encodeSymbol(
        _ key: TerminalKey,
        modifiers: TerminalModifiers
    ) -> [UInt8] {
        let bare = symbolByte(for: key)
        let symbol: [UInt8]
        if modifiers.control {
            switch key {
            case .leftBracket: symbol = [0x1B]
            case .backslash: symbol = [0x1C]
            case .rightBracket: symbol = [0x1D]
            default: symbol = [bare]
            }
        } else {
            symbol = [bare]
        }
        return modifiers.alternate ? [0x1B] + symbol : symbol
    }

    private static func csiModified(
        prefix: [UInt8],
        modifiers: TerminalModifiers,
        final: UInt8
    ) -> [UInt8] {
        [0x1B, 0x5B] + prefix + [0x3B]
            + asciiDigits(for: modifiers.xtermParameter)
            + [final]
    }

    private static func asciiDigits(for number: Int) -> [UInt8] {
        Array(String(number).utf8)
    }

    private static func arrowFinalByte(for key: TerminalKey) -> UInt8 {
        switch key {
        case .left: 0x44
        case .down: 0x42
        case .up: 0x41
        case .right: 0x43
        default: preconditionFailure("expected arrow key")
        }
    }

    private static func lowFunctionFinalByte(for key: TerminalKey) -> UInt8 {
        switch key {
        case .f1: 0x50
        case .f2: 0x51
        case .f3: 0x52
        case .f4: 0x53
        default: preconditionFailure("expected F1-F4 key")
        }
    }

    private static func tildeFunctionNumber(for key: TerminalKey) -> Int {
        switch key {
        case .f5: 15
        case .f6: 17
        case .f7: 18
        case .f8: 19
        case .f9: 20
        case .f10: 21
        case .f11: 23
        case .f12: 24
        default: preconditionFailure("expected F5-F12 key")
        }
    }

    private static func symbolByte(for key: TerminalKey) -> UInt8 {
        switch key {
        case .pipe: 0x7C
        case .tilde: 0x7E
        case .slash: 0x2F
        case .backslash: 0x5C
        case .dollar: 0x24
        case .leftBrace: 0x7B
        case .rightBrace: 0x7D
        case .leftBracket: 0x5B
        case .rightBracket: 0x5D
        case .lessThan: 0x3C
        case .greaterThan: 0x3E
        default: preconditionFailure("expected symbol key")
        }
    }
}

/// Applies one-shot terminal modifiers to a single software-keyboard event.
public enum TerminalSoftwareModifierEncoder {
    /// Paste and composed-Unicode commits pass through and leave one-shot
    /// modifiers armed; only a one-byte key event is eligible.
    public static func encodeNextKey(
        _ bytes: [UInt8],
        modifiers: TerminalModifiers
    ) -> [UInt8]? {
        guard bytes.count == 1, modifiers.hasTerminalModifier else { return nil }
        return encode(bytes, modifiers: modifiers)
    }

    public static func encode(
        _ bytes: [UInt8],
        modifiers: TerminalModifiers
    ) -> [UInt8] {
        guard !bytes.isEmpty, modifiers.hasTerminalModifier else { return bytes }

        var transformed = bytes
        if transformed.count == 1 {
            var byte = transformed[0]

            if modifiers.shift {
                switch byte {
                case 0x61...0x7A: byte -= 0x20
                case 0x31: byte = 0x21
                case 0x32: byte = 0x40
                case 0x33: byte = 0x23
                case 0x34: byte = 0x24
                case 0x35: byte = 0x25
                case 0x36: byte = 0x5E
                case 0x37: byte = 0x26
                case 0x38: byte = 0x2A
                case 0x39: byte = 0x28
                case 0x30: byte = 0x29
                case 0x2D: byte = 0x5F
                case 0x3D: byte = 0x2B
                case 0x5B: byte = 0x7B
                case 0x5D: byte = 0x7D
                case 0x5C: byte = 0x7C
                case 0x3B: byte = 0x3A
                case 0x27: byte = 0x22
                case 0x2C: byte = 0x3C
                case 0x2E: byte = 0x3E
                case 0x2F: byte = 0x3F
                case 0x60: byte = 0x7E
                default: break
                }
            }

            if modifiers.control {
                switch byte {
                case 0x40, 0x20: byte = 0x00
                case 0x41...0x5F: byte &= 0x1F
                case 0x61...0x7A: byte &= 0x1F
                case 0x3F: byte = 0x7F
                default: break
                }
            }

            transformed[0] = byte
        }

        if modifiers.alternate {
            transformed.insert(0x1B, at: 0)
        }
        return transformed
    }
}
