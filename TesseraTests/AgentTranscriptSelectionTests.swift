import ObjectiveC
import UIKit
import XCTest
@testable import Tessera

/// Selection + thread → menu items. Pure: no UIKit, no session.
final class AgentTranscriptSelectionPolicyTests: XCTestCase {
    private let hostID = UUID()
    private let sessionID = UUID()

    private func thread(
        bound: Bool = true, connected: Bool = true, directory: String? = "/srv/app", opener: Bool = true
    ) -> AgentTranscriptSelectionThread {
        AgentTranscriptSelectionThread(
            hostID: hostID, boundSessionID: bound ? sessionID : nil,
            sessionConnected: bound && connected, directory: directory, canOpenArtifacts: opener)
    }

    func testRemoteLoopbackLinkOffersOnlyOpenInArtifacts() {
        for link in ["http://localhost:8001/laptop.html", "  https://127.0.0.1:8443/app?x=1\n", "http://[::1]:3000"] {
            XCTAssertEqual(AgentTranscriptSelectionPolicy.kind(of: link), .link, link)
            XCTAssertEqual(AgentTranscriptSelectionPolicy.items(for: link, thread: thread()), [.openInArtifacts], link)
            // No Reveal for links, bound or not, connected or not.
            XCTAssertEqual(AgentTranscriptSelectionPolicy.items(for: link, thread: thread(bound: false)), [.openInArtifacts])
            XCTAssertEqual(AgentTranscriptSelectionPolicy.items(for: link, thread: thread(connected: false)), [.openInArtifacts])
        }
    }

    func testLinkWithoutAnOpenerOffersNothing() {
        XCTAssertEqual(AgentTranscriptSelectionPolicy.items(
            for: "http://localhost:8001/", thread: thread(opener: false)), [])
    }

    func testOtherLinksAreNeitherLinksNorPaths() {
        for text in ["https://github.com/bambouville/tessera", "http://example.com/a/b.txt",
                     "file:///etc/hosts", "ssh://user@host/srv/app", "ftp://mirror/pub/x.tar.gz"] {
            XCTAssertEqual(AgentTranscriptSelectionPolicy.kind(of: text), .other, text)
            XCTAssertEqual(AgentTranscriptSelectionPolicy.items(for: text, thread: thread()), [], text)
        }
    }

    func testAbsoluteTildeAndRelativePathsOfferBothOnAConnectedBoundThread() {
        for path in ["/etc/hosts", "~/atlas/README.md", "README.md", "src/app/main.swift", "'docs/my notes.md'",
                     "Sources/App.swift:23:5", "docs/review\n    v3.pdf"] {
            XCTAssertEqual(AgentTranscriptSelectionPolicy.kind(of: path), .path, path)
            XCTAssertEqual(AgentTranscriptSelectionPolicy.items(for: path, thread: thread()),
                           [.openInArtifacts, .revealInFiles], path)
            // The directory only matters when the action runs.
            XCTAssertEqual(AgentTranscriptSelectionPolicy.items(for: path, thread: thread(directory: nil)),
                           [.openInArtifacts, .revealInFiles], path)
        }
    }

    func testPlainProseOffersNothing() {
        for text in ["hello", "The notes are in the usual place", "  ", "", "v3", "Done."] {
            XCTAssertEqual(AgentTranscriptSelectionPolicy.items(for: text, thread: thread()), [], text)
        }
        // Over the length cap nothing is classified at all.
        let long = "/" + String(repeating: "a", count: AgentTranscriptSelectionPolicy.maximumSelectionUTF8)
        XCTAssertEqual(AgentTranscriptSelectionPolicy.items(for: long, thread: thread()), [])
    }

    func testUnboundThreadHidesRevealButKeepsOpen() {
        XCTAssertEqual(AgentTranscriptSelectionPolicy.items(for: "/etc/hosts", thread: thread(bound: false)),
                       [.openInArtifacts])
        XCTAssertNil(thread(bound: false).revealSessionID)
    }

    func testDisconnectedSessionHidesRevealButKeepsOpen() {
        XCTAssertEqual(AgentTranscriptSelectionPolicy.items(for: "/etc/hosts", thread: thread(connected: false)),
                       [.openInArtifacts])
        XCTAssertEqual(AgentTranscriptSelectionPolicy.items(for: "~/x.md", thread: thread(connected: false)),
                       [.openInArtifacts])
        XCTAssertNil(thread(connected: false).revealSessionID)
    }

    func testNoOpenerLeavesOnlyRevealAndNoThreadLeavesNothing() {
        XCTAssertEqual(AgentTranscriptSelectionPolicy.items(for: "/etc/hosts", thread: thread(opener: false)),
                       [.revealInFiles])
        XCTAssertEqual(AgentTranscriptSelectionPolicy.items(for: "/etc/hosts", thread: nil), [])
    }

    func testTitlesAreTheTerminalsOwnStrings() {
        XCTAssertEqual(AgentTranscriptSelectionItem.openInArtifacts.title, String(localized: "Open in Artifacts"))
        XCTAssertEqual(AgentTranscriptSelectionItem.revealInFiles.title, String(localized: "Reveal in Files"))
    }
}

/// The actions, against a mock Files bridge. Nothing here may connect a
/// session; the only connect is the bound, connected session's bridge.
@MainActor
final class AgentTranscriptSelectionPerformerTests: XCTestCase {
    private let hostID = UUID()
    private let sessionID = UUID()
    private var opened: [ArtifactOpenRequest] = []
    private var revealed: [(UUID, String)] = []
    private var reports: [String] = []
    private var bridgeRequests = 0
    private var cleared = 0

    override func setUp() {
        super.setUp()
        opened = []; revealed = []; reports = []; bridgeRequests = 0; cleared = 0
    }

    private func makeBridge() -> MockFileBridge {
        let notes = RemoteFileEntry(name: "README.md", path: "/home/mock/atlas/README.md", kind: .file,
                                    size: 3, modified: nil, permissions: 0o644)
        let atlas = RemoteFileEntry(name: "atlas", path: "/home/mock/atlas", kind: .directory,
                                    size: nil, modified: nil, permissions: 0o755)
        let main = RemoteFileEntry(name: "main.swift", path: "/srv/app/main.swift", kind: .file,
                                   size: 3, modified: nil, permissions: 0o644)
        return MockFileBridge(
            key: FileBridgeKey(hostID: hostID, user: "mock", address: "mock.local", port: 22),
            tree: ["/home/mock": [atlas], "/home/mock/atlas": [notes], "/srv/app": [main], "/srv": [], "/": []])
    }

    private func performer(
        bound: Bool = true, connected: Bool = true, directory: String? = "/srv/app",
        bridge: MockFileBridge? = nil, opener: Bool = true
    ) -> AgentTranscriptSelectionPerformer {
        let bridge = bridge ?? makeBridge()
        let state = AgentTranscriptSelectionThread(
            hostID: hostID, boundSessionID: bound ? sessionID : nil,
            sessionConnected: bound && connected, directory: directory, canOpenArtifacts: opener)
        return AgentTranscriptSelectionPerformer(
            thread: { state },
            openArtifact: opener ? { [unowned self] in opened.append($0) } : nil,
            bridge: { [unowned self] id in
                bridgeRequests += 1
                XCTAssertEqual(id, sessionID)
                return bridge
            },
            reveal: { [unowned self] in revealed.append(($0, $1)) },
            report: { [unowned self] in reports.append($0) },
            clearSelection: { [unowned self] in
                // The action lands first; clearing comes after it.
                XCTAssertEqual(opened.count + revealed.count, cleared + 1)
                cleared += 1
            }
        )
    }

    func testLinkOpensTheTerminalsPageRequestWithTheBoundSession() async {
        await performer().perform(.openInArtifacts, selection: " http://localhost:8001/laptop.html\n")
        XCTAssertEqual(opened, [ArtifactTerminalLinkRouting.request(
            for: "http://localhost:8001/laptop.html", hostID: hostID, sessionID: sessionID, canOpenArtifact: true)!])
        XCTAssertEqual(opened.first?.origin, .terminalLink)
        XCTAssertEqual(bridgeRequests, 0)
        XCTAssertEqual(cleared, 1)
        XCTAssertTrue(reports.isEmpty)
    }

    func testLinkOnAnUnboundOrDisconnectedThreadStillOpensWithoutAnyBridge() async {
        await performer(bound: false).perform(.openInArtifacts, selection: "http://localhost:8001/")
        await performer(connected: false).perform(.openInArtifacts, selection: "http://localhost:8001/")
        XCTAssertEqual(opened.map(\.target), [.page(scheme: "http", port: 8001, path: "/"),
                                              .page(scheme: "http", port: 8001, path: "/")])
        XCTAssertEqual(opened.map(\.sessionID), [nil, sessionID])
        XCTAssertEqual(bridgeRequests, 0)
    }

    func testAbsolutePathOpensTheResolvedFileOnTheThreadsHost() async {
        let bridge = makeBridge()
        await performer(bridge: bridge).perform(.openInArtifacts, selection: "/srv/app/main.swift")
        XCTAssertEqual(opened, [ArtifactOpenRequest(
            hostID: hostID, target: .file(path: "/srv/app/main.swift"), origin: .terminalSelection, sessionID: sessionID)])
        XCTAssertEqual(bridge.state, .connected)
        XCTAssertTrue(reports.isEmpty)
    }

    func testTildePathExpandsAgainstTheBridgesHome() async {
        await performer().perform(.openInArtifacts, selection: "~/atlas/README.md")
        XCTAssertEqual(opened.map(\.target), [.file(path: "/home/mock/atlas/README.md")])
    }

    func testRelativePathResolvesAgainstTheBoundPanesDirectory() async {
        await performer(directory: "/srv/app").perform(.openInArtifacts, selection: "main.swift")
        XCTAssertEqual(opened.map(\.target), [.file(path: "/srv/app/main.swift")])
    }

    func testRelativePathWithoutADirectoryIsTheTerminalsMiss() async {
        await performer(directory: nil).perform(.openInArtifacts, selection: "main.swift")
        XCTAssertTrue(opened.isEmpty)
        XCTAssertEqual(reports, [RemotePathResolver.noDirectorySignalMessage(for: "main.swift")])
        XCTAssertEqual(reports.first, String(localized: "Can't resolve \("main.swift") — no directory signal for relative paths."))
    }

    func testRevealOpensTheFilesParentAndADirectoryOpensItself() async {
        await performer().perform(.revealInFiles, selection: "~/atlas/README.md")
        await performer().perform(.openInArtifacts, selection: "~/atlas")
        await performer().perform(.revealInFiles, selection: "/home/mock/atlas")
        XCTAssertEqual(revealed.map { $0.0 }, [sessionID, sessionID, sessionID])
        XCTAssertEqual(revealed.map { $0.1 }, ["/home/mock/atlas", "/home/mock/atlas", "/home/mock/atlas"])
        XCTAssertTrue(opened.isEmpty)
    }

    func testMissesMatchTheTerminalsMessages() async throws {
        await performer().perform(.openInArtifacts, selection: "/srv/app/missing.swift")
        XCTAssertTrue(opened.isEmpty)
        XCTAssertEqual(reports.count, 1)

        // The terminal's selection menu over the same bridge and selection.
        let controller = FilesPanelController()
        controller.attach(bridge: makeBridge())
        var terminalMisses: [String] = []
        controller.openTerminalPath("/srv/app/missing.swift", cwd: nil, intent: .openInArtifacts,
                                    openInArtifacts: { _ in XCTFail("opened a missing file") }) { terminalMisses.append($0) }
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while terminalMisses.isEmpty, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(terminalMisses, reports)
    }

    func testDisconnectedAbsolutePathOpensTheHostTabWithoutTouchingFiles() async {
        await performer(connected: false).perform(.openInArtifacts, selection: "/srv/app/../app/main.swift")
        XCTAssertEqual(opened, [ArtifactOpenRequest(
            hostID: hostID, target: .file(path: "/srv/app/main.swift"), origin: .terminalSelection, sessionID: sessionID)])
        XCTAssertEqual(bridgeRequests, 0)
    }

    func testUnboundAbsolutePathOpensWithoutASessionHint() async {
        await performer(bound: false).perform(.openInArtifacts, selection: "/etc/hosts")
        XCTAssertEqual(opened.map(\.sessionID), [nil])
        XCTAssertEqual(opened.map(\.target), [.file(path: "/etc/hosts")])
        XCTAssertEqual(bridgeRequests, 0)
    }

    func testDisconnectedTildeAndRelativePathsAreMissesThatNeverConnect() async {
        await performer(connected: false).perform(.openInArtifacts, selection: "~/atlas/README.md")
        await performer(connected: false, directory: nil).perform(.openInArtifacts, selection: "README.md")
        XCTAssertTrue(opened.isEmpty)
        XCTAssertEqual(reports, [String(localized: "Not connected to the host."),
                                 RemotePathResolver.noDirectorySignalMessage(for: "README.md")])
        XCTAssertEqual(bridgeRequests, 0)
    }

    func testRevealAfterTheSessionDroppedIsAMissNotAConnect() async {
        await performer(connected: false).perform(.revealInFiles, selection: "/etc/hosts")
        await performer(bound: false).perform(.revealInFiles, selection: "/etc/hosts")
        XCTAssertTrue(revealed.isEmpty)
        XCTAssertEqual(reports, Array(repeating: String(localized: "Not connected to the host."), count: 2))
        XCTAssertEqual(bridgeRequests, 0)
    }

    func testProseDoesNothing() async {
        await performer().perform(.openInArtifacts, selection: "just some words")
        await performer().perform(.revealInFiles, selection: "https://example.com/a/b")
        XCTAssertTrue(opened.isEmpty)
        XCTAssertTrue(revealed.isEmpty)
        XCTAssertTrue(reports.isEmpty)
        XCTAssertEqual(bridgeRequests, 0)
    }
}

/// The UIKit side: install decision, transcript scoping, selected text.
@MainActor
final class AgentTranscriptEditMenuHookTests: XCTestCase {
    func testInstallsOnlyWhereUIWindowInheritsTheResponderImplementation() {
        XCTAssertEqual(AgentTranscriptEditMenuHook.installDecision(windowHasOwnImplementation: false), .install)
        XCTAssertEqual(AgentTranscriptEditMenuHook.installDecision(windowHasOwnImplementation: true), .refuse)
    }

    func testInstallAddsAWindowImplementationOnceAndLeavesUIResponderAlone() {
        let selector = #selector(UIResponder.buildMenu(with:))
        let responderIMP = method_getImplementation(class_getInstanceMethod(UIResponder.self, selector)!)
        AgentTranscriptEditMenuHook.installIfNeeded()
        AgentTranscriptEditMenuHook.installIfNeeded()
        XCTAssertTrue(AgentTranscriptEditMenuHook.isInstalled)
        let windowIMP = method_getImplementation(class_getInstanceMethod(UIWindow.self, selector)!)
        XCTAssertNotEqual(windowIMP, responderIMP)
        XCTAssertEqual(method_getImplementation(class_getInstanceMethod(UIResponder.self, selector)!), responderIMP)
        XCTAssertEqual(method_getImplementation(class_getInstanceMethod(UIView.self, selector)!), responderIMP)
    }

    func testScopeWalksPastInnerScrollViewsToTheMarkedTranscript() {
        let transcript = UIScrollView()
        let row = UIView()
        let codeBlock = UIScrollView()
        let text = UILabel()
        transcript.addSubview(row); row.addSubview(codeBlock); codeBlock.addSubview(text)
        let context = AgentTranscriptSelectionContext()

        XCTAssertNil(AgentTranscriptSelectionRegistry.context(enclosing: text))
        AgentTranscriptSelectionRegistry.register(context, for: transcript)
        XCTAssertTrue(AgentTranscriptSelectionRegistry.hasTranscripts)
        XCTAssertTrue(AgentTranscriptSelectionRegistry.context(enclosing: text) === context)
        XCTAssertTrue(AgentTranscriptSelectionRegistry.context(enclosing: codeBlock) === context)
        XCTAssertNil(AgentTranscriptSelectionRegistry.context(enclosing: UILabel()))

        AgentTranscriptSelectionRegistry.unregister(AgentTranscriptSelectionContext(), from: transcript)
        XCTAssertTrue(AgentTranscriptSelectionRegistry.context(enclosing: text) === context, "a stranger can't unregister")
        AgentTranscriptSelectionRegistry.unregister(context, from: transcript)
        XCTAssertNil(AgentTranscriptSelectionRegistry.context(enclosing: text))
    }

    func testRegistryHoldsNeitherTheViewNorTheContext() {
        weak var weakContext: AgentTranscriptSelectionContext?
        weak var weakScroll: UIScrollView?
        let child = UIView()
        autoreleasepool {
            let scroll = UIScrollView()
            let context = AgentTranscriptSelectionContext()
            weakContext = context; weakScroll = scroll
            AgentTranscriptSelectionRegistry.register(context, for: scroll)
            scroll.addSubview(child)
            XCTAssertNotNil(AgentTranscriptSelectionRegistry.context(enclosing: child))
            child.removeFromSuperview()
        }
        XCTAssertNil(weakContext)
        XCTAssertNil(weakScroll)
    }

    func testSelectedTextReadsOnlyReadOnlySelections() {
        let readOnly = UITextView()
        readOnly.isEditable = false
        readOnly.text = "open ~/atlas/README.md now"
        readOnly.selectedRange = NSRange(location: 5, length: 17)
        XCTAssertEqual(AgentTranscriptEditMenuHook.selectedText(of: readOnly), "~/atlas/README.md")

        readOnly.selectedRange = NSRange(location: 5, length: 0)
        XCTAssertNil(AgentTranscriptEditMenuHook.selectedText(of: readOnly))

        let editable = UITextView()
        editable.text = "~/atlas/README.md"
        editable.selectedRange = NSRange(location: 0, length: 17)
        XCTAssertNil(AgentTranscriptEditMenuHook.selectedText(of: editable), "the composer keeps its own menu")

        let field = UITextField()
        field.text = "~/atlas/README.md"
        XCTAssertNil(AgentTranscriptEditMenuHook.selectedText(of: field))
        XCTAssertNil(AgentTranscriptEditMenuHook.selectedText(of: UIView()))
    }
}

/// Agent Center's Reveal in Files hand-off to the session view.
@MainActor
final class SessionRegistryFilesRevealTests: XCTestCase {
    private func makeLive() -> LiveSession {
        let host = Host(name: "reveal", address: "10.0.0.\(Int.random(in: 1...254))", port: 22, user: "user")
        return LiveSession(session: .ssh(SSHSession(host: host)), hostName: "reveal",
                           hostKey: "ssh:user@\(host.address):22", launchMode: .autoTmux)
    }

    func testRevealIsConsumedOnceByTheShownMatchingSession() {
        let registry = SessionRegistry()
        let live = makeLive(), other = makeLive()
        registry.syncActiveSessions([live, other])
        registry.requestFilesReveal(sessionID: live.id, directory: "/srv/app")
        let token = registry.filesRevealRequest?.token
        XCTAssertNotNil(token)

        XCTAssertNil(registry.takeFilesReveal(sessionID: other.id, carrier: other.session.terminalSession, isShown: true))
        XCTAssertNil(registry.takeFilesReveal(sessionID: live.id, carrier: live.session.terminalSession, isShown: false),
                     "a hidden view waits")
        XCTAssertEqual(registry.filesRevealRequest?.token, token)
        XCTAssertEqual(registry.takeFilesReveal(sessionID: live.id, carrier: live.session.terminalSession, isShown: true),
                       "/srv/app")
        XCTAssertNil(registry.filesRevealRequest)
        XCTAssertNil(registry.takeFilesReveal(sessionID: live.id, carrier: live.session.terminalSession, isShown: true))
    }

    func testExpiredOrForeignCarrierRequestsAreDropped() {
        let registry = SessionRegistry()
        let live = makeLive(), other = makeLive()
        registry.syncActiveSessions([live, other])

        registry.requestFilesReveal(sessionID: live.id, directory: "/srv", lifetime: .seconds(1))
        XCTAssertNil(registry.takeFilesReveal(sessionID: live.id, carrier: live.session.terminalSession, isShown: true,
                                              now: .now.advanced(by: .seconds(2))))
        XCTAssertNil(registry.filesRevealRequest)

        registry.requestFilesReveal(sessionID: live.id, directory: "/srv")
        XCTAssertNil(registry.takeFilesReveal(sessionID: live.id, carrier: other.session.terminalSession, isShown: true))
        XCTAssertNil(registry.filesRevealRequest)
    }

    func testRequestForASessionThatWentAwayIsDropped() {
        let registry = SessionRegistry()
        let live = makeLive(), other = makeLive()
        registry.syncActiveSessions([live, other])
        registry.requestFilesReveal(sessionID: live.id, directory: "/srv")
        registry.syncActiveSessions([live, other])
        XCTAssertNotNil(registry.filesRevealRequest, "an unchanged set keeps it")
        registry.syncActiveSessions([other])
        XCTAssertNil(registry.filesRevealRequest)
    }

    func testOnlyLiveSessionsAndAbsoluteDirectoriesAreAccepted() {
        let registry = SessionRegistry()
        let live = makeLive()
        registry.syncActiveSessions([live])
        registry.requestFilesReveal(sessionID: UUID(), directory: "/srv")
        registry.requestFilesReveal(sessionID: live.id, directory: "relative")
        XCTAssertNil(registry.filesRevealRequest)
    }
}
