// Tessera/AgentCenterV2/AgentTranscriptSelection.swift
//
// "Open in Artifacts" and "Reveal in Files" on text selected in an Agent
// Center thread transcript: the terminal selection menu's two path actions,
// with the same gates, resolution and miss messages. The decision and the
// actions live here; `AgentTranscriptEditMenuHook` adds the items to the
// system edit menu, scoped by the marker below to the transcript's scroll
// view. Nothing here connects or reconnects a session: Files work needs the
// thread's bound session to be connected already.

import SwiftUI
import UIKit
import TesseraArtifactsCore
import TesseraCore

// MARK: - Decision

/// What a thread offers its transcript's selection menu. Read when the menu
/// opens and again when an item fires, so a session that dropped in between
/// gets a miss rather than a connection.
struct AgentTranscriptSelectionThread: Equatable {
    /// The thread's host. Artifact tabs belong to it, as edit cards' do.
    let hostID: UUID
    /// The bound live session, when the thread has a terminal binding.
    var boundSessionID: UUID?
    /// That session's transport is connected. Resolving over Files and
    /// revealing in its Files panel both need it.
    var sessionConnected: Bool
    /// The bound pane's current directory, when the app knows it.
    var directory: String?
    /// An artifacts opener is installed (none in previews and extensions).
    var canOpenArtifacts: Bool

    var revealSessionID: UUID? { sessionConnected ? boundSessionID : nil }
}

enum AgentTranscriptSelectionItem: String, CaseIterable {
    case openInArtifacts
    case revealInFiles

    /// The terminal's own menu titles.
    var title: String {
        switch self {
        case .openInArtifacts: return String(localized: "Open in Artifacts")
        case .revealInFiles: return String(localized: "Reveal in Files")
        }
    }
}

enum AgentTranscriptSelectionPolicy {
    enum Kind: Equatable {
        /// A link to a port on the host's own loopback.
        case link
        /// Plausibly a remote path, by the terminal's gate.
        case path
        case other
    }

    /// Longest selection worth classifying. Paths and links are short; a
    /// swipe over a whole reply must stay as cheap as an ordinary copy.
    static let maximumSelectionUTF8 = 4_096

    static func kind(of selection: String) -> Kind {
        guard selection.utf8.count <= maximumSelectionUTF8 else { return .other }
        let trimmed = selection.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .other }
        switch ArtifactsLinkClassifier.classify(trimmed) {
        case .remoteLoopback:
            return .link
        case .external, .refused:
            // A link is never a path, even though it contains slashes.
            return .other
        case .unsupported:
            break
        }
        // Other schemes (file://, ftp://, ssh://) are links too.
        guard trimmed.range(of: #"^[A-Za-z][A-Za-z0-9+.\-]*://"#, options: .regularExpression) == nil,
              RemotePathResolver.isPlausiblePath(trimmed) else { return .other }
        return .path
    }

    /// The items for one selection, in menu order. Empty keeps the system
    /// menu exactly as it was.
    static func items(
        for selection: String, thread: AgentTranscriptSelectionThread?
    ) -> [AgentTranscriptSelectionItem] {
        guard let thread else { return [] }
        switch kind(of: selection) {
        case .link:
            return thread.canOpenArtifacts ? [.openInArtifacts] : []
        case .path:
            var items: [AgentTranscriptSelectionItem] = []
            if thread.canOpenArtifacts { items.append(.openInArtifacts) }
            if thread.revealSessionID != nil { items.append(.revealInFiles) }
            return items
        case .other:
            return []
        }
    }
}

// MARK: - Actions

/// Runs a chosen item. Every dependency is injected so the routing is
/// testable without a session, and so the host-free fixture can stand in a
/// mock Files bridge.
@MainActor
struct AgentTranscriptSelectionPerformer {
    /// The thread as it is now.
    var thread: () -> AgentTranscriptSelectionThread?
    var openArtifact: ((ArtifactOpenRequest) -> Void)?
    /// The Files bridge the bound session's own panel uses (the terminal
    /// connects it on a selection action the same way).
    var bridge: (_ sessionID: UUID) -> (any FileBridging)?
    /// Asks that session to reveal `directory` in its Files panel and
    /// switches to it, as Agent Center's "open terminal" does.
    var reveal: (_ sessionID: UUID, _ directory: String) -> Void
    /// Agent Center's notice surface.
    var report: (String) -> Void
    /// Ends the text selection once an item has acted. It runs after the
    /// action because resigning can rebuild the input views synchronously
    /// (1.8 s on a fresh simulator process), and it resigns only a
    /// transcript's read-only selection: a reveal may already have moved
    /// focus to the terminal.
    var clearSelection: () -> Void = {
        guard let responder = UIResponder.agentSelectionFirstResponder() as? UIView,
              AgentTranscriptSelectionRegistry.context(enclosing: responder) != nil,
              AgentTranscriptEditMenuHook.selectedText(of: responder) != nil else { return }
        responder.resignFirstResponder()
    }

    func perform(_ item: AgentTranscriptSelectionItem, selection raw: String) async {
        guard let thread = thread() else { return }
        let selection = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        switch AgentTranscriptSelectionPolicy.kind(of: selection) {
        case .link:
            // Exactly the terminal's page request; the store plans the
            // forward over a session that is already connected, or shows
            // the tab offline. Nothing connects here.
            guard item == .openInArtifacts, let openArtifact,
                  let request = ArtifactTerminalLinkRouting.request(
                      for: selection, hostID: thread.hostID,
                      sessionID: thread.boundSessionID, canOpenArtifact: true
                  ) else { return }
            openArtifact(request)
            clearSelection()
        case .path:
            if let sessionID = thread.revealSessionID, let bridge = bridge(sessionID) {
                await resolveOverFiles(item, selection: selection, thread: thread, sessionID: sessionID, bridge: bridge)
            } else {
                openWithoutFiles(item, selection: selection, thread: thread)
            }
        case .other:
            return
        }
    }

    /// Connected session: the terminal's route, over the same bridge.
    private func resolveOverFiles(
        _ item: AgentTranscriptSelectionItem, selection: String,
        thread: AgentTranscriptSelectionThread, sessionID: UUID, bridge: any FileBridging
    ) async {
        let resolution: RemotePathResolution
        do {
            try await bridge.connect()
            resolution = try await RemotePathResolver.resolveSelection(
                selection, bridge: bridge, cwd: thread.directory)
        } catch {
            report((error as? FileBridgeError)?.errorDescription ?? error.localizedDescription)
            return
        }
        switch (resolution, item) {
        case (.file(let entry), .openInArtifacts):
            guard let openArtifact else { return }
            openArtifact(ArtifactOpenRequest(
                hostID: thread.hostID, target: .file(path: entry.path),
                origin: .terminalSelection, sessionID: sessionID
            ))
            clearSelection()
        case (.file(let entry), .revealInFiles):
            reveal(sessionID, (entry.path as NSString).deletingLastPathComponent)
            clearSelection()
        case (.directory(let path), _):
            // A directory opens in Files, as the terminal's does.
            reveal(sessionID, path)
            clearSelection()
        }
    }

    /// No connected session: only the host-level opener, which never
    /// connects. An absolute path opens as the host's file tab (it loads
    /// once Files is connected); anything that needs the host to anchor it
    /// is a miss.
    private func openWithoutFiles(
        _ item: AgentTranscriptSelectionItem, selection: String, thread: AgentTranscriptSelectionThread
    ) {
        guard item == .openInArtifacts, let openArtifact else {
            report(FileBridgeError.notConnected.errorDescription ?? "")
            return
        }
        let candidates = RemotePathResolver.pathCandidates(from: selection)
        guard let candidate = candidates.first else {
            report(String(localized: "Selection doesn't look like a path."))
            return
        }
        // No bridge, so no home: `~` can't anchor without the host.
        guard let absolute = candidates.lazy
            .compactMap({ RemotePathResolver.expand($0, home: nil, cwd: thread.directory) }).first else {
            report(candidate.hasPrefix("~")
                ? FileBridgeError.notConnected.errorDescription ?? ""
                : RemotePathResolver.noDirectorySignalMessage(for: candidate))
            return
        }
        openArtifact(ArtifactOpenRequest(
            hostID: thread.hostID, target: .file(path: absolute),
            origin: .terminalSelection, sessionID: thread.boundSessionID
        ))
        clearSelection()
    }

    /// The live thread, read from the presentation model and the sessions.
    static func liveThread(
        _ threadID: AgentThreadID,
        model: AgentCenterV2PresentationModel,
        sessions: SessionRegistry?,
        canOpenArtifacts: Bool
    ) -> AgentTranscriptSelectionThread? {
        let detail = model.selectedThreadForDetail
        guard let snapshot = model.threadSnapshots[threadID]
                ?? (detail?.summary.id == threadID ? detail : nil) else { return nil }
        let binding = snapshot.binding
        let live = binding.flatMap { sessions?.session(for: $0.liveSessionID) }
        return AgentTranscriptSelectionThread(
            hostID: threadID.hostID,
            boundSessionID: binding?.liveSessionID,
            sessionConnected: live?.session.terminalSession.state == .connected,
            directory: AgentRailPolicy.threadWorkingDirectory(
                snapshot, hostID: threadID.hostID, sessions: sessions, known: model.threadFilesDirectories),
            canOpenArtifacts: canOpenArtifacts
        )
    }
}

// MARK: - Transcript marker

/// One transcript's menu context. The marker owns it and registers it
/// against the transcript's `UIScrollView` weakly on both sides, so it
/// neither retains nor outlives the view.
@MainActor
final class AgentTranscriptSelectionContext: NSObject {
    var thread: () -> AgentTranscriptSelectionThread? = { nil }
    var perform: (AgentTranscriptSelectionItem, String) -> Void = { _, _ in }
}

@MainActor
enum AgentTranscriptSelectionRegistry {
    private static let contexts = NSMapTable<UIScrollView, AgentTranscriptSelectionContext>.weakToWeakObjects()
    private static var registered = 0

    /// The edit-menu hook bails out on this before any other work.
    static var hasTranscripts: Bool { registered > 0 }

    static func register(_ context: AgentTranscriptSelectionContext, for scrollView: UIScrollView) {
        if contexts.object(forKey: scrollView) == nil { registered += 1 }
        contexts.setObject(context, forKey: scrollView)
    }

    static func unregister(_ context: AgentTranscriptSelectionContext, from scrollView: UIScrollView) {
        guard contexts.object(forKey: scrollView) === context else { return }
        contexts.removeObject(forKey: scrollView)
        registered = max(0, registered - 1)
    }

    /// The context of the first marked scroll view above `view`. Every
    /// superview is walked: an inner scroll view (a code block) may come
    /// before the transcript's own.
    static func context(enclosing view: UIView?) -> AgentTranscriptSelectionContext? {
        var ancestor = view
        while let current = ancestor {
            if let scrollView = current as? UIScrollView, let context = contexts.object(forKey: scrollView) {
                return context
            }
            ancestor = current.superview
        }
        return nil
    }
}

/// Marks the enclosing transcript scroll view, the same one
/// `AgentTranscriptScrollProbe` observes, and installs the menu hook.
private struct AgentTranscriptSelectionMarker: UIViewRepresentable {
    var thread: () -> AgentTranscriptSelectionThread?
    var perform: (AgentTranscriptSelectionItem, String) -> Void

    func makeUIView(context: Context) -> MarkerView { MarkerView() }

    func updateUIView(_ view: MarkerView, context: Context) {
        view.context.thread = thread
        view.context.perform = perform
        view.attach()
    }

    static func dismantleUIView(_ view: MarkerView, coordinator: ()) { view.detach() }

    final class MarkerView: UIView {
        let context = AgentTranscriptSelectionContext()
        private weak var scrollView: UIScrollView?

        override init(frame: CGRect) {
            super.init(frame: frame)
            isUserInteractionEnabled = false
            isAccessibilityElement = false
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            attach()
        }

        func attach() {
            guard window != nil else { detach(); return }
            AgentTranscriptEditMenuHook.installIfNeeded()
            var ancestor = superview
            var found: UIScrollView?
            while let view = ancestor {
                if let candidate = view as? UIScrollView { found = candidate; break }
                ancestor = view.superview
            }
            guard found !== scrollView else { return }
            detach()
            scrollView = found
            if let found { AgentTranscriptSelectionRegistry.register(context, for: found) }
        }

        func detach() {
            if let scrollView { AgentTranscriptSelectionRegistry.unregister(context, from: scrollView) }
            scrollView = nil
        }
    }
}

#if DEBUG
/// Host-free fixture stand-ins: a connected session with a known directory
/// and a mock Files bridge. Production never sets it.
struct AgentTranscriptSelectionFixture {
    var sessionConnected = true
    var directory: String?
    var bridge: (any FileBridging)?
}

private struct AgentTranscriptSelectionFixtureKey: EnvironmentKey {
    static let defaultValue: AgentTranscriptSelectionFixture? = nil
}

extension EnvironmentValues {
    var agentTranscriptSelectionFixture: AgentTranscriptSelectionFixture? {
        get { self[AgentTranscriptSelectionFixtureKey.self] }
        set { self[AgentTranscriptSelectionFixtureKey.self] = newValue }
    }
}
#endif

/// Placed behind the transcript's rows. Reads the app's sessions, Files
/// bridges and artifacts opener only when the menu opens or an item fires.
struct AgentTranscriptSelectionScope: View {
    let model: AgentCenterV2PresentationModel
    let threadID: AgentThreadID
    @Environment(SessionRegistry.self) private var sessions: SessionRegistry?
    @Environment(FileBridgeRegistry.self) private var fileBridges: FileBridgeRegistry?
    @Environment(\.openArtifact) private var openArtifact
    #if DEBUG
    @Environment(\.agentTranscriptSelectionFixture) private var fixture
    #endif

    var body: some View {
        let performer = makePerformer()
        AgentTranscriptSelectionMarker(thread: performer.thread) { item, text in
            #if DEBUG
            NSLog("TESSERA_AGENT_SELECTION action=%@ selectionLength=%ld", item.rawValue, text.count)
            #endif
            Task { @MainActor in await performer.perform(item, selection: text) }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func makePerformer() -> AgentTranscriptSelectionPerformer {
        let model = model
        let threadID = threadID
        let sessions = sessions
        let fileBridges = fileBridges
        let opener = openArtifact.map { action in { (request: ArtifactOpenRequest) in action(request) } }
        var performer = AgentTranscriptSelectionPerformer(
            thread: {
                AgentTranscriptSelectionPerformer.liveThread(
                    threadID, model: model, sessions: sessions, canOpenArtifacts: opener != nil)
            },
            openArtifact: opener,
            bridge: { sessionID in
                guard let fileBridges, let live = sessions?.session(for: sessionID) else { return nil }
                switch live.session {
                case .ssh(let session):
                    return fileBridges.bridge(for: session.host, requireBiometric: session.requireBiometric,
                                              isSecureEnclave: session.isSecureEnclave)
                case .mosh(let session):
                    return fileBridges.bridge(for: session.host, requireBiometric: session.requireBiometric,
                                              isSecureEnclave: session.isSecureEnclave)
                }
            },
            reveal: { sessionID, directory in
                sessions?.requestFilesReveal(sessionID: sessionID, directory: directory)
                model.onAction?(.openTerminal(threadID))
            },
            report: { model.reportUnavailable($0) }
        )
        #if DEBUG
        if let fixture {
            performer.thread = {
                guard var thread = AgentTranscriptSelectionPerformer.liveThread(
                    threadID, model: model, sessions: nil, canOpenArtifacts: opener != nil) else { return nil }
                thread.sessionConnected = fixture.sessionConnected && thread.boundSessionID != nil
                thread.directory = fixture.directory
                return thread
            }
            performer.bridge = { _ in fixture.bridge }
            performer.reveal = { sessionID, directory in
                NSLog("TESSERA_AGENT_SELECTION reveal session=%@ directory=%@", sessionID.uuidString, directory)
                model.reportUnavailable("fixture: reveal \(directory) in Files")
            }
        }
        #endif
        return performer
    }
}
