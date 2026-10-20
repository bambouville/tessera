import XCTest
@testable import TmuxControlCore

final class PeerLabelTests: XCTestCase {
    private func label(
        _ peer: String?,
        selfName: String = "Android-Phone",
        known: Set<String> = ["Android-Phone", "Android-Tablet"]
    ) -> String {
        TmuxPeerLabel.display(
            peerDisplayName: peer,
            selfDisplayName: selfName,
            knownDeviceNames: known
        )
    }

    func testKnownDeviceClassRendersVerbatim() {
        XCTAssertEqual(label("iPhone", selfName: "iPad", known: ["iPhone", "iPad"]), "iPhone")
    }

    func testPeerOfOurOwnClassIsDisambiguated() {
        XCTAssertEqual(label("iPad", selfName: "iPad", known: ["iPhone", "iPad"]), "another iPad")
    }

    /// A peer stamp from the other platform is free text this UI cannot render
    /// as a device, and both ends must say the same thing about each other.
    func testCrossPlatformPeerFallsBackToTheSharedWording() {
        XCTAssertEqual(label("iPad"), TmuxStamplessPeer.displayName)
        XCTAssertEqual(
            label("Android-Phone", selfName: "iPad", known: ["iPhone", "iPad"]),
            TmuxStamplessPeer.displayName
        )
    }

    func testMissingOrBlankPeerFallsBack() {
        XCTAssertEqual(label(nil), TmuxStamplessPeer.displayName)
        XCTAssertEqual(label("   "), TmuxStamplessPeer.displayName)
    }

    func testUnknownFreeTextIsNeverRendered() {
        XCTAssertEqual(label("rm -rf /"), TmuxStamplessPeer.displayName)
    }
}

final class WindowDisplayNameTests: XCTestCase {
    private func window(
        name: String? = nil,
        activePaneTitle: String? = nil,
        activePaneTitleIsDefault: Bool = false
    ) -> TmuxWindowSnapshot {
        TmuxWindowSnapshot(
            id: WindowId(3),
            name: name,
            activePaneTitle: activePaneTitle,
            activePaneTitleIsDefault: activePaneTitleIsDefault
        )
    }

    func testPaneTitleWinsOverWindowName() {
        XCTAssertEqual(window(name: "zsh", activePaneTitle: "vim README").displayName, "vim README")
    }

    /// tmux's default pane title is `#{host}`, which names the machine rather
    /// than the window, so it must never become a tab label.
    func testDefaultPaneTitleFallsBackToWindowName() {
        XCTAssertEqual(
            window(name: "build", activePaneTitle: "vps-1", activePaneTitleIsDefault: true).displayName,
            "build"
        )
    }

    func testBlankNamesFallThroughToTheWindowId() {
        XCTAssertEqual(window(name: "   ", activePaneTitle: "").displayName, "@3")
        XCTAssertEqual(window().displayName, "@3")
    }

    /// Non-Swift clients read the label off the wire instead of recomputing it.
    func testDisplayNameIsEncodedOnTheWire() throws {
        let encoded = try JSONEncoder().encode(window(name: "zsh", activePaneTitle: "htop"))
        let decoded = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        XCTAssertEqual(decoded["displayName"] as? String, "htop")
    }

    func testDecodeIgnoresTheDerivedKey() throws {
        let original = window(name: "zsh", activePaneTitle: "htop")
        let round = try JSONDecoder().decode(
            TmuxWindowSnapshot.self,
            from: try JSONEncoder().encode(original)
        )
        XCTAssertEqual(round, original)
        XCTAssertEqual(round.displayName, "htop")
    }
}

final class PaneMetadataSubscriptionTests: XCTestCase {
    private func attached() -> TmuxRuntimeEngine {
        var engine = TmuxRuntimeEngine()
        _ = engine.feed(Array((
            "%session-changed $1 work\n" +
            "%window-add @1\n" +
            "%window-renamed @1 zsh\n" +
            "%window-pane-changed @1 %10\n" +
            "%session-window-changed $1 @1\n"
        ).utf8))
        return engine
    }

    private func payload(
        pane: String = "%10",
        active: String = "1",
        title: String,
        windowName: String = "zsh",
        host: String = "vps-1"
    ) -> [UInt8] {
        let value = [
            "@1", pane, active, "0", "0", "80", "24",
            "zsh", title, windowName, host, "/home/tessera", "",
        ].joined(separator: "\t")
        return Array("%subscription-changed tessera-pane-meta $1 @1 0 \(pane) : \(value)\n".utf8)
    }

    func testSubscriptionFormatCarriesTheTabSafeTitle() {
        XCTAssertTrue(TmuxPaneMetadataSubscription.format.contains("#{s/\t/ /:pane_title}"))
    }

    /// The bug: tmux never announces a pane title change, so a client that only
    /// tracks `%window-renamed` shows a stale label forever.
    func testLivePaneTitleBecomesTheWindowLabel() {
        var engine = attached()
        XCTAssertEqual(engine.snapshot.windows.first?.displayName, "zsh")

        let batch = engine.feed(payload(title: "vim README"))

        XCTAssertEqual(batch.snapshot.windows.first?.displayName, "vim README")
    }

    func testDefaultHostTitleLeavesTheWindowNameShowing() {
        var engine = attached()
        let batch = engine.feed(payload(title: "vps-1"))
        XCTAssertEqual(batch.snapshot.windows.first?.displayName, "zsh")
    }

    /// tmux fans the subscription out over every pane, so a background pane's
    /// title must not relabel the tab the user is looking at.
    func testInactivePaneDoesNotRelabelTheWindow() {
        var engine = attached()
        _ = engine.feed(payload(title: "vim README"))

        let batch = engine.feed(payload(pane: "%11", active: "0", title: "tail -f log"))

        XCTAssertEqual(batch.snapshot.windows.first?.displayName, "vim README")
    }

    /// tmux escapes the field separators themselves, so the payload is decoded
    /// before it is split — the decoded tabs are what delimit the fields.
    func testEscapedSeparatorsDelimitTheDecodedFields() {
        let update = TmuxPaneMetadataSubscription.parse(
            ["@1", "%10", "1", "0", "0", "80", "24", "zsh", "vim README", "build", "vps-1", "/", ""]
                .joined(separator: #"\t"#),
            fallbackWindowID: WindowId(9),
            fallbackPaneID: PaneId(99)
        )
        XCTAssertEqual(update?.windowID, WindowId(1))
        XCTAssertEqual(update?.paneID, PaneId(10))
        XCTAssertEqual(update?.paneTitle, "vim README")
        XCTAssertEqual(update?.windowName, "build")
    }

    /// Backslash and octal escapes survive inside a value; a title is arbitrary
    /// remote text and must not be mangled or dropped.
    func testBackslashAndOctalEscapesDecodeInsideAValue() {
        let update = TmuxPaneMetadataSubscription.parse(
            ["@1", "%10", "1", "0", "0", "80", "24", "zsh", #"C:\\src\075"#, "build", "vps-1", "/", ""]
                .joined(separator: "\t"),
            fallbackWindowID: WindowId(1),
            fallbackPaneID: PaneId(10)
        )
        XCTAssertEqual(update?.paneTitle, #"C:\src="#)
    }

    /// A payload whose leading ids are unusable still names the pane tmux
    /// attributed the event to, rather than dropping the update.
    func testMangledIdentifiersFallBackToTheEventsOwnPane() {
        let update = TmuxPaneMetadataSubscription.parse(
            "not-a-window\tnot-a-pane\t1\t0\t0\t80\t24\tzsh\tvim\tbuild\tvps-1\t/\t",
            fallbackWindowID: WindowId(4),
            fallbackPaneID: PaneId(40)
        )
        XCTAssertEqual(update?.windowID, WindowId(4))
        XCTAssertEqual(update?.paneID, PaneId(40))
        XCTAssertEqual(update?.paneTitle, "vim")
    }

    /// An old server without the geometry fields shifts everything down by
    /// four; the label must still resolve rather than reading a stray column.
    func testShortPreGeometryLayoutStillYieldsATitle() {
        let update = TmuxPaneMetadataSubscription.parse(
            ["@1", "%10", "1", "zsh", "vim README", "build", "vps-1", "/"]
                .joined(separator: "\t"),
            fallbackWindowID: WindowId(1),
            fallbackPaneID: PaneId(10)
        )
        XCTAssertNil(update?.contentRect)
        XCTAssertEqual(update?.paneTitle, "vim README")
        XCTAssertEqual(update?.windowName, "build")
        XCTAssertFalse(update?.paneTitleIsDefault ?? true)
    }
}

/// A tab inside a value is the one thing the tab-separated wire format cannot
/// carry. Captured from tmux 3.4 and 3.6a: backslashes are escaped in the
/// payload, but a tab in `pane_current_path` arrives raw and shifts every later
/// field. tmux's own `s///` removes it before it is ever sent.
final class TabSeparatorSafetyTests: XCTestCase {

    func testEveryFreeTextFieldIsStrippedOfTabsByTheServer() {
        for variable in [
            "pane_current_command", "pane_title", "window_name",
            "pane_current_path", "@tessera_agent_state",
        ] {
            XCTAssertTrue(
                TmuxPaneMetadataSubscription.format.contains("#{s/\t/ /:\(variable)}"),
                "\(variable) can carry free text and must be stripped of tabs"
            )
            XCTAssertFalse(
                TmuxPaneMetadataSubscription.format.contains("\t#{\(variable)}"),
                "\(variable) must not also appear unwrapped"
            )
        }
    }

    /// The directory name is the field that actually reaches this state — tmux
    /// strips tabs from OSC pane titles and escapes them in window names, but a
    /// filesystem will hand back whatever it was given.
    func testHydrationStripsTabsFromTheFieldsThatCanCarryThem() {
        let panes = TmuxRuntimeHydrationQuery.commands.first { $0.contains("list-panes") }
        let windows = TmuxRuntimeHydrationQuery.commands.first { $0.contains("list-windows") }
        XCTAssertNotNil(panes)
        XCTAssertNotNil(windows)
        XCTAssertTrue(panes?.contains("#{s/\t/ /:pane_current_path}") ?? false)
        XCTAssertTrue(panes?.contains("#{s/\t/ /:pane_title}") ?? false)
        XCTAssertTrue(windows?.contains("#{s/\t/ /:window_name}") ?? false)
    }

    /// Identifiers and integers cannot contain a tab, and wrapping them would
    /// cost a substitution per pane per update for nothing.
    func testIdentifiersAndGeometryAreLeftAlone() {
        for variable in ["window_id", "pane_id", "pane_active", "pane_width", "host"] {
            XCTAssertTrue(
                TmuxPaneMetadataSubscription.format.contains("#{\(variable)}"),
                "\(variable) cannot carry a tab and should not pay for a substitution"
            )
        }
    }

    /// With values guaranteed tab-free, the decode-then-split parser is
    /// unambiguous: every tab that survives is a separator.
    func testAFieldCountIsStableForAValueThatWouldOtherwiseShiftIt() {
        let update = TmuxPaneMetadataSubscription.parse(
            ["@1", "%10", "1", "0", "0", "80", "24", "zsh", "vim", "build",
             "vps-1", "/tmp/esc dir", ""].joined(separator: "\t"),
            fallbackWindowID: WindowId(1),
            fallbackPaneID: PaneId(10)
        )
        XCTAssertEqual(update?.currentPath, "/tmp/esc dir")
        XCTAssertEqual(update?.windowName, "build")
        XCTAssertEqual(update?.paneTitle, "vim")
    }
}

/// Hydration is the only path that learns a pane title without the
/// subscription's explicit `pane_title == host` comparison, so the default-title
/// rule has to be re-derived from `#{host}` there. Without it a freshly attached
/// window is labelled with the name of the machine.
final class HydrationDefaultTitleTests: XCTestCase {

    private func hydrate(title: String, host: String) -> TmuxWindowSnapshot? {
        var engine = TmuxRuntimeEngine()
        _ = engine.feed(Array((
            "%begin 1 1 1\n" +
            "__tessera_windows__\t@4\t0\t%8\t0000,80x24,0,0,8\t0000,80x24,0,0,8\t0\tmain\n" +
            "%end 1 1 1\n"
        ).utf8))
        return engine.feed(Array((
            "%begin 1 2 1\n" +
            "__tessera_panes__\t@4\t%8\t1\t0\t0\t80\t24\t\(title)\t/home/dev\t\(host)\n" +
            "%end 1 2 1\n"
        ).utf8)).snapshot.windows.first
    }

    func testHydrationCarriesTheHostSoTheLabelCanIgnoreTmuxsDefaultTitle() {
        XCTAssertTrue(
            TmuxRuntimeHydrationQuery.commands.contains { $0.contains("#{host}") },
            "without #{host} nothing downstream can tell a real title from tmux's default"
        )
    }

    func testADefaultTitledPaneFallsThroughToTheWindowName() {
        let window = hydrate(title: "vps-1", host: "vps-1")
        XCTAssertEqual(window?.panes.first?.titleIsDefault, true)
        XCTAssertEqual(window?.activePaneTitleIsDefault, true)
        XCTAssertEqual(window?.displayName, "main")
    }

    func testAnApplicationTitleWinsOverTheWindowName() {
        let window = hydrate(title: "vim README", host: "vps-1")
        XCTAssertEqual(window?.panes.first?.titleIsDefault, false)
        XCTAssertEqual(window?.activePaneTitle, "vim README")
        XCTAssertEqual(window?.displayName, "vim README")
    }

    /// A server that predates the `#{host}` field sends ten columns, not eleven.
    /// Nothing can be classified as default there, which is the old behaviour —
    /// but the title must not be dropped or misread as the path.
    func testAPreHostServerStillHydratesTheTitle() {
        var engine = TmuxRuntimeEngine()
        _ = engine.feed(Array((
            "%begin 1 1 1\n" +
            "__tessera_windows__\t@4\t0\t%8\t0000,80x24,0,0,8\t0000,80x24,0,0,8\t0\tmain\n" +
            "%end 1 1 1\n"
        ).utf8))
        let window = engine.feed(Array((
            "%begin 1 2 1\n" +
            "__tessera_panes__\t@4\t%8\t1\t0\t0\t80\t24\tvps-1\t/home/dev\n" +
            "%end 1 2 1\n"
        ).utf8)).snapshot.windows.first
        XCTAssertEqual(window?.panes.first?.title, "vps-1")
        XCTAssertEqual(window?.panes.first?.currentPath, "/home/dev")
        XCTAssertEqual(window?.panes.first?.titleIsDefault, false)
    }
}

/// The pane-metadata feed is the only lifecycle carrier that reaches a pane
/// nobody is painting.
///
/// The remote hook writes each event twice — an OSC on the pane's own tty and
/// the `@tessera_agent_state` pane option. A client renders one window, so
/// output scanning only ever sees one pane; the option arrives for every pane
/// of the session. Dropping it here is what left Android's Agent Center empty
/// on a host running an agent in every other window.
final class PaneAgentStateFeedTests: XCTestCase {
    private let claude = #"{"version":9,"provider":"claude","event":"Stop","state":"idle"}"#

    private let attachment =
        "%session-changed $1 work\n" +
        "%window-add @1\n" +
        "%window-pane-changed @1 %10\n" +
        "%session-window-changed $1 @1\n"

    private func attached() -> TmuxRuntimeEngine {
        var engine = TmuxRuntimeEngine()
        _ = engine.feed(Array(attachment.utf8))
        return engine
    }

    private func payload(
        session: String = "$1",
        window: String = "@1",
        pane: String = "%10",
        json: String
    ) -> [UInt8] {
        let value = [
            window, pane, "1", "0", "0", "80", "24",
            "claude", "Claude", "agents", "vps-1", "/home/tessera", json,
        ].joined(separator: "\t")
        return Array(
            "%subscription-changed tessera-pane-meta \(session) \(window) 0 \(pane) : \(value)\n".utf8
        )
    }

    func testAgentStateIsCarriedOutOfTheBatchWithItsPaneAddress() {
        var engine = attached()

        let batch = engine.feed(payload(json: claude))

        XCTAssertEqual(batch.agentStates.count, 1)
        XCTAssertEqual(batch.agentStates.first?.windowID, WindowId(1))
        XCTAssertEqual(batch.agentStates.first?.paneID, PaneId(10))
        XCTAssertEqual(batch.agentStates.first?.json, claude)
    }

    /// The regression: an agent works in a window the client never selected,
    /// so the client was never told the window exists. Topology ingest returns
    /// early for it — the lifecycle must not leave with it.
    func testAnUndescribedWindowStillDeliversItsAgentState() {
        var engine = attached()

        let batch = engine.feed(payload(window: "@7", pane: "%70", json: claude))

        XCTAssertFalse(batch.snapshot.windows.contains { $0.id == WindowId(7) })
        XCTAssertEqual(batch.agentStates.map(\.paneID), [PaneId(70)])
        XCTAssertEqual(batch.agentStates.first?.windowID, WindowId(7))
    }

    /// `%*` subscribes server-wide, so another session's agent must not be
    /// reported as one of this session's.
    func testForeignSessionAgentStateIsNotDelivered() {
        var engine = attached()

        let batch = engine.feed(payload(session: "$4", window: "@9", pane: "%90", json: claude))

        XCTAssertTrue(batch.agentStates.isEmpty)
    }

    func testAPaneWithoutTheOptionReportsNothing() {
        var engine = attached()

        let batch = engine.feed(payload(json: ""))

        XCTAssertTrue(batch.agentStates.isEmpty)
    }

    /// The same ceiling the OSC transport enforces, so one carrier cannot
    /// admit a frame the other would refuse.
    func testAnOversizePayloadIsRefusedRatherThanCarried() {
        var engine = attached()
        let oversize = String(repeating: "a", count: TmuxPaneAgentState.maximumJSONBytes + 1)

        let batch = engine.feed(payload(json: oversize))

        XCTAssertTrue(batch.agentStates.isEmpty)
    }

    /// The regression this layer must never reintroduce. tmux announces a pane
    /// option's current value once, when a client subscribes, and an idle
    /// agent never changes it again. Suppressing the repeat here costs
    /// nothing visible in a test that only replays one stream, and costs the
    /// whole feature in production: the endpoint that consumes these payloads
    /// is built moments after the subscribe, so the single announcement can
    /// land with no consumer, and a suppressed repeat is then never spoken
    /// again. Report what tmux said; let the layer that knows who is
    /// listening decide what is a duplicate.
    func testARepeatedPayloadIsAnnouncedAgainRatherThanSuppressed() {
        var engine = attached()
        XCTAssertEqual(engine.feed(payload(json: claude)).agentStates.count, 1)

        XCTAssertEqual(engine.feed(payload(json: claude)).agentStates.map(\.json), [claude])
    }

    func testAChangedPayloadForTheSamePaneIsDelivered() {
        var engine = attached()
        _ = engine.feed(payload(json: claude))
        let next = #"{"version":9,"provider":"claude","event":"Stop","state":"finished"}"#

        XCTAssertEqual(engine.feed(payload(json: next)).agentStates.map(\.json), [next])
    }

    /// Two panes are two independent states; one must not silence the other.
    func testEachPaneIsCarriedSeparately() {
        var engine = attached()
        _ = engine.feed(payload(json: claude))

        let batch = engine.feed(payload(window: "@7", pane: "%70", json: claude))

        XCTAssertEqual(batch.agentStates.map(\.paneID), [PaneId(70)])
    }

    /// A reconnect replays a whole control stream and tmux re-announces every
    /// pane's current option to the new client, which needs every one of them.
    func testATransportResetStillDeliversTheReannouncedValue() {
        var engine = attached()
        _ = engine.feed(payload(json: claude))
        engine.reset()
        _ = engine.feed(Array(attachment.utf8))

        XCTAssertEqual(engine.feed(payload(json: claude)).agentStates.count, 1)
    }

    /// A side-channel reattach keeps the window model but still replaces the
    /// control stream, so it re-announces every option too.
    func testAResetThatKeepsTheWindowModelStillDelivers() {
        var engine = attached()
        _ = engine.feed(payload(json: claude))
        engine.reset(keepingSnapshot: true)

        XCTAssertEqual(engine.feed(payload(json: claude)).agentStates.count, 1)
    }

    /// Each read owns its own list; a later read must not replay an earlier
    /// one's lifecycle as if it had just arrived.
    func testAgentStatesDoNotLeakIntoTheNextRead() {
        var engine = attached()
        XCTAssertEqual(engine.feed(payload(json: claude)).agentStates.count, 1)

        XCTAssertTrue(engine.feed(Array("%window-renamed @1 agents\n".utf8)).agentStates.isEmpty)
    }
}
