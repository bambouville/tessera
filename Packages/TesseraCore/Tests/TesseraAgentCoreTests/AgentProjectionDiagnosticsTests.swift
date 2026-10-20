import Foundation
import XCTest
@testable import TesseraAgentCore

final class AgentProjectionDiagnosticsTests: XCTestCase {
    func testMalformedSourceDiagnosticsRemainBoundedAndNonSensitive() {
        let wire = #"{"v":1,"kind":"error","error":"malformed","diagnostics":{"provider":"codex","stage":"normalize","reason":"adapterException","exception":"TypeError","sourceBytes":"109976229","recordSequence":"52","frameBytes":"262145","limitBytes":"262144","path":"private","message":"private","payload":"private"}}"#
        let fields = AgentProjectionDiagnostics.errorFields(stdout: Data(wire.utf8))
        XCTAssertEqual(fields["stage"], "normalize")
        XCTAssertEqual(fields["exception"], "TypeError")
        XCTAssertEqual(fields["sourceBytes"], "109976229")
        XCTAssertEqual(fields["recordSequence"], "52")
        XCTAssertEqual(fields.count, 9)
        XCTAssertFalse(fields.values.contains("private"))
    }

    func testOnlyFixedLabelsAndNumericPermissionFactsReachDiagnostics() {
        let wire = #"{"v":1,"kind":"error","error":"permissionDenied","diagnostics":{"provider":"codex","pathKind":"windowsDrive","reason":"ownerMismatch","stage":"sourcePolicy","effectiveUID":"1000","ownerUID":"0","mode":"0666","errno":"13","path":"C:\\private\\secret","transcript":"private text","ownerGID":"secret"}}"#
        XCTAssertEqual(AgentProjectionDiagnostics.errorFields(stdout: Data(wire.utf8)), [
            "error": "permissionDenied", "provider": "codex", "pathKind": "windowsDrive",
            "reason": "ownerMismatch", "stage": "sourcePolicy", "effectiveUID": "1000",
            "ownerUID": "0", "mode": "0666", "errno": "13",
        ])
    }

    func testUntrustedLabelsAndOversizedFramesAreNotLogged() {
        let wire = #"{"v":1,"kind":"error","error":"permissionDenied","diagnostics":{"reason":"secret text","stage":"/private/path","provider":"token","errno":"-1","mode":"12345678901"}}"#
        XCTAssertEqual(AgentProjectionDiagnostics.errorFields(stdout: Data(wire.utf8)), ["error": "permissionDenied"])
        XCTAssertEqual(AgentProjectionDiagnostics.errorFields(stdout: Data(repeating: 65, count: 262_145)), [:])
        XCTAssertEqual(AgentProjectionDiagnostics.errorFields(stdout: Data(#"{"v":1,"kind":"error","error":"private text"}"#.utf8)), [:])
    }
}
