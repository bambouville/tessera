import XCTest
import TmuxControlCore
@testable import TesseraCoreABI

final class TmuxWindowSizeReplayABITests: XCTestCase {
    func testDecisionExposesTheThreeSharedCases() {
        XCTAssertEqual(decision(observed: (56, 48)), 0)
        XCTAssertEqual(decision(observed: (56, 48), lastAttempt: (56, 48)), 0)
        XCTAssertEqual(decision(observed: (56, 45), lastAttempt: (56, 48)), 1)
        XCTAssertEqual(decision(lastAttempt: (56, 48)), 1)
        XCTAssertEqual(decision(observed: (56, 45)), 2)
        XCTAssertEqual(decision(observed: (55, 48), lastAttempt: (55, 48)), 2)
        XCTAssertEqual(decision(), 2)
    }

    func testDecisionRejectsInvalidAndPartialOptionalGeometry() {
        for invalid: (Int32, Int32) in [(0, 48), (56, 0), (-1, 48), (56, -1), (65_536, 48), (56, 65_536)] {
            XCTAssertEqual(decision(requested: invalid), -1)
            XCTAssertEqual(decision(observed: invalid), -1)
            XCTAssertEqual(decision(lastAttempt: invalid), -1)
        }
        XCTAssertEqual(decision(requested: (1, 1), observed: (1, 1)), 0)
        XCTAssertEqual(decision(requested: (65_535, 65_535), lastAttempt: (65_535, 65_535)), 1)
    }

    func testCommandsUseTheExactTwoPhaseStringContract() throws {
        let required = commands(nil, 0)
        XCTAssertGreaterThan(required, 0)
        var output = [UInt8](repeating: 0, count: Int(required))
        XCTAssertEqual(output.withUnsafeMutableBufferPointer { commands($0.baseAddress, $0.count) }, required)
        let expected = TmuxWindowSizeReplay.commands(
            windowID: WindowId(5),
            requested: try TmuxClientGeometry(columns: 56, rows: 48)
        ).joined(separator: "\n")
        XCTAssertEqual(String(decoding: output, as: UTF8.self), expected)
        XCTAssertEqual(expected.split(separator: "\n").count, 4)
        XCTAssertEqual(expected.split(separator: "\n")[1], "select-window")
        XCTAssertFalse(expected.contains(";"))
        XCTAssertTrue(expected.hasSuffix("'tessera-window-size\t#{window_id}\t#{window_width}\t#{window_height}'"))
        XCTAssertEqual(expected.filter { $0 == "\t" }.count, 3)
        XCTAssertFalse(expected.contains("\\t"))
    }

    func testCommandsRejectInvalidArgumentsAndNeverPartiallyCopy() {
        XCTAssertEqual(commands(nil, -1), -1)
        for (windowID, columns, rows): (Int32, Int32, Int32) in [(-1, 56, 48), (5, 0, 48), (5, 56, 0), (5, 65_536, 48), (5, 56, 65_536)] {
            XCTAssertEqual(tesseraTmuxWindowSizeReplayCommands(
                windowID: windowID, columns: columns, rows: rows,
                outputBytes: nil, outputCapacity: 0
            ), -1)
        }
        XCTAssertGreaterThan(tesseraTmuxWindowSizeReplayCommands(
            windowID: 0, columns: 1, rows: 65_535,
            outputBytes: nil, outputCapacity: 0
        ), 0)
        var short = [UInt8](repeating: 0xAA, count: Int(commands(nil, 0)) - 1)
        XCTAssertEqual(short.withUnsafeMutableBufferPointer { commands($0.baseAddress, $0.count) }, -1)
        XCTAssertTrue(short.allSatisfy { $0 == 0xAA })
    }

    func testConfirmationChecksTagTargetAndBothDimensions() {
        let reply = "tessera-window-size\t@5\t56\t48"
        for suffix in ["", "\n", "\r\n"] {
            XCTAssertEqual(confirm(reply + suffix), 1)
        }
        for malformed in [
            "tessera-window-size\t@4\t56\t48",
            "tessera-window-size\t@5\t55\t48",
            "tessera-window-size\t@5\t56\t45",
            "other-tag\t@5\t56\t48",
            "tessera-window-size\t@05\t56\t48",
            "tessera-window-size\t@5\t056\t48",
            "tessera-window-size\t@5\t56\t+48",
            reply + "\tignored", reply + "\n\n", reply + "\r",
            reply + "\n" + reply, "", "56x48",
        ] {
            XCTAssertEqual(confirm(malformed), 0, malformed)
        }
    }

    func testConfirmationRejectsInvalidArgumentsAndUTF8() {
        XCTAssertEqual(tesseraTmuxWindowSizeReplayConfirm(
            windowID: 5, columns: 56, rows: 48, replyBytes: nil, replyCount: 0
        ), 0)
        for invalidCount in [-1, 1, 257] {
            XCTAssertEqual(tesseraTmuxWindowSizeReplayConfirm(
                windowID: 5, columns: 56, rows: 48, replyBytes: nil, replyCount: invalidCount
            ), -1)
        }
        for (windowID, columns, rows): (Int32, Int32, Int32) in [(-1, 56, 48), (5, 0, 48), (5, 56, 65_536)] {
            XCTAssertEqual(tesseraTmuxWindowSizeReplayConfirm(
                windowID: windowID, columns: columns, rows: rows, replyBytes: nil, replyCount: 0
            ), -1)
        }
        let invalidUTF8: [UInt8] = [0xFF, 0xFE]
        XCTAssertEqual(invalidUTF8.withUnsafeBufferPointer {
            tesseraTmuxWindowSizeReplayConfirm(
                windowID: 5, columns: 56, rows: 48,
                replyBytes: $0.baseAddress, replyCount: $0.count
            )
        }, 0)
    }

    func testOwnershipProofSharesTheStrictCanonicalInventoryContract() {
        let rows = "@5\tcontrol\t11\t101\n@5\tvisible\t12\t102"
        for ending in ["", "\n", "\r\n"] {
            XCTAssertEqual(ownershipProof(inventory: Array((rows + ending).utf8)), 1)
        }
        XCTAssertEqual(ownershipProof(inventory: Array((rows + "\n@6\tforeign\t13\t103").utf8)), 1)
        for malformed in [
            rows + "\n@5\tforeign\t13\t103",
            rows + "\n@6\tcontrol\t11\t101",
            rows + "\n@6\tforeign\t13\t103\n@6\tforeign\t13\t103",
            rows + "\n@06\tforeign\t13\t103",
            rows + "\n@6\tforeign\t013\t103",
            rows + "\n@6\tforeign\t13\t+103",
            rows + "\n@6\tforeign\t13\t103\textra",
            rows + "\n@6\tbad|name\t13\t103",
            rows + "\n\n", rows.replacingOccurrences(of: "\t", with: "\\t"),
        ] {
            XCTAssertEqual(ownershipProof(inventory: Array(malformed.utf8)), 0, malformed.debugDescription)
        }
        XCTAssertEqual(ownershipProof(control: Array("visible|12|102".utf8)), 0)
        XCTAssertEqual(ownershipProof(windowID: 6), 0)
    }

    func testOwnershipProofRejectsInvalidArgumentsBeforeReadingBuffers() {
        XCTAssertEqual(ownershipProof(windowID: -1), -1)
        for counts in [(-1, 0, 0), (257, 0, 0), (0, -1, 0), (0, 257, 0), (0, 0, -1), (0, 0, 65_537)] {
            XCTAssertEqual(tesseraTmuxWindowSizeReplayProvesExclusiveOwnership(
                windowID: 5, controlIdentityBytes: nil, controlIdentityCount: counts.0,
                visibleIdentityBytes: nil, visibleIdentityCount: counts.1,
                inventoryBytes: nil, inventoryCount: counts.2
            ), -1)
        }
        for counts in [(1, 0, 0), (0, 1, 0), (0, 0, 1)] {
            XCTAssertEqual(tesseraTmuxWindowSizeReplayProvesExclusiveOwnership(
                windowID: 5, controlIdentityBytes: nil, controlIdentityCount: counts.0,
                visibleIdentityBytes: nil, visibleIdentityCount: counts.1,
                inventoryBytes: nil, inventoryCount: counts.2
            ), -1)
        }
    }

    func testOwnershipProofRejectsInvalidUTF8AndEmptyInputs() {
        XCTAssertEqual(ownershipProof(control: [0xFF, 0xFE]), 0)
        XCTAssertEqual(ownershipProof(visible: [0xFF, 0xFE]), 0)
        XCTAssertEqual(ownershipProof(inventory: [0xFF, 0xFE]), 0)
        XCTAssertEqual(ownershipProof(control: []), 0)
        XCTAssertEqual(ownershipProof(visible: []), 0)
        XCTAssertEqual(ownershipProof(inventory: []), 0)
        XCTAssertEqual(tesseraTmuxWindowSizeReplayProvesExclusiveOwnership(
            windowID: 0, controlIdentityBytes: nil, controlIdentityCount: 0,
            visibleIdentityBytes: nil, visibleIdentityCount: 0,
            inventoryBytes: nil, inventoryCount: 0
        ), 0)
    }

    func testOwnershipProofEnforcesUTF8BoundsInEachInput() {
        let name = String(repeating: "é", count: 126)
        XCTAssertEqual(ownershipProof(
            control: Array((name + "|1|1").utf8),
            inventory: Array(("@5\t\(name)\t1\t1\n@5\tvisible\t12\t102").utf8)
        ), 1)
        XCTAssertEqual(ownershipProof(control: Array((name + "é|1|1").utf8)), -1)
        XCTAssertEqual(ownershipProof(visible: Array((name + "é|1|1").utf8)), -1)
        XCTAssertEqual(ownershipProof(inventory: [UInt8](repeating: 0x61, count: 65_536)), 0)
        XCTAssertEqual(ownershipProof(inventory: [UInt8](repeating: 0x61, count: 65_537)), -1)
    }

    func testOwnershipProofKeepsOpaqueClientNamesByteExact() {
        XCTAssertEqual(ownershipProof(
            control: Array("é|11|101".utf8),
            inventory: Array("@5\te\u{301}\t11\t101\n@5\tvisible\t12\t102".utf8)
        ), 0)
    }

    private func ownershipProof(
        windowID: Int32 = 5,
        control: [UInt8] = Array("control|11|101".utf8),
        visible: [UInt8] = Array("visible|12|102".utf8),
        inventory: [UInt8] = Array("@5\tcontrol\t11\t101\n@5\tvisible\t12\t102".utf8)
    ) -> Int32 {
        control.withUnsafeBufferPointer { controlBytes in
            visible.withUnsafeBufferPointer { visibleBytes in
                inventory.withUnsafeBufferPointer { inventoryBytes in
                    tesseraTmuxWindowSizeReplayProvesExclusiveOwnership(
                        windowID: windowID,
                        controlIdentityBytes: controlBytes.baseAddress, controlIdentityCount: controlBytes.count,
                        visibleIdentityBytes: visibleBytes.baseAddress, visibleIdentityCount: visibleBytes.count,
                        inventoryBytes: inventoryBytes.baseAddress, inventoryCount: inventoryBytes.count
                    )
                }
            }
        }
    }

    private func decision(
        requested: (Int32, Int32) = (56, 48),
        observed: (Int32, Int32) = (0, 0),
        lastAttempt: (Int32, Int32) = (0, 0)
    ) -> Int32 {
        tesseraTmuxWindowSizeReplayDecision(
            requestedColumns: requested.0, requestedRows: requested.1,
            observedColumns: observed.0, observedRows: observed.1,
            lastAttemptColumns: lastAttempt.0, lastAttemptRows: lastAttempt.1
        )
    }

    private func commands(_ output: UnsafeMutablePointer<UInt8>?, _ capacity: Int) -> Int32 {
        tesseraTmuxWindowSizeReplayCommands(
            windowID: 5, columns: 56, rows: 48,
            outputBytes: output, outputCapacity: capacity
        )
    }

    private func confirm(_ reply: String) -> Int32 {
        Array(reply.utf8).withUnsafeBufferPointer {
            tesseraTmuxWindowSizeReplayConfirm(
                windowID: 5, columns: 56, rows: 48,
                replyBytes: $0.baseAddress, replyCount: $0.count
            )
        }
    }
}
