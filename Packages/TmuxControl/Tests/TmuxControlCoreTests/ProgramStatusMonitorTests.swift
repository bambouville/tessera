import Foundation
import Dispatch
import XCTest
@testable import TmuxControlCore

final class ProgramStatusMonitorTests: XCTestCase {
    private final class TokenCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [[UInt64]] = []

        func append(_ tokens: [UInt64]) {
            lock.lock()
            defer { lock.unlock() }
            storage.append(tokens)
        }

        var sequences: [[UInt64]] {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
    }

    private let pane = ProgramStatusTerminalKey.pane(PaneId(1))

    private func bytes(_ body: String) -> [UInt8] { Array("\u{1B}]7501;\(body)\u{7}".utf8) }

    @discardableResult
    private func feed(_ body: String, to monitor: inout ProgramStatusMonitor,
                      terminal: ProgramStatusTerminalKey = .raw) -> [UInt8] {
        monitor.feed(bytes(body)[...], terminal: terminal)
    }

    /// The runtime's revision moves on every published topology change and
    /// survives resets; each fixture topology is a fresh one.
    private var topologyRevision: UInt64 = 0

    private func topology(_ commands: [(Int, String?)], hydrated: Bool = true, revision: UInt64? = nil) -> TmuxSnapshot {
        topologyRevision += 1
        return TmuxSnapshot(sessionID: SessionId(0), sessionName: "test", activeWindowID: WindowId(0),
                            windows: [.init(id: WindowId(0), panes: commands.map {
                                .init(id: PaneId($0.0), currentCommand: $0.1)
                            })], authority: .unknown, isWindowListHydrated: hydrated,
                            revision: revision ?? topologyRevision)
    }

    private func batch(_ messages: [TmuxMessage] = [], commands: [(Int, String?)] = [(1, "cargo")],
                       hydrated: Bool = true, revision: UInt64? = nil) -> TmuxRuntimeBatch {
        TmuxRuntimeBatch(messages: messages, paneOutputs: [], correlationEvents: [],
                         snapshot: topology(commands, hydrated: hydrated, revision: revision))
    }

    func testQueriesOnlyReplyForEnabledRawSupportingTerminalInOrder() {
        for answers in [false, true] {
            var monitor = ProgramStatusMonitor(answersQueries: answers)
            XCTAssertEqual(feed("?", to: &monitor), answers ? ProgramStatusReply.query : [])
            XCTAssertEqual(feed("?", to: &monitor, terminal: pane), [])
            let chunk = bytes("?") + bytes("state=done") + bytes("?")
            XCTAssertEqual(monitor.feed(chunk[...], terminal: .raw), answers ? ProgramStatusReply.query + ProgramStatusReply.query : [])
            XCTAssertEqual(monitor.revision, 1)
            monitor.isEnabled = false
            XCTAssertEqual(feed("?", to: &monitor), [])
        }
    }

    func testAppInheritanceNearestAncestorAndTerminalIsolation() {
        var monitor = ProgramStatusMonitor(answersQueries: false)
        feed("state=idle:app=root", to: &monitor)
        feed("state=idle:id=a:app=parent", to: &monitor)
        feed("state=working:id=a/b", to: &monitor)
        feed("state=working:id=a/b/c:app=own", to: &monitor)
        feed("state=working:id=ab/child", to: &monitor)
        feed("state=working:id=other/child", to: &monitor, terminal: pane)
        let raw = monitor.snapshot().terminal(.raw)!
        XCTAssertEqual(raw.entries.map(\.app), ["root", "parent", "parent", "own", "root"])
        XCTAssertNil(monitor.snapshot().terminal(pane)!.entries[0].app)
        feed("state=clear:id=a", to: &monitor)
        XCTAssertEqual(monitor.snapshot().terminal(.raw)!.entries.map(\.idPath), [[], ["ab", "child"]])
        feed("state=idle", to: &monitor)
        XCTAssertTrue(monitor.snapshot().terminal(.raw)!.entries.allSatisfy { $0.app == nil })
    }

    func testDisplayProjectionAndSortedTerminalKeys() {
        var monitor = ProgramStatusMonitor(answersQueries: false)
        let title = Data(" \u{202E}Build\u{200B}  package ".utf8).base64EncodedString()
        let message = Data(" a\u{2066}b  c ".utf8).base64EncodedString()
        feed("state=working:id=z:title=\(title):msg=\(message)", to: &monitor, terminal: .pane(PaneId(10)))
        feed("state=idle", to: &monitor, terminal: .pane(PaneId(2)))
        feed("state=idle", to: &monitor)
        let snapshot = monitor.snapshot()
        XCTAssertEqual(snapshot.terminals.map(\.key), [.raw, .pane(PaneId(2)), .pane(PaneId(10))])
        XCTAssertEqual(snapshot.terminal(.pane(PaneId(10)))!.entries[0].title, "Build package")
        XCTAssertEqual(snapshot.terminal(.pane(PaneId(10)))!.entries[0].message, "ab c")
        XCTAssertNil(snapshot.terminal(.pane(PaneId(99))))
        XCTAssertFalse(ProgramStatusTerminalKey.raw < .raw)
        XCTAssertFalse(ProgramStatusTerminalKey.pane(PaneId(2)) < .raw)
    }

    func testAttentionPrecedenceRootThenNewestAndFallback() {
        var monitor = ProgramStatusMonitor(answersQueries: false)
        feed("state=idle", to: &monitor)
        feed("state=done:id=done", to: &monitor)
        XCTAssertEqual(monitor.snapshot().terminal(.raw)!.attention, .finished)
        feed("state=error:id=error", to: &monitor)
        XCTAssertEqual(monitor.snapshot().terminal(.raw)!.attention, .failed)
        feed("state=blocked:id=first:kind=auth", to: &monitor)
        feed("state=blocked:id=newest:kind=question", to: &monitor)
        var snapshot = monitor.snapshot().terminal(.raw)!
        XCTAssertEqual(snapshot.attention, .needsInput(.question))
        XCTAssertEqual(snapshot.primaryEntry?.idPath, ["newest"])
        feed("state=blocked:kind=permission", to: &monitor)
        feed("state=blocked:id=last", to: &monitor)
        snapshot = monitor.snapshot().terminal(.raw)!
        XCTAssertEqual(snapshot.primaryEntry?.idPath, [])
        XCTAssertEqual(snapshot.attention, .needsInput(.permission))
        monitor.markAllHistorical()
        XCTAssertNil(monitor.snapshot().terminal(.raw)!.attention)
        XCTAssertEqual(monitor.snapshot().terminal(.raw)!.primaryEntry?.idPath, [])
        feed("state=clear", to: &monitor)
        feed("state=idle:id=first", to: &monitor)
        feed("state=working:id=latest", to: &monitor)
        XCTAssertEqual(monitor.snapshot().terminal(.raw)!.primaryEntry?.idPath, ["latest"])
        XCTAssertGreaterThan(ProgramStatusAttention.needsInput(nil).precedence, ProgramStatusAttention.failed.precedence)
        XCTAssertGreaterThan(ProgramStatusAttention.failed.precedence, ProgramStatusAttention.finished.precedence)
    }

    func testAcknowledgementTokensBindEpisodesAndLeaveNewerResultsUnread() {
        var monitor = ProgramStatusMonitor(answersQueries: false)
        feed("state=done:id=a", to: &monitor)
        let seen = monitor.snapshot().terminal(.raw)!.latestUnreadResultToken!
        feed("state=error:id=b", to: &monitor)
        XCTAssertTrue(monitor.acknowledge(terminal: .raw, through: seen))
        var entries = monitor.snapshot().terminal(.raw)!.entries
        XCTAssertFalse(entries[0].isUnreadResult)
        XCTAssertTrue(entries[1].isUnreadResult)
        feed("state=error:id=a:msg=VXBkYXRl", to: &monitor)
        entries = monitor.snapshot().terminal(.raw)!.entries
        XCTAssertEqual(entries[0].resultToken, seen)
        XCTAssertFalse(entries[0].isUnreadResult)
        feed("state=working:id=a", to: &monitor)
        feed("state=done:id=a", to: &monitor)
        XCTAssertTrue(monitor.snapshot().terminal(.raw)!.entries[0].isUnreadResult)
        let latest = monitor.snapshot().terminal(.raw)!.latestUnreadResultToken!
        XCTAssertGreaterThan(latest, seen)
        XCTAssertTrue(monitor.acknowledge(terminal: .raw, through: latest))
        XCTAssertNil(monitor.snapshot().terminal(.raw)!.latestUnreadResultToken)
        XCTAssertFalse(monitor.acknowledge(terminal: .raw, through: latest))
        XCTAssertFalse(monitor.acknowledge(terminal: pane, through: latest))
    }

    func testTokensIncreaseAcrossReplacementMonitorsAndCopies() {
        var original = ProgramStatusMonitor(answersQueries: false)
        feed("state=done", to: &original)
        let oldToken = original.snapshot().terminal(.raw)!.latestUnreadResultToken!
        var replacement = ProgramStatusMonitor(answersQueries: false)
        feed("state=done", to: &replacement)
        let newToken = replacement.snapshot().terminal(.raw)!.latestUnreadResultToken!
        XCTAssertGreaterThan(newToken, oldToken)
        XCTAssertFalse(replacement.acknowledge(terminal: .raw, through: oldToken))
        XCTAssertEqual(replacement.snapshot().terminal(.raw)!.attention, .finished)
        var copy = replacement
        feed("state=error:id=child", to: &copy)
        let copyToken = copy.snapshot().terminal(.raw)!.latestUnreadResultToken!
        feed("state=error:id=child", to: &replacement)
        XCTAssertGreaterThan(copyToken, newToken)
        XCTAssertGreaterThan(replacement.snapshot().terminal(.raw)!.latestUnreadResultToken!, copyToken)
        XCTAssertEqual(replacement.revision, 2)
        XCTAssertEqual(original.revision, 1)
    }

    func testConcurrentMonitorsAllocateUniqueIncreasingTokens() {
        let collector = TokenCollector()
        let bytes = Array("\u{1B}]7501;state=done\u{7}".utf8)
        DispatchQueue.concurrentPerform(iterations: 64) { _ in
            var monitor = ProgramStatusMonitor(answersQueries: false)
            var tokens: [UInt64] = []
            for _ in 0..<8 {
                _ = monitor.feed(bytes[...], terminal: .raw)
                tokens.append(monitor.snapshot().terminal(.raw)!.entries[0].updateToken)
            }
            collector.append(tokens)
        }
        let sequences = collector.sequences
        let tokens = sequences.flatMap { $0 }
        XCTAssertEqual(tokens.count, 512)
        XCTAssertEqual(Set(tokens).count, tokens.count)
        for sequence in sequences {
            for (previous, next) in zip(sequence, sequence.dropFirst()) { XCTAssertGreaterThan(next, previous) }
        }
        var monitor = ProgramStatusMonitor(answersQueries: false)
        _ = monitor.feed(bytes[...], terminal: .raw)
        XCTAssertGreaterThan(monitor.snapshot().terminal(.raw)!.entries[0].updateToken, tokens.max()!)
    }

    func testRawTransportLossRearmsAcknowledgedResult() {
        var monitor = ProgramStatusMonitor(answersQueries: true)
        feed("state=done", to: &monitor)
        let seen = monitor.snapshot().terminal(.raw)!.latestUnreadResultToken!
        XCTAssertTrue(monitor.acknowledge(terminal: .raw, through: seen))
        monitor.noteTransportLost()
        XCTAssertTrue(monitor.snapshot().terminal(.raw)!.entries[0].isHistorical)
        feed("state=done", to: &monitor)
        let entry = monitor.snapshot().terminal(.raw)!.entries[0]
        XCTAssertGreaterThan(entry.resultToken!, seen)
        XCTAssertTrue(entry.isUnreadResult)
        XCTAssertFalse(monitor.acknowledge(terminal: .raw, through: seen))
        XCTAssertEqual(entry.attention, .finished)
    }

    func testPanePauseRearmsAcknowledgedResult() {
        var monitor = ProgramStatusMonitor(answersQueries: false)
        monitor.observe(batch: batch([.output(paneId: PaneId(1), data: bytes("state=done"))]))
        let seen = monitor.snapshot().terminal(pane)!.latestUnreadResultToken!
        XCTAssertTrue(monitor.acknowledge(terminal: pane, through: seen))
        monitor.observe(batch: batch([.pause(paneId: PaneId(1))]))
        XCTAssertTrue(monitor.snapshot().terminal(pane)!.entries[0].isHistorical)
        monitor.observe(batch: batch([.output(paneId: PaneId(1), data: bytes("state=error"))]))
        let entry = monitor.snapshot().terminal(pane)!.entries[0]
        XCTAssertGreaterThan(entry.resultToken!, seen)
        XCTAssertTrue(entry.isUnreadResult)
        XCTAssertFalse(monitor.acknowledge(terminal: pane, through: seen))
        XCTAssertEqual(entry.attention, .failed)
    }

    func testInvisibleAndWhitespaceOnlyDisplayTextBecomesAbsent() {
        var monitor = ProgramStatusMonitor(answersQueries: false)
        for text in ["\u{206A}", " \u{034F}\u{115F}\u{E0001} ", " \u{00A0}\u{2003} "] {
            let encoded = Data(text.utf8).base64EncodedString()
            feed("state=blocked:app=cargo:title=\(encoded):msg=\(encoded)", to: &monitor)
            let entry = monitor.snapshot().terminal(.raw)!.entries[0]
            XCTAssertNil(entry.title)
            XCTAssertNil(entry.message)
            XCTAssertEqual(entry.app, "cargo")
        }
    }

    func testInvalidClearAndOverwrittenMetadataLeaveRecordsUntouched() {
        var monitor = ProgramStatusMonitor(answersQueries: false)
        feed("state=blocked:app=cargo", to: &monitor)
        let original = monitor.snapshot()
        for body in ["state=clear:msg=Cg==", "state=clear:title=Y:title=YQ==",
                     "state=done:app=\(String(repeating: "a", count: 33)):app=cargo"] {
            feed(body, to: &monitor)
            XCTAssertEqual(monitor.snapshot(), original, body)
        }
    }

    func testPromptAndRISLifetimeAndRetainedPartialScanner() {
        var monitor = ProgramStatusMonitor(answersQueries: false)
        for state in ProgramStatusState.allCases { feed("state=\(state.rawValue):id=\(state.rawValue)", to: &monitor) }
        _ = monitor.feed(Array("\u{1B}]133;A\u{7}".utf8)[...], terminal: .raw)
        XCTAssertEqual(monitor.snapshot().terminal(.raw)!.entries.map(\.state), [.done, .error])
        _ = monitor.feed(Array("\u{1B}c\u{1B}]750".utf8)[...], terminal: .raw)
        XCTAssertTrue(monitor.snapshot().terminals.isEmpty)
        _ = monitor.feed(Array("1;state=done\u{7}".utf8)[...], terminal: .raw)
        XCTAssertEqual(monitor.snapshot().terminal(.raw)!.entries[0].state, .done)
    }

    func testGapResetsPartialScannerAndHistoricalRequiresFreshIDReport() {
        var monitor = ProgramStatusMonitor(answersQueries: false)
        feed("state=blocked:id=a", to: &monitor, terminal: pane)
        feed("state=done:id=b", to: &monitor, terminal: pane)
        _ = monitor.feed(Array("\u{1B}]7501;state=".utf8)[...], terminal: pane)
        monitor.noteStreamGap(terminal: pane)
        _ = monitor.feed(Array("error\u{7}".utf8)[...], terminal: pane)
        var terminal = monitor.snapshot().terminal(pane)!
        XCTAssertEqual(terminal.entries.count, 2)
        XCTAssertTrue(terminal.entries.allSatisfy(\.isHistorical))
        XCTAssertNil(terminal.attention)
        XCTAssertNil(terminal.latestUnreadResultToken)
        feed("state=blocked:id=a:kind=auth", to: &monitor, terminal: pane)
        terminal = monitor.snapshot().terminal(pane)!
        XCTAssertFalse(terminal.entries[0].isHistorical)
        XCTAssertTrue(terminal.entries[1].isHistorical)
        XCTAssertEqual(terminal.attention, .needsInput(.auth))
        _ = monitor.feed(Array("\u{1B}]7501;state=".utf8)[...], terminal: pane)
        monitor.noteTerminalClosed(pane)
        XCTAssertNil(monitor.snapshot().terminal(pane))
        _ = monitor.feed(Array("done\u{7}".utf8)[...], terminal: pane)
        XCTAssertNil(monitor.snapshot().terminal(pane))
    }

    func testObserveMessagesWireOrderIncludesExtendedOutputPauseAndExit() {
        var monitor = ProgramStatusMonitor(answersQueries: true)
        let messages: [TmuxMessage] = [
            .output(paneId: PaneId(1), data: bytes("state=blocked:id=a")),
            .pause(paneId: PaneId(1)),
            .extendedOutput(paneId: PaneId(1), ageMs: 5, data: bytes("state=done:id=b")),
        ]
        monitor.observe(batch: batch(messages))
        var entries = monitor.snapshot().terminal(pane)!.entries
        XCTAssertTrue(entries[0].isHistorical)
        XCTAssertFalse(entries[1].isHistorical)
        let beforeExit = entries[1].resultToken!
        monitor.observe(batch: batch([.exit(reason: nil), .output(paneId: PaneId(1), data: bytes("state=error:id=b"))]))
        entries = monitor.snapshot().terminal(pane)!.entries
        XCTAssertTrue(entries[0].isHistorical)
        XCTAssertFalse(entries[1].isHistorical)
        XCTAssertEqual(entries[1].state, .error)
        XCTAssertGreaterThan(entries[1].resultToken!, beforeExit)
        feed("state=done", to: &monitor)
        monitor.observe(batch: batch([.exit(reason: "lost")]))
        XCTAssertTrue(monitor.snapshot().terminals.flatMap(\.entries).allSatisfy(\.isHistorical))
    }

    func testHydratedPaneRemovalAndCargoToShellHeuristic() {
        var monitor = ProgramStatusMonitor(answersQueries: false)
        let messages = ProgramStatusState.allCases.map {
            TmuxMessage.output(paneId: PaneId(1), data: bytes("state=\($0.rawValue):id=\($0.rawValue)"))
        }
        monitor.observe(batch: batch(messages))
        monitor.observe(batch: batch(commands: [(1, "-zsh")]))
        for entry in monitor.snapshot().terminal(pane)!.entries {
            XCTAssertEqual(entry.isHistorical, entry.state != .done && entry.state != .error)
        }
        monitor.observe(batch: batch(commands: []))
        XCTAssertNil(monitor.snapshot().terminal(pane))
    }

    func testUnchangedTopologyRevisionSkipsTheDiff() {
        var monitor = ProgramStatusMonitor(answersQueries: false)
        monitor.observe(batch: batch([.output(paneId: PaneId(1), data: bytes("state=working"))], revision: 7))
        // An output-only batch republishes the same topology revision.
        monitor.observe(batch: batch(commands: [(1, "zsh")], revision: 7))
        XCTAssertFalse(monitor.snapshot().terminal(pane)!.entries[0].isHistorical)
    }

    func testTransportLossKeepsHistoryUntilHydrationThenPrunesVanishedPanes() {
        var monitor = ProgramStatusMonitor(answersQueries: false)
        let other = ProgramStatusTerminalKey.pane(PaneId(2))
        monitor.observe(batch: batch([
            .output(paneId: PaneId(1), data: bytes("state=blocked")),
            .output(paneId: PaneId(2), data: bytes("state=done")),
        ], commands: [(1, "cargo"), (2, "make")]))
        feed("state=working", to: &monitor)
        monitor.noteTransportLost()
        XCTAssertTrue(monitor.snapshot().terminals.flatMap(\.entries).allSatisfy(\.isHistorical))
        XCTAssertTrue(monitor.snapshot().terminals.allSatisfy { $0.attention == nil })
        // Reconnecting: nothing is decided before the window list hydrates.
        monitor.observe(batch: batch(commands: [], hydrated: false))
        XCTAssertEqual(monitor.snapshot().terminals.count, 3)
        monitor.observe(batch: batch(commands: [(2, "make")]))
        XCTAssertNil(monitor.snapshot().terminal(pane))
        XCTAssertTrue(monitor.snapshot().terminal(other)!.entries[0].isHistorical)
        XCTAssertTrue(monitor.snapshot().terminal(.raw)!.entries[0].isHistorical)
        // Pruning happens once; a later closure is ordinary removal.
        monitor.observe(batch: batch(commands: []))
        XCTAssertNil(monitor.snapshot().terminal(other))
        // A fresh report revives the raw terminal's record.
        feed("state=blocked", to: &monitor)
        XCTAssertEqual(monitor.snapshot().terminal(.raw)!.attention, .needsInput(nil))
    }

    func testUnhydratedTopologyDiffsIgnoredButMessagesProcessed() {
        var monitor = ProgramStatusMonitor(answersQueries: false)
        monitor.observe(batch: batch([.output(paneId: PaneId(1), data: bytes("state=blocked"))], hydrated: false))
        monitor.observe(batch: batch(commands: []))
        XCTAssertNotNil(monitor.snapshot().terminal(pane))
        monitor.observe(batch: batch(commands: [(1, "cargo")]))
        monitor.observe(batch: batch(commands: [(1, "zsh")], hydrated: false))
        XCTAssertFalse(monitor.snapshot().terminal(pane)!.entries[0].isHistorical)
        monitor.observe(batch: batch(commands: []))
        XCTAssertNotNil(monitor.snapshot().terminal(pane))
        monitor.observe(batch: batch([.pause(paneId: PaneId(1))], commands: [], hydrated: false))
        XCTAssertTrue(monitor.snapshot().terminal(pane)!.entries[0].isHistorical)
    }

    func testShellToShellAndUnknownToShellDoNotMarkHistorical() {
        for oldCommand: String? in [nil, "bash", "-fish"] {
            var monitor = ProgramStatusMonitor(answersQueries: false)
            monitor.observe(batch: batch([.output(paneId: PaneId(1), data: bytes("state=working"))], commands: [(1, oldCommand)]))
            monitor.observe(batch: batch(commands: [(1, "zsh")]))
            XCTAssertFalse(monitor.snapshot().terminal(pane)!.entries[0].isHistorical)
        }
        for shell in ProgramStatusMonitor.shellCommands {
            var monitor = ProgramStatusMonitor(answersQueries: false)
            monitor.observe(batch: batch([.output(paneId: PaneId(1), data: bytes("state=working"))]))
            monitor.observe(batch: batch(commands: [(1, "-" + shell)]))
            XCTAssertTrue(monitor.snapshot().terminal(pane)!.entries[0].isHistorical, shell)
        }
    }

    func testRevisionChangesOnlyWhenSnapshotChanges() {
        var monitor = ProgramStatusMonitor(answersQueries: true)
        XCTAssertEqual(monitor.snapshot(), .empty)
        for body in ["?", "state=unknown", "state=clear", "state=clear:id=absent"] {
            feed(body, to: &monitor)
            XCTAssertEqual(monitor.revision, 0)
        }
        monitor.noteStreamGap(terminal: pane)
        monitor.noteTerminalClosed(pane)
        monitor.markAllHistorical()
        XCTAssertEqual(monitor.revision, 0)
        feed("state=done", to: &monitor)
        XCTAssertEqual(monitor.revision, 1)
        feed("state=done", to: &monitor)
        XCTAssertEqual(monitor.revision, 2) // updateToken is visible.
        monitor.noteStreamGap(terminal: .raw)
        XCTAssertEqual(monitor.revision, 3)
        let historical = monitor.snapshot()
        let token = historical.terminal(.raw)!.entries[0].resultToken!
        XCTAssertTrue(monitor.acknowledge(terminal: .raw, through: token))
        XCTAssertEqual(monitor.snapshot(), historical)
        monitor.markAllHistorical()
        XCTAssertEqual(monitor.revision, 3)
        _ = monitor.feed(Array("ordinary output".utf8)[...], terminal: .raw)
        XCTAssertEqual(monitor.revision, 3)
        monitor.noteTerminalClosed(.raw)
        XCTAssertEqual(monitor.revision, 4)
    }

    func testDisableDiscardsStateAndPartialScannersAndKeepsTokensMonotonic() {
        var monitor = ProgramStatusMonitor(answersQueries: true)
        feed("state=done", to: &monitor)
        let token = monitor.snapshot().terminal(.raw)!.entries[0].updateToken
        _ = monitor.feed(Array("\u{1B}]7501;state=".utf8)[...], terminal: .raw)
        monitor.isEnabled = false
        XCTAssertTrue(monitor.snapshot().terminals.isEmpty)
        let revision = monitor.revision
        feed("state=working", to: &monitor)
        monitor.observe(batch: batch([.output(paneId: PaneId(1), data: bytes("state=blocked"))]))
        monitor.isEnabled = false
        XCTAssertEqual(monitor.revision, revision)
        monitor.isEnabled = true
        XCTAssertTrue(monitor.snapshot().terminals.isEmpty)
        _ = monitor.feed(Array("done\u{7}".utf8)[...], terminal: .raw)
        XCTAssertTrue(monitor.snapshot().terminals.isEmpty)
        feed("state=done", to: &monitor)
        XCTAssertGreaterThan(monitor.snapshot().terminal(.raw)!.entries[0].updateToken, token)
        XCTAssertTrue(monitor.snapshot().terminal(.raw)!.entries[0].isUnreadResult)
    }

    func testMonitorCopiesDoNotShareMutableLifetime() {
        var original = ProgramStatusMonitor(answersQueries: false)
        feed("state=blocked", to: &original)
        var copy = original
        _ = copy.feed(Array("ordinary output".utf8)[...], terminal: .raw)
        XCTAssertEqual(copy.snapshot(), original.snapshot())
        copy.noteStreamGap(terminal: .raw)
        XCTAssertFalse(original.snapshot().terminal(.raw)!.entries[0].isHistorical)
        XCTAssertTrue(copy.snapshot().terminal(.raw)!.entries[0].isHistorical)
    }
}
