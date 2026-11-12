import Foundation
import Observation
import XCTest
@testable import Tessera

@MainActor
final class SessionRailActionsTests: XCTestCase {
    private func actions(_ id: UUID, called: @escaping (String) -> Void = { _ in }) -> SessionRailActions {
        SessionRailActions(
            sessionID: id,
            canCreateTmuxWindow: true,
            findOpen: false,
            filesOpen: false,
            hasForwarding: true,
            hasContinuity: true,
            filesConnectUnprompted: false,
            openSwitcher: { called("switcher") },
            createTmuxWindow: { called("new") },
            toggleFind: { called("find") },
            toggleFiles: { called("files") },
            showForwarding: { called("forwarding") },
            showContinuity: { called("continuity") },
            disconnect: { called("disconnect") }
        )
    }

    private func state(_ actions: SessionRailActions, active: Bool) -> SessionRailActionState {
        SessionRailActionState(
            sessionID: actions.sessionID,
            isActive: active,
            canCreateTmuxWindow: actions.canCreateTmuxWindow,
            findOpen: actions.findOpen,
            filesOpen: actions.filesOpen,
            filesConnectUnprompted: actions.filesConnectUnprompted,
            filesDocked: false,
            hasForwarding: actions.hasForwarding,
            hasContinuity: actions.hasContinuity,
            sourceIdentity: ObjectIdentifier(self),
            forwarderIdentity: nil
        )
    }

    func testStartsEmptyAndWithdrawBeforePublishIsHarmless() {
        let center = SessionRailActionCenter()
        XCTAssertNil(center.actions)
        center.withdraw(sessionID: UUID())
        XCTAssertNil(center.actions)
    }

    func testPublishPreservesEveryActionAndCapability() throws {
        let center = SessionRailActionCenter()
        let id = UUID()
        var calls: [String] = []
        center.publish(actions(id) { calls.append($0) }, for: id)
        let published = try XCTUnwrap(center.actions)
        XCTAssertEqual(published.sessionID, id)
        XCTAssertTrue(published.canCreateTmuxWindow)
        XCTAssertFalse(published.findOpen)
        XCTAssertFalse(published.filesOpen)
        XCTAssertTrue(published.hasForwarding)
        XCTAssertTrue(published.hasContinuity)
        published.openSwitcher()
        published.createTmuxWindow()
        published.toggleFind()
        published.toggleFiles()
        published.showForwarding()
        published.showContinuity()
        published.disconnect()
        XCTAssertEqual(calls, ["switcher", "new", "find", "files", "forwarding", "continuity", "disconnect"])
    }

    func testReplaceThenOldSessionWithdrawKeepsTheSelectedSession() {
        let center = SessionRailActionCenter()
        let a = UUID(), b = UUID()
        center.publish(actions(a), for: a)
        center.publish(actions(b), for: b)
        center.withdraw(sessionID: a)
        XCTAssertEqual(center.actions?.sessionID, b)
        center.withdraw(sessionID: b)
        XCTAssertNil(center.actions)
    }

    func testWithdrawThenReplaceAndLateDisappearHaveTheSameResult() {
        let center = SessionRailActionCenter()
        let a = UUID(), b = UUID()
        center.publish(actions(a), for: a)
        center.withdraw(sessionID: a)
        center.publish(actions(b), for: b)
        center.withdraw(sessionID: a)
        XCTAssertEqual(center.actions?.sessionID, b)
    }

    func testRepublishSameSessionReplacesFlagsAndClosuresTogether() {
        let center = SessionRailActionCenter()
        let id = UUID()
        var calls: [String] = []
        center.publish(actions(id) { calls.append("old " + $0) }, for: id)
        var replacement = actions(id) { calls.append("new " + $0) }
        replacement.canCreateTmuxWindow = false
        replacement.findOpen = true
        replacement.filesOpen = true
        replacement.hasForwarding = false
        replacement.hasContinuity = false
        center.publish(replacement, for: id)
        XCTAssertEqual(center.actions?.canCreateTmuxWindow, false)
        XCTAssertEqual(center.actions?.findOpen, true)
        XCTAssertEqual(center.actions?.filesOpen, true)
        XCTAssertEqual(center.actions?.hasForwarding, false)
        XCTAssertEqual(center.actions?.hasContinuity, false)
        center.actions?.toggleFind()
        XCTAssertEqual(calls, ["new find"])
    }

    func testMismatchedPublisherCannotReplaceAnotherSession() {
        let center = SessionRailActionCenter()
        let a = UUID(), b = UUID()
        center.publish(actions(a), for: a)
        center.publish(actions(b), for: a)
        XCTAssertEqual(center.actions?.sessionID, a)
    }

    func testActiveAndInactiveEdgesAreSafeInEitherOrder() {
        for publishFirst in [false, true] {
            let center = SessionRailActionCenter()
            let a = actions(UUID()), b = actions(UUID())
            state(a, active: true).synchronize(a, previousSessionID: nil, with: center)
            if publishFirst {
                state(b, active: true).synchronize(b, previousSessionID: nil, with: center)
                state(a, active: false).synchronize(a, previousSessionID: a.sessionID, with: center)
            } else {
                state(a, active: false).synchronize(a, previousSessionID: a.sessionID, with: center)
                state(b, active: true).synchronize(b, previousSessionID: nil, with: center)
            }
            XCTAssertEqual(center.actions?.sessionID, b.sessionID)
        }
    }

    func testIdentityReplacementWithdrawsPreviousIdentity() {
        let center = SessionRailActionCenter()
        let a = actions(UUID()), b = actions(UUID())
        state(a, active: true).synchronize(a, previousSessionID: nil, with: center)
        state(b, active: false).synchronize(b, previousSessionID: a.sessionID, with: center)
        XCTAssertNil(center.actions)
        state(b, active: true).synchronize(b, previousSessionID: b.sessionID, with: center)
        center.withdraw(sessionID: a.sessionID)
        XCTAssertEqual(center.actions?.sessionID, b.sessionID)
    }

    func testEveryRailFieldAndSourceReplacementInvalidatesPublication() {
        let original = state(actions(UUID()), active: true)
        var changes: [SessionRailActionState] = []
        var changed = original; changed.sessionID = UUID(); changes.append(changed)
        changed = original; changed.isActive.toggle(); changes.append(changed)
        changed = original; changed.canCreateTmuxWindow.toggle(); changes.append(changed)
        changed = original; changed.findOpen.toggle(); changes.append(changed)
        changed = original; changed.filesOpen.toggle(); changes.append(changed)
        changed = original; changed.filesConnectUnprompted.toggle(); changes.append(changed)
        changed = original; changed.filesDocked.toggle(); changes.append(changed)
        changed = original; changed.hasForwarding.toggle(); changes.append(changed)
        changed = original; changed.hasContinuity.toggle(); changes.append(changed)
        let source = NSObject()
        changed = original; changed.sourceIdentity = ObjectIdentifier(source); changes.append(changed)
        changed = original; changed.forwarderIdentity = ObjectIdentifier(source); changes.append(changed)
        for change in changes { XCTAssertNotEqual(original, change) }
    }

    func testPublicationIsObservableAndForeignWithdrawalDoesNotNotify() {
        let center = SessionRailActionCenter()
        let id = UUID()
        let notification = expectation(description: "rail publication observed")
        withObservationTracking {
            _ = center.actions
        } onChange: {
            notification.fulfill()
        }
        center.withdraw(sessionID: UUID())
        center.publish(actions(id), for: id)
        wait(for: [notification], timeout: 1)
    }

    func testWindowCreationUsesTheCompactBarsDisabledRules() {
        for control in [false, true] {
            for degraded in [false, true] {
                for windows in [false, true] {
                    for peer in [false, true] {
                        let allowed = SessionRailPolicy.canCreateTmuxWindow(
                            controlActive: control, degraded: degraded,
                            hasWindows: windows, controlledElsewhere: peer
                        )
                        XCTAssertEqual(allowed, control && !degraded && windows && !peer)
                    }
                }
            }
        }
    }

    func testRailReserves28PointsAndOrdinaryHeightsStayExact() {
        for height: CGFloat in [26, 32, 44, 48, 60] {
            XCTAssertEqual(SessionRailPolicy.reservedHeight(railMode: true, regularHeight: height), 28)
            XCTAssertEqual(SessionRailPolicy.reservedHeight(railMode: false, regularHeight: height), height)
        }
    }

    func testSwitcherUsesOnlyTheSelectedSessionsOpenerAndOtherwiseFallsBack() {
        let selected = UUID()
        var calls: [String] = []
        let published = actions(selected) { calls.append($0) }
        SessionRailPolicy.openSwitcher(sessionID: selected, actions: published) { calls.append("shell") }
        XCTAssertEqual(calls, ["switcher"])
        for (id, candidate): (UUID?, SessionRailActions?) in [
            (selected, nil), (UUID(), published), (nil, published), (nil, nil)
        ] {
            SessionRailPolicy.openSwitcher(sessionID: id, actions: candidate) { calls.append("shell") }
        }
        XCTAssertEqual(calls, ["switcher", "shell", "shell", "shell", "shell"])
    }

    func testPublishedOpenerKeepsTheSessionsNoticeRepairAndFocusRequest() {
        let id = UUID()
        let palette = CommandPalette()
        let center = SessionRailActionCenter()
        let switcher = SessionRailSwitcher()
        let notice = CommandPaletteNotice(title: "integration needs repair", message: "repair the hook", actionLabel: "repair")
        var repairs = 0
        switcher.open = {
            palette.open(sessions: [], currentSessionID: id, notice: notice, onNoticeAction: { repairs += 1 })
        }
        var published = actions(id)
        published.openSwitcher = { switcher.open() }
        center.publish(published, for: id)
        let initialFocus = palette.focusRequestToken
        center.actions?.openSwitcher()
        XCTAssertEqual(palette.notice, notice)
        XCTAssertEqual(palette.currentSessionID, id)
        XCTAssertEqual(palette.focusRequestToken, initialFocus &+ 1)
        palette.performNoticeAction()
        XCTAssertEqual(repairs, 1)
        XCTAssertFalse(palette.isOpen)

        // The mounted chrome refreshes the opener without changing the cheap
        // action-state comparison or republishing every closure on the rail.
        switcher.open = { palette.open(sessions: [], currentSessionID: id) }
        center.actions?.openSwitcher()
        XCTAssertNil(palette.notice)
        XCTAssertEqual(palette.focusRequestToken, initialFocus &+ 2)
    }
}

#if canImport(UIKit)
import UIKit
import SwiftTerm

@MainActor
final class SessionDuoInputTests: XCTestCase {
    private final class Recorder: NSObject, TerminalViewDelegate {
        var writes: [[UInt8]] = []
        var admitted: [UInt8] = []
        var admitsInput = true
        func send(source: TerminalView, data: ArraySlice<UInt8>) {
            writes.append(Array(data))
            if admitsInput { admitted.append(contentsOf: data) }
        }
        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {}
        func setTerminalTitle(source: TerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func scrolled(source: TerminalView, position: Double) {}
        func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {}
        func bell(source: TerminalView) {}
        func clipboardCopy(source: TerminalView, content: Data) {}
        func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    }

    private func terminal() -> (TerminalBox, TesseraResponderAwareTerminalView, Recorder) {
        let view = TesseraResponderAwareTerminalView(frame: CGRect(x: 0, y: 0, width: 900, height: 600))
        view.layoutIfNeeded()
        let recorder = Recorder()
        view.terminalDelegate = recorder
        let box = TerminalBox(traceLabel: "duo-test")
        box.attach(view)
        return (box, view, recorder)
    }

    private func mirror(_ view: TerminalView) -> String {
        guard let range = view.textRange(from: view.beginningOfDocument, to: view.endOfDocument) else { return "" }
        return view.text(in: range) ?? ""
    }

    private func snapshot(_ option: AgentPromptOption) -> SwipePadAgentSnapshot {
        SwipePadAgentSnapshot(
            agentID: AgentInstanceID(sessionID: UUID(), paneID: 7),
            profileID: SwipePadProfile.builtInClaudeCodeID,
            profileName: "Claude Code",
            status: .waitingForInput,
            prompt: AgentPrompt(signature: "duo-prompt", summary: "continue?", options: [option]),
            statusChangedAt: .distantPast,
            detectedAt: .distantPast,
            providerSessionID: "duo-test",
            agentPID: 123
        )
    }

    func testDroppedTextUsesOneModeAwarePasteAndPreservesClipboard() {
        let previous = UIPasteboard.general.items
        defer { UIPasteboard.general.items = previous }
        for bracketed in [false, true] {
            let (box, view, recorder) = terminal()
            view.feed(text: bracketed ? "\u{1b}[?2004h" : "\u{1b}[?2004l")
            view.insertText("old ")
            recorder.writes = []
            UIPasteboard.general.string = "user clipboard"
            SessionDuoInput.paste("one\r\ntwo\n", into: box, allowed: true)
            let text = bracketed ? "\u{1b}[200~one\r\ntwo\n\u{1b}[201~" : "one\r\ntwo\n"
            XCTAssertEqual(recorder.writes, [Array(text.utf8)])
            XCTAssertEqual(mirror(view), "")
            XCTAssertEqual(UIPasteboard.general.string, "user clipboard")
        }
    }

    func testDeniedDropClearsMirrorWithoutWritingOrChangingClipboard() {
        let (box, view, recorder) = terminal()
        view.insertText("old ")
        recorder.writes = []
        let clipboard = UIPasteboard.general.items
        SessionDuoInput.paste("never send", into: box, allowed: false)
        XCTAssertTrue(recorder.writes.isEmpty)
        XCTAssertEqual(mirror(view), "")
        XCTAssertEqual(UIPasteboard.general.items as NSArray, clipboard as NSArray)
    }

    func testAuthorityRefusalDropsTheEntireBracketedPaste() {
        let (box, view, recorder) = terminal()
        view.feed(text: "\u{1b}[?2004h")
        recorder.admitsInput = false
        SessionDuoInput.paste("one\ntwo", into: box, allowed: true)
        XCTAssertEqual(recorder.writes, [Array("\u{1b}[200~one\ntwo\u{1b}[201~".utf8)])
        XCTAssertTrue(recorder.admitted.isEmpty)
        XCTAssertEqual(mirror(view), "")
    }

    func testReplyUsesTheSwipePadAnswerRouteAndClearsMirror() async {
        let (box, view, _) = terminal()
        view.insertText("old ")
        let option = AgentPromptOption(id: 2, label: "yes", responseMacro: "2↵", isDefault: true)
        let displayed = snapshot(option)
        let context = SwipePadAgentContext()
        context.publish(displayed)
        let answered = expectation(description: "same prompt answer route")
        context.onAnswer = { actual, selected in
            XCTAssertEqual(actual, displayed)
            XCTAssertEqual(selected, option)
            answered.fulfill()
        }
        SessionDuoInput.reply(option, displayed: displayed, context: context, box: box, allowed: true)
        XCTAssertEqual(mirror(view), "")
        await fulfillment(of: [answered], timeout: 1)
    }

    func testStaleAndGatedRepliesNeverAnswerAndStillClearMirror() async {
        let option = AgentPromptOption(id: 1, label: "yes", responseMacro: "y", isDefault: true)
        for stale in [false, true] {
            let (box, view, _) = terminal()
            view.insertText("old ")
            let displayed = snapshot(option)
            let context = SwipePadAgentContext()
            context.publish(stale ? nil : displayed)
            context.onAnswer = { _, _ in XCTFail("stale or gated reply answered") }
            SessionDuoInput.reply(option, displayed: displayed, context: context, box: box, allowed: stale)
            await Task.yield()
            XCTAssertEqual(mirror(view), "")
        }
    }

    func testTopBarKeepsTheExistingHeightOutsideRailMode() {
        for height: Double in [26, 32, 44] {
            XCTAssertEqual(SessionTopBar.reservedHeight(pillHeight: height, compact: true), 60)
            XCTAssertEqual(SessionTopBar.reservedHeight(pillHeight: height, compact: false), max(height + 16, 44))
            XCTAssertEqual(SessionTopBar.reservedHeight(pillHeight: height, compact: true, railMode: true), 28)
        }
    }
}

@MainActor
final class SessionTerminalDropUploadTests: XCTestCase {
    @MainActor @Observable
    final class Bridge: FileBridging {
        let key = FileBridgeKey(user: "duo", address: "unused.invalid", port: 22)
        var state: FileBridgeState = .connected
        let homeDirectory: String? = "/home/duo"
        var suppressIdleTeardown = false
        var connectCalls = 0
        var disconnectCalls = 0
        var uploaded: [String] = []
        var renamed: [String] = []
        var files: [String: RemoteFileEntry] = [:]
        var dropDuringUpload = false
        var didUpload: (() -> Void)?

        func connect() async throws { connectCalls += 1; state = .connected }
        func disconnect() async { disconnectCalls += 1; state = .idle }
        func listDirectory(_ path: String) async throws -> [RemoteFileEntry] {
            files.values.filter { ($0.path as NSString).deletingLastPathComponent == path }
        }
        func realPath(_ path: String) async throws -> String { path }
        func createDirectory(_ path: String) async throws {}
        func setPermissions(_ permissions: UInt16, at path: String) async throws {}
        func rename(from oldPath: String, to newPath: String) async throws {
            renamed.append(newPath)
            files.removeValue(forKey: oldPath)
            files[newPath] = RemoteFileEntry(name: (newPath as NSString).lastPathComponent, path: newPath,
                                             kind: .file, size: 3, modified: nil, permissions: 0o600)
        }
        func removeFile(_ path: String) async throws { files.removeValue(forKey: path) }
        func removeDirectory(_ path: String) async throws {}
        func download(remotePath: String, to localURL: URL, progress: TransferProgressHandler?) async throws {}
        func upload(localURL: URL, to remotePath: String, progress: TransferProgressHandler?) async throws {
            if dropDuringUpload { state = .dropped; throw FileBridgeError.notConnected }
            uploaded.append(remotePath)
            files[remotePath] = RemoteFileEntry(name: (remotePath as NSString).lastPathComponent, path: remotePath,
                                                kind: .file, size: 3, modified: nil, permissions: 0o600)
            didUpload?()
        }
        func exec(_ command: String, inShell: Bool) async throws -> String { "" }
    }

    /// Fixture for terminalDropTarget's ownership handoff. Coordinated reads
    /// belong to its tests; these exercise the session's already-staged input.
    private func handedOffCopy(of source: URL) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tessera-staging", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let copy = directory.appendingPathComponent(source.lastPathComponent)
        try FileManager.default.copyItem(at: source, to: copy)
        return copy
    }

    func testStagedFilesUsePasteNamingAndThePanelsQueueInDragOrder() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("fixture.sql")
        try Data("sql".utf8).write(to: source)
        let copies = try [handedOffCopy(of: source), handedOffCopy(of: source)]
        let bridge = Bridge()
        let existing = ["/srv/fixture.sql", "/home/duo/\(RemoteFilesConstants.tempDirectory)/fixture.sql"].map {
            RemoteFileEntry(name: "fixture.sql", path: $0, kind: .file, size: 77, modified: nil, permissions: 0o600)
        }
        existing.forEach { bridge.files[$0.path] = $0 }
        let queue = TransferQueue(bridge: bridge)
        let panel = FilesPanelController()
        panel.configureFileActions(transfers: queue, hostFolderName: "duo-test")
        var injected: [String] = []
        let completed = expectation(description: "both paths injected in order")
        XCTAssertTrue(FilesPanelController.handleTerminalDrop(
            stagedURLs: copies, queue: queue,
            inject: { path in
                injected.append(path)
                if injected.count == copies.count { completed.fulfill() }
            },
            reportFailure: { XCTFail($0) }
        ))
        XCTAssertEqual(panel.transfers?.items.map(\.id), queue.items.map(\.id))
        XCTAssertEqual(queue.items.map(\.localURL), copies)
        XCTAssertTrue(queue.operations.values.allSatisfy {
            if case .pasteUpload = $0 { return true }; return false
        })
        XCTAssertEqual(Set(queue.items.map(\.displayName)).count, copies.count)
        XCTAssertTrue(queue.items.allSatisfy {
            $0.displayName.hasPrefix(RemoteFilesConstants.pastePrefix) && $0.displayName != "fixture.sql"
        })
        await fulfillment(of: [completed], timeout: 2)
        XCTAssertEqual(injected, queue.items.compactMap(\.resolvedRemotePath))
        XCTAssertEqual(bridge.renamed, injected)
        XCTAssertTrue(injected.allSatisfy {
            ($0 as NSString).deletingLastPathComponent == "/home/duo/" + RemoteFilesConstants.tempDirectory
        })
        XCTAssertFalse(bridge.renamed.contains("/srv/fixture.sql"))
        existing.forEach { XCTAssertEqual(bridge.files[$0.path], $0, "an original basename must never be replaced") }
        XCTAssertTrue(copies.allSatisfy { !FileManager.default.fileExists(atPath: $0.deletingLastPathComponent().path) })
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        XCTAssertFalse(panel.isOpen)
    }

    func testRegistryQueueIsSharedVisibleAndCancellableThroughFiles() async throws {
        let registry = FileBridgeRegistry()
        let host = Host(address: "unused.invalid", user: "duo")
        let bridge = registry.bridge(for: host, requireBiometric: false, isSecureEnclave: false)
        let queue = registry.transferQueue(for: bridge)
        XCTAssertTrue(queue === registry.transferQueue(for: bridge))
        XCTAssertTrue(queue === registry.existingTransferQueue(for: FileBridgeKey(host: host)))
        let panel = FilesPanelController()
        panel.configureFileActions(transfers: queue, hostFolderName: "duo-test")
        XCTAssertTrue(FilesPanelController.handleTerminalDrop(
            stagedURLs: [URL(fileURLWithPath: "/unused/fixture.sql")], queue: queue,
            inject: { _ in XCTFail("cancelled path injected") }, reportFailure: { XCTFail($0) }
        ))
        let item = try XCTUnwrap(panel.transfers?.items.first)
        XCTAssertTrue(panel.transfers?.cancel(item, reason: .user) == true)
        await item.awaitFinished()
        XCTAssertEqual(item.phase, .cancelled)
        XCTAssertEqual(bridge.state, .idle, "cancellation before the drain must never dial")
    }

    func testFailedPasteUploadReportsTheShippedFailureAndReleasesStaging() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("fixture.sql")
        try Data("sql".utf8).write(to: source)
        let staged = try handedOffCopy(of: source)
        let bridge = Bridge()
        bridge.dropDuringUpload = true
        let queue = TransferQueue(bridge: bridge)
        let failed = expectation(description: "drop failure surfaced")
        FilesPanelController.handleTerminalDrop(
            stagedURLs: [staged], queue: queue, inject: { _ in XCTFail("failed path injected") },
            reportFailure: { message in
                XCTAssertEqual(message, FileBridgeError.notConnected.localizedDescription)
                failed.fulfill()
            }
        )
        await fulfillment(of: [failed], timeout: 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.deletingLastPathComponent().path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }

    func testDiscardNeverRemovesAnOriginalFile() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("original.sql")
        try Data("sql".utf8).write(to: source)
        TerminalDropStaging.discard([source])
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }

}
#endif
