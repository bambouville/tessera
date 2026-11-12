import XCTest
import TmuxControlCore

final class WindowAgentDisplayNameTests: XCTestCase {
    func testSharedWindowLabelVectors() {
        let vectors: [(String?, String?, String?, Bool, String?, String)] = [
            ("sh", "sh", "vim README", false, "claude", "vim README"),
            ("agent", "node", nil, false, "claude", "agent"),
            ("sh", "sh", nil, false, "claude", "claude"),
            ("sh", "sh", nil, false, nil, "sh"),
            ("", "zsh", nil, false, "codex", "codex"),
            (nil, nil, nil, false, nil, "@3"),
            ("sh", "sh", "devbox", true, "claude", "claude"),
            (" sh ", "sh\n", " ", false, " claude ", "claude"),
            (" tokens ", "node", "devbox", true, "claude", "tokens"),
        ]
        for (name, command, title, isDefault, provider, expected) in vectors {
            XCTAssertEqual(TmuxWindowSnapshot.agentDisplayName(
                windowID: WindowId(3), name: name, activePaneTitle: title,
                activePaneTitleIsDefault: isDefault, activePaneCurrentCommand: command,
                agentProvider: provider
            ), expected)
        }
    }

    func testLegacyDisplayNameAndWireStayUnchanged() throws {
        let window = TmuxWindowSnapshot(id: WindowId(3), name: "sh")
        XCTAssertEqual(window.displayName, "sh")
        let wire = try JSONSerialization.jsonObject(with: JSONEncoder().encode(window)) as! [String: Any]
        XCTAssertEqual(wire["displayName"] as? String, "sh")
        XCTAssertNil(wire["agentDisplayName"])
    }
}
