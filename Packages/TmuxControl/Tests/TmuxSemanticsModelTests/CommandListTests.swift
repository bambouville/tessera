import XCTest
@testable import TmuxSemanticsModel

final class CommandListTests: XCTestCase {
    func testCommandListHasOneClientGuardPairPerCommand() {
        for version in TmuxVersion.allCases {
            let model = TmuxServerModel(version: version)
            let (session, _) = model.newSession("O", size: CellSize(80, 24))
            let client = model.connect(control: "device", session: session)
            XCTAssertEqual(normalized(model.send(client, "display -p a ; display -p b")), [
                "%begin 1", "a", "%end 1", "%begin 1", "b", "%end 1"
            ], version.rawValue)
            assertFullyModelled(model)
        }
    }

    func testCommandListRuntimeErrorDropsTailWithoutGuards() {
        for version in TmuxVersion.allCases {
            let model = TmuxServerModel(version: version)
            let (session, _) = model.newSession("O", size: CellSize(80, 24))
            let client = model.connect(control: "device", session: session)
            XCTAssertEqual(normalized(model.send(client,
                "display -p a ; select-window -t @999999 ; display -p c")), [
                "%begin 1", "a", "%end 1", "%begin 1", "can't find window: @999999", "%error 1"
            ], version.rawValue)
            XCTAssertEqual(normalized(model.send(client, "display -p later")), ["%begin 1", "later", "%end 1"])
            assertFullyModelled(model)
        }
    }

    func testCommandListParseErrorRunsNothingAndHasOneErrorFrame() {
        for version in TmuxVersion.allCases {
            let model = TmuxServerModel(version: version)
            let (session, _) = model.newSession("O", size: CellSize(80, 24))
            let client = model.connect(control: "device", session: session)
            XCTAssertEqual(normalized(model.send(client,
                "set-option @early 1 ; display -p a ; bogus-command ; display -p c")), [
                "%begin 1", "parse error: unknown command: bogus-command", "%error 1"
            ], version.rawValue)
            XCTAssertEqual(payload(model.send(client, "show-options -qv @early")), [])
            XCTAssertEqual(normalized(model.send(client, "display -p later")), ["%begin 1", "later", "%end 1"])
            assertFullyModelled(model)
        }
    }
}
