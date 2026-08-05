struct ArmedModifiers: Equatable {
    var ctrl: Bool = false
    var alt: Bool = false
    var shift: Bool = false

    static let none = ArmedModifiers()

    var isAny: Bool {
        ctrl || alt || shift
    }
}

enum AccessoryChipEncoder {
    static func encode(
        _ chip: AccessoryChip,
        armed: ArmedModifiers,
        applicationCursor: Bool
    ) -> [UInt8] {
        switch chip {
        case .ctrl, .alt, .shift:
            precondition(false, "modifiers should be routed through ModifierState, not the encoder")
            return []
        case .esc:
            return [0x1B]
        case .ctrlJ:
            return [0x0A]
        case .tab:
            return armed.shift ? [0x1B, 0x5B, 0x5A] : [0x09]
        case .left, .down, .up, .right:
            return encodeArrow(chip, armed: armed, applicationCursor: applicationCursor)
        case .home, .end:
            return encodeHomeEnd(chip, armed: armed, applicationCursor: applicationCursor)
        case .pgup, .pgdn:
            return encodePage(chip, armed: armed)
        case .f1, .f2, .f3, .f4:
            return encodeLowFunctionKey(chip, armed: armed)
        case .f5, .f6, .f7, .f8, .f9, .f10, .f11, .f12:
            return encodeTildeFunctionKey(chip, armed: armed)
        case .pipe, .tilde, .slash, .backslash, .dollar, .lbrace, .rbrace, .lbracket, .rbracket, .lt, .gt:
            return encodeSymbol(chip, armed: armed)
        }
    }

    private static func encodeArrow(
        _ chip: AccessoryChip,
        armed: ArmedModifiers,
        applicationCursor: Bool
    ) -> [UInt8] {
        let finalByte = arrowFinalByte(for: chip)

        if armed.isAny {
            return csiModified(prefix: [0x31], modifier: modifierDigit(for: armed), final: finalByte)
        }

        return [0x1B, applicationCursor ? 0x4F : 0x5B, finalByte]
    }

    private static func encodeHomeEnd(
        _ chip: AccessoryChip,
        armed: ArmedModifiers,
        applicationCursor: Bool
    ) -> [UInt8] {
        let finalByte: UInt8 = chip == .home ? 0x48 : 0x46

        if armed.isAny {
            return csiModified(prefix: [0x31], modifier: modifierDigit(for: armed), final: finalByte)
        }

        return [0x1B, applicationCursor ? 0x4F : 0x5B, finalByte]
    }

    private static func encodePage(_ chip: AccessoryChip, armed: ArmedModifiers) -> [UInt8] {
        let pageDigit: UInt8 = chip == .pgup ? 0x35 : 0x36

        if armed.isAny {
            return [0x1B, 0x5B, pageDigit, 0x3B, modifierDigit(for: armed), 0x7E]
        }

        return [0x1B, 0x5B, pageDigit, 0x7E]
    }

    private static func encodeLowFunctionKey(_ chip: AccessoryChip, armed: ArmedModifiers) -> [UInt8] {
        let finalByte = lowFunctionFinalByte(for: chip)

        if armed.isAny {
            return csiModified(prefix: [0x31], modifier: modifierDigit(for: armed), final: finalByte)
        }

        return [0x1B, 0x4F, finalByte]
    }

    private static func encodeTildeFunctionKey(_ chip: AccessoryChip, armed: ArmedModifiers) -> [UInt8] {
        let number = tildeFunctionNumber(for: chip)
        var bytes: [UInt8] = [0x1B, 0x5B]
        bytes.append(contentsOf: asciiDigits(for: number))

        if armed.isAny {
            bytes.append(0x3B)
            bytes.append(modifierDigit(for: armed))
        }

        bytes.append(0x7E)
        return bytes
    }

    private static func encodeSymbol(_ chip: AccessoryChip, armed: ArmedModifiers) -> [UInt8] {
        let bareByte = symbolByte(for: chip)
        let symbolBytes: [UInt8]

        if armed.ctrl {
            switch chip {
            case .lbracket:
                symbolBytes = [0x1B]
            case .backslash:
                symbolBytes = [0x1C]
            case .rbracket:
                symbolBytes = [0x1D]
            default:
                symbolBytes = [bareByte]
            }
        } else {
            symbolBytes = [bareByte]
        }

        if armed.alt {
            return [0x1B] + symbolBytes
        }

        return symbolBytes
    }

    private static func csiModified(prefix: [UInt8], modifier: UInt8, final: UInt8) -> [UInt8] {
        [0x1B, 0x5B] + prefix + [0x3B, modifier, final]
    }

    private static func modifierDigit(for armed: ArmedModifiers) -> UInt8 {
        var modifier = 1

        if armed.shift {
            modifier += 1
        }

        if armed.alt {
            modifier += 2
        }

        if armed.ctrl {
            modifier += 4
        }

        return UInt8(0x30 + modifier)
    }

    private static func arrowFinalByte(for chip: AccessoryChip) -> UInt8 {
        switch chip {
        case .left:
            0x44
        case .down:
            0x42
        case .up:
            0x41
        case .right:
            0x43
        default:
            preconditionFailure("expected arrow chip")
        }
    }

    private static func lowFunctionFinalByte(for chip: AccessoryChip) -> UInt8 {
        switch chip {
        case .f1:
            0x50
        case .f2:
            0x51
        case .f3:
            0x52
        case .f4:
            0x53
        default:
            preconditionFailure("expected F1-F4 chip")
        }
    }

    private static func tildeFunctionNumber(for chip: AccessoryChip) -> Int {
        switch chip {
        case .f5:
            15
        case .f6:
            17
        case .f7:
            18
        case .f8:
            19
        case .f9:
            20
        case .f10:
            21
        case .f11:
            23
        case .f12:
            24
        default:
            preconditionFailure("expected F5-F12 chip")
        }
    }

    private static func asciiDigits(for number: Int) -> [UInt8] {
        String(number).utf8.map { UInt8($0) }
    }

    private static func symbolByte(for chip: AccessoryChip) -> UInt8 {
        switch chip {
        case .pipe:
            0x7C
        case .tilde:
            0x7E
        case .slash:
            0x2F
        case .backslash:
            0x5C
        case .dollar:
            0x24
        case .lbrace:
            0x7B
        case .rbrace:
            0x7D
        case .lbracket:
            0x5B
        case .rbracket:
            0x5D
        case .lt:
            0x3C
        case .gt:
            0x3E
        default:
            preconditionFailure("expected symbol chip")
        }
    }
}

/// Applies an accessory-bar modifier to the next software-keyboard payload.
///
/// SwiftTerm owns text input, so a key typed on the system keyboard arrives as
/// the same byte stream as a hardware key. Keeping this transform beside the
/// accessory encoder gives the phone's "arm Ctrl, then type c" flow the same
/// terminal semantics as a physical Control-C chord.
enum SoftwareModifierEncoder {
    /// A software-keyboard delegate callback may contain a paste or composed
    /// Unicode text, not one key. One-shot terminal modifiers apply only to a
    /// single ASCII key event; multi-byte commits pass through and leave the
    /// modifier armed for the next eligible key.
    static func encodeNextKey(
        _ bytes: [UInt8],
        armed: ArmedModifiers
    ) -> [UInt8]? {
        guard bytes.count == 1, armed.isAny else { return nil }
        return encode(bytes, armed: armed)
    }

    static func encode(_ bytes: [UInt8], armed: ArmedModifiers) -> [UInt8] {
        guard !bytes.isEmpty, armed.isAny else { return bytes }

        var transformed = bytes
        if transformed.count == 1 {
            var byte = transformed[0]

            if armed.shift {
                switch byte {
                case 0x61...0x7A:
                    byte -= 0x20
                case 0x31: byte = 0x21 // 1 → !
                case 0x32: byte = 0x40 // 2 → @
                case 0x33: byte = 0x23 // 3 → #
                case 0x34: byte = 0x24 // 4 → $
                case 0x35: byte = 0x25 // 5 → %
                case 0x36: byte = 0x5E // 6 → ^
                case 0x37: byte = 0x26 // 7 → &
                case 0x38: byte = 0x2A // 8 → *
                case 0x39: byte = 0x28 // 9 → (
                case 0x30: byte = 0x29 // 0 → )
                case 0x2D: byte = 0x5F // - → _
                case 0x3D: byte = 0x2B // = → +
                case 0x5B: byte = 0x7B // [ → {
                case 0x5D: byte = 0x7D // ] → }
                case 0x5C: byte = 0x7C // \ → |
                case 0x3B: byte = 0x3A // ; → :
                case 0x27: byte = 0x22 // ' → "
                case 0x2C: byte = 0x3C // , → <
                case 0x2E: byte = 0x3E // . → >
                case 0x2F: byte = 0x3F // / → ?
                case 0x60: byte = 0x7E // ` → ~
                default:
                    break
                }
            }

            if armed.ctrl {
                switch byte {
                case 0x40, 0x20:
                    byte = 0x00
                case 0x41...0x5F:
                    byte &= 0x1F
                case 0x61...0x7A:
                    byte &= 0x1F
                case 0x3F:
                    byte = 0x7F
                default:
                    break
                }
            }

            transformed[0] = byte
        }

        if armed.alt {
            transformed.insert(0x1B, at: 0)
        }
        return transformed
    }
}

extension ModifierState {
    /// Shared software-keyboard pipeline used by the terminal delegate. A
    /// one-shot modifier is consumed only when the payload represents one
    /// eligible key and the modifier was actually applied.
    func encodeSoftwareKeyboardPayload(_ bytes: [UInt8]) -> [UInt8] {
        guard let encoded = SoftwareModifierEncoder.encodeNextKey(
            bytes,
            armed: armed
        ) else {
            return bytes
        }
        _ = consume()
        return encoded
    }
}
