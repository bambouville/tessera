import XCTest
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

    func test_sessionsPrecedeAgentsRankedByUrgency() {
        let palette = CommandPalette()
        let session = makeLive(name: "session")
        let idle = makeAgent(name: "idle", status: .idle)
        let waiting = makeAgent(name: "waiting", status: .waitingForInput)
        let working = makeAgent(name: "working", status: .working)

        palette.open(sessions: [session], agents: [idle, working, waiting])

        XCTAssertEqual(palette.entries.map(\.id), [
            .session(session.id),
            .agent(waiting.id),
            .agent(working.id),
            .agent(idle.id),
        ])
    }

    func test_atPrefixScopesResultsToAgents() {
        let palette = CommandPalette()
        let session = makeLive(name: "prod-session")
        let agent = makeAgent(name: "Codex", status: .working, hostName: "prod-agent")
        palette.open(sessions: [session], agents: [agent])

        palette.query = "@ prod"

        XCTAssertEqual(palette.agentResults.map(\.id), [agent.id])
        XCTAssertTrue(palette.results.isEmpty)
        XCTAssertEqual(palette.entries.map(\.id), [.agent(agent.id)])
    }

    func test_agentQueryMatchesFullLocation() {
        let palette = CommandPalette()
        let agent = makeAgent(name: "Claude Code", status: .idle, hostName: "buildbox")
        palette.open(sessions: [], agents: [agent])

        palette.query = "window 4"

        XCTAssertEqual(palette.agentResults.map(\.id), [agent.id])
    }

    func test_commitResultReturnsAgentTarget() {
        let palette = CommandPalette()
        let agent = makeAgent(name: "Codex", status: .waitingForInput)
        palette.open(sessions: [], agents: [agent])

        XCTAssertEqual(palette.commitResult(), .agent(agent.id))
        XCTAssertNil(palette.commit())
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

    private func makeAgent(
        name: String,
        status: AgentStatus,
        hostName: String = "host"
    ) -> AgentInstance {
        let sessionID = UUID()
        let now = Date(timeIntervalSinceReferenceDate: 100)
        return AgentInstance(
            id: AgentInstanceID(sessionID: sessionID, paneID: 8),
            profileID: UUID(),
            name: name,
            providerSessionID: nil,
            location: AgentLocation(
                sessionID: sessionID,
                hostName: hostName,
                transportLabel: "ssh+tmux",
                tmuxSessionName: "work",
                windowID: 4,
                windowName: "editor",
                paneID: 8
            ),
            status: status,
            taskSummary: nil,
            outputTail: nil,
            prompt: nil,
            detectedAt: now,
            statusChangedAt: now,
            finishedAt: status == .justFinished ? now : nil,
            lastLifecycleEventAt: now,
            lastOutputAt: now,
            outputSequence: 0,
            bracketedPasteEnabled: false,
            sendInFlight: false,
            actionMessage: nil,
            actionIsError: false
        )
    }
}
