import Foundation
import XCTest
import TesseraDomainCore
import TesseraInputCore
import TesseraPairingCore
import TesseraProtocolCore
import TesseraSessionCore
import TesseraTrustCore
import TmuxControlCore
@testable import TesseraCoreABI

/// The C ABI is the only way Android reaches this policy, so the seam itself is
/// tested — not just the Swift core behind it. Every case exercises the
/// two-phase string/bytes contract the JNI shim relies on: query the length
/// with no buffer, then copy into exactly that many bytes, and assert the two
/// answers agree.
final class SharedPolicyABITests: XCTestCase {

    // MARK: - Harness

    private func buildBytes(
        _ call: (UnsafeMutablePointer<UInt8>?, Int) -> Int32,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> [UInt8] {
        let required = call(nil, 0)
        XCTAssertGreaterThanOrEqual(required, 0, file: file, line: line)
        guard required > 0 else { return [] }
        var buffer = [UInt8](repeating: 0, count: Int(required))
        let written = buffer.withUnsafeMutableBufferPointer {
            call($0.baseAddress, $0.count)
        }
        XCTAssertEqual(written, required, file: file, line: line)
        // A buffer one byte short must be refused, never truncated.
        var short = [UInt8](repeating: 0, count: Int(required) - 1)
        if required > 1 {
            let refused = short.withUnsafeMutableBufferPointer {
                call($0.baseAddress, $0.count)
            }
            XCTAssertEqual(refused, -1, file: file, line: line)
        }
        return buffer
    }

    private func buildString(
        _ call: (UnsafeMutablePointer<UInt8>?, Int) -> Int32,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> String {
        String(decoding: try buildBytes(call, file: file, line: line), as: UTF8.self)
    }

    private func decode<T: Decodable>(
        _ type: T.Type,
        _ call: (UnsafeMutablePointer<UInt8>?, Int) -> Int32,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> T {
        let bytes = try buildBytes(call, file: file, line: line)
        return try JSONDecoder().decode(type, from: Data(bytes))
    }

    private func withUTF8<T>(_ value: String, _ body: (UnsafePointer<UInt8>?, Int) -> T) -> T {
        var bytes = Array(value.utf8)
        return bytes.withUnsafeMutableBufferPointer { body($0.baseAddress, $0.count) }
    }

    private func withBytes<T>(_ value: [UInt8], _ body: (UnsafePointer<UInt8>?, Int) -> T) -> T {
        var bytes = value
        return bytes.withUnsafeMutableBufferPointer { body($0.baseAddress, $0.count) }
    }

    /// Requests cross the ABI as canonical JSON, so they are built with the
    /// same encoder the responses use.
    private func json<T: Encodable>(_ value: T) throws -> String {
        String(decoding: try SharedABI.encoder.encode(value), as: UTF8.self)
    }

    // MARK: - Input: chip encoding

    func testAccessoryChipsEncodeThroughTheCatalogByCanonicalID() throws {
        func encode(_ id: String, bits: Int32 = 0, applicationCursor: Bool = false) throws -> [UInt8] {
            try buildBytes { output, capacity in
                withUTF8(id) { idBytes, idCount in
                    tesseraInputEncodeAccessoryKey(
                        idBytes: idBytes,
                        idCount: idCount,
                        modifierBits: bits,
                        applicationCursorMode: applicationCursor ? 1 : 0,
                        outputBytes: output,
                        outputCapacity: capacity
                    )
                }
            }
        }

        XCTAssertEqual(try encode("esc"), [0x1B])
        XCTAssertEqual(try encode("tab"), [0x09])
        // The drift the shared catalog exists to close: Shift+Tab is backtab,
        // which Android used to send as a bare 0x09.
        XCTAssertEqual(try encode("tab", bits: TerminalModifierBits.shift), [0x1B, 0x5B, 0x5A])
        XCTAssertEqual(try encode("up"), [0x1B, 0x5B, 0x41])
        // DECCKM application-cursor mode moves the arrow to SS3.
        XCTAssertEqual(try encode("up", applicationCursor: true), [0x1B, 0x4F, 0x41])
        // xterm modifier parameter: 1 + shift + 2*alt + 4*ctrl.
        XCTAssertEqual(
            try encode("pgup", bits: TerminalModifierBits.control | TerminalModifierBits.shift),
            Array("\u{1B}[5;6~".utf8)
        )
        // SS3 PQRS for F1-F4, CSI-tilde for F5 and up.
        XCTAssertEqual(try encode("f1"), [0x1B, 0x4F, 0x50])
        XCTAssertEqual(try encode("f5"), Array("\u{1B}[15~".utf8))
        XCTAssertEqual(try encode("ctrlC"), [0x03])

        // Command never reaches the wire, so arming it changes nothing.
        XCTAssertEqual(try encode("tab", bits: TerminalModifierBits.command), [0x09])
    }

    func testAccessoryEncodingRejectsModifiersUnknownIDsAndUndefinedBits() throws {
        func raw(_ id: String, bits: Int32 = 0) -> Int32 {
            withUTF8(id) { idBytes, idCount in
                tesseraInputEncodeAccessoryKey(
                    idBytes: idBytes,
                    idCount: idCount,
                    modifierBits: bits,
                    applicationCursorMode: 0,
                    outputBytes: nil,
                    outputCapacity: 0
                )
            }
        }
        // Modifier chips arm state; they send nothing.
        XCTAssertEqual(raw("ctrl"), -1)
        XCTAssertEqual(raw("cmd"), -1)
        // A legacy Android spelling is not a second vocabulary.
        XCTAssertEqual(raw("page-up"), -1)
        XCTAssertEqual(raw("custom:1E7C"), -1)
        // A bit this ABI does not define must not be silently ignored.
        XCTAssertEqual(raw("tab", bits: TerminalModifierBits.all | (1 << 4)), -1)
        XCTAssertEqual(
            tesseraInputEncodeAccessoryKey(
                idBytes: nil,
                idCount: 0,
                modifierBits: 0,
                applicationCursorMode: 0,
                outputBytes: nil,
                outputCapacity: 0
            ),
            -1
        )
    }

    func testSoftwareModifiersCoverTheWholeTypedKeyPathAndroidNeverHad() throws {
        func apply(_ bytes: [UInt8], _ bits: Int32) throws -> [UInt8] {
            try buildBytes { output, capacity in
                withBytes(bytes) { input, count in
                    tesseraInputApplySoftwareModifiers(
                        inputBytes: input,
                        inputCount: count,
                        modifierBits: bits,
                        outputBytes: output,
                        outputCapacity: capacity
                    )
                }
            }
        }
        // Ctrl+Space is NUL and Ctrl+? is DEL — the two cases a naive
        // "& 0x1F" mask gets wrong.
        XCTAssertEqual(try apply([0x20], TerminalModifierBits.control), [0x00])
        XCTAssertEqual(try apply([0x3F], TerminalModifierBits.control), [0x7F])
        XCTAssertEqual(try apply([0x63], TerminalModifierBits.control), [0x03])
        XCTAssertEqual(try apply([0x65], TerminalModifierBits.alternate), [0x1B, 0x65])
        XCTAssertEqual(try apply([0x65], TerminalModifierBits.shift), [0x45])
        // A paste keeps its bytes; only a one-byte key event is transformed.
        XCTAssertEqual(
            try apply([0x68, 0x69], TerminalModifierBits.control),
            [0x68, 0x69]
        )
        // The Alt case is the one that bites: the ungated core `encode`
        // ESC-prefixes payloads of any length, so the ABI must route through
        // `encodeNextKey` or an armed Alt corrupts a multi-byte paste.
        XCTAssertEqual(
            try apply([0x68, 0x69], TerminalModifierBits.alternate),
            [0x68, 0x69]
        )
        XCTAssertEqual(
            tesseraInputApplySoftwareModifiers(
                inputBytes: nil,
                inputCount: 0,
                modifierBits: 0,
                outputBytes: nil,
                outputCapacity: 0
            ),
            -1
        )
    }

    // MARK: - Input: pointer events

    func testMouseEncodingMatchesTheCoreEncoderAndRejectsInconsistentEvents() throws {
        func encode(_ request: TerminalMouseEventABIRequest) throws -> [UInt8] {
            let payload = try json(request)
            return try buildBytes { output, capacity in
                withUTF8(payload) { bytes, count in
                    tesseraInputEncodeMouseEvent(
                        requestBytes: bytes,
                        requestCount: count,
                        outputBytes: output,
                        outputCapacity: capacity
                    )
                }
            }
        }

        let press = TerminalMouseEventABIRequest(
            encoding: .sgr,
            event: .init(kind: .button, button: .primary, action: .press, column: 10, row: 4)
        )
        XCTAssertEqual(try encode(press), Array("\u{1B}[<0;10;4M".utf8))
        XCTAssertEqual(
            try encode(press),
            TerminalMouseSequenceEncoder.encode(
                .button(.primary, action: .press, column: 10, row: 4, modifiers: .none),
                using: .sgr
            )
        )

        let release = TerminalMouseEventABIRequest(
            encoding: .sgr,
            event: .init(kind: .button, button: .primary, action: .release, column: 10, row: 4)
        )
        XCTAssertEqual(try encode(release), Array("\u{1B}[<0;10;4m".utf8))

        let wheel = TerminalMouseEventABIRequest(
            encoding: .sgr,
            event: .init(kind: .wheel, direction: .up, column: 3, row: 7)
        )
        XCTAssertEqual(try encode(wheel), Array("\u{1B}[<64;3;7M".utf8))

        // Mouse reporting off is a legitimate zero-byte answer, not an error.
        let off = TerminalMouseEventABIRequest(
            encoding: .none,
            event: .init(kind: .button, button: .primary, action: .press, column: 1, row: 1)
        )
        XCTAssertEqual(try encode(off), [])

        // A wheel with no direction would otherwise silently encode as some
        // default button, so it is refused.
        let malformed = try json(
            TerminalMouseEventABIRequest(
                encoding: .sgr,
                event: .init(kind: .wheel, column: 1, row: 1)
            )
        )
        XCTAssertEqual(
            withUTF8(malformed) { bytes, count in
                tesseraInputEncodeMouseEvent(
                    requestBytes: bytes,
                    requestCount: count,
                    outputBytes: nil,
                    outputCapacity: 0
                )
            },
            -1
        )
    }

    // MARK: - Input: catalog

    func testCatalogPublishesTheCanonicalIDsOrdersAndLegacyAndroidMap() throws {
        let catalog = try decode(AccessoryKeyCatalogABIResponse.self) { output, capacity in
            tesseraInputAccessoryCatalog(outputBytes: output, outputCapacity: capacity)
        }
        XCTAssertEqual(catalog.ids, AccessoryKeyCatalog.allIDs)
        XCTAssertEqual(catalog.modifierIDs, ["ctrl", "alt", "shift", "cmd"])
        XCTAssertEqual(
            catalog.defaultPhoneBarOrder,
            AccessoryKeyCatalog.defaultPhoneBarOrder.map(\.rawValue)
        )
        XCTAssertEqual(
            catalog.defaultTabletBarOrder,
            AccessoryKeyCatalog.defaultTabletBarOrder.map(\.rawValue)
        )
        XCTAssertEqual(catalog.customIDPrefix, "custom:")
        XCTAssertEqual(catalog.legacyAndroidIDMap["page-up"], "pgup")
        XCTAssertEqual(catalog.legacyAndroidIDMap["control-c"], "ctrlC")
        // Android never had a Command chip, so it has no legacy peer.
        XCTAssertFalse(catalog.legacyAndroidIDMap.values.contains("cmd"))
    }

    func testStoredBarOrderKeepsTheAbsentVersusDeliberatelyEmptyDistinction() throws {
        func resolve(_ request: AccessoryBarOrderABIRequest) throws -> AccessoryBarOrderABIResponse {
            let payload = try json(request)
            return try decode(AccessoryBarOrderABIResponse.self) { output, capacity in
                withUTF8(payload) { bytes, count in
                    tesseraInputAccessoryBarOrder(
                        requestBytes: bytes,
                        requestCount: count,
                        outputBytes: output,
                        outputCapacity: capacity
                    )
                }
            }
        }

        // Nothing stored: the user never touched the bar.
        let fresh = try resolve(.init(stored: nil, defaults: .phone))
        XCTAssertTrue(fresh.usedDefaults)
        XCTAssertEqual(fresh.ids, AccessoryKeyCatalog.defaultPhoneBarOrder.map(\.rawValue))

        let tablet = try resolve(.init(stored: nil, defaults: .tablet))
        XCTAssertEqual(tablet.ids, AccessoryKeyCatalog.defaultTabletBarOrder.map(\.rawValue))

        // Stored empty is a deliberately empty row and must stay empty —
        // falling back to defaults here resurrects chips a user removed one at
        // a time. This is exactly where Android's codec diverged.
        let emptied = try resolve(.init(stored: [], defaults: .phone))
        XCTAssertFalse(emptied.usedDefaults)
        XCTAssertEqual(emptied.ids, [])

        // Legacy spellings migrate; unknown entries drop individually rather
        // than costing the whole bar; custom slots survive verbatim.
        let migrated = try resolve(
            .init(
                stored: ["escape", "control-c", "not-a-key", "custom:1E7C", "pgup"],
                defaults: .phone
            )
        )
        XCTAssertEqual(migrated.ids, ["esc", "ctrlC", "custom:1E7C", "pgup"])
    }

    // MARK: - Input: chord rendering and arming

    func testChordRenderingCoversBothNotations() throws {
        func render(_ notation: KeyChordNotation, _ chord: KeyChordABIRequest.Chord) throws -> String {
            let payload = try json(KeyChordABIRequest(notation: notation, chord: chord))
            return try buildString { output, capacity in
                withUTF8(payload) { bytes, count in
                    tesseraInputRenderChord(
                        requestBytes: bytes,
                        requestCount: count,
                        outputBytes: output,
                        outputCapacity: capacity
                    )
                }
            }
        }
        // Modifier order is canonical (⌃⌥⇧⌘) no matter how the chord was
        // built or recorded, so a recorder and a hand-written binding render
        // identically.
        let commandShiftE = KeyChordABIRequest.Chord(
            modifiers: [.command, .shift],
            key: .character("e")
        )
        XCTAssertEqual(try render(.glyph, commandShiftE), "⇧⌘E")
        XCTAssertEqual(try render(.words, commandShiftE), "shift-cmd-e")

        // Control unifies on the Mac glyph rather than the terminal caret, so
        // the ^C chip and a ⌃C binding never describe one key two ways.
        let controlC = KeyChordABIRequest.Chord(modifiers: [.control], key: .character("c"))
        XCTAssertEqual(try render(.glyph, controlC), "⌃C")
        XCTAssertEqual(try render(.words, controlC), "ctrl-c")

        // An empty chord has no readable answer under the string contract.
        let empty = try json(
            KeyChordABIRequest(notation: .glyph, chord: .init(modifiers: [], key: nil))
        )
        XCTAssertEqual(
            withUTF8(empty) { bytes, count in
                tesseraInputRenderChord(
                    requestBytes: bytes,
                    requestCount: count,
                    outputBytes: nil,
                    outputCapacity: 0
                )
            },
            -1
        )
    }

    func testModifierArmingConsumesUnderOneShotAndPersistsUnderSticky() throws {
        func transition(_ request: ModifierArmingABIRequest) throws -> ModifierArmingABIResponse {
            let payload = try json(request)
            return try decode(ModifierArmingABIResponse.self) { output, capacity in
                withUTF8(payload) { bytes, count in
                    tesseraInputModifierArmingTransition(
                        requestBytes: bytes,
                        requestCount: count,
                        outputBytes: output,
                        outputCapacity: capacity
                    )
                }
            }
        }

        let armed = try transition(
            .init(state: ModifierArming(behavior: .oneShot), event: .init(kind: .tap, modifier: .control))
        )
        XCTAssertTrue(armed.state.armed.ctrl)
        XCTAssertTrue(armed.isAnyArmed)
        XCTAssertEqual(armed.consumed, nil)

        let oneShot = try transition(
            .init(state: armed.state, event: .init(kind: .consume))
        )
        XCTAssertEqual(oneShot.consumed?.ctrl, true)
        XCTAssertFalse(oneShot.state.armed.ctrl, "one-shot must clear on the key it modified")

        let sticky = try transition(
            .init(
                state: ModifierArming(behavior: .sticky, armed: TerminalModifiers(ctrl: true)),
                event: .init(kind: .consume)
            )
        )
        XCTAssertEqual(sticky.consumed?.ctrl, true)
        XCTAssertTrue(sticky.state.armed.ctrl, "sticky must survive the key it modified")

        let cancelled = try transition(
            .init(state: sticky.state, event: .init(kind: .cancel))
        )
        XCTAssertFalse(cancelled.isAnyArmed)

        // Tapping an armed modifier disarms it — how a user backs out of a
        // chord they started by mistake.
        let untapped = try transition(
            .init(state: armed.state, event: .init(kind: .tap, modifier: .control))
        )
        XCTAssertFalse(untapped.state.armed.ctrl)

        // Command arms the app's own dispatcher and never reaches the wire.
        let command = try transition(
            .init(
                state: ModifierArming(behavior: .oneShot, armed: TerminalModifiers(cmd: true)),
                event: .init(kind: .consume),
                keyBytes: Data([0x45])
            )
        )
        XCTAssertTrue(command.isCommandArmed == false, "one-shot consume clears the arm")
        XCTAssertEqual(command.consumed?.cmd, true)
        XCTAssertEqual(command.wireModifiers, .none)
        XCTAssertEqual(command.commandChordKey, "e")

        // A multi-byte commit is a paste, not a chord.
        let paste = try transition(
            .init(
                state: ModifierArming(behavior: .sticky, armed: TerminalModifiers(cmd: true)),
                event: .init(kind: .consume),
                keyBytes: Data([0x45, 0x46])
            )
        )
        XCTAssertNil(paste.commandChordKey)

        let malformed = try json(
            ModifierArmingABIRequest(state: ModifierArming(), event: .init(kind: .tap))
        )
        XCTAssertEqual(
            withUTF8(malformed) { bytes, count in
                tesseraInputModifierArmingTransition(
                    requestBytes: bytes,
                    requestCount: count,
                    outputBytes: nil,
                    outputCapacity: 0
                )
            },
            -1
        )
    }

    // MARK: - Session policy: restore cohort

    private let sessionA = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private let sessionB = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
    private let hostA = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!

    func testRestoreVerdictHonoursTheAliveFloorAndMoshReachability() throws {
        func verdict(
            live: ForegroundRestoreLiveStateABI?,
            elapsed: TimeInterval,
            floor: TimeInterval = 0.75
        ) throws -> String {
            let payload = try json(
                ForegroundRestoreVerdictABIRequest(
                    candidate: .init(liveSessionID: sessionA, persistedHostID: hostA),
                    live: live,
                    elapsedSinceWindowOpenedSeconds: elapsed,
                    aliveFloorSeconds: floor
                )
            )
            return try buildString { output, capacity in
                withUTF8(payload) { bytes, count in
                    tesseraSessionRestoreVerdict(
                        requestBytes: bytes,
                        requestCount: count,
                        outputBytes: output,
                        outputCapacity: capacity
                    )
                }
            }
        }

        // The tab is gone: a transport death and a clean remote exit are
        // indistinguishable here, and both want a reconnect offer.
        XCTAssertEqual(try verdict(live: nil, elapsed: 5), "dead")

        let connected = ForegroundRestoreLiveStateABI(
            liveSessionID: sessionA,
            persistedHostID: hostA,
            state: .connected
        )
        // The 4 ms race: two transports died 4 ms apart and the summary a
        // millisecond later still said connected, so "looks connected" is not
        // evidence of life until the floor has passed.
        XCTAssertEqual(try verdict(live: connected, elapsed: 0.001), "pending")
        XCTAssertEqual(try verdict(live: connected, elapsed: 1.0), "alive")

        // Mosh keeps `connected` across network loss by design; its
        // reachability lives in the transport signal.
        let moshUnreachable = ForegroundRestoreLiveStateABI(
            liveSessionID: sessionA,
            persistedHostID: hostA,
            state: .connected,
            transportConfirmed: false
        )
        XCTAssertEqual(try verdict(live: moshUnreachable, elapsed: 10), "pending")

        let failed = ForegroundRestoreLiveStateABI(
            liveSessionID: sessionA,
            persistedHostID: hostA,
            state: .failed
        )
        XCTAssertEqual(try verdict(live: failed, elapsed: 0), "dead")
        XCTAssertEqual(
            try verdict(
                live: .init(liveSessionID: sessionA, persistedHostID: hostA, state: .connecting),
                elapsed: 10
            ),
            "pending"
        )
    }

    func testRestoreEvaluationReportsDeadIndicesAndRetirements() throws {
        let request = ForegroundRestoreEvaluateABIRequest(
            cohort: [
                .init(liveSessionID: sessionA, persistedHostID: hostA),
                .init(liveSessionID: sessionB, persistedHostID: hostA),
            ],
            live: [
                .init(liveSessionID: sessionB, persistedHostID: hostA, state: .connected),
            ],
            elapsedSinceWindowOpenedSeconds: 2,
            aliveFloorSeconds: 0.75,
            retiresDeadImmediately: true
        )
        let payload = try json(request)
        let evaluation = try decode(ForegroundRestoreEvaluationABIResponse.self) { output, capacity in
            withUTF8(payload) { bytes, count in
                tesseraSessionRestoreEvaluate(
                    requestBytes: bytes,
                    requestCount: count,
                    outputBytes: output,
                    outputCapacity: capacity
                )
            }
        }
        XCTAssertEqual(evaluation.deadIDs, [sessionA])
        XCTAssertEqual(evaluation.deadIndices, [0])
        XCTAssertEqual(Set(evaluation.retiredIDs), [sessionA, sessionB])
        XCTAssertTrue(evaluation.hasWork)
    }

    func testWindowClosureChargeDeltaAndPersistModeMatchTheCore() throws {
        func closure(
            remaining: Int32,
            elapsed: Double,
            maximum: Double,
            prompting: Int32
        ) throws -> String {
            try buildString { output, capacity in
                tesseraSessionRestoreWindowClosure(
                    remainingCohortCount: remaining,
                    elapsedSinceWindowOpenedSeconds: elapsed,
                    maxWindowSeconds: maximum,
                    hasUnansweredPrompt: prompting,
                    outputBytes: output,
                    outputCapacity: capacity
                )
            }
        }
        XCTAssertEqual(try closure(remaining: 0, elapsed: 1, maximum: 10, prompting: 0), "settled")
        XCTAssertEqual(try closure(remaining: 2, elapsed: 1, maximum: 10, prompting: 0), "open")
        XCTAssertEqual(try closure(remaining: 2, elapsed: 11, maximum: 10, prompting: 0), "backstop")
        // A sheet on screen is a verdict in progress, not one that failed.
        XCTAssertEqual(try closure(remaining: 2, elapsed: 11, maximum: 10, prompting: 1), "open")

        XCTAssertEqual(
            tesseraSessionRestoreChargeDelta(
                nowSeconds: 100,
                lastChargeAtSeconds: 99.5,
                hasLastChargeAt: 1,
                isPrompting: 0,
                maxTickSeconds: 1
            ),
            0.5,
            accuracy: 1e-9
        )
        // A host-key sheet pauses every connecting session's budget, so the
        // window must not keep spending while it is up.
        XCTAssertEqual(
            tesseraSessionRestoreChargeDelta(
                nowSeconds: 100,
                lastChargeAtSeconds: 99.5,
                hasLastChargeAt: 1,
                isPrompting: 1,
                maxTickSeconds: 1
            ),
            0
        )
        // A gap past the cap means the process was suspended, not that time
        // was spent waiting on the wake.
        XCTAssertEqual(
            tesseraSessionRestoreChargeDelta(
                nowSeconds: 100,
                lastChargeAtSeconds: 40,
                hasLastChargeAt: 1,
                isPrompting: 0,
                maxTickSeconds: 1
            ),
            1
        )
        XCTAssertEqual(
            tesseraSessionRestoreChargeDelta(
                nowSeconds: 100,
                lastChargeAtSeconds: 0,
                hasLastChargeAt: 0,
                isPrompting: 0,
                maxTickSeconds: 1
            ),
            0
        )

        func persist(
            active: Int32,
            preserved: Int32,
            open: Int32,
            cohort: Int32
        ) throws -> String {
            try buildString { output, capacity in
                tesseraSessionRestorePersistMode(
                    isActive: active,
                    hasPreservedSnapshots: preserved,
                    isWindowOpen: open,
                    hasCohortEntries: cohort,
                    outputBytes: output,
                    outputCapacity: capacity
                )
            }
        }
        // Backgrounding is the write that carries the dead forward.
        XCTAssertEqual(try persist(active: 0, preserved: 0, open: 0, cohort: 0), "mergeWithStored")
        // App lock at wake: snapshots latched, no window yet.
        XCTAssertEqual(try persist(active: 1, preserved: 1, open: 0, cohort: 0), "mergeWithStored")
        XCTAssertEqual(try persist(active: 1, preserved: 0, open: 1, cohort: 1), "keepCohort")
        XCTAssertEqual(try persist(active: 1, preserved: 0, open: 1, cohort: 0), "liveOnly")
    }

    func testRestoreDocumentRulesReportViolationsAndRepairTheSelection() throws {
        func rules(_ request: ForegroundRestoreDocumentABIRequest) throws
            -> ForegroundRestoreDocumentABIResponse {
            let payload = try json(request)
            return try decode(ForegroundRestoreDocumentABIResponse.self) { output, capacity in
                withUTF8(payload) { bytes, count in
                    tesseraSessionRestoreDocumentRules(
                        requestBytes: bytes,
                        requestCount: count,
                        outputBytes: output,
                        outputCapacity: capacity
                    )
                }
            }
        }

        let valid = try rules(
            .init(schemaVersion: 1, sessionIDs: [sessionA, sessionB], selectedSessionID: sessionB)
        )
        XCTAssertTrue(valid.isValid)
        XCTAssertEqual(valid.violations, [])
        XCTAssertEqual(valid.normalizedSelection, sessionB)
        XCTAssertEqual(valid.maxSnapshots, 64)
        XCTAssertEqual(valid.schemaVersion, 1)

        // A document written by another schema describes sessions whose
        // reconnect semantics we no longer know.
        let wrongSchema = try rules(
            .init(schemaVersion: 2, sessionIDs: [sessionA], selectedSessionID: nil)
        )
        XCTAssertFalse(wrongSchema.isValid)
        XCTAssertEqual(wrongSchema.violations.first?.kind, .unsupportedSchemaVersion)
        XCTAssertEqual(wrongSchema.violations.first?.count, 2)

        let duplicated = try rules(
            .init(schemaVersion: 1, sessionIDs: [sessionA, sessionA], selectedSessionID: nil)
        )
        XCTAssertEqual(duplicated.violations.first?.kind, .duplicateSessionID)
        XCTAssertEqual(duplicated.violations.first?.sessionID, sessionA)

        let tooMany = try rules(
            .init(
                schemaVersion: 1,
                sessionIDs: (0..<65).map { _ in UUID() },
                selectedSessionID: nil
            )
        )
        XCTAssertEqual(tooMany.violations.first?.kind, .tooManySnapshots)
        XCTAssertEqual(tooMany.violations.first?.count, 65)

        // A dangling selection is repaired, not rejected: the sessions are
        // still restorable and only the highlight is stale.
        let dangling = try rules(
            .init(schemaVersion: 1, sessionIDs: [sessionA], selectedSessionID: sessionB)
        )
        XCTAssertNil(dangling.normalizedSelection)
        XCTAssertEqual(dangling.violations.first?.kind, .selectedSessionNotPresent)
    }

    // MARK: - Session policy: resize coalescing

    func testResizeCoalescerSendsFirstWaitsThenDropsTheModalStorm() throws {
        func note(
            _ state: TerminalResizeCoalescerStateABI,
            _ size: TerminalResizeCoalescerStateABI.Size
        ) throws -> TerminalResizeCoalescerNoteABIResponse {
            let payload = try json(TerminalResizeCoalescerABIRequest(state: state, size: size))
            return try decode(TerminalResizeCoalescerNoteABIResponse.self) { output, capacity in
                withUTF8(payload) { bytes, count in
                    tesseraSessionResizeNote(
                        requestBytes: bytes,
                        requestCount: count,
                        outputBytes: output,
                        outputCapacity: capacity
                    )
                }
            }
        }

        // First size SENDs: the session cannot start without it. Android used
        // to schedule this one, which is the drift the shared rule closes.
        let first = try note(.init(), .init(cols: 80, rows: 24))
        XCTAssertEqual(first.decision, "send")
        XCTAssertEqual(first.state.lastDelivered, .init(cols: 80, rows: 24))
        XCTAssertNil(first.state.pending)

        // The modal storm: shrink, then come back to the same size.
        let shrink = try note(first.state, .init(cols: 80, rows: 22))
        XCTAssertEqual(shrink.decision, "wait")
        XCTAssertEqual(shrink.state.pending, .init(cols: 80, rows: 22))

        let restored = try note(shrink.state, .init(cols: 80, rows: 24))
        XCTAssertEqual(restored.decision, "drop")
        XCTAssertNil(restored.state.pending)

        // A stale timer must not deliver a superseded size.
        func settle(
            _ state: TerminalResizeCoalescerStateABI,
            _ size: TerminalResizeCoalescerStateABI.Size
        ) throws -> TerminalResizeCoalescerSettleABIResponse {
            let payload = try json(TerminalResizeCoalescerABIRequest(state: state, size: size))
            return try decode(TerminalResizeCoalescerSettleABIResponse.self) { output, capacity in
                withUTF8(payload) { bytes, count in
                    tesseraSessionResizeSettle(
                        requestBytes: bytes,
                        requestCount: count,
                        outputBytes: output,
                        outputCapacity: capacity
                    )
                }
            }
        }
        XCTAssertFalse(try settle(restored.state, .init(cols: 80, rows: 22)).settled)

        let settled = try settle(shrink.state, .init(cols: 80, rows: 22))
        XCTAssertTrue(settled.settled)
        XCTAssertEqual(settled.state.lastDelivered, .init(cols: 80, rows: 22))
        XCTAssertNil(settled.state.pending)

        // A state the coalescer cannot reach is refused rather than
        // normalized: replaying "waiting with nothing delivered" would answer
        // `send`, and "waiting for the delivered size" would answer `drop` —
        // both plausible-looking answers to a state that never existed.
        for impossible in [
            #"{"size":{"cols":80,"rows":24},"state":{"pending":{"cols":80,"rows":22}}}"#,
            #"{"size":{"cols":80,"rows":24},"state":{"lastDelivered":{"cols":80,"rows":24},"pending":{"cols":80,"rows":24}}}"#,
        ] {
            XCTAssertEqual(
                withUTF8(impossible) { bytes, count in
                    tesseraSessionResizeNote(
                        requestBytes: bytes,
                        requestCount: count,
                        outputBytes: nil,
                        outputCapacity: 0
                    )
                },
                -1
            )
            XCTAssertEqual(
                withUTF8(impossible) { bytes, count in
                    tesseraSessionResizeSettle(
                        requestBytes: bytes,
                        requestCount: count,
                        outputBytes: nil,
                        outputCapacity: 0
                    )
                },
                -1
            )
        }

        XCTAssertEqual(tesseraSessionResizeSettleSeconds(), 0.12)
        XCTAssertEqual(tesseraSessionResizeSettleSeconds(), TerminalResizeCoalescer.settleSeconds)
    }

    // MARK: - Session policy: end classification and retry

    func testRemoteExitVersusEOFIsTheRestoreRecordDecision() throws {
        // EOF alone proves only that the socket is gone.
        XCTAssertEqual(tesseraSessionRemoteProcessEnded(exitStatus: 0, hasExitStatus: 0), 0)
        XCTAssertEqual(tesseraSessionRetainsRestoreRecord(exitStatus: 0, hasExitStatus: 0), 1)
        // Any status — including 0 — is authenticated evidence of a real exit.
        XCTAssertEqual(tesseraSessionRemoteProcessEnded(exitStatus: 0, hasExitStatus: 1), 1)
        XCTAssertEqual(tesseraSessionRemoteProcessEnded(exitStatus: 130, hasExitStatus: 1), 1)
        XCTAssertEqual(tesseraSessionRetainsRestoreRecord(exitStatus: 130, hasExitStatus: 1), 0)

        // Native mosh's transport stop carries no remote status, so the
        // mosh-server on the far side is still there to re-attach.
        XCTAssertEqual(tesseraSessionMoshRemoteProcessEnded(isShutdownCompletion: 0), 0)
        XCTAssertEqual(tesseraSessionMoshRemoteProcessEnded(isShutdownCompletion: 1), 1)
    }

    func testRetryPolicyStructuralRulesAndTransientMarkerTable() throws {
        func shouldRetry(_ request: SessionRetryABIRequest) throws -> Int32 {
            let payload = try json(request)
            return withUTF8(payload) { bytes, count in
                tesseraSessionShouldRetry(requestBytes: bytes, requestCount: count)
            }
        }

        // The user asked for it.
        XCTAssertEqual(
            try shouldRetry(
                .init(
                    explicitDisconnect: true,
                    hadConnectedTransport: true,
                    alreadyRecovering: false,
                    code: "transport_disconnected",
                    arguments: [:]
                )
            ),
            0
        )
        // A first-attempt failure is configuration or credentials; retrying it
        // just spends the user's lockout budget.
        XCTAssertEqual(
            try shouldRetry(
                .init(
                    explicitDisconnect: false,
                    hadConnectedTransport: false,
                    alreadyRecovering: false,
                    code: "transport_disconnected",
                    arguments: [:]
                )
            ),
            0
        )
        XCTAssertEqual(
            try shouldRetry(
                .init(
                    explicitDisconnect: false,
                    hadConnectedTransport: false,
                    alreadyRecovering: true,
                    code: "transport_disconnected",
                    arguments: [:]
                )
            ),
            1
        )
        XCTAssertEqual(
            try shouldRetry(
                .init(
                    explicitDisconnect: false,
                    hadConnectedTransport: true,
                    alreadyRecovering: false,
                    code: "transport_disconnected",
                    arguments: [:]
                )
            ),
            1
        )
        // Case-insensitive substring match, so a wrapped exception message
        // still matches the marker it contains.
        XCTAssertEqual(
            try shouldRetry(
                .init(
                    explicitDisconnect: false,
                    hadConnectedTransport: true,
                    alreadyRecovering: false,
                    code: "session_failed",
                    arguments: ["detail": "java.io.IOException: Broken pipe"]
                )
            ),
            1
        )
        XCTAssertEqual(
            try shouldRetry(
                .init(
                    explicitDisconnect: false,
                    hadConnectedTransport: true,
                    alreadyRecovering: false,
                    code: "session_failed",
                    arguments: ["detail": "permission denied (publickey)"]
                )
            ),
            0
        )
        XCTAssertEqual(
            tesseraSessionShouldRetry(requestBytes: nil, requestCount: 0),
            -1
        )

        XCTAssertEqual(tesseraSessionRetryMaxAttempts(), 5)
        XCTAssertEqual(tesseraSessionRetryDelaySeconds(attempt: 1), 0.25)
        XCTAssertEqual(tesseraSessionRetryDelaySeconds(attempt: 5), 4.0)
        // Clamped at both ends rather than growing without bound.
        XCTAssertEqual(tesseraSessionRetryDelaySeconds(attempt: 0), 0.25)
        XCTAssertEqual(tesseraSessionRetryDelaySeconds(attempt: 99), 4.0)
    }

    // MARK: - Mosh

    func testMoshConnectParseIsStrictAndClassifiesItsFailures() throws {
        func parse(stdout: String, stderr: String = "") throws -> MoshConnectABIResponse {
            try decode(MoshConnectABIResponse.self) { output, capacity in
                withUTF8(stdout) { outBytes, outCount in
                    withUTF8(stderr) { errBytes, errCount in
                        tesseraMoshParseConnectResponse(
                            stdoutBytes: outBytes,
                            stdoutCount: outCount,
                            stderrBytes: errBytes,
                            stderrCount: errCount,
                            outputBytes: output,
                            outputCapacity: capacity
                        )
                    }
                }
            }
        }

        let key = String(repeating: "A", count: 22)
        let good = try parse(
            stdout: "[mosh-server detached, pid = 4321]\nMOSH CONNECT 60001 \(key)\n"
        )
        XCTAssertTrue(good.ok)
        XCTAssertEqual(good.credentials?.udpPort, 60001)
        XCTAssertEqual(good.credentials?.base64Key, key)
        XCTAssertEqual(good.credentials?.serverPID, 4321)

        // The strict literal prefix: a tab-separated banner is a shape
        // mosh-server never emits, and accepting it only widens what a garbled
        // transcript can talk the client into dialling.
        let tabbed = try parse(stdout: "MOSH\tCONNECT\t60001\t\(key)\n")
        XCTAssertFalse(tabbed.ok)
        XCTAssertEqual(tabbed.failure, .missingConnect)

        let malformed = try parse(stdout: "MOSH CONNECT not-a-port \(key)\n")
        XCTAssertFalse(malformed.ok)
        XCTAssertEqual(malformed.failure, .malformedConnect)

        let missingServer = try parse(stdout: "", stderr: "bash: mosh-server: command not found\n")
        XCTAssertFalse(missingServer.ok)
        XCTAssertEqual(missingServer.failure, .missingServer)

        // Neither a bare "command not found" nor a mention of mosh-server is a
        // diagnosis on its own.
        XCTAssertEqual(
            withUTF8("mosh-server is installed at /usr/bin") { bytes, count in
                tesseraMoshTranscriptSuggestsMissingServer(
                    stdoutBytes: bytes,
                    stdoutCount: count,
                    stderrBytes: nil,
                    stderrCount: 0
                )
            },
            0
        )
        XCTAssertEqual(
            withUTF8("sh: mosh-server: not found") { bytes, count in
                tesseraMoshTranscriptSuggestsMissingServer(
                    stdoutBytes: bytes,
                    stdoutCount: count,
                    stderrBytes: nil,
                    stderrCount: 0
                )
            },
            1
        )
    }

    func testMoshCommandBuildersAndPIDHelpers() throws {
        XCTAssertEqual(
            try buildString { output, capacity in
                tesseraMoshServerNewCommand(
                    launchCommandBytes: nil,
                    launchCommandCount: 0,
                    outputBytes: output,
                    outputCapacity: capacity
                )
            },
            MoshBootstrapGrammar.serverNewCommand(launchCommand: nil)
        )
        XCTAssertEqual(
            try buildString { output, capacity in
                withUTF8("  ") { bytes, count in
                    tesseraMoshServerNewCommand(
                        launchCommandBytes: bytes,
                        launchCommandCount: count,
                        outputBytes: output,
                        outputCapacity: capacity
                    )
                }
            },
            MoshBootstrapGrammar.serverNewCommand(launchCommand: nil),
            "an all-whitespace launch command must still yield a plain login shell"
        )
        XCTAssertEqual(
            try buildString { output, capacity in
                withUTF8("tmux new -A -s tessera") { bytes, count in
                    tesseraMoshServerNewCommand(
                        launchCommandBytes: bytes,
                        launchCommandCount: count,
                        outputBytes: output,
                        outputCapacity: capacity
                    )
                }
            },
            MoshBootstrapGrammar.serverNewCommand(launchCommand: "tmux new -A -s tessera")
        )
        XCTAssertTrue(
            MoshBootstrapGrammar.serverNewCommand(launchCommand: "tmux new -A -s tessera")
                .contains("exec mosh-server new -c 256 -- tmux new -A -s tessera"),
            "the ABI must hand Android the same login-shell-resolving command iOS runs"
        )

        let script = try buildString { output, capacity in
            tesseraMoshServerTerminationScript(
                pid: 4321,
                outputBytes: output,
                outputCapacity: capacity
            )
        }
        XCTAssertEqual(script, MoshBootstrapGrammar.makeServerTerminationScript(pid: 4321))
        // The PID-reuse fence is the whole point of the script.
        XCTAssertTrue(script.contains("ps -p"))
        XCTAssertTrue(script.contains("*mosh-server*"))
        XCTAssertTrue(script.contains("kill -TERM"))
        XCTAssertFalse(script.contains("kill -KILL"))
        XCTAssertEqual(
            tesseraMoshServerTerminationScript(pid: 0, outputBytes: nil, outputCapacity: 0),
            -1
        )

        XCTAssertEqual(
            withUTF8("[mosh-server detached, pid = 4321]") { bytes, count in
                tesseraMoshDetachedServerPID(outputInputBytes: bytes, outputInputCount: count)
            },
            4321
        )
        let liveness = try buildString { output, capacity in
            tesseraMoshServerLivenessScript(pid: 4321, outputBytes: output, outputCapacity: capacity)
        }
        XCTAssertEqual(liveness, MoshBootstrapGrammar.makeServerLivenessScript(pid: 4321))
        XCTAssertFalse(liveness.contains("-TERM"), "the probe must never signal the server")
        XCTAssertEqual(tesseraMoshServerLivenessScript(pid: -1, outputBytes: nil, outputCapacity: 0), -1)
        for (output, verdict) in [
            ("TESSERA_MOSH_SERVER=alive\n", Int32(1)),
            ("TESSERA_MOSH_SERVER=gone\n", 2),
            ("TESSERA_MOSH_SERVER=unknown\n", 0),
            ("sh: ps: not found\n", 0),
        ] {
            XCTAssertEqual(
                withUTF8(output) { bytes, count in
                    tesseraMoshServerLivenessVerdict(outputInputBytes: bytes, outputInputCount: count)
                },
                verdict,
                output
            )
        }
        XCTAssertEqual(tesseraMoshServerLivenessVerdict(outputInputBytes: nil, outputInputCount: 0), 0)
        XCTAssertEqual(
            withBytes([0xFF, 0xFE]) { bytes, count in
                tesseraMoshServerLivenessVerdict(outputInputBytes: bytes, outputInputCount: count)
            },
            -1
        )
        XCTAssertEqual(tesseraMoshServerLivenessGraceMilliseconds(), 3_000)
        XCTAssertEqual(tesseraMoshServerLivenessNextProbeMilliseconds(outcome: 2, consecutiveHostFailures: 0, askedOwner: 0), -1)
        XCTAssertEqual(tesseraMoshServerLivenessNextProbeMilliseconds(outcome: 1, consecutiveHostFailures: 0, askedOwner: 0), 60_000)
        XCTAssertEqual(tesseraMoshServerLivenessNextProbeMilliseconds(outcome: 0, consecutiveHostFailures: 0, askedOwner: 0), 60_000)
        XCTAssertEqual(
            (1...11).map {
                tesseraMoshServerLivenessNextProbeMilliseconds(outcome: 3, consecutiveHostFailures: Int32($0), askedOwner: 0)
            },
            [2_000, 4_000, 8_000, 15_000, 15_000, 15_000, 15_000, 30_000, 30_000, 60_000, 60_000]
        )
        XCTAssertEqual(tesseraMoshServerLivenessNextProbeMilliseconds(outcome: 3, consecutiveHostFailures: 2, askedOwner: 0), 4_000)
        XCTAssertEqual(tesseraMoshServerLivenessNextProbeMilliseconds(outcome: 3, consecutiveHostFailures: 2, askedOwner: 1), 60_000)
        XCTAssertEqual(tesseraMoshServerLivenessNextProbeMilliseconds(outcome: 1, consecutiveHostFailures: 0, askedOwner: 1), -2)
        XCTAssertEqual(tesseraMoshServerLivenessNextProbeMilliseconds(outcome: 0, consecutiveHostFailures: 0, askedOwner: 1), -2)
        XCTAssertEqual(tesseraMoshServerLivenessNextProbeMilliseconds(outcome: 2, consecutiveHostFailures: 0, askedOwner: 1), -1)
        XCTAssertEqual(tesseraMoshServerLivenessNextProbeMilliseconds(outcome: 9, consecutiveHostFailures: 0, askedOwner: 0), -1)

        // No banner is ordinary; 0 means "cannot safely signal the server".
        XCTAssertEqual(
            withUTF8("nothing to see") { bytes, count in
                tesseraMoshDetachedServerPID(outputInputBytes: bytes, outputInputCount: count)
            },
            0
        )

        let key = String(repeating: "A", count: 22)
        XCTAssertEqual(
            try buildString { output, capacity in
                withUTF8(key + "==") { bytes, count in
                    tesseraMoshNormalizedConnectKey(
                        keyBytes: bytes,
                        keyCount: count,
                        outputBytes: output,
                        outputCapacity: capacity
                    )
                }
            },
            key
        )
        XCTAssertEqual(
            withUTF8("too-short") { bytes, count in
                tesseraMoshNormalizedConnectKey(
                    keyBytes: bytes,
                    keyCount: count,
                    outputBytes: nil,
                    outputCapacity: 0
                )
            },
            -1
        )

        let summary = try buildString { output, capacity in
            withUTF8("MOSH CONNECT 60001 \(key)") { outBytes, outCount in
                tesseraMoshBootstrapTranscriptSummary(
                    stdoutBytes: outBytes,
                    stdoutCount: outCount,
                    stderrBytes: nil,
                    stderrCount: 0,
                    outputBytes: output,
                    outputCapacity: capacity
                )
            }
        }
        XCTAssertTrue(summary.contains("connectMarker=true"))
        XCTAssertFalse(summary.contains(key), "a summary must never carry key material")
    }

    func testRedactionAppliesTheCoreOrderNotTheCallersArgumentOrder() throws {
        func redact(_ text: String, patterns: [String]? = nil) throws -> String {
            let encoded = try patterns.map { try json($0) }
            return try buildString { output, capacity in
                withUTF8(text) { textBytes, textCount in
                    if let encoded {
                        return withUTF8(encoded) { patternBytes, patternCount in
                            tesseraRedactSensitive(
                                textBytes: textBytes,
                                textCount: textCount,
                                patternsBytes: patternBytes,
                                patternsCount: patternCount,
                                outputBytes: output,
                                outputCapacity: capacity
                            )
                        }
                    }
                    return tesseraRedactSensitive(
                        textBytes: textBytes,
                        textCount: textCount,
                        patternsBytes: nil,
                        patternsCount: 0,
                        outputBytes: output,
                        outputCapacity: capacity
                    )
                }
            }
        }

        let key = String(repeating: "A", count: 22)
        // The invariant: a transcript containing MOSH CONNECT never survives
        // redaction with the key intact.
        let scrubbed = try redact("connecting: MOSH CONNECT 60001 \(key) now")
        XCTAssertFalse(scrubbed.contains(key))

        XCTAssertFalse(try redact("stray \(key) token").contains(key))
        XCTAssertFalse(try redact("password=hunter2").contains("hunter2"))
        XCTAssertFalse(try redact("token:abc123").contains("abc123"))
        XCTAssertFalse(try redact("deploy@example.com").contains("example.com"))

        // The transport-detail subset deliberately keeps the endpoint: the
        // user is entitled to see which host they failed to reach.
        let detail = try redact(
            "deploy@example.com refused; MOSH CONNECT 60001 \(key)",
            patterns: ["moshConnectLine", "moshConnectKey"]
        )
        XCTAssertTrue(detail.contains("deploy@example.com"))
        XCTAssertFalse(detail.contains(key))

        // Order is the core's: asking for the key scrub first must not change
        // what the line scrub does.
        XCTAssertEqual(
            try redact(
                "MOSH CONNECT 60001 \(key)",
                patterns: ["moshConnectKey", "moshConnectLine"]
            ),
            try redact("MOSH CONNECT 60001 \(key)", patterns: ["moshConnectLine", "moshConnectKey"])
        )

        let unknown = try json(["notAPattern"])
        XCTAssertEqual(
            withUTF8("text") { textBytes, textCount in
                withUTF8(unknown) { patternBytes, patternCount in
                    tesseraRedactSensitive(
                        textBytes: textBytes,
                        textCount: textCount,
                        patternsBytes: patternBytes,
                        patternsCount: patternCount,
                        outputBytes: nil,
                        outputCapacity: 0
                    )
                }
            },
            -1
        )
    }

    // MARK: - OS detection

    func testOSDetectionProbeAndParse() throws {
        let command = try buildString { output, capacity in
            tesseraOSDetectionProbeCommand(outputBytes: output, outputCapacity: capacity)
        }
        XCTAssertEqual(command, RemoteOSDetection.probeCommand)
        // The trailing `exit 0` is load-bearing: a missing release file makes
        // the last `cat` exit non-zero, which a client turns into a command
        // failure and discards the accumulated stdout with.
        XCTAssertTrue(command.hasSuffix("exit 0"))

        let macOS = try decode(RemoteOSDetectionABIResponse.self) { output, capacity in
            withUTF8("Darwin\n") { bytes, count in
                tesseraOSDetectionParse(
                    probeOutputBytes: bytes,
                    probeOutputCount: count,
                    outputBytes: output,
                    outputCapacity: capacity
                )
            }
        }
        XCTAssertEqual(macOS.osHint, "macos")
        XCTAssertEqual(macOS.networkPath.kind, .unavailable)
        XCTAssertNil(macOS.networkPath.warning)

        XCTAssertEqual(
            try buildString { output, capacity in
                withUTF8("Darwin\n") { bytes, count in
                    tesseraOSDetectionParseFamily(
                        probeOutputBytes: bytes,
                        probeOutputCount: count,
                        outputBytes: output,
                        outputCapacity: capacity
                    )
                }
            },
            "macos"
        )
        // No family identified is the ordinary "no badge update" outcome.
        XCTAssertEqual(
            withUTF8("banner only") { bytes, count in
                tesseraOSDetectionParseFamily(
                    probeOutputBytes: bytes,
                    probeOutputCount: count,
                    outputBytes: nil,
                    outputCapacity: 0
                )
            },
            -1
        )

        // The documented Tailscale-on-WSL2 shape: the outer interface is too
        // small to carry the encrypted packet.
        let transcript = """
            Linux
            \(RemoteOSDetection.networkMarker) kernel=5.15.0-microsoft-standard-WSL2
            \(RemoteOSDetection.networkMarker) tailscale_path=1
            \(RemoteOSDetection.networkMarker) default_mtu=1280
            \(RemoteOSDetection.networkMarker) tailscale_mtu=1280
            """
        let expected = RemoteOSDetection.parse(probeOutput: transcript)
        let wsl = try decode(RemoteOSDetectionABIResponse.self) { output, capacity in
            withUTF8(transcript) { bytes, count in
                tesseraOSDetectionParse(
                    probeOutputBytes: bytes,
                    probeOutputCount: count,
                    outputBytes: output,
                    outputCapacity: capacity
                )
            }
        }
        XCTAssertEqual(wsl.osHint, expected.osHint)
        switch expected.networkPathAssessment {
        case .warning(let warning):
            XCTAssertEqual(wsl.networkPath.kind, .warning)
            XCTAssertEqual(wsl.networkPath.warning, warning)
        case .notAtRisk:
            XCTAssertEqual(wsl.networkPath.kind, .notAtRisk)
        case .unavailable:
            XCTAssertEqual(wsl.networkPath.kind, .unavailable)
        }
    }

    // MARK: - Trust

    /// Real ed25519 host keys, so the structural check (algorithm token,
    /// canonical base64, and the algorithm name INSIDE the blob agreeing with
    /// it) is exercised rather than sidestepped.
    private static func hostKey(seed: UInt8) -> String {
        var blob = Data()
        let name = Data("ssh-ed25519".utf8)
        blob.append(contentsOf: [0, 0, 0, UInt8(name.count)])
        blob.append(name)
        blob.append(contentsOf: [0, 0, 0, 32])
        blob.append(Data(repeating: seed, count: 32))
        return "ssh-ed25519 \(blob.base64EncodedString())"
    }

    func testTrustCheckReportsRevertedSeparatelyFromChanged() throws {
        let current = Self.hostKey(seed: 1)
        let previous = Self.hostKey(seed: 2)
        let stranger = Self.hostKey(seed: 3)

        func check(
            presented: String,
            trusted: String?,
            previousKey: String? = nil
        ) throws -> KnownHostCheckABIResponse {
            let payload = try json(
                KnownHostCheckABIRequest(
                    endpoint: KnownHostEndpoint(host: "example.test", port: 22),
                    presented: .init(keyString: presented),
                    trusted: trusted.map {
                        .init(key: .init(keyString: $0), trustedAtSeconds: 1_756_000_000)
                    },
                    previous: previousKey.map { .init(keyString: $0) }
                )
            )
            return try decode(KnownHostCheckABIResponse.self) { output, capacity in
                withUTF8(payload) { bytes, count in
                    tesseraTrustCheck(
                        requestBytes: bytes,
                        requestCount: count,
                        outputBytes: output,
                        outputCapacity: capacity
                    )
                }
            }
        }

        XCTAssertEqual(try check(presented: current, trusted: nil).verdict, .unknown)
        XCTAssertEqual(try check(presented: current, trusted: current).verdict, .trusted)
        XCTAssertEqual(try check(presented: stranger, trusted: current).verdict, .changed)
        XCTAssertEqual(
            try check(presented: previous, trusted: current, previousKey: previous).verdict,
            .revertedToPrevious
        )
        // Passing no previous key must be byte-identical to the old behavior.
        XCTAssertEqual(try check(presented: previous, trusted: current).verdict, .changed)
        // The current pin is checked FIRST: a platform that stored the same key
        // as both current and previous must still report trusted.
        XCTAssertEqual(
            try check(presented: current, trusted: current, previousKey: current).verdict,
            .trusted
        )

        let reverted = try check(presented: previous, trusted: current, previousKey: previous)
        // The payload keeps the CURRENTLY pinned key, so a caller that does not
        // care about the distinction can treat it exactly like `.changed`.
        XCTAssertNotEqual(reverted.presentedFingerprint, reverted.trustedFingerprint)
    }

    func testEndpointNormalizationAndFingerprintPadding() throws {
        func normalize(_ host: String, _ port: Int32) throws -> KnownHostEndpointABIResponse {
            try decode(KnownHostEndpointABIResponse.self) { output, capacity in
                withUTF8(host) { bytes, count in
                    tesseraTrustNormalizeEndpoint(
                        hostBytes: bytes,
                        hostCount: count,
                        port: port,
                        outputBytes: output,
                        outputCapacity: capacity
                    )
                }
            }
        }

        let trailingDot = try normalize("  Example.COM.  ", 22)
        XCTAssertTrue(trailingDot.ok)
        XCTAssertEqual(trailingDot.endpoint?.host, "example.com")
        XCTAssertEqual(trailingDot.storageKey, "example.com:22")
        // ssh(1) writes a bare host at the default port.
        XCTAssertEqual(trailingDot.openSSHHostField, "example.com")

        let bracketed = try normalize("[::1]", 2222)
        XCTAssertEqual(bracketed.endpoint?.host, "::1")
        XCTAssertEqual(bracketed.openSSHHostField, "[::1]:2222")

        // A name with two roots is malformed input, not a name to repair.
        let doubleDot = try normalize("example.com..", 22)
        XCTAssertEqual(doubleDot.endpoint?.host, "example.com.")

        XCTAssertEqual(try normalize("   ", 22).error, .emptyHost)
        XCTAssertEqual(try normalize("a b", 22).error, .hostContainsWhitespace)
        XCTAssertEqual(try normalize("example.com", 0).error, .portOutOfRange)
        XCTAssertEqual(try normalize("example.com", 65_536).error, .portOutOfRange)

        let blob = Data("tessera".utf8)
        let unpadded = try buildString { output, capacity in
            withBytes([UInt8](blob)) { bytes, count in
                tesseraTrustSHA256Fingerprint(
                    blobBytes: bytes,
                    blobCount: count,
                    padded: 0,
                    outputBytes: output,
                    outputCapacity: capacity
                )
            }
        }
        let padded = try buildString { output, capacity in
            withBytes([UInt8](blob)) { bytes, count in
                tesseraTrustSHA256Fingerprint(
                    blobBytes: bytes,
                    blobCount: count,
                    padded: 1,
                    outputBytes: output,
                    outputCapacity: capacity
                )
            }
        }
        XCTAssertEqual(unpadded, SSHHostPublicKey.sha256Fingerprint(of: blob))
        XCTAssertEqual(padded, SSHHostPublicKey.sha256Fingerprint(of: blob, padding: .padded))
        XCTAssertTrue(unpadded.hasPrefix("SHA256:"))
        XCTAssertFalse(unpadded.hasSuffix("="))
        XCTAssertTrue(padded.hasSuffix("="))
    }

    private func importPlan(
        _ request: KnownHostsImportPlanABIRequest
    ) throws -> KnownHostsImportPlanABIResponse {
        let payload = try json(request)
        return try decode(KnownHostsImportPlanABIResponse.self) { output, capacity in
            withUTF8(payload) { bytes, count in
                tesseraTrustKnownHostsImportPlan(
                    requestBytes: bytes,
                    requestCount: count,
                    outputBytes: output,
                    outputCapacity: capacity
                )
            }
        }
    }

    private static func fingerprint(seed: UInt8) -> String {
        SSHHostPublicKey.sha256Fingerprint(
            of: Data(base64Encoded: hostKey(seed: seed).split(separator: " ")[1].description)!
        )
    }

    func testImportPlanIsBuiltWholeAndNeverMutatesOnABadLine() throws {
        let first = Self.hostKey(seed: 10)
        let second = Self.hostKey(seed: 11)
        let rotated = Self.hostKey(seed: 12)
        let text = """
            # a comment
            good.example \(first)
            @cert-authority ca.example \(second)
            |1|c2FsdA==|aGFzaA== \(second)
            [rotated.example]:2222 \(rotated)
            broken-line-with-two-fields
            """

        let existing = [
            "rotated.example:2222": SSHHostPublicKey.sha256Fingerprint(
                of: Data(base64Encoded: Self.hostKey(seed: 99).split(separator: " ")[1].description)!
            ),
        ]
        let payload = try json(
            KnownHostsImportPlanABIRequest(text: text, existingFingerprints: existing)
        )
        let plan = try decode(KnownHostsImportPlanABIResponse.self) { output, capacity in
            withUTF8(payload) { bytes, count in
                tesseraTrustKnownHostsImportPlan(
                    requestBytes: bytes,
                    requestCount: count,
                    outputBytes: output,
                    outputCapacity: capacity
                )
            }
        }

        // Two good lines survive alongside three rejections; the store is
        // untouched because nothing here can touch it.
        XCTAssertEqual(plan.candidates.count, 2)
        XCTAssertEqual(plan.addCount, 1)
        XCTAssertEqual(plan.replaceCount, 1)
        XCTAssertFalse(plan.isNoOp)

        let add = try XCTUnwrap(plan.candidates.first { $0.action == .add })
        XCTAssertEqual(add.endpointKey, "good.example:22")
        XCTAssertEqual(add.port, 22)
        XCTAssertNil(add.expectedPriorFingerprint)

        let replace = try XCTUnwrap(plan.candidates.first { $0.action == .replace })
        XCTAssertEqual(replace.endpointKey, "rotated.example:2222")
        // Apply-time must re-check this: a reviewed plan is a proposal about a
        // past state, and the store can have moved underneath it.
        XCTAssertEqual(replace.expectedPriorFingerprint, existing["rotated.example:2222"])

        let reasons = Set(plan.rejections.map(\.reason))
        // Reinterpreting a CA delegation as an ordinary pin would widen trust
        // to everything the CA signs.
        XCTAssertTrue(reasons.contains("unsupportedMarker"))
        XCTAssertTrue(reasons.contains("hashedHost"))
        XCTAssertTrue(reasons.contains("missingFields"))
        XCTAssertEqual(
            plan.rejections.first { $0.reason == "unsupportedMarker" }?.marker,
            "@cert-authority"
        )
    }

    func testImportPlanNormalizedKeysThePlanInTheStoresOwnSpace() throws {
        // The defect this pins: the plan used to be keyed by the file's own
        // spelling while Android's store is keyed normalized, so a pin the file
        // spells differently missed the lookup, was planned as an `add` with no
        // prior fingerprint, and was then refused by `trustIfUnchanged` — the
        // review sheet promised an import that never happened. And two
        // spellings of one host looked like two endpoints, so no ambiguity
        // fired and whichever line applied last silently won.
        let rotated = Self.hostKey(seed: 30)
        let stable = Self.hostKey(seed: 31)
        let contested = Self.hostKey(seed: 32)
        let text = """
            Rotate.Example. \(rotated)
            [2001:DB8::1]:2222 \(stable)
            Contested.Example \(rotated)
            contested.example. \(contested)
            """
        let existing = [
            "rotate.example:22": Self.fingerprint(seed: 99),
            "2001:db8::1:2222": Self.fingerprint(seed: 31),
        ]

        let normalized = try importPlan(
            KnownHostsImportPlanABIRequest(
                text: text,
                existingFingerprints: existing,
                endpointNormalization: .normalized
            )
        )

        // (a) the differently spelled pin is found: replace, not add, and it
        // carries the fingerprint apply-time compares against.
        let replace = try XCTUnwrap(normalized.candidates.first { $0.action == .replace })
        XCTAssertEqual(replace.endpointKey, "rotate.example:22")
        XCTAssertEqual(replace.host, "rotate.example")
        XCTAssertEqual(replace.expectedPriorFingerprint, existing["rotate.example:22"])
        XCTAssertEqual(normalized.addCount, 0)
        // The bracketed IPv6 literal at a non-default port lands on the same
        // key the store holds, so it is correctly "already pinned".
        XCTAssertEqual(
            normalized.candidates.first { $0.action == .unchanged }?.endpointKey,
            "2001:db8::1:2222"
        )
        XCTAssertEqual(normalized.unchangedCount, 1)

        // (b) the two case-variant lines are one endpoint again, so the
        // ambiguity rejection fires on both instead of both being applied.
        let ambiguous = normalized.rejections.filter { $0.reason == "ambiguousEndpoint" }
        XCTAssertEqual(ambiguous.map(\.lineNumber), [3, 4])
        XCTAssertTrue(ambiguous.allSatisfy { $0.source == "contested.example:22" })
        XCTAssertFalse(normalized.candidates.contains { $0.endpointKey == "contested.example:22" })

        // The same request without the flag is the shipped behavior: four
        // unrelated keys, four adds, nothing found and nothing contested.
        let verbatim = try importPlan(
            KnownHostsImportPlanABIRequest(text: text, existingFingerprints: existing)
        )
        XCTAssertEqual(verbatim.addCount, 4)
        XCTAssertEqual(verbatim.rejections, [])
        XCTAssertTrue(verbatim.candidates.allSatisfy { $0.expectedPriorFingerprint == nil })
        XCTAssertEqual(
            verbatim,
            try importPlan(
                KnownHostsImportPlanABIRequest(
                    text: text,
                    existingFingerprints: existing,
                    endpointNormalization: .verbatim
                )
            )
        )
    }

    func testKnownHostsExportRoundTripsThroughSSHShapedText() throws {
        let key = Self.hostKey(seed: 20)
        let records = [
            KnownHostsExportRecordABI(endpointKey: "zeta.example:22", keyString: key),
            KnownHostsExportRecordABI(endpointKey: "alpha.example:2222", keyString: key),
        ]
        let payload = try json(records)
        let text = try buildString { output, capacity in
            withUTF8(payload) { bytes, count in
                tesseraTrustKnownHostsExport(
                    recordsBytes: bytes,
                    recordsCount: count,
                    outputBytes: output,
                    outputCapacity: capacity
                )
            }
        }
        // Sorted so the output is stable across runs and diffable; bare host at
        // the default port, because that is what ssh(1) writes.
        XCTAssertEqual(text, "[alpha.example]:2222 \(key)\nzeta.example \(key)\n")

        // Round trip: exported text must import back to the same endpoints.
        let planPayload = try json(
            KnownHostsImportPlanABIRequest(text: text, existingFingerprints: [:])
        )
        let plan = try decode(KnownHostsImportPlanABIResponse.self) { output, capacity in
            withUTF8(planPayload) { bytes, count in
                tesseraTrustKnownHostsImportPlan(
                    requestBytes: bytes,
                    requestCount: count,
                    outputBytes: output,
                    outputCapacity: capacity
                )
            }
        }
        XCTAssertEqual(
            Set(plan.candidates.map(\.endpointKey)),
            ["alpha.example:2222", "zeta.example:22"]
        )
        XCTAssertEqual(plan.rejections, [])
    }

    // MARK: - Forwarding

    private func rule(
        direction: PortForwardDirection,
        bindPort: UInt16,
        bindHost: String = "127.0.0.1",
        target: PortForwardEndpoint? = PortForwardEndpoint(host: "localhost", port: 80),
        enabled: Bool = true,
        id: UUID = UUID()
    ) -> PortForwardRule {
        PortForwardRule(
            id: id,
            enabled: enabled,
            autoStart: true,
            direction: direction,
            bind: PortForwardEndpoint(host: bindHost, port: bindPort),
            target: target,
            label: ""
        )
    }

    func testForwardingValidationMatchesAndroidsRulesVerbatim() throws {
        func validate(
            _ candidate: PortForwardRule,
            against existing: [PortForwardRule] = []
        ) throws -> PortForwardValidateABIResponse {
            let payload = try json(
                PortForwardValidateABIRequest(rule: candidate, existing: existing)
            )
            return try decode(PortForwardValidateABIResponse.self) { output, capacity in
                withUTF8(payload) { bytes, count in
                    tesseraForwardingValidateRule(
                        requestBytes: bytes,
                        requestCount: count,
                        outputBytes: output,
                        outputCapacity: capacity
                    )
                }
            }
        }

        XCTAssertTrue(try validate(rule(direction: .local, bindPort: 8_080)).valid)

        XCTAssertEqual(
            try validate(rule(direction: .local, bindPort: 8_080, bindHost: "0.0.0.0")).error?.kind,
            "nonLoopbackLocalBind"
        )
        // Only `remote` may bind port 0: the server allocates it and reports
        // back. A local listener on port 0 hands the user an unpredictable
        // address.
        XCTAssertEqual(
            try validate(rule(direction: .local, bindPort: 0)).error?.kind,
            "invalidBindPort"
        )
        XCTAssertTrue(try validate(rule(direction: .remote, bindPort: 0)).valid)
        XCTAssertEqual(
            try validate(rule(direction: .local, bindPort: 8_080, target: nil)).error?.kind,
            "missingTarget"
        )
        XCTAssertEqual(
            try validate(rule(direction: .dynamic, bindPort: 1_080)).error?.kind,
            "dynamicForwardCannotHaveTarget"
        )
        XCTAssertTrue(try validate(rule(direction: .dynamic, bindPort: 1_080, target: nil)).valid)
        XCTAssertEqual(
            try validate(
                rule(
                    direction: .local,
                    bindPort: 8_080,
                    target: PortForwardEndpoint(host: "  ", port: 80)
                )
            ).error?.kind,
            "invalidTargetAddress"
        )
        XCTAssertEqual(
            try validate(
                rule(
                    direction: .local,
                    bindPort: 8_080,
                    target: PortForwardEndpoint(host: "localhost", port: 0)
                )
            ).error?.kind,
            "invalidTargetPort"
        )

        let occupant = rule(direction: .local, bindPort: 8_080)
        let collision = try validate(rule(direction: .local, bindPort: 8_080), against: [occupant])
        XCTAssertEqual(collision.error?.kind, "bindCollision")
        XCTAssertEqual(collision.error?.conflictingRuleID, occupant.id)

        // A disabled rule no longer reserves its bind port — Android's
        // semantics, adopted.
        let disabled = rule(direction: .local, bindPort: 8_080, enabled: false)
        XCTAssertTrue(
            try validate(rule(direction: .local, bindPort: 8_080), against: [disabled]).valid
        )
    }

    func testForwardingCapabilitiesRestartAndTheManifestSubset() throws {
        func capabilities(_ transport: Int32, _ sideChannel: Int32) throws -> ForwardingCapabilities {
            try decode(ForwardingCapabilities.self) { output, capacity in
                tesseraForwardingCapabilities(
                    transport: transport,
                    sshSideChannelAvailable: sideChannel,
                    outputBytes: output,
                    outputCapacity: capacity
                )
            }
        }
        XCTAssertEqual(try capabilities(0, 0), ForwardingCapabilities.forTransport(.ssh))
        XCTAssertEqual(
            try capabilities(1, 1),
            ForwardingCapabilities.forTransport(.mosh(sshSideChannelAvailable: true))
        )
        let stranded = try capabilities(1, 0)
        XCTAssertFalse(stranded.local)
        // A reason, not prose: the platforms localize.
        XCTAssertEqual(stranded.unavailableReason, .moshWithoutSSHSideChannel)
        XCTAssertEqual(
            tesseraForwardingCapabilities(
                transport: 7,
                sshSideChannelAvailable: 0,
                outputBytes: nil,
                outputCapacity: 0
            ),
            -1
        )

        let id = UUID()
        let original = rule(direction: .local, bindPort: 8_080, id: id)
        var relabelled = original
        relabelled.label = "web"
        relabelled.enabled = false
        var rebound = original
        rebound.bind = PortForwardEndpoint(host: "127.0.0.1", port: 9_090)

        func requiresRestart(_ lhs: PortForwardRule, _ rhs: PortForwardRule) throws -> Int32 {
            let payload = try json(PortForwardRestartABIRequest(rule: lhs, other: rhs))
            return withUTF8(payload) { bytes, count in
                tesseraForwardingRequiresRestart(requestBytes: bytes, requestCount: count)
            }
        }
        XCTAssertEqual(try requiresRestart(original, relabelled), 0)
        XCTAssertEqual(try requiresRestart(original, rebound), 1)

        // The manifest carries exactly one shape; dynamic and remote rules are
        // dropped rather than flattened into a wrong local rule.
        let rules = [
            rule(direction: .local, bindPort: 8_080),
            rule(direction: .remote, bindPort: 0),
            rule(direction: .dynamic, bindPort: 1_080, target: nil),
            rule(direction: .local, bindPort: 9_090, target: nil),
        ]
        let payload = try json(rules)
        let subset = try decode([PortForwardRule].self) { output, capacity in
            withUTF8(payload) { bytes, count in
                tesseraForwardingPortableLocalSubset(
                    rulesBytes: bytes,
                    rulesCount: count,
                    outputBytes: output,
                    outputCapacity: capacity
                )
            }
        }
        XCTAssertEqual(subset.map(\.id), [rules[0].id])
    }

    func testForwardingWebTargetCrossesTheBridgeWithTheURLAlreadyBuilt() throws {
        func webTarget(_ candidate: PortForwardRule) throws -> PortForwardWebTargetABIResponse {
            let payload = try json(candidate)
            return try decode(PortForwardWebTargetABIResponse.self) { output, capacity in
                withUTF8(payload) { bytes, count in
                    tesseraForwardingWebTarget(
                        ruleBytes: bytes,
                        ruleCount: count,
                        outputBytes: output,
                        outputCapacity: capacity
                    )
                }
            }
        }

        // Kotlin reads `target.url` and never assembles one, so the scheme,
        // the bracketing, and the trailing slash all have to arrive built.
        let web = try webTarget(rule(direction: .local, bindPort: 8_080))
        XCTAssertTrue(web.browsable)
        XCTAssertEqual(web.target?.url, "http://127.0.0.1:8080/")

        // The service port is the target's, not the bind's.
        let postgres = rule(
            direction: .local,
            bindPort: 18_080,
            target: PortForwardEndpoint(host: "localhost", port: 5_432)
        )
        let refused = try webTarget(postgres)
        XCTAssertFalse(refused.browsable)
        XCTAssertNil(refused.target)

        let tls = rule(
            direction: .local,
            bindPort: 8_443,
            target: PortForwardEndpoint(host: "localhost", port: 443)
        )
        XCTAssertEqual(try webTarget(tls).target?.scheme, "https")

        XCTAssertEqual(
            tesseraForwardingWebTarget(
                ruleBytes: nil,
                ruleCount: 0,
                outputBytes: nil,
                outputCapacity: 0
            ),
            -1
        )
    }

    // MARK: - tmux and agent validation

    func testTmuxNameAndTargetValidationCodes() throws {
        func validate(_ name: String) -> Int32 {
            withUTF8(name) { bytes, count in
                tesseraTmuxSessionNameValidate(nameBytes: bytes, nameCount: count)
            }
        }
        XCTAssertEqual(validate("dev-1.2_prod"), 0)
        XCTAssertEqual(tesseraTmuxSessionNameValidate(nameBytes: nil, nameCount: 0), 1)
        XCTAssertEqual(validate(String(repeating: "a", count: 257)), 2)
        // A pathological paste is still just too long. The Kotlin wrapper maps
        // -1 onto `error()`, so an oversized name that took the invalid-
        // argument path would crash the field it is being typed into.
        XCTAssertEqual(validate(String(repeating: "a", count: 1_025)), 2)
        XCTAssertEqual(validate(String(repeating: "a", count: 64_000)), 2)
        // These names are interpolated into fixed remote commands without shell
        // quoting, so the grammar is deliberately narrow.
        XCTAssertEqual(validate("dev;rm -rf"), 3)
        XCTAssertEqual(validate("dev session"), 3)

        func target(_ value: String, _ kind: Int32) -> Int32 {
            withUTF8(value) { bytes, count in
                tesseraTmuxTargetIDValidate(valueBytes: bytes, valueCount: count, kind: kind)
            }
        }
        XCTAssertEqual(target("$123", 0), 1)
        XCTAssertEqual(target("@7", 1), 1)
        XCTAssertEqual(target("%9", 2), 1)
        XCTAssertEqual(target("%9", 1), 0)
        XCTAssertEqual(target("7", 1), 0)
        XCTAssertEqual(target("@7", 9), -1)
    }

    func testAgentBranchValidationIsTheOneASCIIGrammar() throws {
        func validate(_ branch: String) -> Int32 {
            withUTF8(branch) { bytes, count in
                tesseraAgentValidateBranch(branchBytes: bytes, branchCount: count)
            }
        }
        XCTAssertEqual(validate("feature/shared-core"), 1)
        XCTAssertEqual(validate("release-0.3.4"), 1)
        XCTAssertEqual(tesseraAgentValidateBranch(branchBytes: nil, branchCount: 0), 0)
        XCTAssertEqual(validate("-leading-dash"), 0)
        XCTAssertEqual(validate("has..dots"), 0)
        XCTAssertEqual(validate("has@{ref}"), 0)
        XCTAssertEqual(validate("trailing."), 0)
        // The divergence this closes: a Unicode isLetterOrDigit check accepted
        // names the shared launch path rejects.
        XCTAssertEqual(validate("caf\u{00E9}"), 0)
        XCTAssertEqual(validate(String(repeating: "a", count: 129)), 0)
    }

    // MARK: - Pairing QR and cross-device canonicalization

    private func offer() -> PairingOfferV1 {
        PairingOfferV1(
            offerID: UUID(uuidString: "3F2504E0-4F89-11D3-9A0C-0305E82C3301")!,
            purpose: .bootstrap,
            expiresAt: 1_756_000_000,
            originEphemeralKeyOrCommitment: .init(value: Data(repeating: 7, count: 32)),
            endpointCandidates: [.init(host: "127.0.0.1", port: 23_001)],
            oneTimeOpticalSecret: nil,
            supportedTransactionVersions: [1]
        )
    }

    func testPairingQRCodecIsStrictAndReturnsCanonicalOfferBytes() throws {
        let offerBytes = try offer().encoded()
        let encoded = try decode(PairingQREncodeABIResponse.self) { output, capacity in
            withBytes([UInt8](offerBytes)) { bytes, count in
                tesseraPairingQREncodeOffer(
                    offerBytes: bytes,
                    offerCount: count,
                    outputBytes: output,
                    outputCapacity: capacity
                )
            }
        }
        XCTAssertTrue(encoded.ok)
        let text = try XCTUnwrap(encoded.text)
        XCTAssertTrue(text.hasPrefix(PairingQRTextCodecV1.prefix))

        func decodeOffer(_ scanned: String) throws -> PairingQRDecodeABIResponse {
            try decode(PairingQRDecodeABIResponse.self) { output, capacity in
                withUTF8(scanned) { bytes, count in
                    tesseraPairingQRDecodeOffer(
                        textBytes: bytes,
                        textCount: count,
                        outputBytes: output,
                        outputCapacity: capacity
                    )
                }
            }
        }

        let round = try decodeOffer(text)
        XCTAssertTrue(round.ok)
        XCTAssertEqual(round.offerBytes, offerBytes)
        XCTAssertEqual(round.purpose, .bootstrap)
        XCTAssertEqual(round.offerID, offer().offerID)
        XCTAssertEqual(round.expiresAt, 1_756_000_000)
        XCTAssertEqual(round.originRole, .origin)
        XCTAssertEqual(round.supportedPairingVersions, [1])

        // A standard-alphabet or padded spelling is outside the strict
        // base64url alphabet the grammar accepts.
        XCTAssertEqual(try decodeOffer(text + "=").error, .invalidFormat)
        XCTAssertEqual(try decodeOffer("https://example.com").error, .invalidFormat)
        XCTAssertEqual(try decodeOffer(PairingQRTextCodecV1.prefix).error, .invalidFormat)
        XCTAssertEqual(
            try decodeOffer(PairingQRTextCodecV1.prefix + "A").error,
            .invalidBase64URL
        )
        XCTAssertEqual(
            tesseraPairingQRDecodeOffer(
                textBytes: nil,
                textCount: 0,
                outputBytes: nil,
                outputCapacity: 0
            ),
            -1
        )

        // A malformed offer never becomes a QR image the scanning side would
        // then reject.
        let garbage = try decode(PairingQREncodeABIResponse.self) { output, capacity in
            withBytes([0x7B, 0x7D]) { bytes, count in
                tesseraPairingQREncodeOffer(
                    offerBytes: bytes,
                    offerCount: count,
                    outputBytes: output,
                    outputCapacity: capacity
                )
            }
        }
        XCTAssertFalse(garbage.ok)
    }

    func testCanonicalizeCommandProducesExactlyWhatTheStrictGateAccepts() throws {
        let command = CrossDeviceABICommandV1(
            kind: .createOrigin,
            generation: 31,
            purpose: .bootstrap,
            expiresAt: 1_756_000_000,
            endpointCandidates: [.init(host: "127.0.0.1", port: 23_001)],
            supportedTransactionVersions: [1]
        )
        let canonical = try command.encoded()
        // A hand-built payload with cosmetic whitespace — exactly what a Kotlin
        // builder produces, and exactly what the strict gate rejects.
        let respelled = Data(
            String(decoding: canonical, as: UTF8.self)
                .replacingOccurrences(of: ",", with: ", ")
                .utf8
        )
        XCTAssertThrowsError(try CrossDeviceABICommandV1.decode(respelled))

        let repaired = try buildBytes { output, capacity in
            withBytes([UInt8](respelled)) { bytes, count in
                tesseraCrossDeviceCanonicalizeCommand(
                    commandBytes: bytes,
                    commandCount: count,
                    outputBytes: output,
                    outputCapacity: capacity
                )
            }
        }
        XCTAssertEqual(Data(repaired), canonical)
        // And what comes back does pass the gate.
        XCTAssertEqual(try CrossDeviceABICommandV1.decode(Data(repaired)), command)

        // A field the kind does not allow is still rejected: canonicalizing is
        // not a way around validation.
        let smuggled = Data(#"{"generation":1,"kind":"start","matches":true,"v":1}"#.utf8)
        XCTAssertEqual(
            withBytes([UInt8](smuggled)) { bytes, count in
                tesseraCrossDeviceCanonicalizeCommand(
                    commandBytes: bytes,
                    commandCount: count,
                    outputBytes: nil,
                    outputCapacity: 0
                )
            },
            -1
        )
    }

    // MARK: - Continuation identity

    private func endpoint(
        hostID: UUID,
        address: String,
        port: Int = 22
    ) -> ContinuationEndpointV1 {
        ContinuationEndpointV1(
            hostID: hostID,
            name: "host",
            user: "deploy",
            address: address,
            port: port,
            transport: .ssh
        )
    }

    func testRouteIdentityAgreesBetweenTheEndpointAndDescriptorForms() throws {
        let destination = endpoint(hostID: hostA, address: "example.test")
        let jump = endpoint(hostID: sessionB, address: "bastion.test")

        let payload = try json(ContinuationRouteABIRequest(endpoint: destination, via: [jump]))
        let route = try decode(ContinuationRouteABIResponse.self) { output, capacity in
            withUTF8(payload) { bytes, count in
                tesseraContinuationRouteIdentity(
                    requestBytes: bytes,
                    requestCount: count,
                    outputBytes: output,
                    outputCapacity: capacity
                )
            }
        }
        XCTAssertEqual(
            route.identity,
            ContinuationRouteIdentity.identity(for: destination, via: [jump])
        )
        // The identity joins the TRANSPORT-FREE route key to the fingerprint;
        // the wire key keeps its `transport:` prefix and is returned alongside
        // because callers build descriptors from it.
        XCTAssertEqual(
            route.identity,
            "\(ContinuationRouteIdentity.routeKey(for: destination, via: [jump]))#\(route.fingerprint)"
        )
        XCTAssertTrue(route.connectionKey.hasPrefix("ssh:"))
        // base64url, unpadded.
        XCTAssertFalse(route.fingerprint.contains("+"))
        XCTAssertFalse(route.fingerprint.contains("/"))
        XCTAssertFalse(route.fingerprint.contains("="))

        let descriptor = ContinuationDescriptorV1(
            endpoint: destination,
            launchMode: .customCommand,
            tmuxSessionName: nil,
            via: [jump]
        )
        let descriptorPayload = String(decoding: try descriptor.encoded(), as: UTF8.self)
        let fromDescriptor = try buildString { output, capacity in
            withUTF8(descriptorPayload) { bytes, count in
                tesseraContinuationDescriptorRouteIdentity(
                    descriptorBytes: bytes,
                    descriptorCount: count,
                    outputBytes: output,
                    outputCapacity: capacity
                )
            }
        }
        // The two derivations must agree byte for byte — that agreement is the
        // point of routing both through one implementation.
        XCTAssertEqual(fromDescriptor, route.identity)

        // A different jump chain is a different route.
        let direct = try json(ContinuationRouteABIRequest(endpoint: destination, via: nil))
        let directRoute = try decode(ContinuationRouteABIResponse.self) { output, capacity in
            withUTF8(direct) { bytes, count in
                tesseraContinuationRouteIdentity(
                    requestBytes: bytes,
                    requestCount: count,
                    outputBytes: output,
                    outputCapacity: capacity
                )
            }
        }
        XCTAssertNotEqual(directRoute.fingerprint, route.fingerprint)

        XCTAssertEqual(
            tesseraContinuationRouteIdentity(
                requestBytes: nil,
                requestCount: 0,
                outputBytes: nil,
                outputCapacity: 0
            ),
            -1
        )
    }

    // MARK: - The JSON contract itself

    /// The Kotlin wrappers read these payloads with `org.json`, so the exact
    /// shape is the contract — not just the values. Two properties are load
    /// bearing there: keys are sorted (so a payload is byte-stable), and an
    /// absent optional is OMITTED rather than written as null (which is why
    /// every Kotlin reader uses `isNull`, which treats a missing key and an
    /// explicit null alike).
    func testResponsesAreSortedKeyJSONAndOmitAbsentOptionals() throws {
        let verdict = try json(
            KnownHostCheckABIRequest(
                endpoint: KnownHostEndpoint(host: "example.test", port: 22),
                presented: .init(keyString: Self.hostKey(seed: 30))
            )
        )
        let unknown = try buildString { output, capacity in
            withUTF8(verdict) { bytes, count in
                tesseraTrustCheck(
                    requestBytes: bytes,
                    requestCount: count,
                    outputBytes: output,
                    outputCapacity: capacity
                )
            }
        }
        // No pin, so there is no trusted fingerprint and no hint to carry.
        XCTAssertFalse(unknown.contains("trustedFingerprint"))
        XCTAssertFalse(unknown.contains("comparisonHint"))
        XCTAssertFalse(unknown.contains("null"))
        XCTAssertTrue(unknown.hasPrefix(#"{"presentedFingerprint""#), unknown)

        let request = try json(
            TerminalResizeCoalescerABIRequest(
                state: .init(),
                size: .init(cols: 80, rows: 24)
            )
        )
        let note = try buildString { output, capacity in
            withUTF8(request) { bytes, count in
                tesseraSessionResizeNote(
                    requestBytes: bytes,
                    requestCount: count,
                    outputBytes: output,
                    outputCapacity: capacity
                )
            }
        }
        XCTAssertEqual(
            note,
            #"{"decision":"send","state":{"lastDelivered":{"cols":80,"rows":24}}}"#,
            "an absent `pending` must be omitted, not null"
        )

        // And a request built the way Kotlin builds one — explicit nulls for
        // the fields it has nothing for — still decodes.
        let explicitNulls = #"""
            {"size":{"cols":80,"rows":24},"state":{"lastDelivered":null,"pending":null}}
            """#
        let fromNulls = try buildString { output, capacity in
            withUTF8(explicitNulls) { bytes, count in
                tesseraSessionResizeNote(
                    requestBytes: bytes,
                    requestCount: count,
                    outputBytes: output,
                    outputCapacity: capacity
                )
            }
        }
        XCTAssertEqual(fromNulls, note)
    }

    // MARK: - The header gate

    func testEveryExportedSymbolIsDeclaredInTheCHeader() throws {
        // The header is the only thing the JNI shim compiles against, and
        // nothing links it to these exports: a function added on one side and
        // forgotten on the other fails at dlsym time, on a device. Five
        // tessera_tmux_runtime_* prototypes had already drifted out that way.
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // TesseraCoreABITests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // TesseraCore
            .deletingLastPathComponent()   // Packages
            .deletingLastPathComponent()   // repository root
        let sources = root.appendingPathComponent(
            "Packages/TesseraCore/Sources/TesseraCoreABI"
        )
        let header = root.appendingPathComponent(
            "Packages/TesseraCore/Sources/TesseraCoreCABIHeaders/include/TesseraCoreABI.h"
        )
        guard let names = try? FileManager.default.contentsOfDirectory(
            at: sources,
            includingPropertiesForKeys: nil
        ), let headerText = try? String(contentsOf: header, encoding: .utf8) else {
            throw XCTSkip("ABI sources are not readable from this test environment")
        }

        var exported: Set<String> = []
        let exportPattern = try NSRegularExpression(pattern: #"@_cdecl\("([A-Za-z0-9_]+)"\)"#)
        for url in names where url.pathExtension == "swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            exportPattern.enumerateMatches(
                in: text,
                range: NSRange(text.startIndex..., in: text)
            ) { match, _, _ in
                guard let match, let range = Range(match.range(at: 1), in: text) else { return }
                exported.insert(String(text[range]))
            }
        }
        XCTAssertGreaterThan(exported.count, 100)

        // Strip comments so prose naming a function is not read as a
        // prototype, then take every `tessera_…(`.
        let uncommented = headerText
            .replacingOccurrences(
                of: #"/\*.*?\*/"#,
                with: " ",
                options: [.regularExpression]
            )
        var declared: Set<String> = []
        let declarationPattern = try NSRegularExpression(pattern: #"\btessera_[a-z0-9_]+\("#)
        declarationPattern.enumerateMatches(
            in: uncommented,
            range: NSRange(uncommented.startIndex..., in: uncommented)
        ) { match, _, _ in
            guard let match, let range = Range(match.range, in: uncommented) else { return }
            declared.insert(String(uncommented[range].dropLast()))
        }

        XCTAssertEqual(
            exported.subtracting(declared).sorted(),
            [],
            "exported by Swift but missing from TesseraCoreABI.h"
        )
        XCTAssertEqual(
            declared.subtracting(exported).sorted(),
            [],
            "declared in TesseraCoreABI.h but not exported by Swift"
        )
    }
}
