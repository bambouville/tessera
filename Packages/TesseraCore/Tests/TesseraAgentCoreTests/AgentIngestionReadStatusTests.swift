import Foundation
import XCTest
@testable import TesseraAgentCore

final class AgentIngestionReadStatusTests: XCTestCase {
    private func decode(_ state: String, _ recovery: String, code: String = "readPending", version: Int = 1) throws -> AgentIngestionReadStatus {
        try AgentIngestionReadStatus.decode(.object([
            "v": .number(Decimal(version)), "state": .string(state), "domain": .string("source"),
            "recovery": .string(recovery), "code": .string(code)
        ]))
    }
    func testProgressIsSeparateFromFailureAndLocalPageMemory() throws {
        let preparing = try decode("preparing", "continue")
        XCTAssertTrue(preparing.isProgress)
        XCTAssertEqual(preparing.message, "Preparing conversation…")
        let budget = try decode("resourceLimited", "retryRead", code: "codexIndexCapacity")
        XCTAssertFalse(budget.isProgress)
        XCTAssertEqual(budget.code, "codexIndexCapacity")
        XCTAssertFalse(budget.message.contains("history memory"))
    }
    func testRejectsIncoherentStatusAndUnsafeDiagnostics() {
        for pair in [("preparing", "manual"), ("failed", "continue"), ("future", "manual")] {
            XCTAssertThrowsError(try decode(pair.0, pair.1))
        }
        for code in ["", "private path /users", "line\ntext", String(repeating: "x", count: 81)] {
            XCTAssertThrowsError(try decode("failed", "manual", code: code))
        }
        XCTAssertThrowsError(try decode("failed", "manual", version: 2))
    }
    func testExactCauseDoesNotChangeRecoveryPolicy() throws {
        let value = try decode("sourceChanged", "rebootstrap", code: "sourceChanged")
        XCTAssertEqual(value.recovery, .rebootstrap)
        XCTAssertFalse(value.isProgress)
    }
}
