import Foundation
import XCTest
import TesseraSessionCore
import TesseraTrustCore
import TmuxControlCore
@testable import TesseraCoreABI

final class CoreABITests: XCTestCase {
    func testCompactTmuxGeometryCABIProjectsAndRejectsPeerReclaim() {
        // No layout: the ratio fallback.
        let packed = tesseraTmuxCompactLayoutClientSize(
            viewportColumns: 39,
            viewportRows: 15,
            layoutBytes: nil,
            layoutCount: 0,
            focusPaneID: -1,
            windowColumns: 80,
            windowRows: 24,
            focusColumns: 40,
            focusRows: 24
        )
        XCTAssertEqual(Int(packed >> 32), 78)
        XCTAssertEqual(Int(packed & 0xffff_ffff), 15)

        var memo: [UInt64] = [0, 0]
        XCTAssertEqual(
            tesseraTmuxCompactLayoutReprojection(
                viewportColumns: 39,
                viewportRows: 15,
                lastColumns: 78,
                lastRows: 15,
                layoutBytes: nil,
                layoutCount: 0,
                focusPaneID: -1,
                windowColumns: 160,
                windowRows: 50,
                focusColumns: 80,
                focusRows: 50,
                memo: &memo
            ),
            0
        )
        let judged = memo
        XCTAssertEqual(
            tesseraTmuxCompactLayoutReprojection(
                viewportColumns: 0, viewportRows: 15, lastColumns: 0, lastRows: 0,
                layoutBytes: nil, layoutCount: 0, focusPaneID: -1,
                windowColumns: 0, windowRows: 0, focusColumns: 0, focusRows: 0,
                memo: &memo
            ),
            -1
        )
        XCTAssertEqual(memo, judged)
        XCTAssertEqual(
            tesseraTmuxCompactLayoutReprojection(
                viewportColumns: 39, viewportRows: 15, lastColumns: 0, lastRows: 0,
                layoutBytes: nil, layoutCount: 0, focusPaneID: -1,
                windowColumns: 0, windowRows: 0, focusColumns: 0, focusRows: 0,
                memo: nil
            ),
            -1
        )
    }

    /// The layout Android re-encodes reaches the solver: the measured
    /// 59-of-200-column case lands in one advertisement, the layout tmux
    /// leaves holds, and the ratio two-cycle (45 of 200) stops at the guard
    /// with the memo carried through the ABI.
    func testCompactTmuxGeometryCABISolvesAgainstTheLayoutTree() {
        func size(_ cells: String, focus: Int32) -> (columns: Int, rows: Int) {
            let bytes = Array(cells.utf8)
            let packed = bytes.withUnsafeBufferPointer {
                tesseraTmuxCompactLayoutClientSize(
                    viewportColumns: 50, viewportRows: 40,
                    layoutBytes: $0.baseAddress, layoutCount: $0.count,
                    focusPaneID: focus,
                    windowColumns: 0, windowRows: 0, focusColumns: 0, focusRows: 0
                )
            }
            return (Int(packed >> 32), Int(packed & 0xffff_ffff))
        }
        func decide(_ cells: String?, last: (Int32, Int32), window: (Int32, Int32), focus: (Int32, Int32), memo: inout [UInt64]) -> Int32 {
            let bytes = Array((cells ?? "").utf8)
            return bytes.withUnsafeBufferPointer { layout in
                tesseraTmuxCompactLayoutReprojection(
                    viewportColumns: 50, viewportRows: 40,
                    lastColumns: last.0, lastRows: last.1,
                    layoutBytes: layout.baseAddress, layoutCount: layout.count,
                    focusPaneID: cells == nil ? -1 : 1,
                    windowColumns: window.0, windowRows: window.1,
                    focusColumns: focus.0, focusRows: focus.1,
                    memo: &memo
                )
            }
        }

        let start = "200x40,0,0{140x40,0,0,0,59x40,141,0,1}"
        XCTAssertEqual(size(start, focus: 1).columns, 181)
        XCTAssertEqual(size(start, focus: 1).rows, 40)
        var memo: [UInt64] = [0, 0]
        XCTAssertEqual(decide(start, last: (50, 40), window: (200, 40), focus: (59, 40), memo: &memo), 1)
        let landed = "181x40,0,0{130x40,0,0,0,50x40,131,0,1}"
        XCTAssertEqual(decide(landed, last: (181, 40), window: (181, 40), focus: (50, 40), memo: &memo), 0)
        // A malformed layout is the ratio fallback, not a failure.
        XCTAssertEqual(size("181x40,0,0{", focus: 1).columns, 50)
        // A pane after the first of a nested same-direction split never
        // grows; the window stays rather than running to tmux's maximum.
        XCTAssertEqual(size("200x40,0,0{100x40,0,0,0,99x40,101,0{58x40,101,0,2,40x40,160,0,1}}", focus: 1).columns, 200)

        // Ratio fallback (no tree): 200/45 <-> 223/56 stops after three
        // corrections, and the stop is reported once.
        memo = [0, 0]
        var decisions: [Int32] = []
        var last: (Int32, Int32) = (50, 40)
        var focusWidth: Int32 = 45
        var window: Int32 = 200
        for _ in 0..<6 {
            let decision = decide(nil, last: last, window: (window, 40), focus: (focusWidth, 40), memo: &memo)
            decisions.append(decision)
            guard decision == 1 else { break }
            last = (window == 200 ? 223 : 200, 40)
            window = last.0
            focusWidth = window == 223 ? 56 : 45
        }
        XCTAssertEqual(decisions, [1, 1, 1, 1, 3])
        let stopped = memo
        XCTAssertEqual(decide(nil, last: last, window: (window, 40), focus: (focusWidth, 40), memo: &memo), 2)
        XCTAssertEqual(memo, stopped)
    }

    func testCompactTmuxGeometryCABIBoundsAnswersInterleavedWithPeerLayouts() {
        var memo: [UInt64] = [0, 0]
        var published: Int32 = 200
        func decide(_ window: Int32, _ focus: Int32) -> Int32 {
            let cells = Array("\(window)x40,0,0{\(window - focus - 1)x40,0,0,0,\(focus)x40,\(window - focus),0,1}".utf8)
            return cells.withUnsafeBufferPointer {
                tesseraTmuxCompactLayoutReprojection(
                    viewportColumns: 50, viewportRows: 40, lastColumns: published, lastRows: 40,
                    layoutBytes: $0.baseAddress, layoutCount: $0.count, focusPaneID: 1,
                    windowColumns: window, windowRows: 40, focusColumns: focus, focusRows: 40, memo: &memo
                )
            }
        }
        var decisions: [Int32] = []
        for step in 0..<4 {
            decisions.append(decide(step.isMultiple(of: 2) ? 200 : 203, step.isMultiple(of: 2) ? 49 : 51))
            if decisions.last == 1 { published = step.isMultiple(of: 2) ? 202 : 200 }
            XCTAssertEqual(decide(1_000, 400), 0)
        }
        XCTAssertEqual(decisions, [1, 1, 1, 3], "the two-word ABI memo must retain the publication across a peer hold")
        for _ in 0..<40 {
            XCTAssertEqual(decide(203, 51), 2, "a stopped cycle is reported only once")
            XCTAssertEqual(decide(1_000, 400), 0)
        }
    }

    /// The layout length limit lives only in the core parser: a caller hands
    /// over whatever it encoded, and a layout past the limit is sized by
    /// ratio like any other the parser refuses, never rejected as invalid.
    func testCompactTmuxGeometryCABITakesOversizedLayoutsAsRatios() {
        var cells = "\(WindowLayout.maxByteLength)x40,0,0{"
        while cells.utf8.count <= WindowLayout.maxByteLength { cells += "1x40,0,0,1," }
        cells += "1x40,0,0,2}"
        let bytes = Array(cells.utf8)
        XCTAssertGreaterThan(bytes.count, WindowLayout.maxByteLength)
        let packed = bytes.withUnsafeBufferPointer {
            tesseraTmuxCompactLayoutClientSize(
                viewportColumns: 39, viewportRows: 15,
                layoutBytes: $0.baseAddress, layoutCount: $0.count,
                focusPaneID: 1,
                windowColumns: 80, windowRows: 24, focusColumns: 40, focusRows: 24
            )
        }
        XCTAssertEqual(Int(packed >> 32), 78)
        XCTAssertEqual(Int(packed & 0xffff_ffff), 15)
        var memo: [UInt64] = [0, 0]
        let decision = bytes.withUnsafeBufferPointer {
            tesseraTmuxCompactLayoutReprojection(
                viewportColumns: 39, viewportRows: 15, lastColumns: 39, lastRows: 15,
                layoutBytes: $0.baseAddress, layoutCount: $0.count, focusPaneID: 1,
                windowColumns: 80, windowRows: 24, focusColumns: 40, focusRows: 24,
                memo: &memo
            )
        }
        XCTAssertEqual(decision, 1)
    }

    func testCoarseInputBatchRoundTripsWithoutPerByteCalls() throws {
        let bytes = Data(repeating: 0x41, count: 64 * 1024)
        let command = CoreABICommand(kind: .sendInput, bytes: bytes)
        let decoded = try CoreABICommand.decode(command.encoded())
        XCTAssertEqual(decoded, command)
        XCTAssertEqual(decoded.bytes?.count, 64 * 1024)
    }

    func testEveryTmuxMutationRoundTripsThroughTheCoarseABI() throws {
        let receipt = SessionCommandReceipt()
        let samples: [(CoreABICommand, SessionCommand)] = [
            (
                .init(
                    kind: .sendTmuxPaneInput,
                    bytes: Data([0x41]),
                    targetID: "%3",
                    receipt: receipt
                ),
                .sendTmuxPaneInput(data: Data([0x41]), paneID: "%3", receipt: receipt)
            ),
            (
                .init(kind: .sendTmuxPaneKey, targetID: "%3", receipt: receipt, paneKey: .enter),
                .sendTmuxPaneKey(.enter, paneID: "%3", receipt: receipt)
            ),
            (.init(kind: .moveTmuxWindow, targetID: "@2", windowMove: .relative(.next)), .moveTmuxWindow("@2", move: .relative(.next))),
            (.init(kind: .renumberTmuxWindows), .renumberTmuxWindows),
            (.init(kind: .closeTmuxPane, targetID: "%3"), .closeTmuxPane("%3")),
            (
                .init(kind: .splitTmuxPane, targetID: "%3", splitAxis: .vertical),
                .splitTmuxPane("%3", axis: .vertical, before: false)
            ),
            (
                .init(kind: .splitTmuxPane, targetID: "%3", splitAxis: .horizontal, flag: true),
                .splitTmuxPane("%3", axis: .horizontal, before: true)
            ),
            (.init(kind: .cycleTmuxPane, flag: false), .cycleTmuxPane(forward: false)),
            (
                .init(kind: .setTmuxPaneZoomed, targetID: "%3", flag: true),
                .setTmuxPaneZoomed("%3", zoomed: true)
            ),
            (
                .init(kind: .renameTmuxWindow, targetID: "@2", name: "work"),
                .renameTmuxWindow("@2", name: "work")
            ),
            (
                .init(kind: .setTmuxGridPresentation, gridPresentation: .singlePane),
                .setTmuxGridPresentation(.singlePane)
            ),
            (
                .init(
                    kind: .claimTmuxGridAuthority,
                    gridAuthorityReason: .forceRefresh,
                    flag: true
                ),
                .claimTmuxGridAuthority(reason: .forceRefresh, repaintEvenIfSame: true)
            ),
            (
                .init(kind: .reclaimTmuxGridAuthority, gridAuthorityReason: .user),
                .reclaimTmuxGridAuthority(reason: .user)
            ),
            (
                .init(kind: .completeTmuxGridAuthorityRepaint, authorityGeneration: 12),
                .completeTmuxGridAuthorityRepaint(generation: 12)
            ),
        ]

        for (envelope, expected) in samples {
            let decoded = try CoreABICommand.decode(envelope.encoded())
            XCTAssertEqual(try decoded.sessionCommand(), expected)
        }
    }

    func testAcknowledgedTmuxCommandCompletionRoundTripsThroughTheRuntime() async throws {
        let expectations = (0..<5).map { expectation(description: "event \($0)") }
        let capture = OrderedEventCapture(expectations: expectations)
        let runtime = CoreABIRuntime { capture.receive($0) }
        let receipt = SessionCommandReceipt()
        let intent = ConnectionIntent(hostID: UUID(), policyGeneration: 1)
        runtime.submit(try CoreABICommand(
            kind: .connect,
            requestID: intent.requestID,
            hostID: intent.hostID,
            policyGeneration: intent.policyGeneration
        ).encoded())
        runtime.receive(try CoreABIBackendEvent(
            kind: .transportConnected,
            attemptID: intent.requestID,
            policyGeneration: intent.policyGeneration
        ).encoded())
        runtime.submit(try CoreABICommand(
            kind: .sendTmuxPaneInput,
            bytes: Data([0x41]),
            targetID: "%3",
            receipt: receipt
        ).encoded())
        let completion = SessionCommandCompletion(receipt: receipt, result: .succeeded)
        runtime.receive(try CoreABIBackendEvent(
            kind: .commandCompleted,
            payload: try JSONEncoder().encode(completion)
        ).encoded())

        await fulfillment(of: expectations, timeout: 2)
        XCTAssertEqual(capture.events.map(\.kind), [
            .stateChanged,
            .backendCommandRequested,
            .stateChanged,
            .backendCommandRequested,
            .commandCompleted,
        ])
        let output = try XCTUnwrap(capture.events.last?.payload)
        XCTAssertEqual(
            try JSONDecoder().decode(SessionCommandCompletion.self, from: output),
            completion
        )
        runtime.destroy()
    }

    func testTerminalOutputReceiptRoundTripsThroughTheRuntime() async throws {
        let expectations = (0..<4).map { expectation(description: "event \($0)") }
        let capture = OrderedEventCapture(expectations: expectations)
        let runtime = CoreABIRuntime { capture.receive($0) }
        let intent = ConnectionIntent(hostID: UUID(), policyGeneration: 1)
        runtime.submit(try CoreABICommand(
            kind: .connect,
            requestID: intent.requestID,
            hostID: intent.hostID,
            policyGeneration: intent.policyGeneration
        ).encoded())
        runtime.receive(try CoreABIBackendEvent(
            kind: .transportConnected,
            attemptID: intent.requestID,
            policyGeneration: intent.policyGeneration
        ).encoded())
        runtime.receive(try CoreABIBackendEvent(
            kind: .terminalBytes,
            generation: 1,
            attemptID: intent.requestID,
            payload: Data([0x41]),
            arguments: ["deliveryID": "17", "repaintRequestID": "9"]
        ).encoded())

        await fulfillment(of: expectations, timeout: 2)
        let output = try XCTUnwrap(capture.events.last)
        XCTAssertEqual(output.kind, .terminalBytes)
        XCTAssertEqual(output.payload, Data([0x41]))
        XCTAssertEqual(output.arguments?["deliveryID"], "17")
        XCTAssertEqual(output.arguments?["repaintRequestID"], "9")
        runtime.destroy()
    }

    func testTerminalOutputFromForeignAttemptIsDroppedWithCurrentGeneration() async throws {
        let expectations = (0..<4).map { expectation(description: "event \($0)") }
        let capture = OrderedEventCapture(expectations: expectations)
        let runtime = CoreABIRuntime { capture.receive($0) }
        let intent = ConnectionIntent(hostID: UUID(), policyGeneration: 1)
        runtime.submit(try CoreABICommand(
            kind: .connect,
            requestID: intent.requestID,
            hostID: intent.hostID,
            policyGeneration: intent.policyGeneration
        ).encoded())
        runtime.receive(try CoreABIBackendEvent(
            kind: .transportConnected,
            attemptID: intent.requestID,
            policyGeneration: intent.policyGeneration
        ).encoded())
        runtime.receive(try CoreABIBackendEvent(
            kind: .terminalBytes,
            generation: 1,
            attemptID: UUID(),
            payload: Data([0x58]),
            arguments: ["deliveryID": "1"]
        ).encoded())
        runtime.receive(try CoreABIBackendEvent(
            kind: .diagnostics,
            generation: 1,
            code: "attempt-barrier"
        ).encoded())

        await fulfillment(of: expectations, timeout: 2)
        XCTAssertEqual(capture.events.map(\.kind), [
            .stateChanged,
            .backendCommandRequested,
            .stateChanged,
            .diagnostics,
        ])
        runtime.destroy()
    }

    func testMalformedTerminalOutputReceiptsAreRejected() async throws {
        let invalidArguments = [
            ["deliveryID": "17", "repaintRequestID": "0"],
            ["repaintRequestID": "9"],
            ["deliveryID": "9223372036854775808"],
            ["deliveryID": "17", "repaintRequestID": "9223372036854775808"],
        ]
        let expectations = (0..<(3 + invalidArguments.count)).map {
            expectation(description: "event \($0)")
        }
        let capture = OrderedEventCapture(expectations: expectations)
        let runtime = CoreABIRuntime { capture.receive($0) }
        let intent = ConnectionIntent(hostID: UUID(), policyGeneration: 1)
        runtime.submit(try CoreABICommand(
            kind: .connect,
            requestID: intent.requestID,
            hostID: intent.hostID,
            policyGeneration: intent.policyGeneration
        ).encoded())
        runtime.receive(try CoreABIBackendEvent(
            kind: .transportConnected,
            attemptID: intent.requestID,
            policyGeneration: intent.policyGeneration
        ).encoded())
        for arguments in invalidArguments {
            runtime.receive(try CoreABIBackendEvent(
                kind: .terminalBytes,
                attemptID: intent.requestID,
                payload: Data([0x58]),
                arguments: arguments
            ).encoded())
        }

        await fulfillment(of: expectations, timeout: 2)
        XCTAssertEqual(
            Array(capture.events.suffix(invalidArguments.count)).map(\.kind),
            Array(repeating: .commandRejected, count: invalidArguments.count)
        )
        XCTAssertEqual(
            Array(capture.events.suffix(invalidArguments.count)).map(\.code),
            Array(repeating: "abi_invalidField", count: invalidArguments.count)
        )
        runtime.destroy()
    }

    func testMalformedAcknowledgedCommandEmitsCorrelatedFailureBeforeRejection() async throws {
        let expectations = (0..<2).map { expectation(description: "event \($0)") }
        let capture = OrderedEventCapture(expectations: expectations)
        let runtime = CoreABIRuntime { capture.receive($0) }
        let receipt = SessionCommandReceipt()
        let malformed = try JSONEncoder().encode(CoreABICommand(
            kind: .sendTmuxPaneKey,
            targetID: "%3",
            receipt: receipt
        ))

        runtime.submit(malformed)

        await fulfillment(of: expectations, timeout: 2)
        XCTAssertEqual(capture.events.map(\.kind), [.commandCompleted, .commandRejected])
        let payload = try XCTUnwrap(capture.events.first?.payload)
        XCTAssertEqual(
            try JSONDecoder().decode(SessionCommandCompletion.self, from: payload),
            SessionCommandCompletion(
                receipt: receipt,
                result: .failed(CoreFailure(code: "command_rejected"))
            )
        )
        runtime.destroy()
    }

    func testOversizedNestedPaneInputFailsReceiptInsteadOfSilentlyDroppingBackendRequest() async throws {
        let expectations = (0..<5).map { expectation(description: "event \($0)") }
        let capture = OrderedEventCapture(expectations: expectations)
        let runtime = CoreABIRuntime { capture.receive($0) }
        let intent = ConnectionIntent(hostID: UUID(), policyGeneration: 7)
        let receipt = SessionCommandReceipt()

        runtime.submit(try CoreABICommand(
            kind: .connect,
            requestID: intent.requestID,
            hostID: intent.hostID,
            policyGeneration: intent.policyGeneration
        ).encoded())
        runtime.receive(try CoreABIBackendEvent(
            kind: .transportConnected,
            attemptID: intent.requestID,
            policyGeneration: intent.policyGeneration
        ).encoded())
        runtime.submit(try CoreABICommand(
            kind: .sendTmuxPaneInput,
            bytes: Data(repeating: 0x41, count: 700_000),
            targetID: "%3",
            receipt: receipt
        ).encoded())

        await fulfillment(of: expectations, timeout: 3)
        XCTAssertEqual(capture.events.map(\.kind), [
            .stateChanged,
            .backendCommandRequested,
            .stateChanged,
            .commandCompleted,
            .commandRejected,
        ])
        let payload = try XCTUnwrap(capture.events[3].payload)
        XCTAssertEqual(
            try JSONDecoder().decode(SessionCommandCompletion.self, from: payload),
            SessionCommandCompletion(
                receipt: receipt,
                result: .failed(CoreFailure(code: "command_rejected"))
            )
        )
        runtime.destroy()
    }

    func testABIDecoderRejectsMissingTypedFields() throws {
        let malformed = Data(#"{"kind":"connect","v":4}"#.utf8)
        XCTAssertThrowsError(try CoreABICommand.decode(malformed)) {
            XCTAssertEqual($0 as? CoreABIError, .missingField)
        }
    }

    func testRuntimeReportsStructuredRejectionForMalformedCommand() async throws {
        let expectation = expectation(description: "rejection callback")
        let capture = EventCapture(expectation: expectation)
        let runtime = CoreABIRuntime { capture.receive($0) }
        runtime.submit(Data("not-json".utf8))
        await fulfillment(of: [expectation], timeout: 2)
        let event = try XCTUnwrap(capture.event)
        XCTAssertEqual(event.kind, .commandRejected)
        XCTAssertNotNil(event.code)
        runtime.destroy()
    }

    func testRuntimeSerializesBackendCommandAndPlatformEventCallbacks() async throws {
        let expectations = (0..<4).map { expectation(description: "event \($0)") }
        let capture = OrderedEventCapture(expectations: expectations)
        let runtime = CoreABIRuntime { capture.receive($0) }
        runtime.submit(try CoreABICommand(kind: .disconnect).encoded())
        runtime.submit(try CoreABICommand(kind: .setFocused, flag: true).encoded())
        runtime.receive(try CoreABIBackendEvent(
            kind: .diagnostics,
            generation: 2,
            code: "platform_ready"
        ).encoded())

        await fulfillment(of: expectations, timeout: 2)
        XCTAssertEqual(capture.events.map(\.kind), [
            .stateChanged,
            .backendCommandRequested,
            .backendCommandRequested,
            .diagnostics,
        ])
        runtime.destroy()
    }

    func testCEntryPointProjectsBackendCleanDisconnect() async throws {
        let expectations = (0..<4).map { expectation(description: "event \($0)") }
        let capture = OrderedEventCapture(expectations: expectations)
        let context = Unmanaged.passRetained(capture).toOpaque()
        let callback: TesseraCoreABIEventCallback = { bytes, count, context in
            guard let bytes, let context else { return }
            Unmanaged<OrderedEventCapture>
                .fromOpaque(context)
                .takeUnretainedValue()
                .receive(Data(bytes: bytes, count: count))
        }
        let handle = tesseraCoreRuntimeCreate(callback: callback, context: context)
        defer {
            tesseraCoreRuntimeDestroy(handle: handle)
            Unmanaged<OrderedEventCapture>.fromOpaque(context).release()
        }
        let intent = ConnectionIntent(hostID: UUID(), policyGeneration: 3)

        XCTAssertEqual(try sendToCABI(
            CoreABICommand(
                kind: .connect,
                requestID: intent.requestID,
                hostID: intent.hostID,
                policyGeneration: intent.policyGeneration
            ).encoded(),
            handle: handle
        ), 0)
        XCTAssertEqual(try emitToCABI(
            CoreABIBackendEvent(
                kind: .transportConnected,
                attemptID: intent.requestID,
                policyGeneration: intent.policyGeneration
            ).encoded(),
            handle: handle
        ), 0)
        XCTAssertEqual(try emitToCABI(
            CoreABIBackendEvent(
                kind: .transportDisconnected,
                attemptID: intent.requestID
            ).encoded(),
            handle: handle
        ), 0)

        await fulfillment(of: expectations, timeout: 2)
        XCTAssertEqual(capture.events.map(\.kind), [
            .stateChanged,
            .backendCommandRequested,
            .stateChanged,
            .stateChanged,
        ])
        XCTAssertEqual(capture.events.map(\.code), [
            "connecting",
            "connect",
            "connected",
            "disconnected",
        ])
        XCTAssertEqual(capture.events.last?.generation, 2)
        XCTAssertNotNil(capture.events[1].arguments?["sessionID"].flatMap(UUID.init(uuidString:)))
    }

    func testABIDisconnectRequiresAttemptID() async throws {
        let expectation = expectation(description: "missing attempt rejection")
        let capture = OrderedEventCapture(expectations: [expectation])
        let runtime = CoreABIRuntime { capture.receive($0) }
        let missingAttempt = CoreABIBackendEvent(kind: .transportDisconnected)

        XCTAssertThrowsError(try missingAttempt.encoded()) {
            XCTAssertEqual($0 as? CoreABIError, .missingField)
        }
        runtime.receive(try JSONEncoder().encode(missingAttempt))

        await fulfillment(of: [expectation], timeout: 2)
        XCTAssertEqual(capture.events.map(\.kind), [.commandRejected])
        XCTAssertEqual(capture.events.first?.code, "abi_missingField")
        runtime.destroy()
    }

    func testABIDelayedDisconnectFromAttemptACannotTearDownAttemptB() async throws {
        let expectations = (0..<9).map { expectation(description: "event \($0)") }
        let capture = OrderedEventCapture(expectations: expectations)
        let runtime = CoreABIRuntime { capture.receive($0) }
        let first = ConnectionIntent(hostID: UUID(), policyGeneration: 1)
        let second = ConnectionIntent(hostID: first.hostID, policyGeneration: 2)

        runtime.submit(try CoreABICommand(
            kind: .connect,
            requestID: first.requestID,
            hostID: first.hostID,
            policyGeneration: first.policyGeneration
        ).encoded())
        runtime.receive(try CoreABIBackendEvent(
            kind: .transportConnected,
            attemptID: first.requestID,
            policyGeneration: first.policyGeneration
        ).encoded())
        runtime.receive(try CoreABIBackendEvent(
            kind: .transportDisconnected,
            attemptID: first.requestID
        ).encoded())
        runtime.submit(try CoreABICommand(
            kind: .connect,
            requestID: second.requestID,
            hostID: second.hostID,
            policyGeneration: second.policyGeneration
        ).encoded())
        runtime.receive(try CoreABIBackendEvent(
            kind: .transportConnected,
            attemptID: second.requestID,
            policyGeneration: second.policyGeneration
        ).encoded())
        runtime.receive(try CoreABIBackendEvent(
            kind: .transportDisconnected,
            attemptID: first.requestID
        ).encoded())

        await fulfillment(of: Array(expectations.prefix(8)), timeout: 2)
        XCTAssertEqual(capture.events.last?.kind, .commandRejected)
        XCTAssertEqual(capture.events.last?.code, "session_staleAttempt")
        XCTAssertEqual(capture.events[capture.events.count - 2].code, "connected")

        runtime.receive(try CoreABIBackendEvent(
            kind: .transportDisconnected,
            attemptID: second.requestID
        ).encoded())
        await fulfillment(of: [expectations[8]], timeout: 2)
        XCTAssertEqual(capture.events.last?.kind, .stateChanged)
        XCTAssertEqual(capture.events.last?.code, "disconnected")
        runtime.destroy()
    }

    func testABIProjectsEveryFullChallengeVariantWithCompatibilityFields() async throws {
        let expectations = (0..<7).map { expectation(description: "event \($0)") }
        let capture = OrderedEventCapture(expectations: expectations)
        let now = Date(timeIntervalSince1970: 100)
        let sessionID = UUID()
        let runtime = CoreABIRuntime(
            sessionID: sessionID,
            now: { now },
            eventSink: { capture.receive($0) }
        )
        let intent = ConnectionIntent(hostID: UUID(), policyGeneration: 4)
        runtime.submit(try CoreABICommand(
            kind: .connect,
            requestID: intent.requestID,
            hostID: intent.hostID,
            policyGeneration: intent.policyGeneration
        ).encoded())
        runtime.receive(try CoreABIBackendEvent(
            kind: .transportConnected,
            attemptID: intent.requestID,
            policyGeneration: intent.policyGeneration
        ).encoded())

        func context() -> ChallengeContext {
            ChallengeContext(
                sessionID: sessionID,
                attemptID: intent.requestID,
                policyGeneration: intent.policyGeneration,
                expiresAt: now.addingTimeInterval(30)
            )
        }
        let challenges: [SessionChallenge] = [
            .hostKey(
                context: context(),
                endpoint: KnownHostEndpoint(host: "server.example", port: 2202),
                fingerprint: "SHA256:host-key",
                hint: "first connection"
            ),
            .credential(context: context(), credentialID: UUID(), kind: "password"),
            .ownerAuthorization(context: context(), reasonCode: "install_key"),
            .importConflict(context: context(), conflictCode: "host_exists"),
        ]
        for challenge in challenges {
            runtime.receive(try CoreABIBackendEvent(
                kind: .challenge,
                generation: 1,
                payload: try JSONEncoder().encode(challenge)
            ).encoded())
        }

        await fulfillment(of: expectations, timeout: 2)
        XCTAssertEqual(capture.events[1].arguments?["sessionID"], sessionID.uuidString)
        let projected = Array(capture.events.suffix(challenges.count))
        XCTAssertEqual(projected.map(\.kind), Array(repeating: .challenge, count: 4))
        XCTAssertEqual(projected.map(\.code), [
            "host_key",
            "credential",
            "owner_authorization",
            "import_conflict",
        ])
        for (event, challenge) in zip(projected, challenges) {
            XCTAssertEqual(
                try JSONDecoder().decode(
                    SessionChallenge.self,
                    from: XCTUnwrap(event.payload)
                ),
                challenge
            )
            XCTAssertEqual(event.arguments?["challengeID"], challenge.context.challengeID.uuidString)
            XCTAssertEqual(event.arguments?["attemptID"], challenge.context.attemptID.uuidString)
            XCTAssertEqual(
                event.arguments?["policyGeneration"],
                String(challenge.context.policyGeneration)
            )
        }
        runtime.destroy()
    }

    func testABIRejectsUnknownChallengeResponseBeforeBackendDispatch() async throws {
        let expectations = (0..<4).map { expectation(description: "event \($0)") }
        let capture = OrderedEventCapture(expectations: expectations)
        let runtime = CoreABIRuntime { capture.receive($0) }
        let intent = ConnectionIntent(hostID: UUID(), policyGeneration: 5)
        runtime.submit(try CoreABICommand(
            kind: .connect,
            requestID: intent.requestID,
            hostID: intent.hostID,
            policyGeneration: intent.policyGeneration
        ).encoded())
        runtime.receive(try CoreABIBackendEvent(
            kind: .transportConnected,
            attemptID: intent.requestID,
            policyGeneration: intent.policyGeneration
        ).encoded())
        runtime.submit(try CoreABICommand(
            kind: .submitChallengeResponse,
            requestID: intent.requestID,
            policyGeneration: intent.policyGeneration,
            challengeID: UUID(),
            decision: .reject
        ).encoded())

        await fulfillment(of: expectations, timeout: 2)
        XCTAssertEqual(capture.events.map(\.kind), [
            .stateChanged,
            .backendCommandRequested,
            .stateChanged,
            .commandRejected,
        ])
        XCTAssertEqual(capture.events.last?.code, "challenge_unknown")
        runtime.destroy()
    }

    func testABIRejectsExpiredChallengeResponseBeforeBackendDispatch() async throws {
        let expectations = (0..<5).map { expectation(description: "event \($0)") }
        let capture = OrderedEventCapture(expectations: expectations)
        let clock = ABITestClock(Date(timeIntervalSince1970: 100))
        let sessionID = UUID()
        let runtime = CoreABIRuntime(
            sessionID: sessionID,
            now: { clock.value },
            eventSink: { capture.receive($0) }
        )
        let intent = ConnectionIntent(hostID: UUID(), policyGeneration: 6)
        runtime.submit(try CoreABICommand(
            kind: .connect,
            requestID: intent.requestID,
            hostID: intent.hostID,
            policyGeneration: intent.policyGeneration
        ).encoded())
        runtime.receive(try CoreABIBackendEvent(
            kind: .transportConnected,
            attemptID: intent.requestID,
            policyGeneration: intent.policyGeneration
        ).encoded())
        let context = ChallengeContext(
            sessionID: sessionID,
            attemptID: intent.requestID,
            policyGeneration: intent.policyGeneration,
            expiresAt: clock.value.addingTimeInterval(1)
        )
        runtime.receive(try CoreABIBackendEvent(
            kind: .challenge,
            generation: 1,
            payload: try JSONEncoder().encode(SessionChallenge.ownerAuthorization(
                context: context,
                reasonCode: "install_key"
            ))
        ).encoded())
        await fulfillment(of: Array(expectations.prefix(4)), timeout: 2)
        XCTAssertEqual(capture.events.last?.kind, .challenge)
        clock.value = clock.value.addingTimeInterval(2)
        runtime.submit(try CoreABICommand(
            kind: .submitChallengeResponse,
            requestID: intent.requestID,
            policyGeneration: intent.policyGeneration,
            challengeID: context.challengeID,
            decision: .approve
        ).encoded())

        await fulfillment(of: [expectations[4]], timeout: 2)
        XCTAssertEqual(capture.events.last?.kind, .commandRejected)
        XCTAssertEqual(capture.events.last?.code, "challenge_expired")
        XCTAssertEqual(capture.events.last?.arguments?["command"], "submit_challenge_response")
        XCTAssertEqual(capture.events.filter { $0.kind == .backendCommandRequested }.count, 1)
        runtime.destroy()
    }

    func testABIRejectsReplayedChallengeResponseBeforeSecondBackendDispatch() async throws {
        let expectations = (0..<6).map { expectation(description: "event \($0)") }
        let capture = OrderedEventCapture(expectations: expectations)
        let now = Date(timeIntervalSince1970: 100)
        let sessionID = UUID()
        let runtime = CoreABIRuntime(
            sessionID: sessionID,
            now: { now },
            eventSink: { capture.receive($0) }
        )
        let intent = ConnectionIntent(hostID: UUID(), policyGeneration: 7)
        runtime.submit(try CoreABICommand(
            kind: .connect,
            requestID: intent.requestID,
            hostID: intent.hostID,
            policyGeneration: intent.policyGeneration
        ).encoded())
        runtime.receive(try CoreABIBackendEvent(
            kind: .transportConnected,
            attemptID: intent.requestID,
            policyGeneration: intent.policyGeneration
        ).encoded())
        let context = ChallengeContext(
            sessionID: sessionID,
            attemptID: intent.requestID,
            policyGeneration: intent.policyGeneration,
            expiresAt: now.addingTimeInterval(30)
        )
        runtime.receive(try CoreABIBackendEvent(
            kind: .challenge,
            generation: 1,
            payload: try JSONEncoder().encode(SessionChallenge.importConflict(
                context: context,
                conflictCode: "host_exists"
            ))
        ).encoded())
        let response = try CoreABICommand(
            kind: .submitChallengeResponse,
            requestID: intent.requestID,
            policyGeneration: intent.policyGeneration,
            challengeID: context.challengeID,
            decision: .reject
        ).encoded()
        runtime.submit(response)
        runtime.submit(response)

        await fulfillment(of: expectations, timeout: 2)
        XCTAssertEqual(capture.events.suffix(2).map(\.kind), [
            .backendCommandRequested,
            .commandRejected,
        ])
        XCTAssertEqual(capture.events.last?.code, "challenge_already_consumed")
        XCTAssertEqual(capture.events.last?.arguments?["command"], "submit_challenge_response")
        XCTAssertEqual(capture.events.filter { $0.kind == .backendCommandRequested }.count, 2)
        runtime.destroy()
    }

    func testCHandleRegistryRejectsUseAfterIdempotentDestroy() throws {
        let callback: TesseraCoreABIEventCallback = { _, _, _ in }
        let handle = tesseraCoreRuntimeCreate(callback: callback, context: nil)
        let command = try CoreABICommand(kind: .disconnect).encoded()
        XCTAssertEqual(command.withUnsafeBytes { raw in
            tesseraCoreRuntimeSend(
                handle: handle,
                bytes: raw.bindMemory(to: UInt8.self).baseAddress,
                count: raw.count
            )
        }, 0)
        tesseraCoreRuntimeDestroy(handle: handle)
        tesseraCoreRuntimeDestroy(handle: handle)
        XCTAssertEqual(command.withUnsafeBytes { raw in
            tesseraCoreRuntimeSend(
                handle: handle,
                bytes: raw.bindMemory(to: UInt8.self).baseAddress,
                count: raw.count
            )
        }, -2)
        XCTAssertEqual(tesseraCoreABIVersion(), 4)
        XCTAssertEqual(tesseraCoreABIMaxPayloadBytes(), 1_048_576)
    }

    func testConcurrentCSubmitAndDestroyNeverDereferenceStaleHandles() throws {
        let callback: TesseraCoreABIEventCallback = { _, _, _ in }
        let handle = tesseraCoreRuntimeCreate(callback: callback, context: nil)
        let command = try CoreABICommand(kind: .disconnect).encoded()
        let statuses = StatusCapture()

        DispatchQueue.concurrentPerform(iterations: 32) { index in
            if index == 16 {
                tesseraCoreRuntimeDestroy(handle: handle)
            } else {
                statuses.append(command.withUnsafeBytes { raw in
                    tesseraCoreRuntimeSend(
                        handle: handle,
                        bytes: raw.bindMemory(to: UInt8.self).baseAddress,
                        count: raw.count
                    )
                })
            }
        }
        tesseraCoreRuntimeDestroy(handle: handle)
        XCTAssertTrue(statuses.values.allSatisfy { $0 == 0 || $0 == -2 })
        XCTAssertEqual(command.withUnsafeBytes { raw in
            tesseraCoreRuntimeSend(
                handle: handle,
                bytes: raw.bindMemory(to: UInt8.self).baseAddress,
                count: raw.count
            )
        }, -2)
    }

    func testCDestroyIsAContextLifetimeBarrier() throws {
        let counter = CallbackCounter()
        var capture: DestroyBarrierContext? = DestroyBarrierContext(counter: counter)
        weak var weakCapture = capture
        let callbackEntered = capture!.callbackEntered
        let allowCallbackToReturn = capture!.allowCallbackToReturn
        let context = Unmanaged.passRetained(capture!).toOpaque()
        capture = nil

        let callback: TesseraCoreABIEventCallback = { _, _, context in
            guard let context else { return }
            Unmanaged<DestroyBarrierContext>
                .fromOpaque(context)
                .takeUnretainedValue()
                .receive()
        }
        let handle = tesseraCoreRuntimeCreate(callback: callback, context: context)
        let command = try CoreABICommand(kind: .disconnect).encoded()
        XCTAssertEqual(command.withUnsafeBytes { raw in
            tesseraCoreRuntimeSend(
                handle: handle,
                bytes: raw.bindMemory(to: UInt8.self).baseAddress,
                count: raw.count
            )
        }, 0)
        XCTAssertEqual(callbackEntered.wait(timeout: .now() + 2), .success)

        let destroyReturned = DispatchSemaphore(value: 0)
        let handleToken = UInt(bitPattern: handle)
        DispatchQueue.global().async {
            tesseraCoreRuntimeDestroy(handle: UnsafeMutableRawPointer(bitPattern: handleToken))
            destroyReturned.signal()
        }
        XCTAssertEqual(destroyReturned.wait(timeout: .now() + 0.05), .timedOut)

        allowCallbackToReturn.signal()
        XCTAssertEqual(destroyReturned.wait(timeout: .now() + 2), .success)
        let callbacksAtReturn = counter.value
        Unmanaged<DestroyBarrierContext>.fromOpaque(context).release()
        XCTAssertNil(weakCapture)
        Thread.sleep(forTimeInterval: 0.05)
        XCTAssertEqual(counter.value, callbacksAtReturn)
    }

    func testReentrantCDestroySuppressesEveryLaterContextCallback() throws {
        let counter = CallbackCounter()
        var capture: ReentrantDestroyContext? = ReentrantDestroyContext(counter: counter)
        weak var weakCapture = capture
        let callbackExited = capture!.callbackExited
        let context = Unmanaged.passRetained(capture!).toOpaque()
        let callback: TesseraCoreABIEventCallback = { _, _, context in
            guard let context else { return }
            // Signal once this frame no longer holds the context: signalled
            // from inside `receive()`, a preempted callback still owned it
            // when the test released its own reference and checked for nil.
            let exited: DispatchSemaphore = {
                let receiver = Unmanaged<ReentrantDestroyContext>.fromOpaque(context).takeUnretainedValue()
                receiver.receive()
                return receiver.callbackExited
            }()
            exited.signal()
        }
        let handle = tesseraCoreRuntimeCreate(callback: callback, context: context)
        capture!.handleToken = UInt(bitPattern: handle)
        capture = nil

        let command = try CoreABICommand(kind: .disconnect).encoded()
        XCTAssertEqual(command.withUnsafeBytes { raw in
            tesseraCoreRuntimeSend(
                handle: handle,
                bytes: raw.bindMemory(to: UInt8.self).baseAddress,
                count: raw.count
            )
        }, 0)
        XCTAssertEqual(callbackExited.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(counter.value, 1)
        XCTAssertEqual(command.withUnsafeBytes { raw in
            tesseraCoreRuntimeSend(
                handle: handle,
                bytes: raw.bindMemory(to: UInt8.self).baseAddress,
                count: raw.count
            )
        }, -2)

        Unmanaged<ReentrantDestroyContext>.fromOpaque(context).release()
        XCTAssertNil(weakCapture)
        Thread.sleep(forTimeInterval: 0.05)
        XCTAssertEqual(counter.value, 1)
    }
}

private final class CallbackCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    @discardableResult
    func increment() -> Int {
        lock.lock()
        storage += 1
        let value = storage
        lock.unlock()
        return value
    }
}

private final class DestroyBarrierContext: @unchecked Sendable {
    let callbackEntered = DispatchSemaphore(value: 0)
    let allowCallbackToReturn = DispatchSemaphore(value: 0)
    private let counter: CallbackCounter

    init(counter: CallbackCounter) {
        self.counter = counter
    }

    func receive() {
        if counter.increment() == 1 {
            callbackEntered.signal()
            _ = allowCallbackToReturn.wait(timeout: .now() + 2)
        }
    }
}

private final class ReentrantDestroyContext: @unchecked Sendable {
    let callbackExited = DispatchSemaphore(value: 0)
    var handleToken: UInt = 0
    private let counter: CallbackCounter

    init(counter: CallbackCounter) {
        self.counter = counter
    }

    func receive() {
        if counter.increment() == 1 {
            tesseraCoreRuntimeDestroy(handle: UnsafeMutableRawPointer(bitPattern: handleToken))
        }
    }
}

private final class StatusCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Int32] = []

    var values: [Int32] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ value: Int32) {
        lock.lock()
        storage.append(value)
        lock.unlock()
    }
}

private final class ABITestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Date

    init(_ value: Date) { storage = value }

    var value: Date {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
        set {
            lock.lock()
            storage = newValue
            lock.unlock()
        }
    }
}

private func sendToCABI(_ data: Data, handle: UnsafeMutableRawPointer?) -> Int32 {
    data.withUnsafeBytes { raw in
        tesseraCoreRuntimeSend(
            handle: handle,
            bytes: raw.bindMemory(to: UInt8.self).baseAddress,
            count: raw.count
        )
    }
}

private func emitToCABI(_ data: Data, handle: UnsafeMutableRawPointer?) -> Int32 {
    data.withUnsafeBytes { raw in
        tesseraCoreRuntimeEmit(
            handle: handle,
            bytes: raw.bindMemory(to: UInt8.self).baseAddress,
            count: raw.count
        )
    }
}

private final class OrderedEventCapture: @unchecked Sendable {
    private let lock = NSLock()
    private let expectations: [XCTestExpectation]
    private var storage: [CoreABIEvent] = []

    init(expectations: [XCTestExpectation]) {
        self.expectations = expectations
    }

    var events: [CoreABIEvent] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func receive(_ data: Data) {
        guard let event = try? JSONDecoder().decode(CoreABIEvent.self, from: data) else { return }
        lock.lock()
        let index = storage.count
        storage.append(event)
        lock.unlock()
        if index < expectations.count { expectations[index].fulfill() }
    }
}

private final class EventCapture: @unchecked Sendable {
    private let lock = NSLock()
    private let expectation: XCTestExpectation
    private var storage: CoreABIEvent?

    init(expectation: XCTestExpectation) {
        self.expectation = expectation
    }

    var event: CoreABIEvent? {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func receive(_ data: Data) {
        lock.lock()
        let shouldFulfill = storage == nil
        storage = storage ?? (try? JSONDecoder().decode(CoreABIEvent.self, from: data))
        lock.unlock()
        if shouldFulfill { expectation.fulfill() }
    }
}
