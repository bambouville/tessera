import Foundation
import XCTest
@testable import TesseraInputCore

final class TerminalInputCoreTests: XCTestCase {
    func test_checkedInCrossPlatformVectorsMatchExactTerminalBytes() throws {
        let data = try Data(contentsOf: vectorURL())
        let vectors = try JSONDecoder().decode(InputVectors.self, from: data)
        XCTAssertEqual(vectors.version, 1)

        for vector in vectors.keySequences {
            let key = try XCTUnwrap(TerminalKey(rawValue: vector.key), vector.name)
            XCTAssertEqual(
                TerminalKeySequenceEncoder.encode(
                    key,
                    modifiers: try modifiers(vector.modifiers),
                    mode: TerminalKeyMode(
                        applicationCursorKeys: vector.applicationCursorKeys
                    )
                ),
                try bytes(vector.hex),
                vector.name
            )
        }

        for vector in vectors.softwareKeys {
            XCTAssertEqual(
                TerminalSoftwareModifierEncoder.encode(
                    try bytes(vector.inputHex),
                    modifiers: try modifiers(vector.modifiers)
                ),
                try bytes(vector.outputHex),
                vector.name
            )
        }

        for vector in vectors.mouse {
            let encoding = try XCTUnwrap(
                TerminalMouseEncoding(rawValue: vector.encoding),
                vector.name
            )
            XCTAssertEqual(
                TerminalMouseSequenceEncoder.encode(
                    try mouseEvent(vector),
                    using: encoding
                ),
                try bytes(vector.hex),
                vector.name
            )
        }
    }

    func test_modifierNormalizationExcludesCommandFromTerminalWireState() {
        let modifiers = TerminalModifiers([
            .control, .alternate, .shift, .command,
        ])

        XCTAssertEqual(modifiers.xtermParameter, 8)
        XCTAssertEqual(modifiers.xtermMouseFlags, 28)
        XCTAssertTrue(modifiers.isAnyArmed)
        XCTAssertEqual(
            modifiers.terminalOnly,
            TerminalModifiers(ctrl: true, alt: true, shift: true)
        )
        XCTAssertFalse(modifiers.terminalOnly.cmd)
    }

    func test_softwareModifiersApplyOnlyToOneByteKeyEvents() {
        let modifiers = TerminalModifiers(ctrl: true)
        XCTAssertNil(
            TerminalSoftwareModifierEncoder.encodeNextKey(
                Array("paste".utf8),
                modifiers: modifiers
            )
        )
        XCTAssertNil(
            TerminalSoftwareModifierEncoder.encodeNextKey(
                Array("é".utf8),
                modifiers: modifiers
            )
        )
        XCTAssertEqual(
            TerminalSoftwareModifierEncoder.encodeNextKey(
                Array("c".utf8),
                modifiers: modifiers
            ),
            [0x03]
        )
    }

    func test_modeTransitionsReturnExactResetRulesAndClearPressedButtons() {
        let initial = TerminalInputMode(
            applicationCursorKeys: false,
            alternateScreen: true,
            mouseTracking: .anyEvent,
            mouseEncoding: .sgr
        )
        var state = TerminalInputStateMachine(mode: initial)
        state.note(.button(
            .primary,
            action: .press,
            column: 1,
            row: 1,
            modifiers: .none
        ))
        XCTAssertEqual(state.pressedButtons, [.primary])

        var cursorMode = initial
        cursorMode.applicationCursorKeys = true
        XCTAssertEqual(
            state.transition(to: cursorMode),
            [.keySequenceState]
        )
        XCTAssertEqual(state.pressedButtons, [.primary])

        var mouseMode = cursorMode
        mouseMode.mouseEncoding = .x10
        XCTAssertEqual(
            state.transition(to: mouseMode),
            [.pointerState, .scrollAccumulator]
        )
        XCTAssertTrue(state.pressedButtons.isEmpty)
        XCTAssertEqual(state.transition(to: mouseMode), [])
    }

    func test_alternateScreenAndMouseTrackingChangesResetPointerAndScrollState() {
        var state = TerminalInputStateMachine()
        var alternate = state.mode
        alternate.alternateScreen = true
        XCTAssertEqual(
            state.transition(to: alternate),
            [.pointerState, .scrollAccumulator]
        )

        var reporting = alternate
        reporting.mouseTracking = .buttonDrag
        reporting.mouseEncoding = .sgr
        XCTAssertEqual(
            state.transition(to: reporting),
            [.pointerState, .scrollAccumulator]
        )
    }

    func test_mouseEncodingClampsCoordinatesForEachWireFormat() {
        let event = TerminalMouseEvent.wheel(
            .up,
            column: 100_000,
            row: 0,
            modifiers: .none
        )
        XCTAssertEqual(
            TerminalMouseSequenceEncoder.encode(event, using: .sgr),
            Array("\u{1B}[<64;9999;1M".utf8)
        )
        XCTAssertEqual(
            TerminalMouseSequenceEncoder.encode(event, using: .x10),
            [0x1B, 0x5B, 0x4D, 0x60, 0xFF, 0x21]
        )
        XCTAssertEqual(
            TerminalMouseSequenceEncoder.encode(event, using: .none),
            []
        )
    }
}

private struct InputVectors: Decodable {
    let version: Int
    let keySequences: [KeyVector]
    let softwareKeys: [SoftwareKeyVector]
    let mouse: [MouseVector]
}

private struct KeyVector: Decodable {
    let name: String
    let key: String
    let modifiers: [String]
    let applicationCursorKeys: Bool
    let hex: String
}

private struct SoftwareKeyVector: Decodable {
    let name: String
    let inputHex: String
    let modifiers: [String]
    let outputHex: String
}

private struct MouseVector: Decodable {
    let name: String
    let event: String
    let button: String?
    let modifiers: [String]
    let column: Int
    let row: Int
    let encoding: String
    let hex: String
}

private func modifiers(_ raw: [String]) throws -> TerminalModifiers {
    try TerminalModifiers(raw.map { value in
        guard let modifier = TerminalModifier(rawValue: value) else {
            throw VectorError.invalidModifier(value)
        }
        return modifier
    })
}

private func mouseEvent(_ vector: MouseVector) throws -> TerminalMouseEvent {
    let modifiers = try modifiers(vector.modifiers)
    switch vector.event {
    case "press", "release":
        let button = try mouseButton(vector.button)
        return .button(
            button,
            action: vector.event == "press" ? .press : .release,
            column: vector.column,
            row: vector.row,
            modifiers: modifiers
        )
    case "motion":
        return .motion(
            button: try mouseButton(vector.button),
            column: vector.column,
            row: vector.row,
            modifiers: modifiers
        )
    case "wheelUp":
        return .wheel(
            .up,
            column: vector.column,
            row: vector.row,
            modifiers: modifiers
        )
    case "wheelDown":
        return .wheel(
            .down,
            column: vector.column,
            row: vector.row,
            modifiers: modifiers
        )
    default:
        throw VectorError.invalidMouseEvent(vector.event)
    }
}

private func mouseButton(_ raw: String?) throws -> TerminalMouseButton {
    switch raw {
    case "primary": .primary
    case "middle": .middle
    case "secondary": .secondary
    default: throw VectorError.invalidMouseButton(raw)
    }
}

private func bytes(_ hex: String) throws -> [UInt8] {
    guard hex.count.isMultiple(of: 2) else {
        throw VectorError.invalidHex(hex)
    }
    var result: [UInt8] = []
    var index = hex.startIndex
    while index < hex.endIndex {
        let end = hex.index(index, offsetBy: 2)
        guard let byte = UInt8(hex[index..<end], radix: 16) else {
            throw VectorError.invalidHex(hex)
        }
        result.append(byte)
        index = end
    }
    return result
}

private func vectorURL(filePath: String = #filePath) -> URL {
    var root = URL(fileURLWithPath: filePath)
    for _ in 0..<5 { root.deleteLastPathComponent() }
    return root.appendingPathComponent(
        "ProtocolVectors/input/v1/terminal-input.json"
    )
}

private enum VectorError: Error {
    case invalidModifier(String)
    case invalidMouseButton(String?)
    case invalidMouseEvent(String)
    case invalidHex(String)
}
