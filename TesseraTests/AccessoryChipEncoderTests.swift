import XCTest
@testable import Tessera

final class AccessoryChipEncoderTests: XCTestCase {
    func test_escIgnoresArmedAndApplicationCursor() {
        XCTAssertEqual(
            AccessoryChipEncoder.encode(
                .esc,
                armed: ArmedModifiers(ctrl: true, alt: true, shift: true),
                applicationCursor: true
            ),
            [0x1B]
        )
    }

    func test_tabBareAndShiftBackTab() {
        XCTAssertEqual(
            AccessoryChipEncoder.encode(.tab, armed: .none, applicationCursor: false),
            [0x09]
        )
        XCTAssertEqual(
            AccessoryChipEncoder.encode(
                .tab,
                armed: ArmedModifiers(shift: true),
                applicationCursor: false
            ),
            [0x1B, 0x5B, 0x5A]
        )
    }

    func test_arrowsNormalModeUseCSI() {
        XCTAssertEqual(AccessoryChipEncoder.encode(.left, armed: .none, applicationCursor: false), [0x1B, 0x5B, 0x44])
        XCTAssertEqual(AccessoryChipEncoder.encode(.down, armed: .none, applicationCursor: false), [0x1B, 0x5B, 0x42])
        XCTAssertEqual(AccessoryChipEncoder.encode(.up, armed: .none, applicationCursor: false), [0x1B, 0x5B, 0x41])
        XCTAssertEqual(AccessoryChipEncoder.encode(.right, armed: .none, applicationCursor: false), [0x1B, 0x5B, 0x43])
    }

    func test_arrowsApplicationModeUseSS3WhenUnmodified() {
        XCTAssertEqual(AccessoryChipEncoder.encode(.left, armed: .none, applicationCursor: true), [0x1B, 0x4F, 0x44])
        XCTAssertEqual(AccessoryChipEncoder.encode(.down, armed: .none, applicationCursor: true), [0x1B, 0x4F, 0x42])
        XCTAssertEqual(AccessoryChipEncoder.encode(.up, armed: .none, applicationCursor: true), [0x1B, 0x4F, 0x41])
        XCTAssertEqual(AccessoryChipEncoder.encode(.right, armed: .none, applicationCursor: true), [0x1B, 0x4F, 0x43])
    }

    func test_upWithCtrlUsesModifierDigitFive() {
        XCTAssertEqual(
            AccessoryChipEncoder.encode(
                .up,
                armed: ArmedModifiers(ctrl: true),
                applicationCursor: true
            ),
            [0x1B, 0x5B, 0x31, 0x3B, 0x35, 0x41]
        )
    }

    func test_rightWithShiftAltUsesModifierDigitFour() {
        XCTAssertEqual(
            AccessoryChipEncoder.encode(
                .right,
                armed: ArmedModifiers(alt: true, shift: true),
                applicationCursor: true
            ),
            [0x1B, 0x5B, 0x31, 0x3B, 0x34, 0x43]
        )
    }

    func test_arrowsWithAllModifiersUseModifierDigitEight() {
        let armed = ArmedModifiers(ctrl: true, alt: true, shift: true)

        XCTAssertEqual(AccessoryChipEncoder.encode(.left, armed: armed, applicationCursor: true), [0x1B, 0x5B, 0x31, 0x3B, 0x38, 0x44])
        XCTAssertEqual(AccessoryChipEncoder.encode(.down, armed: armed, applicationCursor: true), [0x1B, 0x5B, 0x31, 0x3B, 0x38, 0x42])
        XCTAssertEqual(AccessoryChipEncoder.encode(.up, armed: armed, applicationCursor: true), [0x1B, 0x5B, 0x31, 0x3B, 0x38, 0x41])
        XCTAssertEqual(AccessoryChipEncoder.encode(.right, armed: armed, applicationCursor: true), [0x1B, 0x5B, 0x31, 0x3B, 0x38, 0x43])
    }

    func test_f1BareAndCtrl() {
        XCTAssertEqual(
            AccessoryChipEncoder.encode(.f1, armed: .none, applicationCursor: false),
            [0x1B, 0x4F, 0x50]
        )
        XCTAssertEqual(
            AccessoryChipEncoder.encode(
                .f1,
                armed: ArmedModifiers(ctrl: true),
                applicationCursor: false
            ),
            [0x1B, 0x5B, 0x31, 0x3B, 0x35, 0x50]
        )
    }

    func test_f5BareAndAlt() {
        XCTAssertEqual(
            AccessoryChipEncoder.encode(.f5, armed: .none, applicationCursor: false),
            [0x1B, 0x5B, 0x31, 0x35, 0x7E]
        )
        XCTAssertEqual(
            AccessoryChipEncoder.encode(
                .f5,
                armed: ArmedModifiers(alt: true),
                applicationCursor: false
            ),
            [0x1B, 0x5B, 0x31, 0x35, 0x3B, 0x33, 0x7E]
        )
    }

    func test_f11AndF12BareUseGappedTildeNumbers() {
        XCTAssertEqual(
            AccessoryChipEncoder.encode(.f11, armed: .none, applicationCursor: false),
            [0x1B, 0x5B, 0x32, 0x33, 0x7E]
        )
        XCTAssertEqual(
            AccessoryChipEncoder.encode(.f12, armed: .none, applicationCursor: false),
            [0x1B, 0x5B, 0x32, 0x34, 0x7E]
        )
    }

    func test_homeEndBareAndModified() {
        XCTAssertEqual(
            AccessoryChipEncoder.encode(.home, armed: .none, applicationCursor: false),
            [0x1B, 0x5B, 0x48]
        )
        XCTAssertEqual(
            AccessoryChipEncoder.encode(.end, armed: .none, applicationCursor: false),
            [0x1B, 0x5B, 0x46]
        )
        XCTAssertEqual(
            AccessoryChipEncoder.encode(
                .home,
                armed: ArmedModifiers(shift: true),
                applicationCursor: true
            ),
            [0x1B, 0x5B, 0x31, 0x3B, 0x32, 0x48]
        )
        XCTAssertEqual(
            AccessoryChipEncoder.encode(
                .end,
                armed: ArmedModifiers(ctrl: true),
                applicationCursor: true
            ),
            [0x1B, 0x5B, 0x31, 0x3B, 0x35, 0x46]
        )
    }

    func test_homeEndApplicationCursorBareUseSS3() {
        XCTAssertEqual(
            AccessoryChipEncoder.encode(.home, armed: .none, applicationCursor: true),
            [0x1B, 0x4F, 0x48]
        )
        XCTAssertEqual(
            AccessoryChipEncoder.encode(.end, armed: .none, applicationCursor: true),
            [0x1B, 0x4F, 0x46]
        )
    }

    func test_pageKeysBareAndModified() {
        XCTAssertEqual(
            AccessoryChipEncoder.encode(.pgup, armed: .none, applicationCursor: false),
            [0x1B, 0x5B, 0x35, 0x7E]
        )
        XCTAssertEqual(
            AccessoryChipEncoder.encode(.pgdn, armed: .none, applicationCursor: false),
            [0x1B, 0x5B, 0x36, 0x7E]
        )
        XCTAssertEqual(
            AccessoryChipEncoder.encode(
                .pgup,
                armed: ArmedModifiers(alt: true),
                applicationCursor: false
            ),
            [0x1B, 0x5B, 0x35, 0x3B, 0x33, 0x7E]
        )
        XCTAssertEqual(
            AccessoryChipEncoder.encode(
                .pgdn,
                armed: ArmedModifiers(ctrl: true),
                applicationCursor: false
            ),
            [0x1B, 0x5B, 0x36, 0x3B, 0x35, 0x7E]
        )
    }

    func test_symbolEncodings() {
        XCTAssertEqual(
            AccessoryChipEncoder.encode(.pipe, armed: .none, applicationCursor: false),
            [0x7C]
        )
        XCTAssertEqual(
            AccessoryChipEncoder.encode(
                .lbracket,
                armed: ArmedModifiers(ctrl: true),
                applicationCursor: false
            ),
            [0x1B]
        )
        XCTAssertEqual(
            AccessoryChipEncoder.encode(
                .backslash,
                armed: ArmedModifiers(ctrl: true),
                applicationCursor: false
            ),
            [0x1C]
        )
        XCTAssertEqual(
            AccessoryChipEncoder.encode(
                .slash,
                armed: ArmedModifiers(alt: true),
                applicationCursor: false
            ),
            [0x1B, 0x2F]
        )
        XCTAssertEqual(
            AccessoryChipEncoder.encode(
                .pipe,
                armed: ArmedModifiers(shift: true),
                applicationCursor: false
            ),
            [0x7C]
        )
    }
}

final class TerminalInputNormalizerTests: XCTestCase {
    func test_ctrlCCSIuBecomesETX() {
        XCTAssertEqual(
            TerminalInputNormalizer.normalizeNormalBufferInput([0x1B, 0x5B, 0x39, 0x39, 0x3B, 0x35, 0x75][...]),
            [0x03]
        )
    }

    func test_ctrlTabCSIuBecomesTab() {
        XCTAssertEqual(
            TerminalInputNormalizer.normalizeNormalBufferInput([0x1B, 0x5B, 0x39, 0x3B, 0x35, 0x75][...]),
            [0x09]
        )
    }

    func test_ctrlCSIuReleaseIsDropped() {
        XCTAssertEqual(
            TerminalInputNormalizer.normalizeNormalBufferInput([0x1B, 0x5B, 0x39, 0x39, 0x3B, 0x35, 0x3A, 0x33, 0x75][...]),
            []
        )
    }

    func test_optionArrowsBecomeReadlineWordMovement() {
        XCTAssertEqual(
            TerminalInputNormalizer.normalizeNormalBufferInput([0x1B, 0x5B, 0x31, 0x3B, 0x33, 0x44][...]),
            [0x1B, 0x62]
        )
        XCTAssertEqual(
            TerminalInputNormalizer.normalizeNormalBufferInput([0x1B, 0x5B, 0x31, 0x3B, 0x33, 0x43][...]),
            [0x1B, 0x66]
        )
    }

    func test_optionArrowRepeatBecomesReadlineWordMovement() {
        XCTAssertEqual(
            TerminalInputNormalizer.normalizeNormalBufferInput([0x1B, 0x5B, 0x31, 0x3B, 0x33, 0x3A, 0x32, 0x44][...]),
            [0x1B, 0x62]
        )
    }

    func test_optionArrowReleaseIsDropped() {
        XCTAssertEqual(
            TerminalInputNormalizer.normalizeNormalBufferInput([0x1B, 0x5B, 0x31, 0x3B, 0x33, 0x3A, 0x33, 0x44][...]),
            []
        )
    }

    func test_optionBackspaceBecomesReadlineBackwardKillWord() {
        XCTAssertEqual(
            TerminalInputNormalizer.normalizeNormalBufferInput([0x1B, 0x5B, 0x31, 0x32, 0x37, 0x3B, 0x33, 0x75][...]),
            [0x1B, 0x7F]
        )
    }

    func test_optionBackspaceControlHCSIuBecomesReadlineBackwardKillWord() {
        XCTAssertEqual(
            TerminalInputNormalizer.normalizeNormalBufferInput([0x1B, 0x5B, 0x38, 0x3B, 0x33, 0x75][...]),
            [0x1B, 0x7F]
        )
    }

    func test_optionBackspaceReleaseIsDropped() {
        XCTAssertEqual(
            TerminalInputNormalizer.normalizeNormalBufferInput([0x1B, 0x5B, 0x31, 0x32, 0x37, 0x3B, 0x33, 0x3A, 0x33, 0x75][...]),
            []
        )
    }

    func test_optionBackspaceControlHReleaseIsDropped() {
        XCTAssertEqual(
            TerminalInputNormalizer.normalizeNormalBufferInput([0x1B, 0x5B, 0x38, 0x3B, 0x33, 0x3A, 0x33, 0x75][...]),
            []
        )
    }

    func test_splitOptionBackspaceCSIuDoesNotLeakSuffix() {
        var pending: [UInt8] = []

        XCTAssertEqual(
            TerminalInputNormalizer.normalizeNormalBufferInput([0x1B, 0x5B, 0x38][...], pending: &pending),
            []
        )
        XCTAssertEqual(
            TerminalInputNormalizer.normalizeNormalBufferInput([0x3B, 0x33, 0x75][...], pending: &pending),
            [0x1B, 0x7F]
        )
        XCTAssertTrue(pending.isEmpty)
    }

    func test_splitOptionBackspaceReleaseDoesNotLeakSuffix() {
        var pending: [UInt8] = []

        XCTAssertEqual(
            TerminalInputNormalizer.normalizeNormalBufferInput([0x1B, 0x5B, 0x38][...], pending: &pending),
            []
        )
        XCTAssertEqual(
            TerminalInputNormalizer.normalizeNormalBufferInput([0x3B, 0x33, 0x3A, 0x33, 0x75][...], pending: &pending),
            []
        )
        XCTAssertTrue(pending.isEmpty)
    }

    func test_shiftCtrlCSIuIsPreserved() {
        let bytes: [UInt8] = [0x1B, 0x5B, 0x39, 0x39, 0x3B, 0x36, 0x75]

        XCTAssertEqual(
            TerminalInputNormalizer.normalizeNormalBufferInput(bytes[...]),
            bytes
        )
    }

    func test_plainTextIsPreserved() {
        let bytes = Array("hello".utf8)

        XCTAssertEqual(
            TerminalInputNormalizer.normalizeNormalBufferInput(bytes[...]),
            bytes
        )
    }
}
