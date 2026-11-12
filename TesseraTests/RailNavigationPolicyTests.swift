import Foundation
import SwiftUI
import Testing
@testable import Tessera

struct RailNavigationPolicyTests {
    private let first = UUID(uuidString: "D0010000-0000-4000-8000-000000000001")!
    private let second = UUID(uuidString: "D0010000-0000-4000-8000-000000000002")!
    private let closed = UUID(uuidString: "D0010000-0000-4000-8000-000000000003")!

    private func selection(
        from previousTab: CompactRootTab = .sessions,
        to newTab: CompactRootTab,
        current: SidebarItem? = nil,
        last: UUID? = nil,
        live: Set<UUID> = [],
        agents: Bool = true
    ) -> SidebarItem? {
        RailNavigationPolicy.selection(
            previousTab: previousTab,
            newTab: newTab,
            currentSelection: current,
            lastSessionID: last,
            liveSessionIDs: live,
            agentCenterEnabled: agents
        )
    }

    @Test("A layer beside the TabView reserves the inner display's rail and nothing on the outer one")
    func overlayRailInset() {
        let innerWindow = CGRect(x: 0, y: 0, width: 951, height: 669)
        let innerContent = CGRect(x: 0, y: 0, width: 867, height: 669)
        #expect(RailShellPolicy.overlayRailInset(railEdge: .trailing, overlay: innerWindow, tabContent: innerContent) == 84)
        let outer = CGRect(x: 0, y: 0, width: 382, height: 678)
        #expect(RailShellPolicy.overlayRailInset(railEdge: .trailing, overlay: outer, tabContent: outer) == 0)
        let leadingContent = CGRect(x: 84, y: 0, width: 867, height: 669)
        #expect(RailShellPolicy.overlayRailInset(railEdge: .leading, overlay: innerWindow, tabContent: leadingContent) == 84)
        #expect(RailShellPolicy.overlayRailInset(railEdge: nil, overlay: innerWindow, tabContent: innerContent) == 0)
        #expect(RailShellPolicy.overlayRailInset(railEdge: .trailing, overlay: innerWindow, tabContent: nil) == 0)
        #expect(RailShellPolicy.overlayRailInset(railEdge: .trailing, overlay: innerWindow, tabContent: .zero) == 0)
        let wider = CGRect(x: 0, y: 0, width: 1000, height: 669)
        #expect(RailShellPolicy.overlayRailInset(railEdge: .trailing, overlay: innerWindow, tabContent: wider) == 0)
        // Measured at launch on the outer display: a tab frame mid-layout.
        let outerOverlay = CGRect(x: 0, y: 32.3, width: 382, height: 645.7)
        let midLayout = CGRect(x: -18, y: -15, width: 36, height: 30)
        #expect(RailShellPolicy.overlayRailInset(railEdge: .trailing, overlay: outerOverlay, tabContent: midLayout) == 0)
        // The outer display's frame, still reported after opening to the inner one.
        let stale = CGRect(x: 0, y: 0, width: 382, height: 678)
        #expect(RailShellPolicy.overlayRailInset(railEdge: .trailing, overlay: innerWindow, tabContent: stale) == 0)
        let shifted = CGRect(x: 40, y: 0, width: 827, height: 669)
        #expect(RailShellPolicy.overlayRailInset(railEdge: .trailing, overlay: innerWindow, tabContent: shifted) == 0)
    }

    /// The overlay's mask drawn alone at 1×, in a canvas the width of the
    /// window so whatever reaches over the rail shows.
    @MainActor
    private func maskAlpha(width: CGFloat, railInset: CGFloat, keyboardBar: CGRect?, at points: [CGPoint]) throws -> [UInt8] {
        let canvas = ZStack(alignment: .topLeading) {
            Color.clear.frame(width: 466, height: 678)
            CompactOverlayMask(bottom: nil, railEdge: .trailing, railInset: railInset, keyboardBar: keyboardBar)
                .frame(width: width, height: 678)
        }
        let renderer = ImageRenderer(content: canvas)
        renderer.scale = 1
        let image = try #require(renderer.cgImage)
        return points.map { point in
            var pixel = [UInt8](repeating: 0, count: 4)
            pixel.withUnsafeMutableBytes { bytes in
                let context = CGContext(
                    data: bytes.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                )
                context?.draw(image, in: CGRect(
                    x: -point.x, y: point.y - CGFloat(image.height) + 1,
                    width: CGFloat(image.width), height: CGFloat(image.height)
                ))
            }
            return pixel[3]
        }
    }

    @MainActor
    @Test("Over a docked keyboard only the accessory bar reaches over the rail, on either display")
    func overlayMaskKeepsTheRailClearAboveTheBar() throws {
        let bar = CGRect(x: 0, y: 361, width: 466, height: 52)
        let pane = CGPoint(x: 100, y: 100), rail = CGPoint(x: 420, y: 100), barOverRail = CGPoint(x: 420, y: 380)
        // Outer display: the window's safe area already stops the overlay at the rail.
        #expect(try maskAlpha(width: 382, railInset: 0, keyboardBar: bar, at: [pane, rail, barOverRail]) == [255, 0, 255])
        // Inner display: the mask spans the window and insets itself off the rail.
        #expect(try maskAlpha(width: 466, railInset: 84, keyboardBar: bar, at: [pane, rail, barOverRail]) == [255, 0, 255])
        #expect(try maskAlpha(width: 382, railInset: 0, keyboardBar: nil, at: [pane, rail, barOverRail]) == [255, 0, 0])
    }

    @Test("Every rail section leaves a selected session for its own destination")
    func sectionsNavigateFromLiveSession() {
        let destinations: [(CompactRootTab, SidebarItem?)] = [
            (.hosts, nil), (.agents, .agents), (.artifacts, .artifacts), (.settings, .settings)
        ]
        for (tab, expected) in destinations {
            #expect(selection(to: tab, current: .session(first), last: first, live: [first]) == expected)
        }
    }

    @Test("Every changed rail section navigates away from the host editor")
    func sectionsNavigateFromHost() {
        let destinations: [(CompactRootTab, SidebarItem?)] = [
            (.sessions, .session(first)), (.agents, .agents),
            (.artifacts, .artifacts), (.settings, .settings)
        ]
        for (tab, expected) in destinations {
            #expect(selection(from: .hosts, to: tab, current: .host(second), last: first,
                              live: [first]) == expected)
        }
        #expect(selection(from: .settings, to: .hosts, current: .host(second),
                          last: first, live: [first]) == nil)
    }

    @Test("All changed tab pairs select their destination with no remembered session")
    func changedTabMatrix() {
        let tabs: [CompactRootTab] = [.hosts, .sessions, .agents, .artifacts, .settings]
        for previous in tabs {
            for tab in tabs where tab != previous {
                let expected: SidebarItem?
                switch tab {
                case .hosts, .sessions: expected = nil
                case .agents: expected = .agents
                case .artifacts: expected = .artifacts
                case .settings: expected = .settings
                }
                #expect(selection(from: previous, to: tab) == expected)
            }
        }
    }

    @Test("Sessions returns to the last selected live session from every other section")
    func returnsToRememberedSession() {
        let sources: [(CompactRootTab, SidebarItem?)] = [
            (.hosts, nil), (.hosts, .host(closed)), (.agents, .agents),
            (.artifacts, .artifacts), (.settings, .settings)
        ]
        for (tab, current) in sources {
            #expect(selection(from: tab, to: .sessions, current: current, last: second,
                              live: [first, second]) == .session(second))
        }
    }

    @Test("Sessions keeps a current live selection ahead of an older remembered session")
    func currentLiveSelectionWins() {
        #expect(selection(from: .hosts, to: .sessions, current: .session(first),
                          last: second, live: [first, second]) == .session(first))
    }

    @Test("An absent or closed remembered session shows the list without choosing another live slot")
    func neverSubstitutesAnUnselectedLiveSession() {
        #expect(selection(from: .hosts, to: .sessions, live: [first, second]) == nil)
        #expect(selection(from: .artifacts, to: .sessions, current: .artifacts,
                          last: closed, live: [first, second]) == nil)
        #expect(selection(from: .settings, to: .sessions, last: first) == nil)
    }

    @Test("A stale current session can fall back only to the remembered live slot")
    func staleCurrentSelection() {
        #expect(selection(from: .hosts, to: .sessions, current: .session(closed),
                          last: second, live: [first, second]) == .session(second))
        #expect(selection(from: .hosts, to: .sessions, current: .session(closed),
                          last: closed, live: [first]) == nil)
    }

    @Test("An unchanged tab preserves the overlay, including back to the sessions list")
    func unchangedTabDoesNotNavigate() {
        let sources: [(CompactRootTab, SidebarItem?)] = [
            (.hosts, .host(second)), (.sessions, .session(first)), (.sessions, nil),
            (.agents, .agents), (.artifacts, .artifacts), (.settings, .settings)
        ]
        for (tab, current) in sources {
            #expect(selection(from: tab, to: tab, current: current, last: first,
                              live: [first]) == current)
        }
    }

    @Test("An unchanged tab cannot retain a closed session or disabled Agent Center")
    func unchangedTabRejectsUnavailableSelection() {
        #expect(selection(from: .sessions, to: .sessions, current: .session(closed),
                          last: first, live: [first]) == nil)
        #expect(selection(from: .hosts, to: .hosts, current: .agents, agents: false) == nil)
    }

    @Test("Disabling Agent Center substitutes the sessions tab before TabView reads its selection")
    func hiddenAgentTabIsNeverSelectable() {
        let tabs: [CompactRootTab] = [.hosts, .sessions, .agents, .artifacts, .settings]
        for tab in tabs {
            #expect(RailNavigationPolicy.visibleTab(tab, agentCenterEnabled: true) == tab)
            #expect(RailNavigationPolicy.visibleTab(tab, agentCenterEnabled: false)
                    == (tab == .agents ? .sessions : tab))
        }
    }

    @Test("A hidden Agents destination returns to the remembered session or the list")
    func disabledAgentsUsesSessionsDestination() {
        let tabs: [CompactRootTab] = [.hosts, .sessions, .agents, .artifacts, .settings]
        for tab in tabs {
            #expect(selection(from: tab, to: .agents, current: .agents, last: second,
                              live: [first, second], agents: false) == .session(second))
            #expect(selection(from: tab, to: .agents, current: .agents, last: closed,
                              live: [first], agents: false) == nil)
        }
    }

    @Test("Disabling Agent Center leaves every other changed section's destination alone")
    func disablingAgentsDoesNotAffectOtherSections() {
        #expect(selection(to: .hosts, current: .session(first), last: first,
                          live: [first], agents: false) == nil)
        #expect(selection(to: .artifacts, current: .session(first), agents: false) == .artifacts)
        #expect(selection(to: .settings, current: .host(second), agents: false) == .settings)
        #expect(selection(from: .settings, to: .sessions, last: first,
                          live: [first], agents: false) == .session(first))
    }

    @Test("A rail round trip keeps the same live session ID and a closed slot stays closed")
    func sessionRoundTripAndClose() {
        let browse = selection(to: .artifacts, current: .session(second), last: second,
                               live: [first, second])
        #expect(browse == .artifacts)
        #expect(selection(from: .artifacts, to: .sessions, current: browse, last: second,
                          live: [first, second]) == .session(second))
        #expect(selection(from: .artifacts, to: .sessions, current: browse, last: second,
                          live: [first]) == nil)
    }

    @Test("Rail mode needs both the phone shell and a vertical rail edge")
    func railModeRequiresBothInputs() {
        for edge in [HorizontalEdge?.none, .leading, .trailing] {
            #expect(!RailShellPolicy.isRailMode(isPhone: false, railEdge: edge))
            #expect(RailShellPolicy.isRailMode(isPhone: true, railEdge: edge) == (edge != nil))
        }
    }

    @Test("Only a shown session folds the tabs for its actions, and never over another tab's badge")
    func railActionsYieldToSessionsAndBadges() {
        #expect(RailShellPolicy.prefersRailActions(sessionShown: true, otherTabBadged: false))
        #expect(!RailShellPolicy.prefersRailActions(sessionShown: true, otherTabBadged: true))
        #expect(!RailShellPolicy.prefersRailActions(sessionShown: false, otherTabBadged: false))
        #expect(!RailShellPolicy.prefersRailActions(sessionShown: false, otherTabBadged: true))
    }

    @Test("Overlay drawing leaves either rail edge clear and extends over the other three")
    func overlaysRespectBothRailEdges() {
        let leading = RailShellPolicy.overlayIgnoredEdges(isPhone: true, railEdge: .leading)
        #expect(leading == [.top, .bottom, .trailing])
        #expect(!leading.contains(.leading))
        let trailing = RailShellPolicy.overlayIgnoredEdges(isPhone: true, railEdge: .trailing)
        #expect(trailing == [.top, .bottom, .leading])
        #expect(!trailing.contains(.trailing))
    }

    @Test("The non-rail background keeps today's all-edge safe-area behavior")
    func nonRailOverlaysKeepAllEdges() {
        #expect(RailShellPolicy.overlayIgnoredEdges(isPhone: true, railEdge: nil) == .all)
        for edge in [HorizontalEdge?.none, .leading, .trailing] {
            #expect(RailShellPolicy.overlayIgnoredEdges(isPhone: false, railEdge: edge) == .all)
        }
    }

    @Test("Every live session gets one independent workspace state")
    func workspaceStateIsPerSession() {
        var states = RailShellPolicy.workspaceStates([:], liveSessionIDs: [first, second])
        #expect(Set(states.keys) == [first, second])
        #expect(states[first] == DuoWorkspaceState())
        #expect(states[second] == DuoWorkspaceState())
        states[first]?.toggleContext(arrangement: .sideBySide)
        states[first]?.swap()
        let retained = RailShellPolicy.workspaceStates(states, liveSessionIDs: [first, second])
        #expect(retained[first]?.contextHidden == true)
        #expect(retained[first]?.swapped == true)
        #expect(retained[second] == DuoWorkspaceState())
    }

    @Test("Closing a session drops only its state and a new slot starts with defaults")
    func closedWorkspaceStatesAreRemoved() {
        let remembered = DuoWorkspaceState(contextHidden: true, fullScreen: true, swapped: true)
        let states = RailShellPolicy.workspaceStates(
            [first: remembered, closed: DuoWorkspaceState(contextHidden: true)],
            liveSessionIDs: [first, second]
        )
        #expect(Set(states.keys) == [first, second])
        #expect(states[first] == remembered)
        #expect(states[second] == DuoWorkspaceState())
        #expect(states[closed] == nil)
        #expect(RailShellPolicy.workspaceStates(states, liveSessionIDs: []).isEmpty)
    }

    @Test("The book acts only beside a second pane, and the states survive pruning")
    func contextUsesTheCurrentArrangement() {
        var states = RailShellPolicy.workspaceStates([:], liveSessionIDs: [first, second])
        states[first]?.toggleContext(arrangement: .single)
        states[second]?.toggleContext(arrangement: .stacked)
        #expect(states[first] == DuoWorkspaceState())
        #expect(states[second]?.contextHidden == true)
        #expect(RailShellPolicy.workspaceStates(states, liveSessionIDs: [first, second]) == states)
    }

    @Test("The main pane fits 80 real cell widths plus the phone's four points on each side")
    func mainWidthIncludesBothPhoneInsets() {
        #expect(RailShellPolicy.mainIdealWidth(cellWidth: 6.5, isPhone: true, cornerInset: 24) == 528)
        #expect(RailShellPolicy.mainIdealWidth(cellWidth: 7.25, isPhone: true, cornerInset: 40) == 588)
        #expect(RailShellPolicy.mainIdealWidth(cellWidth: 6.5, isPhone: false, cornerInset: 24) == 568)
    }

    @Test("A delayed publication from another session never supplies the selected toolbar")
    func toolbarRejectsStaleActionsWithoutInvokingThem() {
        var calls = 0
        let actions = SessionRailActions(
            sessionID: first, canCreateTmuxWindow: true, findOpen: false, filesOpen: false,
            hasForwarding: true, hasContinuity: true, filesConnectUnprompted: false,
            openSwitcher: { calls += 1 },
            createTmuxWindow: { calls += 1 }, toggleFind: { calls += 1 },
            toggleFiles: { calls += 1 }, showForwarding: { calls += 1 },
            showContinuity: { calls += 1 }, disconnect: { calls += 1 }
        )
        #expect(RailShellPolicy.sessionActions(for: second, published: actions) == nil)
        #expect(RailShellPolicy.sessionActions(for: nil, published: actions) == nil)
        #expect(RailShellPolicy.sessionActions(for: first, published: nil) == nil)
        let selected = RailShellPolicy.sessionActions(for: first, published: actions)
        #expect(selected?.sessionID == first)
        #expect(selected?.canCreateTmuxWindow == true)
        #expect(selected?.hasForwarding == true)
        #expect(selected?.hasContinuity == true)
        #expect(calls == 0)
        selected?.toggleFind()
        #expect(calls == 1)
    }

    @Test("System-size harness mode preserves nil, compact and regular across width notifications")
    func systemHarnessDoesNotOverrideSizeClass() {
        for size in [UserInterfaceSizeClass?.none, .compact, .regular] {
            for compact in [false, true] {
                #expect(RailShellPolicy.harnessSizeClass(
                    usesSystemSizeClass: true, usesCompactWidth: compact, systemSizeClass: size
                ) == size)
            }
        }
    }

    @Test("Explicit harness sizes continue to override the system as before")
    func explicitHarnessWidthStillWorks() {
        #expect(RailShellPolicy.harnessSizeClass(
            usesSystemSizeClass: false, usesCompactWidth: true, systemSizeClass: .regular
        ) == .compact)
        #expect(RailShellPolicy.harnessSizeClass(
            usesSystemSizeClass: false, usesCompactWidth: false, systemSizeClass: .compact
        ) == .regular)
    }
}
