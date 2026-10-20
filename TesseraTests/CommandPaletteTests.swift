import XCTest
import TmuxControl
@testable import Tessera

@MainActor
final class CommandPaletteTests: XCTestCase {
    func test_open_seedsSnapshotAndFocusToken() {
        let palette = CommandPalette()
        let a = makeLive(name: "alpha")
        let b = makeLive(name: "beta")
        let initialToken = palette.focusRequestToken

        palette.open(sessions: [a, b])

        XCTAssertTrue(palette.isOpen)
        XCTAssertEqual(palette.sessions.map(\.id), [a.id, b.id])
        XCTAssertEqual(palette.query, "")
        XCTAssertEqual(palette.selectedIndex, 0)
        XCTAssertEqual(palette.focusRequestToken, initialToken &+ 1)
    }

    func test_open_bumpsFocusTokenOnReopen() {
        let palette = CommandPalette()
        palette.open(sessions: [])
        let token = palette.focusRequestToken

        palette.open(sessions: [])

        XCTAssertEqual(palette.focusRequestToken, token &+ 1)
    }

    func test_compactNoticeIsFirstLineOnlyForAnEmptyQuery() {
        let palette = CommandPalette()
        let notice = CommandPaletteNotice(
            title: "Agent integration not installed",
            message: "Install the status hook for precise state.",
            actionLabel: "Install integration"
        )

        palette.open(sessions: [], notice: notice)
        XCTAssertEqual(palette.visibleNotice, notice)

        palette.query = "host"
        XCTAssertNil(palette.visibleNotice)
    }

    func test_compactNoticeActionClosesPaletteAndRunsCallback() {
        let palette = CommandPalette()
        var performed = false
        palette.open(
            sessions: [],
            notice: CommandPaletteNotice(
                title: "Agent integration not installed",
                message: "Install the status hook for precise state.",
                actionLabel: "Install integration"
            ),
            onNoticeAction: { performed = true }
        )

        palette.performNoticeAction()

        XCTAssertTrue(performed)
        XCTAssertFalse(palette.isOpen)
        XCTAssertNil(palette.notice)
    }

    func test_close_clearsIsOpenWithoutResettingSnapshot() {
        let palette = CommandPalette()
        let a = makeLive(name: "a")
        palette.open(sessions: [a])

        palette.close()

        XCTAssertFalse(palette.isOpen)
        XCTAssertEqual(palette.sessions.count, 1)
    }

    func test_emptyQueryReturnsAllActiveSessions() {
        let palette = CommandPalette()
        let a = makeLive(name: "a")
        let b = makeLive(name: "b")
        palette.open(sessions: [a, b])

        XCTAssertEqual(palette.results.count, 2)
    }

    func test_filterMatchesByHostName_caseInsensitive() {
        let palette = CommandPalette()
        let prod = makeLive(name: "prod-web-01")
        let db = makeLive(name: "db-replica")
        palette.open(sessions: [prod, db])

        palette.query = "PROD"
        XCTAssertEqual(palette.results.map(\.id), [prod.id])
    }

    func test_filterMatchesByHostKey() {
        let palette = CommandPalette()
        let s = makeLive(name: "any", hostKeyOverride: "ssh:bob@example.com:22")
        palette.open(sessions: [s])

        palette.query = "bob@example"

        XCTAssertEqual(palette.results.map(\.id), [s.id])
    }

    func test_filterMatchesByPaneTitle() {
        let palette = CommandPalette()
        let s = makeLive(name: "host")
        palette.open(sessions: [s], paneTitles: [s.id: "editor"])

        palette.query = "edit"

        XCTAssertEqual(palette.results.map(\.id), [s.id])
    }

    func test_filterTrimsWhitespace() {
        let palette = CommandPalette()
        let s = makeLive(name: "alpha")
        palette.open(sessions: [s])

        palette.query = "   "
        XCTAssertEqual(palette.results.count, 1)
    }

    func test_resultsSortedByLastTouchedDescending() {
        let palette = CommandPalette()
        let a = makeLive(name: "a")
        let b = makeLive(name: "b")
        let c = makeLive(name: "c")
        let t = Date(timeIntervalSinceReferenceDate: 0)
        let touched: [UUID: Date] = [
            a.id: t.addingTimeInterval(1),
            b.id: t.addingTimeInterval(3),
            c.id: t.addingTimeInterval(2),
        ]

        palette.open(sessions: [a, b, c], lastTouched: touched)

        XCTAssertEqual(palette.results.map(\.id), [b.id, c.id, a.id])
    }

    func test_untouchedSessionsTailTheResultList() {
        let palette = CommandPalette()
        let a = makeLive(name: "a")
        let b = makeLive(name: "b")
        palette.open(sessions: [a, b], lastTouched: [b.id: Date()])

        XCTAssertEqual(palette.results.first?.id, b.id)
        XCTAssertEqual(palette.results.last?.id, a.id)
    }

    func test_emptyActiveSet_yieldsEmptyResults() {
        let palette = CommandPalette()
        palette.open(sessions: [])
        XCTAssertEqual(palette.results.count, 0)
        XCTAssertNil(palette.commit())
    }

    func test_selectNext_wrapsAtEnd() {
        let palette = CommandPalette()
        let a = makeLive(name: "a")
        let b = makeLive(name: "b")
        palette.open(sessions: [a, b])
        palette.selectedIndex = 1

        palette.selectNext()

        XCTAssertEqual(palette.selectedIndex, 0)
    }

    func test_selectPrevious_wrapsAtStart() {
        let palette = CommandPalette()
        let a = makeLive(name: "a")
        let b = makeLive(name: "b")
        palette.open(sessions: [a, b])
        palette.selectedIndex = 0

        palette.selectPrevious()

        XCTAssertEqual(palette.selectedIndex, 1)
    }

    func test_commit_returnsHighlightedID() {
        let palette = CommandPalette()
        let a = makeLive(name: "a")
        let b = makeLive(name: "b")
        palette.open(sessions: [a, b])
        palette.selectedIndex = 1

        XCTAssertEqual(palette.commit(), b.id)
    }

    func test_commit_returnsNilWhenResultsEmpty() {
        let palette = CommandPalette()
        let s = makeLive(name: "a")
        palette.open(sessions: [s])
        palette.query = "no-match-anywhere"

        XCTAssertNil(palette.commit())
    }

    func test_didChangeQuery_clampsSelection() {
        let palette = CommandPalette()
        let a = makeLive(name: "alpha")
        let b = makeLive(name: "beta")
        palette.open(sessions: [a, b])
        palette.selectedIndex = 1
        palette.query = "alpha"

        palette.didChangeQuery()

        XCTAssertEqual(palette.selectedIndex, 0)
    }

    func test_refreshSnapshot_updatesUnderlyingDataAndClamps() {
        let palette = CommandPalette()
        let a = makeLive(name: "a")
        let b = makeLive(name: "b")
        palette.open(sessions: [a, b])
        palette.selectedIndex = 1

        palette.refreshSnapshot(sessions: [a], paneTitles: [:], lastTouched: [:])

        XCTAssertEqual(palette.sessions.map(\.id), [a.id])
        XCTAssertEqual(palette.selectedIndex, 0)
    }

    func test_refreshSnapshot_noOpWhenClosed() {
        let palette = CommandPalette()
        let a = makeLive(name: "a")

        palette.refreshSnapshot(sessions: [a], paneTitles: [:], lastTouched: [:])

        XCTAssertEqual(palette.sessions.count, 0)
    }

    func test_sharedTmuxBuilderPreservesOrderNamesAndPaneTitlePrecedence() {
        let windows = CommandPaletteTmuxSnapshot.buildWindows([
            TmuxController.WindowInfo(
                id: WindowId(7), index: 4, windowName: "agent work", activePaneId: PaneId(11),
                activePaneTitle: "host", activePaneTitleIsDefault: true,
                panes: [
                    .init(id: PaneId(11), title: "host", titleIsDefault: true, currentCommand: "sh"),
                    .init(id: PaneId(12), title: " README ", currentCommand: "sh"),
                    .init(id: PaneId(13), currentCommand: "htop"),
                    .init(id: PaneId(14)),
                ]
            ),
            TmuxController.WindowInfo(id: WindowId(2), index: 9, windowName: "logs"),
        ]) { paneID in
            [PaneId(11): "claude", PaneId(12): "codex"][paneID]
        }

        XCTAssertEqual(windows.map(\.id), [WindowId(7), WindowId(2)])
        XCTAssertEqual(windows.map(\.position), [0, 1])
        XCTAssertEqual(windows.map(\.tmuxIndex), [4, 9])
        XCTAssertEqual(windows[0].title, "claude")
        XCTAssertEqual(windows[0].renameSeed, "agent work")
        XCTAssertEqual(windows[0].panes.map(\.title), ["claude", "README", "htop", "agent work"])
        XCTAssertEqual(windows[0].panes[0].command, "sh")
    }

    func test_sharedTmuxBuilderKeepsExplicitTitlesAndDropsAbsentAgentFallback() {
        let window = TmuxController.WindowInfo(
            id: WindowId(7), windowName: "sh", activePaneId: PaneId(11),
            activePaneTitle: "Release checklist",
            panes: [.init(id: PaneId(11), title: "Release checklist", currentCommand: "sh")]
        )
        let titled = CommandPaletteTmuxSnapshot.buildWindows([window]) { _ in "codex" }
        XCTAssertEqual(titled[0].title, "Release checklist")
        XCTAssertEqual(titled[0].panes[0].title, "Release checklist")

        var untitled = window
        untitled.activePaneTitle = nil
        untitled.panes[0].title = nil
        let bound = CommandPaletteTmuxSnapshot.buildWindows([untitled]) { _ in "codex" }
        XCTAssertEqual(bound[0].title, "codex")
        XCTAssertEqual(bound[0].panes[0].title, "codex")
        let unbound = CommandPaletteTmuxSnapshot.buildWindows([untitled]) { _ in nil }
        XCTAssertEqual(unbound[0].title, "sh")
        XCTAssertEqual(unbound[0].panes[0].title, "sh")
    }

    func test_sharedTmuxBuilderSupportsWindowNameSearchAndStableFocusCommit() {
        let session = makeLive(name: "host")
        let windows = CommandPaletteTmuxSnapshot.buildWindows([
            TmuxController.WindowInfo(
                id: WindowId(7), windowName: "release work", activePaneId: PaneId(11),
                panes: [.init(id: PaneId(11), currentCommand: "sh")]
            ),
        ]) { _ in "claude" }
        let palette = CommandPalette()
        palette.open(sessions: [session], tmuxWindows: windows, currentSessionID: session.id)
        palette.query = "release"
        XCTAssertEqual(palette.tmuxResults.map(\.id), [.window(WindowId(7))])
        XCTAssertEqual(palette.commitResult(), .window(sessionID: session.id, windowID: WindowId(7)))

        palette.refreshSnapshot(sessions: [session], paneTitles: [:], lastTouched: [:], tmuxWindows: [])
        XCTAssertNil(palette.currentSessionID)
        XCTAssertTrue(palette.tmuxResults.isEmpty)
    }

    func test_selectedSessionAcceptsFirstHydratedWindowSnapshotWhileOpen() {
        let session = makeLive(name: "host")
        let palette = CommandPalette()
        palette.open(sessions: [session], currentSessionID: session.id, allowsTmuxMutation: false)
        XCTAssertTrue(palette.tmuxResults.isEmpty)

        let windows = CommandPaletteTmuxSnapshot.buildWindows([
            TmuxController.WindowInfo(id: WindowId(8), windowName: "deploy"),
        ]) { _ in nil }
        palette.refreshSnapshot(
            sessions: [session], paneTitles: [:], lastTouched: [:],
            tmuxWindows: windows, currentSessionID: session.id
        )
        palette.query = "deploy"
        XCTAssertEqual(palette.commitResult(), .window(sessionID: session.id, windowID: WindowId(8)))
    }

    func test_compactSwitcherOrdersHomeThenWindowsAndPaneTargets() {
        let palette = CommandPalette()
        let session = makeLive(name: "phone")
        let firstWindow = CommandPaletteTmuxWindow(
            id: WindowId(4),
            title: "shell",
            panes: [
                CommandPaletteTmuxPane(id: PaneId(8), title: "zsh", command: "zsh"),
            ]
        )
        let splitWindow = CommandPaletteTmuxWindow(
            id: WindowId(5),
            title: "work",
            panes: [
                CommandPaletteTmuxPane(id: PaneId(9), title: "editor", command: "nvim"),
                CommandPaletteTmuxPane(id: PaneId(10), title: "tests", command: "swift"),
            ]
        )

        palette.open(
            sessions: [session],
            tmuxWindows: [firstWindow, splitWindow],
            currentSessionID: session.id,
            activeWindowID: splitWindow.id,
            activePaneID: PaneId(9),
            includesHome: true
        )

        XCTAssertEqual(palette.entries.map(\.id), [
            .home,
            .window(firstWindow.id),
            .window(splitWindow.id),
            .pane(splitWindow.id, PaneId(9)),
            .pane(splitWindow.id, PaneId(10)),
            .session(session.id),
        ])
    }

    func test_compactSwitcherFiltersPaneByTitleAndCommitsStableIDs() {
        let palette = CommandPalette()
        let session = makeLive(name: "phone")
        let window = CommandPaletteTmuxWindow(
            id: WindowId(12),
            title: "work",
            panes: [
                CommandPaletteTmuxPane(id: PaneId(20), title: "editor", command: "nvim"),
                CommandPaletteTmuxPane(id: PaneId(21), title: "tests", command: "swift test"),
            ]
        )
        palette.open(
            sessions: [session],
            tmuxWindows: [window],
            currentSessionID: session.id,
            includesHome: true
        )

        palette.query = "tests"

        XCTAssertEqual(palette.entries.map(\.id), [
            .window(window.id),
            .pane(window.id, PaneId(21)),
        ])
        palette.selectedIndex = 1
        XCTAssertEqual(
            palette.commitResult(),
            .pane(sessionID: session.id, windowID: window.id, paneID: PaneId(21))
        )
    }

    func test_compactSwitcherHomeCommitIsIndependentOfSessions() {
        let palette = CommandPalette()
        palette.open(sessions: [], includesHome: true)

        XCTAssertEqual(palette.commitResult(), .home)
    }

    func test_authoritativeRefreshReplacesDragPreviewAndMutationState() {
        let palette = CommandPalette()
        let session = makeLive(name: "phone")
        let windows = [1, 2, 3].map { id in
            CommandPaletteTmuxWindow(
                id: WindowId(id),
                title: "w\(id)",
                position: id - 1,
                tmuxIndex: id,
                panes: []
            )
        }
        palette.open(
            sessions: [session],
            tmuxWindows: windows,
            currentSessionID: session.id,
            canReorderTmuxWindows: true,
            canTidyTmuxWindows: true
        )
        palette.previewMoveWindow(WindowId(1), to: 2)

        XCTAssertEqual(palette.tmuxWindows.map(\.id), [WindowId(2), WindowId(3), WindowId(1)])
        XCTAssertFalse(palette.isTmuxWindowMutationPending, "only an admitted controller operation may mark the palette pending")

        let externalOrder = [windows[2], windows[0], windows[1]]
        palette.refreshSnapshot(
            sessions: [session],
            paneTitles: [:],
            lastTouched: [:],
            tmuxWindows: externalOrder,
            currentSessionID: session.id,
            canReorderTmuxWindows: true,
            canTidyTmuxWindows: true,
            isTmuxWindowMutationPending: false,
            tmuxWindowOrderError: "remote order won"
        )

        XCTAssertEqual(palette.tmuxWindows.map(\.id), [WindowId(3), WindowId(1), WindowId(2)])
        XCTAssertFalse(palette.isTmuxWindowMutationPending)
        XCTAssertTrue(palette.canReorderTmuxWindows)
        XCTAssertTrue(palette.canTidyTmuxWindows)
        XCTAssertEqual(palette.tmuxWindowOrderError, "remote order won")
    }

    func test_refreshRepeatingTheSameTmuxStateKeepsADragPreview() {
        let palette = CommandPalette()
        let session = makeLive(name: "host")
        let windows = [1, 2, 3].map { id in
            CommandPaletteTmuxWindow(id: WindowId(id), title: "w\(id)", position: id - 1, tmuxIndex: id, panes: [])
        }
        func refresh(_ windows: [CommandPaletteTmuxWindow]) {
            palette.refreshSnapshot(
                sessions: [session], paneTitles: [:], lastTouched: [:],
                tmuxWindows: windows, currentSessionID: session.id,
                allowsTmuxMutation: true, canReorderTmuxWindows: true, canTidyTmuxWindows: true,
                isTmuxWindowMutationPending: false, tmuxWindowOrderError: nil
            )
        }
        palette.open(sessions: [session], tmuxWindows: windows, currentSessionID: session.id,
                     canReorderTmuxWindows: true, canTidyTmuxWindows: true)
        palette.previewMoveWindow(WindowId(1), to: 2)
        let generation = palette.tmuxSnapshotGeneration

        // An agent row changing refreshes the palette with the same windows.
        refresh(windows)
        XCTAssertEqual(palette.tmuxWindows.map(\.id), [WindowId(2), WindowId(3), WindowId(1)])
        XCTAssertEqual(palette.tmuxSnapshotGeneration, generation)

        var renamed = windows
        renamed[1] = CommandPaletteTmuxWindow(id: WindowId(2), title: "build", position: 1, tmuxIndex: 2, panes: [])
        refresh(renamed)
        XCTAssertEqual(palette.tmuxWindows.map(\.id), [WindowId(1), WindowId(2), WindowId(3)])
        XCTAssertEqual(palette.tmuxSnapshotGeneration, generation &+ 1)
    }

    // MARK: helpers

    private func makeLive(name: String, hostKeyOverride: String? = nil) -> LiveSession {
        let host = Host(name: name, address: "10.0.0.1", port: 22, user: "user")
        let key = hostKeyOverride ?? "ssh:user@\(host.address):22"
        return LiveSession(
            session: .ssh(SSHSession(host: host)),
            hostName: name,
            hostKey: key,
            launchMode: .autoTmux
        )
    }

}

@MainActor
final class CompactNavigationPresentationTests: XCTestCase {
    func test_regularDestinationsMapToTheirCompactPresentation() {
        let id = UUID()
        assertPresentation(nil, tab: .hosts)
        assertPresentation(.host(id), tab: .hosts)
        assertPresentation(.session(id), tab: .sessions, sessions: .sessions)
        assertPresentation(.agents, tab: .sessions, sessions: .agents)
        assertPresentation(.keys, tab: .keys, keys: .keys)
        assertPresentation(.knownHosts, tab: .keys, keys: .knownHosts)
        assertPresentation(.settings, tab: .settings)
    }

    func test_iPadOnlyTunnelsFallsBackToHostsWithoutOwningRegularSelection() {
        var presentation = CompactNavigationPresentation(tab: .settings)

        presentation.reconcile(with: .tunnels)

        XCTAssertEqual(presentation.tab, .hosts)
    }

    func test_unrelatedSubviewChoicesSurviveReconciliation() {
        var presentation = CompactNavigationPresentation(
            tab: .keys,
            sessionsView: .agents,
            keysView: .knownHosts
        )

        presentation.reconcile(with: .settings)

        XCTAssertEqual(presentation.tab, .settings)
        XCTAssertEqual(presentation.sessionsView, .agents)
        XCTAssertEqual(presentation.keysView, .knownHosts)
    }

    private func assertPresentation(
        _ selection: SidebarItem?,
        tab: CompactRootTab,
        sessions: CompactSessionsView = .sessions,
        keys: CompactKeysView = .keys,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        var presentation = CompactNavigationPresentation()
        presentation.reconcile(with: selection)
        XCTAssertEqual(presentation.tab, tab, file: file, line: line)
        XCTAssertEqual(presentation.sessionsView, sessions, file: file, line: line)
        XCTAssertEqual(presentation.keysView, keys, file: file, line: line)
    }
}
