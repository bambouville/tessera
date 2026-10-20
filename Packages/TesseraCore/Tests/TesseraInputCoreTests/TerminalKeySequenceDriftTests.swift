import XCTest
@testable import TesseraInputCore

/// The places the two platforms' accessory encoders were found to disagree, or
/// were only covered by one of them. Each case here is a wire fact: if it
/// changes, a keystroke changes meaning on someone's remote host.
///
/// Android's `AccessoryKeySequenceEncoder.kt` is the peer implementation. Where
/// it differs, iOS is canonical — the divergences are named in the test bodies
/// so the Kotlin side has something to port against.
final class TerminalKeySequenceDriftTests: XCTestCase {

    // MARK: - Tab

    /// Shift+Tab is backtab (`CSI Z`), not a bare HT. Android's encoder answers
    /// `0x09` for every Tab regardless of modifiers, which loses reverse focus
    /// movement in every TUI that reads it.
    func test_shiftTabIsBacktab() {
        XCTAssertEqual(
            TerminalKeySequenceEncoder.encode(.tab, modifiers: TerminalModifiers(shift: true)),
            [0x1B, 0x5B, 0x5A]
        )
        XCTAssertEqual(TerminalKeySequenceEncoder.encode(.tab), [0x09])
    }

    /// Only Shift moves Tab. Ctrl+Tab and Alt+Tab stay a plain HT because the
    /// terminal has no agreed encoding for them and the app intercepts those
    /// chords itself.
    func test_onlyShiftChangesTab() {
        XCTAssertEqual(
            TerminalKeySequenceEncoder.encode(.tab, modifiers: TerminalModifiers(ctrl: true)),
            [0x09]
        )
        XCTAssertEqual(
            TerminalKeySequenceEncoder.encode(.tab, modifiers: TerminalModifiers(alt: true)),
            [0x09]
        )
        XCTAssertEqual(
            TerminalKeySequenceEncoder.encode(
                .tab,
                modifiers: TerminalModifiers(ctrl: true, alt: true, shift: true)
            ),
            [0x1B, 0x5B, 0x5A]
        )
    }

    // MARK: - One-shot Ctrl over typed keys

    /// The two control mappings that are not `byte & 0x1F`. Ctrl+Space is the
    /// canonical way to send NUL (readline's set-mark, tmux's copy-mode start)
    /// and Ctrl+? is DEL — both are unreachable from an iPhone without this.
    func test_oneShotControlOverTypedKeysCoversNulAndDelete() {
        let ctrl = TerminalModifiers(ctrl: true)
        XCTAssertEqual(TerminalSoftwareModifierEncoder.encode([0x20], modifiers: ctrl), [0x00])
        XCTAssertEqual(TerminalSoftwareModifierEncoder.encode([0x40], modifiers: ctrl), [0x00])
        XCTAssertEqual(TerminalSoftwareModifierEncoder.encode([0x3F], modifiers: ctrl), [0x7F])
    }

    func test_oneShotControlMasksLettersInEitherCase() {
        let ctrl = TerminalModifiers(ctrl: true)
        XCTAssertEqual(TerminalSoftwareModifierEncoder.encode(Array("a".utf8), modifiers: ctrl), [0x01])
        XCTAssertEqual(TerminalSoftwareModifierEncoder.encode(Array("A".utf8), modifiers: ctrl), [0x01])
        XCTAssertEqual(TerminalSoftwareModifierEncoder.encode(Array("c".utf8), modifiers: ctrl), [0x03])
        XCTAssertEqual(TerminalSoftwareModifierEncoder.encode(Array("[".utf8), modifiers: ctrl), [0x1B])
        XCTAssertEqual(TerminalSoftwareModifierEncoder.encode(Array("\\".utf8), modifiers: ctrl), [0x1C])
        XCTAssertEqual(TerminalSoftwareModifierEncoder.encode(Array("]".utf8), modifiers: ctrl), [0x1D])
    }

    /// Shift is applied to the raw key before Ctrl masks it, so ⌃⇧Z is the same
    /// SUB byte as ⌃Z rather than a different code point.
    func test_shiftIsAppliedBeforeControlMasking() {
        XCTAssertEqual(
            TerminalSoftwareModifierEncoder.encode(
                Array("z".utf8),
                modifiers: TerminalModifiers(ctrl: true, shift: true)
            ),
            [0x1A]
        )
        XCTAssertEqual(
            TerminalSoftwareModifierEncoder.encode(
                Array("2".utf8),
                modifiers: TerminalModifiers(ctrl: true, shift: true)
            ),
            [0x00]
        )
    }

    // MARK: - Alt / Meta

    /// Alt is an ESC prefix, applied last so it wraps whatever Shift and Ctrl
    /// produced rather than being folded into it.
    func test_alternatePrefixesEscapeAfterEveryOtherTransform() {
        XCTAssertEqual(
            TerminalSoftwareModifierEncoder.encode(
                Array("f".utf8),
                modifiers: TerminalModifiers(alt: true)
            ),
            [0x1B, 0x66]
        )
        XCTAssertEqual(
            TerminalSoftwareModifierEncoder.encode(
                Array("c".utf8),
                modifiers: TerminalModifiers(ctrl: true, alt: true)
            ),
            [0x1B, 0x03]
        )
        XCTAssertEqual(
            TerminalSoftwareModifierEncoder.encode(
                Array("z".utf8),
                modifiers: TerminalModifiers(ctrl: true, alt: true, shift: true)
            ),
            [0x1B, 0x1A]
        )
    }

    /// Alt on a symbol chip prefixes the same ESC. Ctrl on `[`, `\`, `]` still
    /// takes precedence over the literal byte.
    func test_alternateAndControlOnSymbolChips() {
        XCTAssertEqual(
            TerminalKeySequenceEncoder.encode(.slash, modifiers: TerminalModifiers(alt: true)),
            [0x1B, 0x2F]
        )
        XCTAssertEqual(
            TerminalKeySequenceEncoder.encode(
                .leftBracket,
                modifiers: TerminalModifiers(ctrl: true, alt: true)
            ),
            [0x1B, 0x1B]
        )
        // Shift is meaningless on a symbol chip — the chip already *is* the
        // shifted character.
        XCTAssertEqual(
            TerminalKeySequenceEncoder.encode(.pipe, modifiers: TerminalModifiers(shift: true)),
            [0x7C]
        )
    }

    // MARK: - DECCKM

    /// Application-cursor mode swaps CSI for SS3 on the bare arrows only.
    func test_applicationCursorModeSwapsCSIForSS3OnBareArrows() {
        let app = TerminalKeyMode(applicationCursorKeys: true)
        XCTAssertEqual(TerminalKeySequenceEncoder.encode(.up, mode: app), [0x1B, 0x4F, 0x41])
        XCTAssertEqual(TerminalKeySequenceEncoder.encode(.down, mode: app), [0x1B, 0x4F, 0x42])
        XCTAssertEqual(TerminalKeySequenceEncoder.encode(.right, mode: app), [0x1B, 0x4F, 0x43])
        XCTAssertEqual(TerminalKeySequenceEncoder.encode(.left, mode: app), [0x1B, 0x4F, 0x44])
        XCTAssertEqual(TerminalKeySequenceEncoder.encode(.home, mode: app), [0x1B, 0x4F, 0x48])
        XCTAssertEqual(TerminalKeySequenceEncoder.encode(.end, mode: app), [0x1B, 0x4F, 0x46])
    }

    /// A modified arrow is always CSI 1;<param> — there is no SS3 form for it,
    /// so DECCKM stops mattering the moment a modifier is armed.
    func test_modifiedArrowsIgnoreApplicationCursorMode() {
        let ctrl = TerminalModifiers(ctrl: true)
        for mode in [TerminalKeyMode(applicationCursorKeys: false), TerminalKeyMode(applicationCursorKeys: true)] {
            XCTAssertEqual(
                TerminalKeySequenceEncoder.encode(.up, modifiers: ctrl, mode: mode),
                [0x1B, 0x5B, 0x31, 0x3B, 0x35, 0x41]
            )
            XCTAssertEqual(
                TerminalKeySequenceEncoder.encode(.home, modifiers: ctrl, mode: mode),
                [0x1B, 0x5B, 0x31, 0x3B, 0x35, 0x48]
            )
        }
    }

    /// Page keys, function keys and symbols never look at DECCKM.
    func test_nonCursorKeysIgnoreApplicationCursorMode() {
        let app = TerminalKeyMode(applicationCursorKeys: true)
        for key in TerminalKey.allCases where ![.left, .down, .up, .right, .home, .end].contains(key) {
            XCTAssertEqual(
                TerminalKeySequenceEncoder.encode(key, mode: app),
                TerminalKeySequenceEncoder.encode(key),
                "\(key.rawValue) must not depend on application-cursor mode"
            )
        }
    }

    // MARK: - xterm modifier parameter

    /// `1 + shift + 2*alt + 4*ctrl`, and Command never contributes.
    func test_xtermModifierParameterTable() {
        let expected: [(TerminalModifiers, Int)] = [
            (TerminalModifiers(), 1),
            (TerminalModifiers(shift: true), 2),
            (TerminalModifiers(alt: true), 3),
            (TerminalModifiers(alt: true, shift: true), 4),
            (TerminalModifiers(ctrl: true), 5),
            (TerminalModifiers(ctrl: true, shift: true), 6),
            (TerminalModifiers(ctrl: true, alt: true), 7),
            (TerminalModifiers(ctrl: true, alt: true, shift: true), 8),
        ]
        for (modifiers, parameter) in expected {
            XCTAssertEqual(modifiers.xtermParameter, parameter)
            var withCommand = modifiers
            withCommand.cmd = true
            XCTAssertEqual(withCommand.xtermParameter, parameter)
        }
    }

    /// The tilde-terminated keys carry the parameter after the key number:
    /// `CSI <n> ; <param> ~`. Every F5–F12 number is the gapped VT sequence.
    func test_tildeKeysCarryTheModifierParameterAfterTheKeyNumber() {
        let all = TerminalModifiers(ctrl: true, alt: true, shift: true)
        XCTAssertEqual(TerminalKeySequenceEncoder.encode(.pageUp), Array("\u{1B}[5~".utf8))
        XCTAssertEqual(
            TerminalKeySequenceEncoder.encode(.pageUp, modifiers: all),
            Array("\u{1B}[5;8~".utf8)
        )
        XCTAssertEqual(
            TerminalKeySequenceEncoder.encode(.pageDown, modifiers: TerminalModifiers(ctrl: true)),
            Array("\u{1B}[6;5~".utf8)
        )

        let numbers: [(TerminalKey, Int)] = [
            (.f5, 15), (.f6, 17), (.f7, 18), (.f8, 19),
            (.f9, 20), (.f10, 21), (.f11, 23), (.f12, 24),
        ]
        for (key, number) in numbers {
            XCTAssertEqual(
                TerminalKeySequenceEncoder.encode(key),
                Array("\u{1B}[\(number)~".utf8),
                "\(key.rawValue) bare"
            )
            XCTAssertEqual(
                TerminalKeySequenceEncoder.encode(key, modifiers: TerminalModifiers(shift: true)),
                Array("\u{1B}[\(number);2~".utf8),
                "\(key.rawValue) shifted"
            )
        }
    }

    // MARK: - SS3 function keys

    /// F1–F4 are SS3 P/Q/R/S bare, and CSI 1;<param> P/Q/R/S once modified —
    /// the one place a function key changes introducer with its modifier.
    func test_lowFunctionKeysUseSS3PQRSAndCSIWhenModified() {
        let bare: [(TerminalKey, UInt8)] = [(.f1, 0x50), (.f2, 0x51), (.f3, 0x52), (.f4, 0x53)]
        for (key, final) in bare {
            XCTAssertEqual(
                TerminalKeySequenceEncoder.encode(key),
                [0x1B, 0x4F, final],
                "\(key.rawValue) bare"
            )
            XCTAssertEqual(
                TerminalKeySequenceEncoder.encode(key, modifiers: TerminalModifiers(ctrl: true)),
                [0x1B, 0x5B, 0x31, 0x3B, 0x35, final],
                "\(key.rawValue) with control"
            )
        }
    }

    // MARK: - Command

    /// Command is representable so app adapters can carry it, but no encoder
    /// path may ever put it on the wire.
    func test_commandNeverChangesAnyEncodedSequence() {
        var command = TerminalModifiers()
        command.cmd = true
        for key in TerminalKey.allCases {
            for mode in [TerminalKeyMode(), TerminalKeyMode(applicationCursorKeys: true)] {
                XCTAssertEqual(
                    TerminalKeySequenceEncoder.encode(key, modifiers: command, mode: mode),
                    TerminalKeySequenceEncoder.encode(key, mode: mode),
                    "\(key.rawValue) changed when Command was armed"
                )
            }
        }
        XCTAssertEqual(
            TerminalSoftwareModifierEncoder.encode(Array("c".utf8), modifiers: command),
            Array("c".utf8)
        )
        XCTAssertNil(
            TerminalSoftwareModifierEncoder.encodeNextKey(Array("c".utf8), modifiers: command)
        )
    }
}
